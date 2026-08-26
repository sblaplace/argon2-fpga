// SPDX-License-Identifier: MIT
// Per-channel capacity ceiling: how many argon2 block-compressions can ONE
// DDR4-2400 channel actually serve per second?
//
// Why this bench exists
// ---------------------
// `tb_perf` measures ONE lane on one channel and reports the channel's port
// only ~50% busy — the lane, not the memory, is the limit. The follow-up
// question is how much room the channel has for a *second* lane sharing the
// same port (the HBM4 doc's "do not pin one candidate to one channel"
// argument, applied to the 4-channel F1 box that exists today).
//
// This bench answers it by driving `sim/tb_ddr4_ram.sv` with an idealized,
// always-ready AXI master that issues the argon2 traffic mix and never runs
// out of work:
//
//   * NRD read bursts per NWR write bursts. The default 5:3 is the t=3 mix:
//     one 1 KiB reference read per compression, one 1 KiB dest read on two of
//     three passes, one 1 KiB write per compression.
//   * read block addresses are LFSR-random (argon2's reference pattern);
//     write block addresses are sequential (the fill order), wrapping at NBLK.
//   * up to OUTSTANDING read bursts in flight (the model's AR queue is 4),
//     one write burst at a time (the model captures one AW at a time).
//
// The reported number is therefore an UPPER BOUND on per-channel cand/s: real
// lanes reach it only if arbitration and hazard gating keep the port fed. Use
// it to size lanes-per-channel, not as an achieved rate.
//
// Build/run:  make -C sim SIM=verilator ddrceil
//             make -C sim SIM=verilator CEIL_MHZ=250 ddrceil
//             make -C sim SIM=verilator CEIL_OUT=2 ddrceil
//             make -C sim SIM=verilator CEIL_NRD=1 CEIL_NWR=1 ddrceil

