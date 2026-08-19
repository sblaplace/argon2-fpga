// SPDX-License-Identifier: MIT
// Performance bench: how fast is one argon2 lane, really?
//
// Runs the same argon2i job (p=1, m' = NBLK blocks, t = PASSES) twice:
//
//   phase IDEAL : zero-latency, infinite-bandwidth memory. This is the
//                 pure compute + FSM floor — what the lane costs even if
//                 DRAM were free (it is also ~what a BRAM-only bring-up
//                 stage 1 would see).
//   phase DDR4  : tb_ddr4_ram, a cycle-accurate DDR4-2400 channel model
//                 (tRCD/tCL/tRP/tRFC/refresh, row open/close, read-write
//                 turnaround, write response only after commit).
//
// Reported per phase:
//   * cycles per 1 KiB block (compresses happen once per block per pass)
//   * blocks/s and G/s at 200 MHz
//   * projected cand/s for the 1 GiB / t=3 reference job
//     (3 * 2^20 compresses per candidate)
//   * measured AXI traffic and port utilization (DDR4 phase)
//
// The 4-channel F1 aggregate for independent p=1 jobs is 4x the per-lane
// number (no cross-channel traffic or barriers in p=1 mode).
//
// Build/run:  make -C sim perf                       (iverilog)
//             make -C sim SIM=verilator perf         (faster)
//             make -C sim PERF_BLKS=16384 ... perf   (16 MiB working set)

