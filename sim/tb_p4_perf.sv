// SPDX-License-Identifier: MIT
// Partitioned-memory p=4 performance bench: ONE argon2 candidate across
// four lanes and four INDEPENDENT cycle-accurate DDR4-2400 channels,
// connected by argon2_mem_xbar (cross-lane reference routing).
//
// This is the hardware comparison the perf docs call for before any
// 4x p=1 versus 1x p=4 decision: the RFC p=4 bench verified fill/index/
// barrier behavior on shared memory only, and tb_perf verified p=1 on one
// channel. Here each lane owns a private memory (NBLK/4 blocks) exactly as
// on an f1.2xlarge (4 DDR4 channels) or a U50 slice, and ~75% of all
// references cross the router.
//
// Reported: cycles per block-compression over the whole candidate, cand/s
// projected to the 1 GiB / t=3 reference job, per-channel read/write GB/s
// and port utilization, crossbar contention (lane cycles spent waiting for
// a grant), and slice-barrier skew (per-lane SLICE_SYNC cycles).
//
// Build/run:  make -C sim p4perf                        (m'=16384 total)
//             make -C sim P4_TYPE=0 p4perf              (argon2d)
//             make -C sim P4_BLKS=4096 P4_NP=8 p4perf
//             make -C sim P4_MHZ=250 p4perf             (closure target)
//
// Timing only (like tb_perf): data is not checked. The functional check
// for this topology is tb_argon2_p4 (RFC 9106 §5 + geometry sweep).

