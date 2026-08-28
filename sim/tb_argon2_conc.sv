// SPDX-License-Identifier: MIT
// Multi-context concentrator known-answer fill: NCTX independent p=1
// contexts (distinct password/salt per context) through argon2_lane_conc
// onto ONE shared memory port, against the per-context golden images.
//
// What this adds over tb_argon2_multi_ctx (same context-isolation check,
// fabric topology) and tb_argon2_p4 (tagged-return check, crossbar
// topology): the concentrator's two sharing-specific mechanisms —
//   * the in-flight lane-tag FIFO: read commands of different contexts are
//     accepted back-to-back (multi-in-flight) and every returning beat
//     must reach the owning context's controller (a misroute lands on the
//     wrong context's region and fails the compare, since the contexts
//     hold different data);
//   * the BURST-LOCKED write arbiter: the memory model stalls write beats
//     mid-burst (1 cycle in 4), so a per-beat arbiter would interleave two
//     contexts' blocks; the model checks burst contiguity (exactly 16
//     beats between wr_last pulses) and the compare checks placement.
//
// Built-in protocol assertions (all folded into the final verdict):
//   * per-lane read beats arrive in order 0..15, last exactly on beat 15;
//   * the shared port returns read bursts in ACCEPTANCE order (the
//     invariant the concentrator's in-flight tag FIFO depends on).
//
// Geometries: m'=16 / t=3 / p=1 x NCTX=4 contexts, argon2i/d/id.
// Vectors: tests/dump_vectors.py dump_multi(..., "conc_..", m=16, t=3).
// Build:  make -C sim conc                        (iverilog)
//         make -C sim SIM=verilator NP=8 conc     (parallel-P point)