`timescale 1ns / 1ps

module tb_perf #(
    parameter int NBLK   = 4096,   // working set in 1 KiB blocks (m')
    parameter int PASSES = 3,      // time cost t
    parameter int N_P    = 1,      // parallel P units in the compression G
    parameter int IDEAL_WR = 0     // experiment: DDR model with instant writes
) (
);
    localparam int NBEAT  = 16;
    localparam int ADDR_W = 64;
    localparam int ID_W   = 6;
    localparam int DATA_W = 512;
    localparam real F_MHZ  = 200.0;            // clock rate
    localparam real CAND_BLKS = 3.0 * 1048576.0; // compresses per 1 GiB t=3 guess

    // ---- clock / reset --------------------------------------------------
    logic clk, rst_n;
    always #2.5 clk = ~clk;    // 200 MHz

    logic [63:0] sim_cycles;

    // =====================================================================
    // Phase A: IDEAL memory (zero latency, infinite bandwidth)
    // =====================================================================
    logic a_start, a_busy, a_done;
    logic a_arvalid, a_arready;
    logic [ADDR_W-1:0] a_araddr;
    logic a_rvalid, a_rlast;
    logic [DATA_W-1:0] a_rdata;
    logic a_rready;
    logic a_awvalid, a_awready, a_wvalid, a_wready, a_wlast, a_bvalid, a_bready;
    logic [ADDR_W-1:0] a_awaddr;
    logic [DATA_W-1:0] a_wdata;

    logic [4:0]       a_rd_beat;
    logic             a_rd_act;
    logic [ADDR_W-1:0] a_rd_addr;
    logic [4:0]       a_wr_beat;
    logic [ADDR_W-1:0] a_wr_addr;
    logic             a_b_sent;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_rd_act  <= 1'b0;
            a_rd_beat <= 5'd0;
            a_rvalid  <= 1'b0;
            a_rlast   <= 1'b0;
            a_rdata   <= '0;
            a_wr_beat <= 5'd0;
            a_bvalid  <= 1'b0;
            a_b_sent  <= 1'b0;
        end else begin
            if (a_arvalid && a_arready && !a_rd_act) begin
                a_rd_act  <= 1'b1;
                a_rd_addr <= a_araddr;
                a_rd_beat <= 5'd0;
            end
            a_rvalid <= a_rd_act;
            if (a_rd_act) begin
                a_rdata <= {64{a_rd_beat}};   // any data; timing only
                a_rlast <= (a_rd_beat == 5'd15);
                if (a_rvalid && a_rready) begin
                    if (a_rd_beat == 5'd15) a_rd_act <= 1'b0;
                    else                    a_rd_beat <= a_rd_beat + 5'd1;
                end
            end
            if (a_wvalid && a_wready) begin
                if (a_wlast || a_wr_beat == 5'd15) begin
                    a_wr_beat <= 5'd0;
                    a_bvalid  <= 1'b1;      // B one cycle after the burst
                    a_b_sent  <= 1'b0;
                end else
                    a_wr_beat <= a_wr_beat + 5'd1;
            end
            if (a_bvalid && a_bready) a_bvalid <= 1'b0;
        end
    end
    assign a_arready = 1'b1;
    assign a_awready = 1'b1;
    assign a_wready  = 1'b1;

    // =====================================================================
    // Phase B: DDR4-2400 channel model
    // =====================================================================
    logic b_start, b_busy, b_done;
    logic b_arvalid, b_arready;
    logic [ADDR_W-1:0] b_araddr;
    logic b_rvalid, b_rlast;
    logic [DATA_W-1:0] b_rdata;
    logic b_rready;
    logic b_awvalid, b_awready, b_wvalid, b_wready, b_wlast, b_bvalid, b_bready;
    logic [ADDR_W-1:0] b_awaddr;
    logic [DATA_W-1:0] b_wdata;
    logic [63:0] ddr_cycles, ddr_busy, ddr_refresh, ddr_rd_beats, ddr_wr_beats;
    logic [63:0] ddr_rd_req, ddr_wr_req;

    // ---- fill-ctrl FSM state histograms (cycle accounting) --------------
    logic [4:0] a_state, b_state;
    longint a_hist [0:31];
    longint b_hist [0:31];
    string  st_name [0:15];

    always_ff @(posedge clk) begin
        if (rst_n) begin
            if (a_busy) a_hist[a_state] <= a_hist[a_state] + 1;
            if (b_busy) b_hist[b_state] <= b_hist[b_state] + 1;
        end
    end

    // =====================================================================
    // Two identical lanes, one per memory model
    // =====================================================================
    argon2_fill_axi #(.AXI_ADDR_W(ADDR_W), .AXI_ID_W(ID_W),
                      .AXI_DATA_W(DATA_W), .BLK_ADDR_W(32), .N_P(N_P)) u_ideal (
        .clk(clk), .rst_n(rst_n),
        .start(a_start), .busy(a_busy), .done(a_done),
        .passes(PASSES), .lanes(1), .lane_id(0),
        .lane_length(NBLK), .memory_blocks(NBLK), .type_i(2'd1),
        .sync_req(), .sync_ack(1'b1),
        .base_addr(64'd0),
        .state_o(a_state),
        .m_axi_awid(), .m_axi_awaddr(a_awaddr), .m_axi_awlen(), .m_axi_awsize(),
        .m_axi_awburst(), .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(),
        .m_axi_awqos(), .m_axi_awvalid(a_awvalid), .m_axi_awready(a_awready),
        .m_axi_wdata(a_wdata), .m_axi_wstrb(), .m_axi_wlast(a_wlast),
        .m_axi_wvalid(a_wvalid), .m_axi_wready(a_wready),
        .m_axi_bid('0), .m_axi_bresp('0), .m_axi_bvalid(a_bvalid),
        .m_axi_bready(a_bready),
        .m_axi_arid(), .m_axi_araddr(a_araddr), .m_axi_arlen(), .m_axi_arsize(),
        .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(),
        .m_axi_arqos(), .m_axi_arvalid(a_arvalid), .m_axi_arready(a_arready),
        .m_axi_rid('0), .m_axi_rdata(a_rdata), .m_axi_rresp('0),
        .m_axi_rlast(a_rlast), .m_axi_rvalid(a_rvalid), .m_axi_rready(a_rready)
    );

    argon2_fill_axi #(.AXI_ADDR_W(ADDR_W), .AXI_ID_W(ID_W),
                      .AXI_DATA_W(DATA_W), .BLK_ADDR_W(32), .N_P(N_P)) u_ddr4 (
        .clk(clk), .rst_n(rst_n),
        .start(b_start), .busy(b_busy), .done(b_done),
        .passes(PASSES), .lanes(1), .lane_id(0),
        .lane_length(NBLK), .memory_blocks(NBLK), .type_i(2'd1),
        .sync_req(), .sync_ack(1'b1),
        .base_addr(64'd0),
        .state_o(b_state),
        .m_axi_awid(), .m_axi_awaddr(b_awaddr), .m_axi_awlen(), .m_axi_awsize(),
        .m_axi_awburst(), .m_axi_awlock(), .m_axi_awcache(), .m_axi_awprot(),
        .m_axi_awqos(), .m_axi_awvalid(b_awvalid), .m_axi_awready(b_awready),
        .m_axi_wdata(b_wdata), .m_axi_wstrb(), .m_axi_wlast(b_wlast),
        .m_axi_wvalid(b_wvalid), .m_axi_wready(b_wready),
        .m_axi_bid('0), .m_axi_bresp('0), .m_axi_bvalid(b_bvalid),
        .m_axi_bready(b_bready),
        .m_axi_arid(), .m_axi_araddr(b_araddr), .m_axi_arlen(), .m_axi_arsize(),
        .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(), .m_axi_arprot(),
        .m_axi_arqos(), .m_axi_arvalid(b_arvalid), .m_axi_arready(b_arready),
        .m_axi_rid('0), .m_axi_rdata(b_rdata), .m_axi_rresp('0),
        .m_axi_rlast(b_rlast), .m_axi_rvalid(b_rvalid), .m_axi_rready(b_rready)
    );

    tb_ddr4_ram #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .NBLK(NBLK),
                  .IDEAL_WR(IDEAL_WR)) u_ddr (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid('0), .s_axi_awaddr(b_awaddr), .s_axi_awlen(8'd15),
        .s_axi_awsize(3'd6), .s_axi_awvalid(b_awvalid), .s_axi_awready(b_awready),
        .s_axi_wdata(b_wdata), .s_axi_wstrb('1), .s_axi_wlast(b_wlast),
        .s_axi_wvalid(b_wvalid), .s_axi_wready(b_wready),
        .s_axi_bid(), .s_axi_bresp(), .s_axi_bvalid(b_bvalid),
        .s_axi_bready(b_bready),
        .s_axi_arid('0), .s_axi_araddr(b_araddr), .s_axi_arlen(8'd15),
        .s_axi_arvalid(b_arvalid), .s_axi_arready(b_arready),
        .s_axi_rid(), .s_axi_rdata(b_rdata), .s_axi_rresp(),
        .s_axi_rlast(b_rlast), .s_axi_rvalid(b_rvalid), .s_axi_rready(b_rready),
        .st_cycles(ddr_cycles), .st_port_busy(ddr_busy), .st_refresh(ddr_refresh),
        .st_rd_beats(ddr_rd_beats), .st_wr_beats(ddr_wr_beats),
        .st_rd_req(ddr_rd_req), .st_wr_req(ddr_wr_req)
    );

    // ---- run one job ----------------------------------------------------
    task automatic run_job(ref logic      start_sig,
                           ref logic      busy_sig,
                           ref logic      done_sig,
                           ref longint    cyc_start,
                           ref longint    cyc_end);
        start_sig = 1'b1;
        @(posedge clk);
        start_sig = 1'b0;
        cyc_start = sim_cycles;
        while (!done_sig) begin
            @(posedge clk);
            if (sim_cycles - cyc_start > 64'd100_000_000) begin
                $display("tb_perf: TIMEOUT waiting for done");
                $finish;
            end
        end
        cyc_end = sim_cycles;
    endtask

    // ---- print an FSM cycle histogram -----------------------------------
    task automatic dump_hist(input longint h [0:31], input string who);
        longint tot;
        tot = 0;
        for (int s = 1; s <= 15; s = s + 1) tot = tot + h[s];
        $display("%s FSM cycles (excl. IDLE): %0d", who, tot);
        for (int s = 1; s <= 15; s = s + 1)
            if (h[s] != 0)
                $display("   %-12s %0d  (%0.1f%%)", st_name[s], h[s],
                         100.0 * h[s] / (tot != 0 ? tot : 1));
    endtask

    initial begin
        longint i_cyc0, i_cyc1, d_cyc0, d_cyc1;
        real    i_cyc_blk, d_cyc_blk;
        real    i_cand, d_cand;
        real    rd_gb, wr_gb, util, ref_pct;
        integer rdb32, wrb32, busy32, ref32, cyc32;
        longint d_rd0, d_wr0, d_busy0, d_ref0, d_rrq0, d_wrq0;

        clk = 1'b0;
        rst_n = 1'b0;
        a_start = 1'b0;
        b_start = 1'b0;

        st_name[1]  = "SEG_PREP";
        st_name[2]  = "ADDR_WAIT";
        st_name[3]  = "DISPATCH";
        st_name[4]  = "ISSUE_REF";
        st_name[5]  = "COLLECT_REF";
        st_name[6]  = "ISSUE_PREV";
        st_name[7]  = "COLLECT_PREV";
        st_name[8]  = "ISSUE_DEST";
        st_name[9]  = "COLLECT_DEST";
        st_name[10] = "COMPRESS";
        st_name[11] = "WRITE";
        st_name[12] = "ADVANCE";
        st_name[13] = "SLICE_SYNC";
        st_name[14] = "DREF_SETTLE";
        st_name[15] = "DEST_WAIT";

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        $display("tb_perf: m'=%0d blocks (%0d MiB), t=%0d, argon2i, p=1, 200 MHz",
                 NBLK, (NBLK >> 10), PASSES);

        // Phase A: ideal memory
        run_job(a_start, a_busy, a_done, i_cyc0, i_cyc1);
        i_cyc_blk = (i_cyc1 - i_cyc0) / (1.0 * NBLK * PASSES);
        i_cand = F_MHZ * 1e6 / (i_cyc_blk * CAND_BLKS);
        dump_hist(a_hist, "IDEAL");

        $display("IDEAL: %0d cycles, %0.1f cyc/blk, %0.3f Mblk/s, %0.3f cand/s (1 GiB t=3, one lane)",
                 i_cyc1 - i_cyc0, i_cyc_blk, F_MHZ / i_cyc_blk, i_cand);

        // Phase B: DDR4-2400 channel. Snapshot the model counters first —
        // the model runs for the whole bench (both phases), so report the
        // delta over this phase's window only.
        d_rd0 = ddr_rd_beats; d_wr0 = ddr_wr_beats; d_busy0 = ddr_busy;
        d_ref0 = ddr_refresh;
        d_rrq0 = ddr_rd_req; d_wrq0 = ddr_wr_req;
        run_job(b_start, b_busy, b_done, d_cyc0, d_cyc1);
        d_cyc_blk = (d_cyc1 - d_cyc0) / (1.0 * NBLK * PASSES);
        d_cand = F_MHZ * 1e6 / (d_cyc_blk * CAND_BLKS);

        rdb32  = 32'(ddr_rd_beats  - d_rd0);
        wrb32  = 32'(ddr_wr_beats  - d_wr0);
        busy32 = 32'(ddr_busy     - d_busy0);
        ref32  = 32'(ddr_refresh  - d_ref0);
        cyc32  = 32'(d_cyc1 - d_cyc0);

        // GB/s = beats * 64 B * (F_MHZ * 1e6 cycles/s) / cycles / 1e9
        rd_gb  = rdb32 * 64.0 * F_MHZ / 1e3 / cyc32;
        wr_gb  = wrb32 * 64.0 * F_MHZ / 1e3 / cyc32;
        util   = 100.0 * busy32 / cyc32;
        ref_pct = 100.0 * ref32 / cyc32;

        $display("DDR4 : %0d cycles, %0.1f cyc/blk, %0.3f Mblk/s, %0.3f cand/s (1 GiB t=3, one lane)",
                 d_cyc1 - d_cyc0, d_cyc_blk, F_MHZ / d_cyc_blk, d_cand);
        $display("DDR4 : %0.2f GB/s read, %0.2f GB/s write, port busy %0.1f%%, refresh %0.1f%%",
                 rd_gb, wr_gb, util, ref_pct);
        $display("DDR4 : %0d rd req, %0d wr req, %0d rd beats, %0d wr beats",
                 ddr_rd_req - d_rrq0, ddr_wr_req - d_wrq0,
                 ddr_rd_beats - d_rd0, ddr_wr_beats - d_wr0);
        $display("F1 x4 : %0.3f cand/s aggregate (4 independent channels)", 4.0 * d_cand);
        dump_hist(b_hist, "DDR4 ");

        $display("tb_perf: done");
        $finish;
    end

    // free-running cycle counter
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sim_cycles <= 64'd0;
        else        sim_cycles <= sim_cycles + 64'd1;
    end
endmodule
