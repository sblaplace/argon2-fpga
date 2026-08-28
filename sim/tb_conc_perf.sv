// SPDX-License-Identifier: MIT
// Multi-context concentrator performance bench: NCTX independent p=1
// contexts sharing ONE cycle-accurate DDR4-2400 channel through
// argon2_lane_conc + argon2_axi_mm(MAX_RD_PEND=4).
//
// This measures lever 2 of docs/PERFORMANCE.md ("ranked levers"): a single
// lane is at the single-outstanding-read capacity of its channel (1.044
// cand/s at N_P=8 / 200 MHz), while the channel itself serves ~1.41 cand/s
// with 2 reads in flight (tb_ddr4_ceiling). N contexts each present their
// own single outstanding read, so the concentrator should recover most of
// the gap — measured here instead of assumed.
//
// Reported: cycles per block-compression (aggregate over all contexts),
// cand/s per channel projected to the 1 GiB / t=3 reference job
// (3*2^20 compressions per candidate), the f1.2xlarge box projection
// (x4 channels), per-context completion spread, DDR port busy / GB/s, and
// per-lane concentrator wait cycles (lane offered a read and was not
// accepted).
//
// Timing only (like tb_perf / tb_p4_perf): data is not checked here — the
// functional check for this topology is tb_argon2_conc.
//
// Build/run:
//   make -C sim concperf                          (2 ctx, argon2id)
//   make -C sim CONC_CTXS=3 concperf
//   make -C sim CONC_CTXS=4 CONC_NP=8 concperf
//   make -C sim CONC_MHZ=250 concperf             (closure point)