`timescale 1ns / 1ps

// One shared-channel memory: 2-deep pipelined read (a new command is
// accepted while the previous burst is still counting latency or
// streaming, like argon2_axi_mm + DDR4), occasional read-beat gaps, and
// write-beat backpressure that stalls mid-burst.
module tb_conc_mem #(
    parameter int LL     = 64,    // total blocks (all contexts)
    parameter int RD_LAT = 10
) (
    input  logic         clk,
    input  logic         rst_n,
    input  logic         rd_valid,
    output logic         rd_ready,
    input  logic [31:0]  rd_addr,
    output logic         rd_data_v,
    output logic [511:0] rd_data,
    output logic         rd_last,
    input  logic         wr_valid,
    output logic         wr_ready,
    input  logic [31:0]  wr_addr,
    input  logic [511:0] wr_data,
    input  logic         wr_last
);
    localparam int NBEAT = 16;
    logic [511:0] mem [0:LL*NBEAT-1];

    // slot 0: latency-counting command; slot 1: queued command.
    // All slot updates compose through nq0_*/nq1_* FIRST, then commit:
    // (a) an acceptance and a q1->q0 shift in the same cycle must not race
    //     (two NBA writes to q0_v would silently drop one command);
    // (b) an arrival must never take the empty q0 slot AHEAD of a command
    //     still parked in q1 (a 2-slot reorder) — routing on the composed
    //     (post-shift) state keeps acceptance order == stream order, which
    //     the in-flight tag FIFOs upstream depend on.
    logic        q0_v, q1_v;
    logic [31:0] q0_addr, q1_addr;
    logic [7:0]  q0_wait;
    logic        nq0_v, nq1_v;
    logic [31:0] nq0_addr, nq1_addr;
    logic [7:0]  nq0_wait;

    logic        strm_busy;
    logic [31:0] strm_blk;
    logic [4:0]  strm_beat;

    logic [4:0]  wr_beat;
    logic [31:0] cyc;

    integer errors;
    initial errors = 0;

    // Ordered accepted-vs-returned check: bursts must return in acceptance
    // order. A violation here is a shared-port reorder (model bug);
    // concentrator tag misroutes surface as the per-lane beat-order check
    // in the parent bench plus the final data compare.
    logic [31:0] ord_q [0:7];
    logic [2:0]  ord_head, ord_tail;
    integer      ord_errs;
    initial ord_errs = 0;

    assign rd_ready = !(q0_v && q1_v);
    assign wr_ready = (cyc[1:0] != 2'b10);   // stall 1 cycle in 4

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q0_v <= 1'b0; q1_v <= 1'b0;
            q0_addr <= '0; q1_addr <= '0;
            q0_wait <= 8'd0;
            strm_busy <= 1'b0; strm_blk <= '0; strm_beat <= '0;
            wr_beat <= '0; cyc <= '0;
            rd_data_v <= 1'b0; rd_last <= 1'b0; rd_data <= '0;
            ord_head <= 3'd0; ord_tail <= 3'd0;
        end else begin
            cyc <= cyc + 32'd1;
            rd_data_v <= 1'b0;
            rd_last   <= 1'b0;

            nq0_v    = q0_v;
            nq0_addr = q0_addr;
            nq0_wait = q0_wait;
            nq1_v    = q1_v;
            nq1_addr = q1_addr;

            // ---- read command pipeline ----
            if (rd_valid && rd_ready) begin
                ord_q[ord_tail] <= rd_addr;
                ord_tail        <= ord_tail + 3'd1;
                if (!nq0_v) begin
                    nq0_v    = 1'b1;
                    nq0_addr = rd_addr;
                    nq0_wait = RD_LAT[7:0];
                end else begin
                    nq1_v    = 1'b1;
                    nq1_addr = rd_addr;
                end
            end
            if (nq0_v && nq0_wait != 8'd0)
                nq0_wait = nq0_wait - 8'd1;

            // hand a matured command to the streamer (back-to-back OK)
            if (!strm_busy && nq0_v && nq0_wait == 8'd0) begin
                strm_busy <= 1'b1;
                strm_blk  <= nq0_addr;
                strm_beat <= 5'd0;
                if (nq1_v) begin
                    q0_addr <= nq1_addr;
                    q0_wait <= RD_LAT[7:0];
                    q0_v    <= 1'b1;
                    q1_v    <= 1'b0;
                end else begin
                    q0_v <= 1'b0;
                end
                q1_addr <= nq1_addr;
                q1_v    <= 1'b0;   // nq1 (old or this cycle's arrival) shifted up
            end else begin
                q0_v     <= nq0_v;
                q0_addr  <= nq0_addr;
                q0_wait  <= nq0_wait;
                q1_v     <= nq1_v;
                q1_addr  <= nq1_addr;
            end

            // stream beats (1/cycle, minus an occasional 1-cycle gap)
            if (strm_busy && cyc[2:0] != 3'b101) begin
                if (strm_beat == 5'd0) begin
                    if (strm_blk !== ord_q[ord_head]) begin
                        ord_errs = ord_errs + 1;
                        if (ord_errs == 1)
                            $display("CONC ERR: port reordered: returned blk %0d, expected %0d",
                                     strm_blk, ord_q[ord_head]);
                    end
                    ord_head <= ord_head + 3'd1;
                end
                rd_data_v <= 1'b1;
                rd_data   <= mem[strm_blk * NBEAT + strm_beat[3:0]];
                rd_last   <= (strm_beat == 5'd15);
                if (strm_beat == 5'd15) strm_busy <= 1'b0;
                else                    strm_beat <= strm_beat + 5'd1;
            end

            // ---- write path (committed on beat) ----
            if (wr_valid && wr_ready) begin
                mem[wr_addr * NBEAT + wr_beat[3:0]] <= wr_data;
                if (wr_last) begin
                    if (wr_beat != 5'd15) begin
                        errors = errors + 1;
                        $display("CONC ERR: wr_last at beat %0d (addr %0d) — burst not contiguous",
                                 wr_beat, wr_addr);
                    end
                    wr_beat <= 5'd0;
                end else begin
                    wr_beat <= wr_beat + 5'd1;
                end
            end
        end
    end
endmodule

module tb_argon2_conc #(
    parameter int N_P     = 1,
    parameter int NCTX    = 4,     // contexts sharing the channel
    parameter int CTXBLKS = 16,    // m' per context (blocks)
    parameter int PASSES  = 3
);
    localparam int NBEAT    = 16;
    localparam int ADDR_W   = 32;
    localparam int TOTALBLK = NCTX * CTXBLKS;

    logic clk, rst_n, start;
    logic [31:0] passes, lane_length, memory_blocks;
    logic [1:0]  type_i;

    always #5 clk = ~clk;

    logic [NCTX-1:0]             l_rd_valid, l_rd_ready, l_rd_data_v, l_rd_last;
    logic [NCTX-1:0][ADDR_W-1:0] l_rd_addr;
    logic [NCTX-1:0][511:0]      l_rd_data;
    logic [NCTX-1:0]             l_wr_valid, l_wr_ready, l_wr_last;
    logic [NCTX-1:0][ADDR_W-1:0] l_wr_addr;
    logic [NCTX-1:0][511:0]      l_wr_data;

    logic              c_rd_valid, c_rd_ready, c_rd_data_v, c_rd_last;
    logic [ADDR_W-1:0] c_rd_addr;
    logic [511:0]      c_rd_data;
    logic              c_wr_valid, c_wr_ready, c_wr_last;
    logic [ADDR_W-1:0] c_wr_addr;
    logic [511:0]      c_wr_data;

    logic [NCTX-1:0] lane_busy, lane_done;
    logic [NCTX-1:0] start_mask;   // CI-debug: which contexts launch

    genvar g;
    generate
        for (g = 0; g < NCTX; g++) begin : ctx
            argon2_fill_ctrl #(.ADDR_W(ADDR_W), .N_P(N_P)) u_fill (
                .clk           (clk),
                .rst_n         (rst_n),
                .start         (start & start_mask[g]),
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

    argon2_lane_conc #(.ADDR_W(ADDR_W), .LANES(NCTX), .MAX_INFLIGHT(4)) conc (
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

    tb_conc_mem #(.LL(TOTALBLK), .RD_LAT(10)) u_mem (
        .clk(clk), .rst_n(rst_n),
        .rd_valid(c_rd_valid), .rd_ready(c_rd_ready), .rd_addr(c_rd_addr),
        .rd_data_v(c_rd_data_v), .rd_data(c_rd_data), .rd_last(c_rd_last),
        .wr_valid(c_wr_valid), .wr_ready(c_wr_ready), .wr_addr(c_wr_addr),
        .wr_data(c_wr_data), .wr_last(c_wr_last)
    );

    // ---- protocol assertion: per-lane beat order --------------------------
    logic [NCTX-1:0][4:0] rx_beat;
    integer proto_err;
    initial proto_err = 0;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < NCTX; i++) rx_beat[i] <= '0;
        end else begin
            for (int i = 0; i < NCTX; i++) begin
                if (l_rd_data_v[i]) begin
                    if (l_rd_last[i] != (rx_beat[i] == 5'd15)) begin
                        proto_err = proto_err + 1;
                        $display("CONC ERR: lane %0d rd_last at beat %0d",
                                 i, rx_beat[i]);
                    end
                    rx_beat[i] <= (rx_beat[i] == 5'd15) ? 5'd0
                                                        : rx_beat[i] + 5'd1;
                end
            end
        end
    end

    // ---- drive + check ----------------------------------------------------
    integer errors, cycles, mism;
    logic [NCTX-1:0] seen_done;
    logic [511:0] exp_img [0:TOTALBLK*NBEAT-1];
    // Compact per-block divergence fingerprint (debugging 4-state vs
    // 2-state simulator differences; see docs/PERFORMANCE.md conc section):
    //   UNWRITTEN  got == seeded init image for all 16 beats
    //   X-POLLUTED any beat has an X bit (4-state propagation)
    //   WRONG-DATA fully written, none X, differs from golden
    logic [511:0] init_snap [0:TOTALBLK*NBEAT-1];
    string        fp_sum [0:7];   // divergence fingerprints, reprinted at end
    integer       fp_n;
    initial fp_n = 0;
    string        fp2_sum [0:7];
    integer       fp2_n;
    initial fp2_n = 0;
    integer       wr_log [0:255];
    integer       wr_n;
    integer       wr_beats;    // beats accepted by the model (channel side)
    integer       lwr_beats;   // lane-side write-beat handshakes (all lanes)
    integer       lwr_last;    // lane-side last-beat handshakes
    integer       mux_gap;     // cycles a lane offers a beat but mux sends none
    initial wr_n = 0;

    always @(posedge clk) begin
        if (rst_n && c_wr_valid && c_wr_ready) begin
            wr_beats = wr_beats + 1;
            if (c_wr_last) wr_log[wr_n++ % 256] = c_wr_addr;
        end
        if (rst_n) begin
            for (int i = 0; i < NCTX; i++)
                if (l_wr_valid[i] && l_wr_ready[i]) begin
                    lwr_beats = lwr_beats + 1;
                    if (l_wr_last[i]) lwr_last = lwr_last + 1;
                end
            if ((|l_wr_valid) && !c_wr_valid) mux_gap = mux_gap + 1;
        end
    end

    function automatic string blk_class(input int blk);
        int nx, ni;
        begin
            nx = 0; ni = 0;
            for (int q = 0; q < NBEAT; q++) begin
                if ((^u_mem.mem[blk*NBEAT + q]) === 1'bx) nx++;
                if (u_mem.mem[blk*NBEAT + q] === init_snap[blk*NBEAT + q]) ni++;
            end
            if (nx != 0)          blk_class = "X-POLLUTED";
            else if (ni == NBEAT) blk_class = "UNWRITTEN";
            else begin
                int ng;
                ng = 0;
                for (int q = 0; q < NBEAT; q++)
                    if (u_mem.mem[blk*NBEAT + q] === exp_img[blk*NBEAT + q]) ng++;
                if (ng == NBEAT) blk_class = "GOOD";
                else             blk_class = "WRONG-DATA";
            end
        end
    endfunction

    task automatic run_type(
        input [1:0] typ, input string init_f, input string exp_f,
        input string name
    );
        begin
            $display("conc %s ...", name);
            wr_n = 0; wr_beats = 0; lwr_beats = 0; lwr_last = 0; mux_gap = 0;
            rst_n = 1'b0; start = 1'b0;
            passes = PASSES; lane_length = CTXBLKS; memory_blocks = CTXBLKS;
            type_i = typ;
            seen_done = '0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);

            // Seed the shared memory (context-major: ctx c's blocks live at
            // c*CTXBLKS..+CTXBLKS — exactly the conc's i*ctx_len mapping).
            for (int b = 0; b < TOTALBLK * NBEAT; b++)
                u_mem.mem[b] = '0;
            $readmemh(init_f, u_mem.mem);
            for (int b = 0; b < TOTALBLK * NBEAT; b++)
                init_snap[b] = u_mem.mem[b];
            for (int b = 0; b < TOTALBLK * NBEAT; b++)
                exp_img[b] = '0;
            $readmemh(exp_f, exp_img);

            start = 1'b1;
            @(posedge clk);
            start = 1'b0;

            cycles = 0;
            while (((seen_done & start_mask) != start_mask) && cycles < 1_000_000) begin
                @(posedge clk);
                seen_done <= seen_done | lane_done;
                cycles = cycles + 1;
            end

            if ((seen_done & start_mask) != start_mask) begin
                $display("FAIL %s timeout (%0d cycles, done=%b)",
                         name, cycles, seen_done);
                errors = errors + 1;
            end else begin
                begin : fp_always
                    int nw, nu, nx;
                    string cl;
                    nw = 0; nu = 0; nx = 0;
                    for (int c2 = 0; c2 < NCTX; c2++)
                        if (start_mask[c2])
                            for (int k2 = 0; k2 < CTXBLKS; k2++) begin
                                cl = blk_class(c2*CTXBLKS+k2);
                                if (cl == "WRONG-DATA") nw++;
                                else if (cl == "UNWRITTEN") nu++;
                                else if (cl == "X-POLLUTED") nx++;
                            end
                    $display("  [fp] %s classes: wrong=%0d unwritten=%0d xpoll=%0d good=%0d wr_n=%0d",
                             name, nw, nu, nx,
                             (start_mask & {NCTX{1'b1}} ? 4'd0 : 4'd0)
                             + (CTXBLKS*$countones(start_mask) - nw - nu - nx),
                             wr_n);
                    $display("  [fp] %s writes[0..11]: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                             name, wr_log[0], wr_log[1], wr_log[2], wr_log[3],
                             wr_log[4], wr_log[5], wr_log[6], wr_log[7],
                             wr_log[8], wr_log[9], wr_log[10], wr_log[11]);
                    $display("  [fp] %s writes[..last]: %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                             name, wr_log[12], wr_log[13], wr_log[14], wr_log[15],
                             wr_log[16], wr_log[17], wr_log[18], wr_log[19],
                             wr_log[20], wr_log[21], wr_log[22], wr_log[23]);
                    $sformat(fp2_sum[fp2_n],
                             "%s: model_beats=%0d model_last=%0d lane_beats=%0d lane_last=%0d muxgap=%0d wrlog0..3=%0d,%0d,%0d,%0d",
                             name, wr_beats, wr_n, lwr_beats, lwr_last, mux_gap,
                             wr_log[0], wr_log[1], wr_log[2], wr_log[3]);
                    fp2_n = fp2_n + 1;
                    $display("  [fp2] %s: model(beats=%0d last=%0d) lane(beats=%0d last=%0d) muxgap=%0d",
                             name, wr_beats, wr_n, lwr_beats, lwr_last, mux_gap);
                end
                mism = 0;
                for (int b = 0; b < TOTALBLK * NBEAT; b++) begin
                    // sharing-level probes: only started contexts are checked
                    if (start_mask[b / (CTXBLKS*NBEAT)] &&
                        (u_mem.mem[b] !== exp_img[b]))
                        mism = mism + 1;
                end
                if (mism != 0) begin
                    int fd_ctx, fd_blk;
                    fd_ctx = -1; fd_blk = -1;
                    // find the true first differing block (any beat)
                    for (int c = 0; c < NCTX && fd_ctx < 0; c++)
                        for (int k = 0; k < CTXBLKS && start_mask[c]; k++) begin
                            int nd;
                            nd = 0;
                            for (int q = 0; q < NBEAT; q++)
                                if (u_mem.mem[(c*CTXBLKS+k)*NBEAT+q] !== exp_img[(c*CTXBLKS+k)*NBEAT+q])
                                    nd++;
                            if (nd != 0) begin
                                fd_ctx = c; fd_blk = k;
                                fp_sum[fp_n] = "";
                                fp_sum[fp_n] = {name, " mask=", " ",
                                               blk_class(c*CTXBLKS+k)};
                                fp_n = fp_n + 1;
                                $display("  [fp] %s mask=%b first_div=(ctx %0d blk %0d) %s got0=%016h want0=%016h",
                                         name, start_mask, c, k,
                                         blk_class(c*CTXBLKS+k),
                                         u_mem.mem[(c*CTXBLKS+k)*NBEAT][63:0],
                                         exp_img[(c*CTXBLKS+k)*NBEAT][63:0]);
                                k = CTXBLKS;
                            end
                        end
                    $display("FAIL %s %0d beat(s) differ", name, mism);
                    errors = errors + 1;
                end else begin
                    $display("  %s: %0d contexts x %0d blocks OK (mask=%b, %0d cycles)",
                             name, NCTX, CTXBLKS, start_mask, cycles);
                end
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        errors = 0;
        rst_n = 1'b0;
        start_mask = {NCTX{1'b1}};

        run_type(2'd1, "gen/conc_i_init.hex",  "gen/conc_i_exp.hex",  "argon2i");
        run_type(2'd0, "gen/conc_d_init.hex",  "gen/conc_d_exp.hex",  "argon2d");
        run_type(2'd2, "gen/conc_id_init.hex", "gen/conc_id_exp.hex", "argon2id");

        // Sharing-level probes for the d path (CI-debug fingerprints).
        start_mask = '0;
        start_mask[0] = 1'b1;    // single context through the conc
        run_type(2'd0, "gen/conc_d_init.hex",  "gen/conc_d_exp.hex",  "argon2d@1ctx");
        start_mask = '0;
        start_mask[0] = 1'b1;    // two contexts
        start_mask[1] = 1'b1;
        run_type(2'd0, "gen/conc_d_init.hex",  "gen/conc_d_exp.hex",  "argon2d@2ctx");
        start_mask = {NCTX{1'b1}};

        $display("FP-SUMMARY: %0d fingerprints", fp_n);
        for (int q = 0; q < fp_n; q++)
            $display("FP-SUMMARY: %0s", fp_sum[q]);
        for (int q = 0; q < fp2_n; q++)
            $display("FP2 %0s", fp2_sum[q]);
        if (proto_err != 0 || u_mem.errors != 0 || u_mem.ord_errs != 0) begin
            $display("FAIL conc protocol errors: %0d beat-order, %0d write-burst, %0d port-order",
                     proto_err, u_mem.errors, u_mem.ord_errs);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("tb_argon2_conc PASS (NCTX=%0d m'=%0d t=%0d N_P=%0d)",
                     NCTX, CTXBLKS, PASSES, N_P);
        else
            $display("tb_argon2_conc FAIL (%0d)", errors);
        $finish;
    end
endmodule