`timescale 1ns / 1ps

module tb_p4_perf #(
    parameter int NBLK   = 16384,  // TOTAL working set in 1 KiB blocks (m')
    parameter int PASSES = 3,
    parameter int N_P    = 1,
    parameter int TYPE_I = 1,      // 0=d, 1=i, 2=id
    parameter int PERF_MHZ = 200
) ();
    localparam int P       = 4;
    localparam int CBLK    = NBLK / P;   // blocks per lane / channel
    localparam int NBEAT   = 16;
    localparam int ADDR_W  = 64;
    localparam int ID_W    = 6;
    localparam int DATA_W  = 512;
    localparam real F_MHZ  = PERF_MHZ * 1.0;
    localparam real CAND_BLKS = 3.0 * 1048576.0;

    localparam int T_CL_C   = (14  * PERF_MHZ + 999) / 1000;
    localparam int T_RCD_C  = (14  * PERF_MHZ + 999) / 1000;
    localparam int T_RP_C   = (14  * PERF_MHZ + 999) / 1000;
    localparam int T_WL_C   = (12  * PERF_MHZ + 999) / 1000;
    localparam int T_RTW_C  = (10  * PERF_MHZ + 999) / 1000;
    localparam int T_WTR_C  = (8   * PERF_MHZ + 999) / 1000;
    localparam int T_RFC_C  = (350 * PERF_MHZ + 999) / 1000;
    localparam int T_REFI_C = (7800* PERF_MHZ + 999) / 1000;

    logic clk, rst_n, start, busy, done;
    logic [31:0] passes, lane_length, memory_blocks;
    logic [1:0]  type_i;

    always #(500.0/PERF_MHZ) clk = ~clk;

    logic [63:0] sim_cycles;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) sim_cycles <= 64'd0;
        else        sim_cycles <= sim_cycles + 64'd1;
    end

    // ---- lanes + crossbar ----------------------------------------------
    logic [P-1:0]             l_rd_valid, l_rd_ready, l_rd_data_v, l_rd_last;
    logic [P-1:0][31:0]       l_rd_addr;
    logic [P-1:0][3:0]        l_rd_owner;
    logic [P-1:0][511:0]      l_rd_data;
    logic [P-1:0]             l_wr_valid, l_wr_ready, l_wr_last;
    logic [P-1:0][31:0]       l_wr_addr;
    logic [P-1:0][511:0]      l_wr_data;

    argon2_fill_job #(.ADDR_W(32), .LANES(P), .N_P(N_P)) job (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
        .passes(passes), .lane_length(lane_length),
        .memory_blocks(memory_blocks), .type_i(type_i),
        .mem_rd_valid(l_rd_valid), .mem_rd_ready(l_rd_ready),
        .mem_rd_addr(l_rd_addr), .mem_rd_owner(l_rd_owner),
        .mem_rd_data_v(l_rd_data_v), .mem_rd_data(l_rd_data),
        .mem_rd_last(l_rd_last),
        .mem_wr_valid(l_wr_valid), .mem_wr_ready(l_wr_ready),
        .mem_wr_addr(l_wr_addr), .mem_wr_data(l_wr_data),
        .mem_wr_last(l_wr_last)
    );

    logic [P-1:0]             c_rd_valid, c_rd_ready, c_rd_data_v, c_rd_last;
    logic [P-1:0][31:0]       c_rd_addr;
    logic [P-1:0][511:0]      c_rd_data;
    logic [P-1:0]             c_wr_valid, c_wr_ready, c_wr_last;
    logic [P-1:0][31:0]       c_wr_addr;
    logic [P-1:0][511:0]      c_wr_data;

    argon2_mem_xbar #(.ADDR_W(32), .LANES(P)) xb (
        .clk(clk), .rst_n(rst_n), .lane_length(lane_length),
        .l_rd_valid(l_rd_valid), .l_rd_ready(l_rd_ready),
        .l_rd_addr(l_rd_addr), .l_rd_owner(l_rd_owner),
        .l_rd_data_v(l_rd_data_v), .l_rd_data(l_rd_data),
        .l_rd_last(l_rd_last),
        .l_wr_valid(l_wr_valid), .l_wr_ready(l_wr_ready),
        .l_wr_addr(l_wr_addr), .l_wr_data(l_wr_data), .l_wr_last(l_wr_last),
        .c_rd_valid(c_rd_valid), .c_rd_ready(c_rd_ready),
        .c_rd_addr(c_rd_addr), .c_rd_data_v(c_rd_data_v),
        .c_rd_data(c_rd_data), .c_rd_last(c_rd_last),
        .c_wr_valid(c_wr_valid), .c_wr_ready(c_wr_ready),
        .c_wr_addr(c_wr_addr), .c_wr_data(c_wr_data), .c_wr_last(c_wr_last)
    );

    // ---- one AXI-MM adapter + DDR4 channel per lane ---------------------
    logic [P-1:0][ADDR_W-1:0] axi_awaddr, axi_araddr;
    logic [P-1:0] axi_awvalid, axi_awready, axi_wvalid, axi_wready;
    logic [P-1:0] axi_wlast, axi_bvalid, axi_bready;
    logic [P-1:0][DATA_W-1:0] axi_wdata, axi_rdata;
    logic [P-1:0] axi_arvalid, axi_arready, axi_rvalid, axi_rready, axi_rlast;

    logic [P-1:0][63:0] st_cycles, st_busy, st_refresh, st_rd_beats, st_wr_beats;
    logic [P-1:0][63:0] st_rd_req, st_wr_req;

    for (genvar g = 0; g < P; g++) begin : ch
        argon2_axi_mm #(
            .AXI_ADDR_W(ADDR_W), .AXI_ID_W(ID_W),
            .AXI_DATA_W(DATA_W), .BLK_ADDR_W(32)
        ) u_mm (
            .clk(clk), .rst_n(rst_n), .base_addr(64'd0),
            .mem_rd_valid(c_rd_valid[g]), .mem_rd_ready(c_rd_ready[g]),
            .mem_rd_addr(c_rd_addr[g]), .mem_rd_data_v(c_rd_data_v[g]),
            .mem_rd_data(c_rd_data[g]), .mem_rd_last(c_rd_last[g]),
            .mem_wr_valid(c_wr_valid[g]), .mem_wr_ready(c_wr_ready[g]),
            .mem_wr_addr(c_wr_addr[g]), .mem_wr_data(c_wr_data[g]),
            .mem_wr_last(c_wr_last[g]),
            .m_axi_awid(), .m_axi_awaddr(axi_awaddr[g]), .m_axi_awlen(),
            .m_axi_awsize(), .m_axi_awburst(), .m_axi_awlock(), .m_axi_awcache(),
            .m_axi_awprot(), .m_axi_awqos(), .m_axi_awvalid(axi_awvalid[g]),
            .m_axi_awready(axi_awready[g]),
            .m_axi_wdata(axi_wdata[g]), .m_axi_wstrb(), .m_axi_wlast(axi_wlast[g]),
            .m_axi_wvalid(axi_wvalid[g]), .m_axi_wready(axi_wready[g]),
            .m_axi_bid('0), .m_axi_bresp('0), .m_axi_bvalid(axi_bvalid[g]),
            .m_axi_bready(axi_bready[g]),
            .m_axi_arid(), .m_axi_araddr(axi_araddr[g]), .m_axi_arlen(),
            .m_axi_arsize(), .m_axi_arburst(), .m_axi_arlock(), .m_axi_arcache(),
            .m_axi_arprot(), .m_axi_arqos(), .m_axi_arvalid(axi_arvalid[g]),
            .m_axi_arready(axi_arready[g]),
            .m_axi_rid('0), .m_axi_rdata(axi_rdata[g]), .m_axi_rresp('0),
            .m_axi_rlast(axi_rlast[g]), .m_axi_rvalid(axi_rvalid[g]),
            .m_axi_rready(axi_rready[g])
        );

        tb_ddr4_ram #(
            .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .NBLK(CBLK),
            .T_CL_C(T_CL_C), .T_RCD_C(T_RCD_C), .T_RP_C(T_RP_C),
            .T_WL_C(T_WL_C), .T_RTW_C(T_RTW_C), .T_WTR_C(T_WTR_C),
            .T_RFC_C(T_RFC_C), .T_REFI_C(T_REFI_C)
        ) u_ram (
            .clk(clk), .rst_n(rst_n),
            .s_axi_awid('0), .s_axi_awaddr(axi_awaddr[g]), .s_axi_awlen(8'd15),
            .s_axi_awsize(3'd6), .s_axi_awvalid(axi_awvalid[g]),
            .s_axi_awready(axi_awready[g]),
            .s_axi_wdata(axi_wdata[g]), .s_axi_wstrb('1),
            .s_axi_wlast(axi_wlast[g]), .s_axi_wvalid(axi_wvalid[g]),
            .s_axi_wready(axi_wready[g]),
            .s_axi_bid(), .s_axi_bresp(), .s_axi_bvalid(axi_bvalid[g]),
            .s_axi_bready(axi_bready[g]),
            .s_axi_arid('0), .s_axi_araddr(axi_araddr[g]), .s_axi_arlen(8'd15),
            .s_axi_arvalid(axi_arvalid[g]), .s_axi_arready(axi_arready[g]),
            .s_axi_rid(), .s_axi_rdata(axi_rdata[g]), .s_axi_rresp(),
            .s_axi_rlast(axi_rlast[g]), .s_axi_rvalid(axi_rvalid[g]),
            .s_axi_rready(axi_rready[g]),
            .st_cycles(st_cycles[g]), .st_port_busy(st_busy[g]),
            .st_refresh(st_refresh[g]), .st_rd_beats(st_rd_beats[g]),
            .st_wr_beats(st_wr_beats[g]), .st_rd_req(st_rd_req[g]),
            .st_wr_req(st_wr_req[g])
        );
    end

    // ---- stats: crossbar wait + barrier skew ----------------------------
    logic [15:0][63:0] own_cnt;   // own_cnt[lane*4+owner]
    logic [P-1:0][63:0] xb_wait;
    logic [P-1:0][63:0] sync_cycles;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xb_wait <= '0;
            own_cnt <= '0;
            sync_cycles <= '0;
        end else if (busy) begin
            for (int i = 0; i < P; i++) begin
                if (l_rd_valid[i] && l_rd_ready[i])
                    own_cnt[i*4 + l_rd_owner[i][1:0]] <= own_cnt[i*4 + l_rd_owner[i][1:0]] + 64'd1;
                if (l_rd_valid[i] && !l_rd_ready[i]) xb_wait[i] <= xb_wait[i] + 64'd1;
                case (i)
                    0: if (job.lane[0].u_fill.state_o == 5'd13) sync_cycles[0] <= sync_cycles[0] + 64'd1;
                    1: if (job.lane[1].u_fill.state_o == 5'd13) sync_cycles[1] <= sync_cycles[1] + 64'd1;
                    2: if (job.lane[2].u_fill.state_o == 5'd13) sync_cycles[2] <= sync_cycles[2] + 64'd1;
                    3: if (job.lane[3].u_fill.state_o == 5'd13) sync_cycles[3] <= sync_cycles[3] + 64'd1;
                endcase
            end
        end
    end

    longint t0, t1;
    longint rb, wb, bsy, rrq, wrq, xw, sc;   // per-channel stat scratch

    // Pseudo-random memory preload. tb_perf (p=1) can run on zeroed memory:
    // nothing in a p=1 lane depends on read DATA. p=4 does — the reference
    // LANE is J2 = prev block word 0 [63:32], and with zeroed memory every
    // dependent ref collapses onto lane 0 (maximally imbalanced channels).
    // A multiplicative-hash preload gives pass 0 realistic J1/J2 statistics;
    // from pass 1 the prev word is computed output, i.e. avalanche-random.
    // (Timing bench only — data correctness is tb_argon2_p4's job.)
    function automatic logic [511:0] beat_pat(input int unsigned idx);
        logic [63:0] base;
        base = 64'h9E37_79B9_7F4A_7C15;
        beat_pat = '0;
        for (int w = 0; w < 8; w++)
            beat_pat[64*w +: 64] = 64'((idx * 8 + w) * base);
    endfunction

    initial begin
        real    cyc_blk, cand, rd_gb, wr_gb, util, skew;
        integer cyc32;
        longint rd_beats_tot, wr_beats_tot, busy_tot;

        clk = 1'b0;
        rst_n = 1'b0;
        start = 1'b0;
        passes = PASSES;
        lane_length = CBLK;
        memory_blocks = NBLK;
        type_i = 2'(TYPE_I);

        repeat (8) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);
        for (int i2 = 0; i2 < CBLK*NBEAT; i2++) begin
            logic [511:0] pv;
            pv = beat_pat(i2);
            ch[0].u_ram.mem[i2] = pv;
            ch[1].u_ram.mem[i2] = pv;
            ch[2].u_ram.mem[i2] = pv;
            ch[3].u_ram.mem[i2] = pv;
        end

        $display("tb_p4_perf: m'=%0d blocks (%0d MiB total, %0d blocks/channel), t=%0d, type=%0d (%s), p=4 x 1 ch, %0d MHz, N_P=%0d",
                 NBLK, NBLK >> 10, CBLK, PASSES, TYPE_I,
                 (TYPE_I==0)?"argon2d":(TYPE_I==1)?"argon2i":"argon2id",
                 PERF_MHZ, N_P);

        start = 1'b1;
        @(posedge clk);
        start = 1'b0;
        t0 = sim_cycles;
        while (!done) begin
            @(posedge clk);
            if (sim_cycles - t0 > 64'd400_000_000) begin
                $display("tb_p4_perf: TIMEOUT waiting for done");
                $finish;
            end
        end
        t1 = sim_cycles;

        cyc_blk = (t1 - t0) / (1.0 * NBLK * PASSES);
        cand    = F_MHZ * 1e6 / (cyc_blk * CAND_BLKS);

        $display("P4   : %0d cycles, %0.1f cyc/blk (candidate-wide), %0.3f cand/s (1 GiB t=3, p=4 on 4 channels)",
                 t1 - t0, cyc_blk, cand);
        for (int c = 0; c < P; c++) begin
            case (c)
                0: begin rb = st_rd_beats[0]; wb = st_wr_beats[0]; bsy = st_busy[0]; rrq = st_rd_req[0]; wrq = st_wr_req[0]; xw = xb_wait[0]; sc = sync_cycles[0]; end
                1: begin rb = st_rd_beats[1]; wb = st_wr_beats[1]; bsy = st_busy[1]; rrq = st_rd_req[1]; wrq = st_wr_req[1]; xw = xb_wait[1]; sc = sync_cycles[1]; end
                2: begin rb = st_rd_beats[2]; wb = st_wr_beats[2]; bsy = st_busy[2]; rrq = st_rd_req[2]; wrq = st_wr_req[2]; xw = xb_wait[2]; sc = sync_cycles[2]; end
                3: begin rb = st_rd_beats[3]; wb = st_wr_beats[3]; bsy = st_busy[3]; rrq = st_rd_req[3]; wrq = st_wr_req[3]; xw = xb_wait[3]; sc = sync_cycles[3]; end
            endcase
            cyc32 = 32'(t1 - t0);
            rd_gb  = 64.0 * rb * F_MHZ / 1e3 / cyc32;
            wr_gb  = 64.0 * wb * F_MHZ / 1e3 / cyc32;
            util   = 100.0 * bsy / cyc32;
            $display("  ch %0d: %0.2f GB/s rd, %0.2f GB/s wr, port busy %0.1f%%, %0d rd req, %0d wr req, xbar wait %0d cyc, sync %0d cyc",
                     c, rd_gb, wr_gb, util, 32'(rrq), 32'(wrq),
                     32'(xw), 32'(sc));
        end
        rd_beats_tot = st_rd_beats[0] + st_rd_beats[1] + st_rd_beats[2] + st_rd_beats[3];
        wr_beats_tot = st_wr_beats[0] + st_wr_beats[1] + st_wr_beats[2] + st_wr_beats[3];
        busy_tot = st_busy[0] + st_busy[1] + st_busy[2] + st_busy[3];
        skew = 0.0;
        for (int c = 0; c < P; c++)
            if (64.0 * sync_cycles[c] / (1.0 * (t1 - t0)) > skew)
                skew = 100.0 * sync_cycles[c] / (1.0 * (t1 - t0));
        $display("P4   : aggregate %0.2f GB/s rd + %0.2f GB/s wr over 4 channels, worst-lane barrier skew %0.1f%%",
                 64.0 * rd_beats_tot * F_MHZ / 1e3 / (t1 - t0),
                 64.0 * wr_beats_tot * F_MHZ / 1e3 / (t1 - t0), skew);
        $display("P4   : F1-class aggregate for 1x p=4 = %0.3f cand/s; compare 4x p=1 = 4 x per-lane cand/s (make perf PERF_BLKS=%0d)",
                 cand, NBLK);
        $display("req matrix lane->owner (rows=lane):");
        for (int i = 0; i < P; i++)
            $display("  L%0d: %0d %0d %0d %0d", i, 32'(own_cnt[i*4+0]),
                     32'(own_cnt[i*4+1]), 32'(own_cnt[i*4+2]), 32'(own_cnt[i*4+3]));
        $display("tb_p4_perf: done");
        $finish;
    end
endmodule