`timescale 1ns / 1ps

module tb_conc_perf #(
    parameter int NBLK    = 4096,  // TOTAL working set in 1 KiB blocks
    parameter int PASSES  = 3,
    parameter int N_P     = 8,
    parameter int TYPE_I  = 2,     // 0=d, 1=i, 2=id
    parameter int NCTX    = 2,     // contexts sharing the channel (2..16)
    parameter int PERF_MHZ = 200
) ();
    localparam int CTXBLKS  = NBLK / NCTX;   // blocks per context
    localparam int NBEAT    = 16;
    localparam int ADDR_W   = 64;
    localparam int ID_W     = 6;
    localparam int DATA_W   = 512;
    localparam real F_MHZ   = PERF_MHZ * 1.0;
    localparam real CAND_BLKS = 3.0 * 1048576.0;

    localparam int T_CL_C   = (14  * PERF_MHZ + 999) / 1000;
    localparam int T_RCD_C  = (14  * PERF_MHZ + 999) / 1000;
    localparam int T_RP_C   = (14  * PERF_MHZ + 999) / 1000;
    localparam int T_WL_C   = (12  * PERF_MHZ + 999) / 1000;
    localparam int T_RTW_C  = (10  * PERF_MHZ + 999) / 1000;
    localparam int T_WTR_C  = (8   * PERF_MHZ + 999) / 1000;
    localparam int T_RFC_C  = (350 * PERF_MHZ + 999) / 1000;
    localparam int T_REFI_C = (7800* PERF_MHZ + 999) / 1000;

    logic clk, rst_n, start;
    logic [31:0] passes, lane_length, memory_blocks;
    logic [1:0]  type_i;

    always #(500.0/PERF_MHZ) clk = ~clk;

    logic [63:0] sim_cycles;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sim_cycles <= 64'd0;
        else        sim_cycles <= sim_cycles + 64'd1;
    end

    // ---- contexts + concentrator -----------------------------------------
    logic [NCTX-1:0]             l_rd_valid, l_rd_ready, l_rd_data_v, l_rd_last;
    logic [NCTX-1:0][31:0]       l_rd_addr;
    logic [NCTX-1:0][511:0]      l_rd_data;
    logic [NCTX-1:0]             l_wr_valid, l_wr_ready, l_wr_last;
    logic [NCTX-1:0][31:0]       l_wr_addr;
    logic [NCTX-1:0][511:0]      l_wr_data;

    logic [NCTX-1:0] lane_busy, lane_done;

    genvar g;
    generate
        for (g = 0; g < NCTX; g++) begin : ctx
            argon2_fill_ctrl #(.ADDR_W(32), .N_P(N_P)) u_fill (
                .clk           (clk),
                .rst_n         (rst_n),
                .start         (start),
                .busy          (lane_busy[g]),
                .done          (lane_done[g]),
                .passes        (passes),
                .lanes         (32'd1),
                .lane_id       (32'd0),
                .lane_length   (lane_length),
                .memory_blocks (memory_blocks),
                .type_i        (type_i),
                .sync_req      (),
                .sync_ack      (1'b1),
                .mem_rd_valid  (l_rd_valid[g]),
                .mem_rd_ready  (l_rd_ready[g]),
                .mem_rd_addr   (l_rd_addr[g]),
                .mem_rd_owner  (),
                .mem_rd_data_v (l_rd_data_v[g]),
                .mem_rd_data   (l_rd_data[g]),
                .mem_rd_last   (l_rd_last[g]),
                .mem_wr_valid  (l_wr_valid[g]),
                .mem_wr_ready  (l_wr_ready[g]),
                .mem_wr_addr   (l_wr_addr[g]),
                .mem_wr_data   (l_wr_data[g]),
                .mem_wr_last   (l_wr_last[g]),
                .state_o       ()
            );
        end
    endgenerate

    logic        c_rd_valid, c_rd_ready, c_rd_data_v, c_rd_last;
    logic [31:0] c_rd_addr;
    logic [511:0] c_rd_data;
    logic        c_wr_valid, c_wr_ready, c_wr_last;
    logic [31:0] c_wr_addr;
    logic [511:0] c_wr_data;

    argon2_lane_conc #(.ADDR_W(32), .LANES(NCTX), .MAX_INFLIGHT(4)) conc (
        .clk(clk), .rst_n(rst_n), .ctx_len(lane_length),
        .l_rd_valid(l_rd_valid), .l_rd_ready(l_rd_ready),
        .l_rd_addr(l_rd_addr),
        .l_rd_data_v(l_rd_data_v), .l_rd_data(l_rd_data), .l_rd_last(l_rd_last),
        .l_wr_valid(l_wr_valid), .l_wr_ready(l_wr_ready),
        .l_wr_addr(l_wr_addr), .l_wr_data(l_wr_data), .l_wr_last(l_wr_last),
        .c_rd_valid(c_rd_valid), .c_rd_ready(c_rd_ready), .c_rd_addr(c_rd_addr),
        .c_rd_data_v(c_rd_data_v), .c_rd_data(c_rd_data), .c_rd_last(c_rd_last),
        .c_wr_valid(c_wr_valid), .c_wr_ready(c_wr_ready), .c_wr_addr(c_wr_addr),
        .c_wr_data(c_wr_data), .c_wr_last(c_wr_last)
    );

    // ---- one AXI-MM adapter + DDR4 channel --------------------------------
    logic [ADDR_W-1:0] axi_awaddr, axi_araddr;
    logic axi_awvalid, axi_awready, axi_wvalid, axi_wready;
    logic axi_wlast, axi_bvalid, axi_bready;
    logic [DATA_W-1:0] axi_wdata, axi_rdata;
    logic axi_arvalid, axi_arready, axi_rvalid, axi_rready, axi_rlast;

    logic [63:0] st_cycles, st_busy, st_refresh, st_rd_beats, st_wr_beats;
    logic [63:0] st_rd_req, st_wr_req;

    argon2_axi_mm #(
        .AXI_ADDR_W(ADDR_W), .AXI_ID_W(ID_W),
        .AXI_DATA_W(DATA_W), .BLK_ADDR_W(32),
        .MAX_RD_PEND(4)
    ) u_mm (
        .clk(clk), .rst_n(rst_n), .base_addr(64'd0),
        .mem_rd_valid(c_rd_valid), .mem_rd_ready(c_rd_ready),
        .mem_rd_addr(c_rd_addr), .mem_rd_data_v(c_rd_data_v),
        .mem_rd_data(c_rd_data), .mem_rd_last(c_rd_last),
        .mem_wr_valid(c_wr_valid), .mem_wr_ready(c_wr_ready),
        .mem_wr_addr(c_wr_addr), .mem_wr_data(c_wr_data),
        .mem_wr_last(c_wr_last),
        .m_axi_awid(), .m_axi_awaddr(axi_awaddr), .m_axi_awlen(),
        .m_axi_awsize(), .m_axi_awburst(), .m_axi_awlock(), .m_axi_awcache(),
        .m_axi_awprot(), .m_axi_awqos(), .m_axi_awvalid(axi_awvalid),
        .m_axi_awready(axi_awready),
        .m_axi_wdata(axi_wdata), .m_axi_wstrb(), .m_axi_wlast(axi_wlast),
        .m_axi_wvalid(axi_wvalid), .m_axi_wready(axi_wready),
        .m_axi_bid('0), .m_axi_bresp('0), .m_axi_bvalid(axi_bvalid),
        .m_axi_bready(axi_bready),
        .m_axi_arid(), .m_axi_araddr(axi_araddr), .m_axi_arlen(),
        .m_axi_arsize(), .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(),
        .m_axi_arprot(), .m_axi_arqos(), .m_axi_arvalid(axi_arvalid),
        .m_axi_arready(axi_arready),
        .m_axi_rid('0), .m_axi_rdata(axi_rdata), .m_axi_rresp('0),
        .m_axi_rlast(axi_rlast), .m_axi_rvalid(axi_rvalid),
        .m_axi_rready(axi_rready)
    );

    tb_ddr4_ram #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .NBLK(NBLK),
        .T_CL_C(T_CL_C), .T_RCD_C(T_RCD_C), .T_RP_C(T_RP_C),
        .T_WL_C(T_WL_C), .T_RTW_C(T_RTW_C), .T_WTR_C(T_WTR_C),
        .T_RFC_C(T_RFC_C), .T_REFI_C(T_REFI_C)
    ) u_ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid('0), .s_axi_awaddr(axi_awaddr), .s_axi_awlen(8'd15),
        .s_axi_awsize(3'd6), .s_axi_awvalid(axi_awvalid),
        .s_axi_awready(axi_awready),
        .s_axi_wdata(axi_wdata), .s_axi_wstrb('1),
        .s_axi_wlast(axi_wlast), .s_axi_wvalid(axi_wvalid),
        .s_axi_wready(axi_wready),
        .s_axi_bid(), .s_axi_bresp(), .s_axi_bvalid(axi_bvalid),
        .s_axi_bready(axi_bready),
        .s_axi_arid('0), .s_axi_araddr(axi_araddr), .s_axi_arlen(8'd15),
        .s_axi_arvalid(axi_arvalid), .s_axi_arready(axi_arready),
        .s_axi_rid(), .s_axi_rdata(axi_rdata), .s_axi_rresp(),
        .s_axi_rlast(axi_rlast), .s_axi_rvalid(axi_rvalid),
        .s_axi_rready(axi_rready),
        .st_cycles(st_cycles), .st_port_busy(st_busy),
        .st_refresh(st_refresh), .st_rd_beats(st_rd_beats),
        .st_wr_beats(st_wr_beats), .st_rd_req(st_rd_req), .st_wr_req(st_wr_req)
    );

    // ---- stats: conc wait + completion ------------------------------------
    logic [NCTX-1:0][63:0] xb_wait;
    logic [63:0] t0, t1;
    logic [NCTX-1:0] seen_done;
    logic running;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xb_wait <= '0;
        end else if (running) begin
            for (int i = 0; i < NCTX; i++)
                if (l_rd_valid[i] && !l_rd_ready[i])
                    xb_wait[i] <= xb_wait[i] + 64'd1;
        end
    end

    // zeroed memory is fine for p=1 timing (see tb_perf): nothing in a p=1
    // lane's TIMING depends on read data (J1/J2 avalanche-random from the
    // H'-derived init blocks). Correctness is tb_argon2_conc's job.

    initial begin
        real cyc_blk, cand, rd_gb, wr_gb, util;
        longint xw_tot;

        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        running = 1'b0;
        passes = PASSES;
        lane_length = CTXBLKS;
        memory_blocks = CTXBLKS;
        type_i = 2'(TYPE_I);

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        $display("tb_conc_perf: %0d contexts x m'=%0d KiB each (channel total %0d KiB), t=%0d, type=%0d (%s), 1 ch, %0d MHz, N_P=%0d",
                 NCTX, CTXBLKS, NBLK, PASSES, TYPE_I,
                 (TYPE_I==0)?"argon2d":(TYPE_I==1)?"argon2i":"argon2id",
                 PERF_MHZ, N_P);

        start   = 1'b1;
        running = 1'b1;
        @(posedge clk);
        start   = 1'b0;
        t0 = sim_cycles;
        seen_done = '0;
        while (seen_done != {NCTX{1'b1}}) begin
            @(posedge clk);
            seen_done <= seen_done | lane_done;
            if (sim_cycles - t0 > 64'd800_000_000) begin
                $display("tb_conc_perf: TIMEOUT waiting for done");
                $finish;
            end
        end
        t1 = sim_cycles;
        running = 1'b0;

        cyc_blk = (t1 - t0) / (1.0 * NBLK * PASSES);
        cand    = F_MHZ * 1e6 / (cyc_blk * CAND_BLKS);

        xw_tot = 0;
        for (int i = 0; i < NCTX; i++) xw_tot += xb_wait[i];

        rd_gb = 64.0 * st_rd_beats * F_MHZ / 1e3 / (t1 - t0);
        wr_gb = 64.0 * st_wr_beats * F_MHZ / 1e3 / (t1 - t0);
        util  = 100.0 * st_busy / (t1 - t0);

        $display("CONC : %0d cycles, %0.1f cyc/blk (aggregate), %0.3f cand/s per channel (1 GiB t=3)",
                 t1 - t0, cyc_blk, cand);
        $display("CONC : %0.2f GB/s rd + %0.2f GB/s wr, port busy %0.1f%%, conc wait %0d cyc total (%0.0f/blk)",
                 rd_gb, wr_gb, util, xw_tot, 1.0 * xw_tot / (1.0 * NBLK * PASSES));
        $display("CONC : f1.2xlarge box (x4 channels, %0d ctx/ch) = %0.3f cand/s   [1 lane/ch baseline: 4.18]",
                 NCTX, 4.0 * cand);
        $display("tb_conc_perf: done");
        $finish;
    end
endmodule