`timescale 1ns / 1ps

module tb_ddr4_ceiling #(
    parameter int N_P         = 1,      // unused; keeps the suite's -GN_P override uniform
    parameter int NBLK        = 4096,   // 1 KiB blocks in the channel (m')
    parameter int NRD         = 5,      // read bursts per round
    parameter int NWR         = 3,      // write bursts per round (5:3 = t=3)
    parameter int OUTSTANDING = 4,      // AR bursts in flight (model max: 4)
    parameter int NCOMP       = 24576,  // write bursts (= compressions) to run
    parameter int PERF_MHZ    = 200,    // core clock; re-tunes the DRAM model
    // Reference single-lane rate for the "how many lanes fit" line: the
    // tb_perf argon2id N_P=8 measurement at the same clock (200 MHz 1.044,
    // 250 MHz 1.239). Reporting only, not used by the master.
    parameter real LANE_CAND  = 1.044
) ();
    localparam int ADDR_W = 64;
    localparam int ID_W   = 6;
    localparam int DATA_W = 512;
    localparam int NBEAT  = 16;
    localparam real F_MHZ     = PERF_MHZ * 1.0;
    localparam real CAND_BLKS = 3.0 * 1048576.0;  // compresses per 1 GiB t=3 guess

    // DDR4-2400 timings in core cycles — identical derivation to tb_perf so
    // the two benches are directly comparable at any PERF_MHZ.
    localparam int T_CL_C   = (14  * PERF_MHZ + 999) / 1000;
    localparam int T_RCD_C  = (14  * PERF_MHZ + 999) / 1000;
    localparam int T_RP_C   = (14  * PERF_MHZ + 999) / 1000;
    localparam int T_WL_C   = (12  * PERF_MHZ + 999) / 1000;
    localparam int T_RTW_C  = (10  * PERF_MHZ + 999) / 1000;
    localparam int T_WTR_C  = (8   * PERF_MHZ + 999) / 1000;
    localparam int T_RFC_C  = (350 * PERF_MHZ + 999) / 1000;
    localparam int T_REFI_C = (7800* PERF_MHZ + 999) / 1000;

    logic clk, rst_n;
    always #(500.0/PERF_MHZ) clk = ~clk;

    // ---- AXI master / slave wiring --------------------------------------
    logic              arvalid, arready;
    logic [ADDR_W-1:0] araddr;
    logic              rvalid, rlast;
    logic [DATA_W-1:0] rdata;
    logic              awvalid, awready;
    logic [ADDR_W-1:0] awaddr;
    logic              wvalid, wready, wlast;
    logic [DATA_W-1:0] wdata;
    logic              bvalid;

    tb_ddr4_ram #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .NBLK(NBLK),
                  .T_CL_C(T_CL_C), .T_RCD_C(T_RCD_C), .T_RP_C(T_RP_C),
                  .T_WL_C(T_WL_C), .T_RTW_C(T_RTW_C), .T_WTR_C(T_WTR_C),
                  .T_RFC_C(T_RFC_C), .T_REFI_C(T_REFI_C)) u_ddr (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid('0), .s_axi_awaddr(awaddr), .s_axi_awlen(8'd15),
        .s_axi_awsize(3'd6), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb('1), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(), .s_axi_bresp(), .s_axi_bvalid(bvalid), .s_axi_bready(1'b1),
        .s_axi_arid('0), .s_axi_araddr(araddr), .s_axi_arlen(8'd15),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(), .s_axi_rdata(rdata), .s_axi_rresp(),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(1'b1),
        .st_cycles(st_cycles), .st_port_busy(st_busy), .st_refresh(st_ref),
        .st_rd_beats(st_rd_beats), .st_wr_beats(st_wr_beats),
        .st_rd_req(st_rd_req), .st_wr_req(st_wr_req)
    );

    logic [63:0] st_cycles, st_busy, st_ref, st_rd_beats, st_wr_beats;
    logic [63:0] st_rd_req, st_wr_req;

    // ---- saturating master ----------------------------------------------
    logic              run;
    logic [2:0]        ar_out;         // read bursts issued, not yet streamed
    logic [31:0]       lfsr;
    logic [31:0]       rd_credit, wr_credit;
    logic              aw_busy;
    logic [4:0]        wbeat;
    logic [ADDR_W-1:0] wr_addr_r;
    longint            n_rd, n_wr, cycles;

    logic ar_hs, r_hs, aw_hs, w_hs, b_hs, r_burst_done, refill;
    assign ar_hs = arvalid && arready;
    assign r_hs  = rvalid;                  // rready is tied high
    assign aw_hs = awvalid && awready;
    assign w_hs  = wvalid && wready;
    assign b_hs  = bvalid;                  // bready is tied high
    assign r_burst_done = r_hs && rlast;

    // Refill one round (NRD reads + NWR writes) only when both credits are
    // empty, so the long-run mix is exactly NRD:NWR regardless of which
    // engine drains faster.
    assign refill = run && (rd_credit == 32'd0) && (wr_credit == 32'd0);

    logic [31:0] rd_blk;
    always_comb rd_blk = 32'(lfsr % NBLK);

    assign arvalid = run && (rd_credit != 32'd0) && (ar_out < 3'(OUTSTANDING));
    assign araddr  = {32'd0, rd_blk} << 10;
    assign awvalid = run && (wr_credit != 32'd0) && !aw_busy;
    assign awaddr  = wr_addr_r;
    assign wvalid  = aw_busy;
    assign wdata   = {16{32'hA5A5_5A5A}};
    assign wlast   = (wbeat == 5'(NBEAT-1));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            run       <= 1'b0;
            lfsr      <= 32'hACE1_2345;
            rd_credit <= 32'd0;
            wr_credit <= 32'd0;
            ar_out    <= 3'd0;
            aw_busy   <= 1'b0;
            wbeat     <= 5'd0;
            wr_addr_r <= '0;
            n_rd      <= 64'd0;
            n_wr      <= 64'd0;
            cycles    <= 64'd0;
        end else begin
            if (run) cycles <= cycles + 64'd1;

            rd_credit <= rd_credit + (refill ? 32'(NRD) : 32'd0)
                                   - (ar_hs  ? 32'd1    : 32'd0);
            wr_credit <= wr_credit + (refill ? 32'(NWR) : 32'd0)
                                   - (b_hs   ? 32'd1    : 32'd0);
            ar_out    <= ar_out    + (ar_hs  ? 3'd1     : 3'd0)
                                   - (r_burst_done ? 3'd1 : 3'd0);

            if (ar_hs) begin
                lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
                n_rd <= n_rd + 64'd1;
            end

            if (aw_hs) begin
                aw_busy <= 1'b1;
                wbeat   <= 5'd0;
                // Sequential fill order, wrapping inside the channel.
                wr_addr_r <= ((wr_addr_r >> 10) == (ADDR_W'(NBLK) - 64'd1))
                             ? '0 : (wr_addr_r + 64'd1024);
            end
            if (w_hs) wbeat <= wlast ? 5'd0 : (wbeat + 5'd1);
            if (b_hs) begin
                aw_busy <= 1'b0;
                n_wr    <= n_wr + 64'd1;
            end
        end
    end

    // ---- drive + report ---------------------------------------------------
    initial begin
        real    cyc_comp, cand, rd_gb, wr_gb, util, ref_pct, rd_per_wr;
        longint c0, rd0, wr0, busy0, ref0;

        clk   = 1'b0;
        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        $display("tb_ddr4_ceiling: m'=%0d blocks, %0d MHz, mix %0d rd : %0d wr, %0d AR outstanding, %0d compressions",
                 NBLK, PERF_MHZ, NRD, NWR, OUTSTANDING, NCOMP);

        c0 = cycles; rd0 = st_rd_beats; wr0 = st_wr_beats;
        busy0 = st_busy; ref0 = st_ref;
        run = 1'b1;

        wait (n_wr >= NCOMP);
        run = 1'b0;
        // Drain the reads already in flight so the beat counters are whole.
        wait (ar_out == 3'd0);
        repeat (4) @(posedge clk);

        cyc_comp = (cycles - c0) / (1.0 * NCOMP);
        cand     = F_MHZ * 1e6 / (cyc_comp * CAND_BLKS);
        rd_gb    = (st_rd_beats - rd0) * 64.0 * F_MHZ / 1e3 / (cycles - c0);
        wr_gb    = (st_wr_beats - wr0) * 64.0 * F_MHZ / 1e3 / (cycles - c0);
        util     = 100.0 * (st_busy - busy0) / (cycles - c0);
        ref_pct  = 100.0 * (st_ref  - ref0)  / (cycles - c0);
        rd_per_wr = 1.0 * (st_rd_beats - rd0) / (st_wr_beats - wr0);

        $display("CEIL : %0d cycles, %0.1f cyc/compression, %0.3f Mblk/s, %0.3f cand/s per channel (1 GiB t=3)",
                 cycles - c0, cyc_comp, F_MHZ / cyc_comp, cand);
        $display("CEIL : %0.2f GB/s read, %0.2f GB/s write (%0.2f total), port busy %0.1f%%, refresh %0.1f%%",
                 rd_gb, wr_gb, rd_gb + wr_gb, util, ref_pct);
        $display("CEIL : %0d rd bursts, %0d wr bursts, %0.2f rd beats per wr beat",
                 n_rd, n_wr, rd_per_wr);
        $display("CEIL : one argon2 lane at %0.3f cand/s (tb_perf argon2id N_P=8) would fit %0.2fx on this channel",
                 LANE_CAND, cand / LANE_CAND);

        $display("tb_ddr4_ceiling: done");
        $finish;
    end
endmodule
