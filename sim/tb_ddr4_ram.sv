// SPDX-License-Identifier: MIT
// AXI4-MM slave modeling one DDR4-2400 channel (AWS F1 sh_ddr geometry):
// 64-bit DIMM, 16 banks, 1 KiB rows, one burst = one row activation.
//
// Timing is in CLOCK CYCLES at 200 MHz (5 ns):
//   tCL  = 14 ns -> 3 cyc   read data after column command
//   tRCD = 14 ns -> 3 cyc   activate -> column command
//   tRP  = 14 ns -> 3 cyc   precharge a bank
//   tWL  = 12 ns -> 3 cyc   write data after column command
//   tRTW = 10 ns -> 2 cyc   read -> write turnaround
//   tWTR =  8 ns -> 2 cyc   write -> read turnaround
//   tRFC = 350 ns -> 70 cyc refresh
//   tREFI = 7.8 us -> 1560 cyc between refreshes
//
// Supports pipelined read command queueing (up to 4 in-flight AR requests).
// Writes are captured immediately, executed on the port when free, and
// BVALID is returned only after the write commits.
//
// Exposed counters let a perf bench report utilization and traffic.

`timescale 1ns / 1ps

module tb_ddr4_ram #(
    parameter int ADDR_W = 64,
    parameter int DATA_W = 512,
    parameter int ID_W   = 6,
    parameter int NBLK   = 8,
    // Timing (cycles @ 200 MHz), see header
    parameter int T_CL_C   = 3,
    parameter int T_RCD_C  = 3,
    parameter int T_RP_C   = 3,
    parameter int T_WL_C   = 3,
    parameter int T_RTW_C  = 2,
    parameter int T_WTR_C  = 2,
    parameter int T_RFC_C  = 70,
    parameter int T_REFI_C = 1560,
    // Write starvation bound: a pending write is forced onto the port
    // after this many cycles even if reads keep arriving.
    parameter int WR_STARVE = 64,
    // Experiment: writes commit instantly (B one cycle after the burst,
    // no port execution). Isolates the read path's effect on throughput.
    parameter int IDEAL_WR = 0
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [ID_W-1:0]         s_axi_awid,
    input  logic [ADDR_W-1:0]       s_axi_awaddr,
    input  logic [7:0]              s_axi_awlen,
    input  logic [2:0]              s_axi_awsize,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,

    input  logic [DATA_W-1:0]       s_axi_wdata,
    input  logic [DATA_W/8-1:0]     s_axi_wstrb,
    input  logic                    s_axi_wlast,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,

    output logic [ID_W-1:0]         s_axi_bid,
    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    input  logic [ID_W-1:0]         s_axi_arid,
    input  logic [ADDR_W-1:0]       s_axi_araddr,
    input  logic [7:0]              s_axi_arlen,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,

    output logic [ID_W-1:0]         s_axi_rid,
    output logic [DATA_W-1:0]       s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rlast,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready,

    // ---- statistics ----------------------------------------------------
    output logic [63:0]             st_cycles,     // total cycles
    output logic [63:0]             st_port_busy,  // port executing rd/wr/ref
    output logic [63:0]             st_refresh,    // cycles lost to refresh
    output logic [63:0]             st_rd_beats,   // data beats transferred
    output logic [63:0]             st_wr_beats,
    output logic [63:0]             st_rd_req,
    output logic [63:0]             st_wr_req
);
    localparam int NBEAT  = 16;
    localparam int ROW_W  = ADDR_W - 14;         // row = addr >> 14
    localparam int NBFIFO = NBLK * NBEAT;        // beats of storage
    localparam int AR_Q_DEPTH = 4;

    logic [DATA_W-1:0] mem [0:NBFIFO-1];

    // ---- per-bank open-row state (16 banks) ----------------------------
    logic [ROW_W-1:0] open_row [0:15];
    logic [15:0]      row_valid;

    // ---- port scheduler --------------------------------------------------
    typedef enum logic [1:0] { P_IDLE, P_RD, P_WR, P_REF } pstate_t;
    pstate_t pstate;
    logic [7:0]  pcnt;
    logic        last_was_wr;

    logic [15:0] refresh_cnt;
    logic        refresh_due;

    // ---- read capture & in-flight pipeline -------------------------------
    logic [ADDR_W-1:0] ar_q_addr [0:AR_Q_DEPTH-1];
    logic [ID_W-1:0]   ar_q_id   [0:AR_Q_DEPTH-1];
    logic [1:0]        ar_wr_ptr;
    logic [1:0]        ar_exec_ptr;
    logic [1:0]        ar_stream_ptr;
    logic [2:0]        ar_cnt;
    logic [2:0]        ar_pend_exec;
    logic [2:0]        ar_pend_stream;

    logic              rd_stream;    // R beats flowing now
    logic [4:0]        rd_beat;

    // ---- write capture ---------------------------------------------------
    logic              aw_captured;  // AW accepted, W beats arriving
    logic              wb_done;      // full W burst in, awaiting port + B
    logic              b_pending;    // port executed; BVALID held
    logic [ADDR_W-1:0] wr_addr;
    logic [4:0]        wr_beat;
    logic [ID_W-1:0]   wr_id;
    logic [15:0]       wr_starve;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    assign rd_stream    = (ar_pend_stream != 3'd0);
    assign s_axi_rvalid = rd_stream;
    assign s_axi_rlast  = (rd_beat == 5'd15);
    assign s_axi_rdata  = mem[ar_q_addr[ar_stream_ptr][31:6] + 32'(rd_beat)];
    assign s_axi_rid    = ar_q_id[ar_stream_ptr];

    assign s_axi_arready = (ar_cnt < 3'(AR_Q_DEPTH));
    assign s_axi_awready = !aw_captured;
    assign s_axi_wready  = aw_captured;
    assign s_axi_bvalid  = b_pending;
    assign s_axi_bid     = wr_id;

    // Latency for the captured read if granted this cycle.
    function automatic logic [7:0] rd_latency(input logic [ADDR_W-1:0] addr);
        logic [3:0]   bank;
        logic [ROW_W-1:0] row;
        logic [7:0]   lat;
        bank = addr[13:10];
        row  = addr[ADDR_W-1:14];
        lat  = T_CL_C[7:0];
        if (!(row_valid[bank] && open_row[bank] == row)) begin
            // precharge (if a row is open) + activate
            lat = lat + (row_valid[bank] ? T_RP_C[7:0] + T_RCD_C[7:0]
                                          : T_RCD_C[7:0]);
        end
        if (last_was_wr) lat = lat + T_WTR_C[7:0];
        return lat;
    endfunction

    function automatic logic [7:0] wr_latency(input logic [ADDR_W-1:0] addr);
        logic [3:0]   bank;
        logic [ROW_W-1:0] row;
        logic [7:0]   lat;
        bank = addr[13:10];
        row  = addr[ADDR_W-1:14];
        lat  = T_WL_C[7:0];
        if (!(row_valid[bank] && open_row[bank] == row)) begin
            lat = lat + (row_valid[bank] ? T_RP_C[7:0] + T_RCD_C[7:0]
                                          : T_RCD_C[7:0]);
        end
        if (!last_was_wr) lat = lat + T_RTW_C[7:0];
        return lat;
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pstate         <= P_IDLE;
            pcnt           <= 8'd0;
            last_was_wr    <= 1'b0;
            refresh_cnt    <= T_REFI_C[15:0];
            refresh_due    <= 1'b0;
            ar_wr_ptr      <= 2'd0;
            ar_exec_ptr    <= 2'd0;
            ar_stream_ptr  <= 2'd0;
            ar_cnt         <= 3'd0;
            ar_pend_exec   <= 3'd0;
            ar_pend_stream <= 3'd0;
            rd_beat        <= 5'd0;
            aw_captured    <= 1'b0;
            wb_done        <= 1'b0;
            b_pending      <= 1'b0;
            wr_addr        <= '0;
            wr_beat        <= 5'd0;
            wr_id          <= '0;
            wr_starve      <= 16'd0;
            for (int i = 0; i < 16; i = i + 1) begin
                open_row[i] <= '0;
            end
            row_valid <= 16'd0;
            st_cycles    <= 64'd0;
            st_port_busy <= 64'd0;
            st_refresh   <= 64'd0;
            st_rd_beats  <= 64'd0;
            st_wr_beats  <= 64'd0;
            st_rd_req    <= 64'd0;
            st_wr_req    <= 64'd0;
            for (int i = 0; i < AR_Q_DEPTH; i++) begin
                ar_q_addr[i] <= '0;
                ar_q_id[i]   <= '0;
            end
        end else begin
            logic ar_in, exec_start, exec_done, stream_beat, stream_done;

            ar_in = s_axi_arvalid && s_axi_arready;
            stream_beat = rd_stream && s_axi_rvalid && s_axi_rready;
            stream_done = stream_beat && (rd_beat == 5'd15);
            exec_start = 1'b0;
            exec_done = 1'b0;

            st_cycles <= st_cycles + 64'd1;
            if (pstate != P_IDLE) st_port_busy <= st_port_busy + 64'd1;

            // Assert refresh_due on transition to zero
            if (refresh_cnt == 16'd1) begin
                refresh_cnt <= 16'd0;
                refresh_due <= 1'b1;
            end else if (refresh_cnt != 16'd0) begin
                refresh_cnt <= refresh_cnt - 16'd1;
            end

            // ---- read AR capture ---------------------------------------
            if (ar_in) begin
                ar_q_addr[ar_wr_ptr] <= s_axi_araddr;
                ar_q_id[ar_wr_ptr]   <= s_axi_arid;
                ar_wr_ptr <= ar_wr_ptr + 2'd1;
                st_rd_req <= st_rd_req + 64'd1;
            end

            // ---- read data streaming -----------------------------------
            if (stream_beat) begin
                st_rd_beats <= st_rd_beats + 64'd1;
                if (rd_beat == 5'd15) begin
                    rd_beat <= 5'd0;
                    ar_stream_ptr <= ar_stream_ptr + 2'd1;
                end else begin
                    rd_beat <= rd_beat + 5'd1;
                end
            end

            // ---- write capture -----------------------------------------
            if (!aw_captured && s_axi_awvalid && s_axi_awready) begin
                aw_captured <= 1'b1;
                wr_addr     <= s_axi_awaddr;
                wr_id       <= s_axi_awid;
                wr_beat     <= 5'd0;
                st_wr_req   <= st_wr_req + 64'd1;
            end
            if (aw_captured && s_axi_wvalid && s_axi_wready) begin
                mem[wr_addr[31:6] + 32'(wr_beat)] <= s_axi_wdata;
                st_wr_beats <= st_wr_beats + 64'd1;
                if (s_axi_wlast || wr_beat == 5'd15) begin
                    aw_captured <= 1'b0;
                    if (IDEAL_WR) begin
                        b_pending <= 1'b1;
                    end else begin
                        wb_done <= 1'b1;
                    end
                end else begin
                    wr_beat <= wr_beat + 5'd1;
                end
            end
            if (b_pending && s_axi_bvalid && s_axi_bready)
                b_pending <= 1'b0;

            // ---- port scheduler ----------------------------------------
            case (pstate)
                P_IDLE: begin
                    if (refresh_due) begin
                        pstate      <= P_REF;
                        pcnt        <= T_RFC_C[7:0] + (rd_stream ? 8'(16 - rd_beat) : 8'd0);
                        refresh_due <= 1'b0;
                    end else if (ar_pend_exec != 3'd0 &&
                                 !(wb_done && wr_starve >= WR_STARVE[15:0])) begin
                        exec_start  = 1'b1;
                        pstate      <= P_RD;
                        pcnt        <= rd_latency(ar_q_addr[ar_exec_ptr]);
                        last_was_wr <= 1'b0;
                        row_valid[ar_q_addr[ar_exec_ptr][13:10]] <= 1'b1;
                        open_row [ar_q_addr[ar_exec_ptr][13:10]] <= ar_q_addr[ar_exec_ptr][ADDR_W-1:14];
                        ar_exec_ptr <= ar_exec_ptr + 2'd1;
                    end else if (wb_done) begin
                        pstate      <= P_WR;
                        pcnt        <= wr_latency(wr_addr) + (rd_stream ? 8'(16 - rd_beat) : 8'd0);
                        last_was_wr <= 1'b1;
                        row_valid[wr_addr[13:10]] <= 1'b1;
                        open_row [wr_addr[13:10]] <= wr_addr[ADDR_W-1:14];
                        wb_done     <= 1'b0;
                        wr_starve   <= 16'd0;
                    end
                    if (wb_done) wr_starve <= wr_starve + 16'd1;
                    else         wr_starve <= 16'd0;
                end

                P_RD: begin
                    if (pcnt != 8'd0) begin
                        pcnt <= pcnt - 8'd1;
                    end else begin
                        exec_done = 1'b1;
                        pstate    <= P_IDLE;
                    end
                end

                P_WR: begin
                    if (pcnt != 8'd0) begin
                        pcnt <= pcnt - 8'd1;
                    end else begin
                        b_pending <= 1'b1;
                        pstate    <= P_IDLE;
                    end
                end

                P_REF: begin
                    st_refresh <= st_refresh + 64'd1;
                    if (pcnt != 8'd0)
                        pcnt <= pcnt - 8'd1;
                    else begin
                        refresh_cnt <= T_REFI_C[15:0];
                        pstate      <= P_IDLE;
                    end
                end

                default: pstate <= P_IDLE;
            endcase

            // Pipeline tracking updates
            ar_cnt         <= ar_cnt + (ar_in ? 3'd1 : 3'd0) - (stream_done ? 3'd1 : 3'd0);
            ar_pend_exec   <= ar_pend_exec + (ar_in ? 3'd1 : 3'd0) - (exec_start ? 3'd1 : 3'd0);
            ar_pend_stream <= ar_pend_stream + (exec_done ? 3'd1 : 3'd0) - (stream_done ? 3'd1 : 3'd0);
        end
    end
endmodule
