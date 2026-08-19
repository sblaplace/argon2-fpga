// SPDX-License-Identifier: MIT
// Single-lane fill controller (the bandwidth-critical loop).
//
// Assumes B[0] and B[1] have already been written (H' of H0). Walks
// columns 2 .. lane_length-1 for each pass / slice, issuing:
//   1. compute (lane, index) of the reference block
//        argon2i / first half of argon2id: G in counter mode, known
//        a whole 128-block window ahead — the random read is issued
//        at the start of G so it is a full compute-latency early.
//        argon2d: J1||J2 = first 8 bytes of the previous block.
//   2. read prev block (sequential, cacheable)
//   3. read ref  block (random) — first, when the address is independent
//   4. on pass > 0, read dest (v1.3 XOR)
//   5. G(prev, ref) [⊕ dest]
//   6. write dest
//
// Memory port is block-addressed: the interconnect (AWS F1 CL_DRAM_DMA,
// AXI-MM, HBM) bursts 1024-byte blocks. One outstanding read.
//
// One instance walks one lane. Multi-lane jobs instantiate several of
// these and join `sync_req`/`sync_ack` at each slice boundary (see
// argon2_fill_job). p = 1 never waits.

`timescale 1ns / 1ps

module argon2_fill_ctrl #(
    parameter int ADDR_W = 32,
    parameter int N_P    = 1   // parallel P units in the compression G
) (
    input  logic              clk,
    input  logic              rst_n,

    // Job (held stable while busy)
    input  logic              start,
    output logic              busy,
    output logic              done,
    input  logic [31:0]       passes,          // t
    input  logic [31:0]       lanes,           // p  (this ctrl walks one lane)
    input  logic [31:0]       lane_id,
    input  logic [31:0]       lane_length,     // q
    input  logic [31:0]       memory_blocks,   // m'
    input  logic [1:0]        type_i,          // 0=d 1=i 2=id

    // Slice barrier. Held until every sibling lane finishes the same
    // slice; ignored when lanes == 1 (ack may be tied high or left open).
    output logic              sync_req,
    input  logic              sync_ack,

    // Block memory (1024 B = 16 × 512 b)
    output logic              mem_rd_valid,
    input  logic              mem_rd_ready,
    output logic [ADDR_W-1:0] mem_rd_addr,     // block index
    input  logic              mem_rd_data_v,
    input  logic [511:0]      mem_rd_data,
    input  logic              mem_rd_last,

    output logic              mem_wr_valid,
    input  logic              mem_wr_ready,
    output logic [ADDR_W-1:0] mem_wr_addr,
    output logic [511:0]      mem_wr_data,
    output logic              mem_wr_last,

    // Debug: current FSM state (for cycle-accounting perf benches).
    output logic [4:0]        state_o
);
    localparam int SYNC = 4;

    typedef enum logic [4:0] {
        IDLE,
        SEG_PREP,
        ADDR_WAIT,
        DISPATCH,
        ISSUE_REF,
        COLLECT_REF,
        ISSUE_PREV,
        COLLECT_PREV,
        ISSUE_DEST,
        COLLECT_DEST,
        COMPRESS,
        WRITE,
        ADVANCE,
        SLICE_SYNC,
        DREF_SETTLE,
        DEST_WAIT
    } state_t;
    state_t state;

    logic [31:0] pass_r, slice_r, index_r;
    logic [31:0] segment_length;
    logic [31:0] curr_idx, prev_idx, ref_idx, ref_lane;
    logic        independent;
    logic        with_xor;

    logic [511:0] prev_q [0:15];
    logic [511:0] ref_q  [0:15];
    logic [511:0] dest_q [0:15];
    logic [511:0] pref_q [0:15];
    logic [511:0] cache_q [0:15]; // last block written: next block's prev
    logic         cache_valid;
    logic         dstream;        // dest read streams straight into G's LOAD
    logic [4:0]   beat;
    logic [4:0]   pref_beat;
    logic [4:0]   wr_beat;
    logic         pref_issued, pref_ready, pref_accepted;
    logic         dest_issued, dest_accepted, dest_done;
    logic [4:0]   dest_beat;

    assign state_o = state;

    // Compress streaming. in_* and out_* are driven combinationally from the
    // FSM state and `beat`: the beat counter only advances on a handshake, so
    // registering the payload off `beat` would present each word one cycle
    // late (word 0 twice, word 15 never).
    logic         c_in_valid, c_in_ready, c_in_last;
    logic [511:0] c_in_x, c_in_y, c_in_dest;
    logic         c_out_valid, c_out_ready, c_out_last;
    logic [511:0] c_out_data;

    // When dstream is set the dest read arrives on the memory port beat by
    // beat and feeds the compression LOAD directly (stream-locked): no
    // COLLECT_DEST round trip, no separate 16-beat LOAD afterwards.
    assign c_in_valid = (state == COMPRESS) && (dstream ? mem_rd_data_v : 1'b1);
    assign c_in_x     = prev_q[beat[3:0]];
    assign c_in_y     = ref_q [beat[3:0]];
    assign c_in_dest  = dstream ? mem_rd_data
                                : (with_xor ? dest_q[beat[3:0]] : 512'd0);
    assign c_in_last  = (beat == 5'd15);

    // Write port is a straight pass-through of the compress output stream.
    assign c_out_ready  = (state == WRITE) && mem_wr_ready;
    assign mem_wr_valid = (state == WRITE) && c_out_valid;
    assign mem_wr_data  = c_out_data;
    assign mem_wr_last  = c_out_last;

    argon2_compress #(.N_P(N_P)) u_g (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (c_in_valid),
        .in_ready (c_in_ready),
        .in_x     (c_in_x),
        .in_y     (c_in_y),
        .in_last  (c_in_last),
        .with_xor (with_xor),
        .in_dest  (c_in_dest),
        .out_valid(c_out_valid),
        .out_ready(c_out_ready),
        .out_data (c_out_data),
        .out_last (c_out_last)
    );

    // Current-position index_alpha
    logic [31:0] j1, ref_area, start_pos, z;
    logic        same_lane;
    logic [63:0] pseudo_rand, prev_word0, addr_word, addr_word_n;

    argon2_ref_area u_area (
        .pass           (pass_r),
        .slice          (slice_r),
        .index          (index_r),
        .lane_length    (lane_length),
        .segment_length (segment_length),
        .same_lane      (same_lane),
        .ref_area       (ref_area),
        .start_position (start_pos)
    );

    argon2_index u_idx (
        .j1             (j1),
        .ref_area       (ref_area),
        .start_position (start_pos),
        .lane_length    (lane_length),
        .ref_index      (z)
    );

    // Lookahead index_alpha (next column, same window) for the prefetch.
    logic [31:0] index_n, j1_n, ref_area_n, start_pos_n, z_n, ref_lane_n, ref_idx_n;
    logic        same_lane_n, can_prefetch;

    argon2_ref_area u_area_n (
        .pass           (pass_r),
        .slice          (slice_r),
        .index          (index_n),
        .lane_length    (lane_length),
        .segment_length (segment_length),
        .same_lane      (same_lane_n),
        .ref_area       (ref_area_n),
        .start_position (start_pos_n)
    );

    argon2_index u_idx_n (
        .j1             (j1_n),
        .ref_area       (ref_area_n),
        .start_position (start_pos_n),
        .lane_length    (lane_length),
        .ref_index      (z_n)
    );

    logic        a_init, a_start, a_busy, a_done;

    argon2_addr_gen #(.N_P(N_P)) u_addr (
        .clk           (clk),
        .rst_n         (rst_n),
        .init          (a_init),
        .pass          (pass_r),
        .lane          (lane_id),
        .slice         (slice_r),
        .memory_blocks (memory_blocks),
        .time_cost     (passes),
        .type_i        ({30'd0, type_i}),
        .start         (a_start),
        .busy          (a_busy),
        .done          (a_done),
        .rd_idx        (index_r[6:0]),
        .rd_j          (addr_word),
        .rd_idx_b      (index_n[6:0]),
        .rd_j_b        (addr_word_n)
    );

    // Continuous assigns (not one big always_comb): ref_area / start_pos feed
    // argon2_index, whose output feeds ref_idx. Lumping them into a single
    // procedural block makes the whole set look like one circular node to a
    // cycle-accurate simulator (Verilator UNOPTFLAT).
    assign segment_length = lane_length / SYNC;
    assign independent    = (type_i == 2'd1) ||
                            (type_i == 2'd2 && pass_r == 32'd0 && slice_r < 32'd2);
    assign with_xor       = (pass_r != 32'd0);
    assign curr_idx       = lane_id * lane_length + slice_r * segment_length + index_r;
    assign prev_idx       = (curr_idx % lane_length == 32'd0)
                          ? (curr_idx + lane_length - 32'd1)
                          : (curr_idx - 32'd1);

    // Destination of the NEXT block's dest-xor read (pass > 0): either the
    // next column of this slice or the first column of the next slice/pass.
    // Issued as soon as the prefetch releases the read port, so the whole
    // read hides behind the current block's G and write.
    logic [31:0] next_slice_base, dest_next_addr;
    logic        dest_last_blk;
    assign next_slice_base = (slice_r == 32'd3)
        ? (lane_id * lane_length)                             // next pass, slice 0
        : (lane_id * lane_length + (slice_r + 32'd1) * segment_length);
    assign dest_next_addr  = (index_r + 32'd1 < segment_length)
        ? (curr_idx + 32'd1)
        : next_slice_base;
    assign dest_last_blk   = (pass_r + 32'd1 == passes)
                           && (slice_r == 32'd3)
                           && (index_r + 32'd1 >= segment_length);
    assign prev_word0     = prev_q[0][63:0];
    assign pseudo_rand    = independent ? addr_word : prev_word0;
    assign j1             = pseudo_rand[31:0];
    assign ref_lane       = ((pass_r == 32'd0) && (slice_r == 32'd0))
                          ? lane_id
                          : pseudo_rand[63:32] % lanes;
    assign same_lane      = (ref_lane == lane_id);
    assign ref_idx        = ref_lane * lane_length + z;

    assign index_n        = index_r + 32'd1;
    assign j1_n           = addr_word_n[31:0];
    assign ref_lane_n     = ((pass_r == 32'd0) && (slice_r == 32'd0))
                          ? lane_id
                          : addr_word_n[63:32] % lanes;
    assign same_lane_n    = (ref_lane_n == lane_id);
    assign ref_idx_n      = ref_lane_n * lane_length + z_n;
    assign can_prefetch   = independent
                          && (index_n < segment_length)
                          && (index_n[6:0] != 7'd0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            mem_rd_valid <= 1'b0;
            a_init       <= 1'b0;
            a_start      <= 1'b0;
            pass_r       <= 32'd0;
            slice_r      <= 32'd0;
            index_r      <= 32'd0;
            beat         <= 5'd0;
            pref_beat    <= 5'd0;
            pref_issued  <= 1'b0;
            pref_ready   <= 1'b0;
            pref_accepted<= 1'b0;
            dest_issued  <= 1'b0;
            dest_accepted<= 1'b0;
            dest_done    <= 1'b0;
            dest_beat    <= 5'd0;
            cache_valid  <= 1'b0;
            dstream      <= 1'b0;
            wr_beat      <= 5'd0;
            sync_req     <= 1'b0;
            mem_rd_addr  <= '0;
            mem_wr_addr  <= '0;
        end else begin
            done        <= 1'b0;
            a_init      <= 1'b0;
            a_start     <= 1'b0;

            // Prefetch collector: the random read launched at the start of G
            // returns during COMPRESS / WRITE / ADVANCE. Collection starts
            // only once the prefetch's own AR has been accepted, so beats of
            // a still-in-flight dest read (dstream mode) are never captured.
            if (pref_issued && !pref_accepted && mem_rd_valid && mem_rd_ready) begin
                pref_accepted <= 1'b1;
                mem_rd_valid  <= 1'b0;
            end
            if ((state == COMPRESS || state == WRITE || state == ADVANCE)
                    && pref_issued && pref_accepted && !pref_ready) begin
                if (mem_rd_data_v) begin
                    pref_q[pref_beat] <= mem_rd_data;
                    if (mem_rd_last || pref_beat == 5'd15) begin
                        pref_ready    <= 1'b1;
                        pref_accepted <= 1'b0;
                        pref_beat     <= 5'd0;
                        // The read port is free: launch the NEXT block's
                        // dest-xor read now so its latency hides behind
                        // this block's G and write.
                        if (with_xor && !dest_last_blk
                                && !dest_issued && !mem_rd_valid) begin
                            mem_rd_addr  <= dest_next_addr[ADDR_W-1:0];
                            mem_rd_valid <= 1'b1;
                            dest_issued  <= 1'b1;
                            dest_beat    <= 5'd0;
                        end
                    end else begin
                        pref_beat <= pref_beat + 5'd1;
                    end
                end
            end

            // Dest collector: the early dest read returns during
            // COMPRESS / WRITE / ADVANCE and fills dest_q in the background.
            // No data gating is needed: the dest read is issued only after
            // the prefetch has fully returned, so the only beats on the R
            // channel from then on are the dest read's. (The dstream path,
            // where the LOAD itself consumes the beats, has dest_issued
            // cleared, so this collector is inactive there.)
            if (dest_issued && !dest_accepted && mem_rd_valid && mem_rd_ready) begin
                dest_accepted <= 1'b1;
                mem_rd_valid  <= 1'b0;
            end
            if (dest_issued && dest_accepted && !dest_done) begin
                if (mem_rd_data_v) begin
                    dest_q[dest_beat] <= mem_rd_data;
                    if (mem_rd_last || dest_beat == 5'd15) begin
                        dest_done    <= 1'b1;
                        dest_beat    <= 5'd0;
                    end else begin
                        dest_beat <= dest_beat + 5'd1;
                    end
                end
            end

            case (state)
                IDLE: begin
                    busy     <= 1'b0;
                    sync_req <= 1'b0;
                    if (start) begin
                        busy        <= 1'b1;
                        pass_r      <= 32'd0;
                        slice_r     <= 32'd0;
                        index_r     <= 32'd2; // B[0], B[1] already filled
                        pref_issued  <= 1'b0;
                        pref_ready   <= 1'b0;
                        pref_accepted<= 1'b0;
                        cache_valid  <= 1'b0;  // B[0..1] were not written by us
                        state       <= SEG_PREP;
                    end
                end

                SEG_PREP: begin
                    if (pass_r == passes) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= IDLE;
                    end else if (index_r >= segment_length) begin
                        // Empty first segment (q/4 == 2): skip to the next.
                        state <= ADVANCE;
                    end else if (independent) begin
                        a_init  <= 1'b1;
                        a_start <= 1'b1;
                        state   <= ADDR_WAIT;
                    end else begin
                        state <= DISPATCH;
                    end
                end

                ADDR_WAIT: begin
                    if (a_done) begin
                        if (index_r >= segment_length)
                            state <= ADVANCE;
                        else
                            state <= DISPATCH;
                    end
                end

                DISPATCH: begin
                    beat <= 5'd0;
                    if (independent && pref_ready) begin
                        ref_q[0]  <= pref_q[0];
                        ref_q[1]  <= pref_q[1];
                        ref_q[2]  <= pref_q[2];
                        ref_q[3]  <= pref_q[3];
                        ref_q[4]  <= pref_q[4];
                        ref_q[5]  <= pref_q[5];
                        ref_q[6]  <= pref_q[6];
                        ref_q[7]  <= pref_q[7];
                        ref_q[8]  <= pref_q[8];
                        ref_q[9]  <= pref_q[9];
                        ref_q[10] <= pref_q[10];
                        ref_q[11] <= pref_q[11];
                        ref_q[12] <= pref_q[12];
                        ref_q[13] <= pref_q[13];
                        ref_q[14] <= pref_q[14];
                        ref_q[15] <= pref_q[15];
                        pref_ready   <= 1'b0;
                        pref_issued  <= 1'b0;
                        pref_accepted<= 1'b0;
                        if (cache_valid) begin
                            prev_q[0]  <= cache_q[0];
                            prev_q[1]  <= cache_q[1];
                            prev_q[2]  <= cache_q[2];
                            prev_q[3]  <= cache_q[3];
                            prev_q[4]  <= cache_q[4];
                            prev_q[5]  <= cache_q[5];
                            prev_q[6]  <= cache_q[6];
                            prev_q[7]  <= cache_q[7];
                            prev_q[8]  <= cache_q[8];
                            prev_q[9]  <= cache_q[9];
                            prev_q[10] <= cache_q[10];
                            prev_q[11] <= cache_q[11];
                            prev_q[12] <= cache_q[12];
                            prev_q[13] <= cache_q[13];
                            prev_q[14] <= cache_q[14];
                            prev_q[15] <= cache_q[15];
                            if (with_xor) begin
                                if (dest_done) begin
                                    // Dest-xor read completed in the
                                    // background: compress straight away.
                                    dstream <= 1'b0;
                                    state   <= COMPRESS;
                                    dest_issued   <= 1'b0;
                                    dest_accepted <= 1'b0;
                                    dest_done     <= 1'b0;
                                end else if (dest_issued) begin
                                    // Still in flight: wait for the
                                    // background collector to finish.
                                    dstream <= 1'b0;
                                    state   <= DEST_WAIT;
                                end else begin
                                    dstream      <= 1'b1;
                                    mem_rd_addr  <= curr_idx[ADDR_W-1:0];
                                    mem_rd_valid <= 1'b1;
                                    state        <= ISSUE_DEST;
                                end
                            end else begin
                                dstream <= 1'b0;
                                state   <= COMPRESS;
                                dest_issued   <= 1'b0;
                                dest_accepted <= 1'b0;
                                dest_done     <= 1'b0;
                            end
                        end else begin
                            mem_rd_addr  <= prev_idx[ADDR_W-1:0];
                            mem_rd_valid <= 1'b1;
                            state        <= ISSUE_PREV;
                        end
                    end else if (independent) begin
                        dstream      <= 1'b0;
                        mem_rd_addr  <= ref_idx[ADDR_W-1:0];
                        mem_rd_valid <= 1'b1;
                        state        <= ISSUE_REF;
                    end else if (cache_valid) begin
                        // argon2d / second half of argon2id: J1||J2 comes
                        // from prev_q[0]. The cache copy lands next cycle,
                        // so settle one cycle before issuing the ref read.
                        prev_q[0]  <= cache_q[0];
                        prev_q[1]  <= cache_q[1];
                        prev_q[2]  <= cache_q[2];
                        prev_q[3]  <= cache_q[3];
                        prev_q[4]  <= cache_q[4];
                        prev_q[5]  <= cache_q[5];
                        prev_q[6]  <= cache_q[6];
                        prev_q[7]  <= cache_q[7];
                        prev_q[8]  <= cache_q[8];
                        prev_q[9]  <= cache_q[9];
                        prev_q[10] <= cache_q[10];
                        prev_q[11] <= cache_q[11];
                        prev_q[12] <= cache_q[12];
                        prev_q[13] <= cache_q[13];
                        prev_q[14] <= cache_q[14];
                        prev_q[15] <= cache_q[15];
                        dstream     <= 1'b0;
                        state       <= DREF_SETTLE;
                    end else begin
                        dstream      <= 1'b0;
                        mem_rd_addr  <= prev_idx[ADDR_W-1:0];
                        mem_rd_valid <= 1'b1;
                        state        <= ISSUE_PREV;
                    end
                end

                DREF_SETTLE: begin
                    mem_rd_addr  <= ref_idx[ADDR_W-1:0];
                    mem_rd_valid <= 1'b1;
                    state        <= ISSUE_REF;
                end

                DEST_WAIT: begin
                    // The early dest read is still streaming into dest_q
                    // (background collector). Hold until it lands.
                    if (dest_done) begin
                        dstream       <= 1'b0;
                        dest_issued   <= 1'b0;
                        dest_accepted <= 1'b0;
                        dest_done     <= 1'b0;
                        state         <= COMPRESS;
                    end
                end

                ISSUE_REF: begin
                    if (mem_rd_ready) begin
                        mem_rd_valid <= 1'b0;
                        state        <= COLLECT_REF;
                    end
                end

                COLLECT_REF: begin
                    if (mem_rd_data_v) begin
                        ref_q[beat] <= mem_rd_data;
                        if (mem_rd_last || beat == 5'd15) begin
                            beat <= 5'd0;
                            if (independent) begin
                                mem_rd_addr  <= prev_idx[ADDR_W-1:0];
                                mem_rd_valid <= 1'b1;
                                state        <= ISSUE_PREV;
                            end else if (with_xor) begin
                                if (dest_done) begin
                                    dstream <= 1'b0;
                                    state   <= COMPRESS;
                                    dest_issued   <= 1'b0;
                                    dest_accepted <= 1'b0;
                                    dest_done     <= 1'b0;
                                end else begin
                                    dstream      <= 1'b1;
                                    mem_rd_addr  <= curr_idx[ADDR_W-1:0];
                                    mem_rd_valid <= 1'b1;
                                    state        <= ISSUE_DEST;
                                end
                            end else begin
                                state <= COMPRESS;
                            dest_issued   <= 1'b0;
                            dest_accepted <= 1'b0;
                            dest_done     <= 1'b0;
                                dest_issued   <= 1'b0;
                                dest_accepted <= 1'b0;
                                dest_done     <= 1'b0;
                            end
                        end else begin
                            beat <= beat + 5'd1;
                        end
                    end
                end

                ISSUE_PREV: begin
                    if (mem_rd_ready) begin
                        mem_rd_valid <= 1'b0;
                        state        <= COLLECT_PREV;
                    end
                end

                COLLECT_PREV: begin
                    if (mem_rd_data_v) begin
                        prev_q[beat] <= mem_rd_data;
                        if (mem_rd_last || beat == 5'd15) begin
                            beat <= 5'd0;
                            if (!independent) begin
                                // J1||J2 now live in prev_q[0]; combo ref_idx
                                // updates this cycle, issue next cycle.
                                mem_rd_addr  <= ref_idx[ADDR_W-1:0];
                                mem_rd_valid <= 1'b1;
                                state        <= ISSUE_REF;
                            end else if (with_xor) begin
                                if (dest_done) begin
                                    dstream <= 1'b0;
                                    state   <= COMPRESS;
                                    dest_issued   <= 1'b0;
                                    dest_accepted <= 1'b0;
                                    dest_done     <= 1'b0;
                                end else if (dest_issued) begin
                                    dstream <= 1'b0;
                                    state   <= DEST_WAIT;
                                end else begin
                                    dstream      <= 1'b1;
                                    mem_rd_addr  <= curr_idx[ADDR_W-1:0];
                                    mem_rd_valid <= 1'b1;
                                    state        <= ISSUE_DEST;
                                end
                            end else begin
                                state <= COMPRESS;
                            dest_issued   <= 1'b0;
                            dest_accepted <= 1'b0;
                            dest_done     <= 1'b0;
                                dest_issued   <= 1'b0;
                                dest_accepted <= 1'b0;
                                dest_done     <= 1'b0;
                            end
                        end else begin
                            beat <= beat + 5'd1;
                        end
                    end
                end

                ISSUE_DEST: begin
                    if (mem_rd_ready) begin
                        mem_rd_valid <= 1'b0;
                        state        <= dstream ? COMPRESS : COLLECT_DEST;
                    end
                end

                COLLECT_DEST: begin
                    if (mem_rd_data_v) begin
                        dest_q[beat] <= mem_rd_data;
                        if (mem_rd_last || beat == 5'd15) begin
                            beat  <= 5'd0;
                            state <= COMPRESS;
                            dest_issued   <= 1'b0;
                            dest_accepted <= 1'b0;
                            dest_done     <= 1'b0;
                        end else begin
                            beat <= beat + 5'd1;
                        end
                    end
                end

                COMPRESS: begin
                    // Launch the next random read as soon as this G starts
                    // so it is a full compute-latency early.
                    if (can_prefetch && !pref_issued && !pref_ready && !mem_rd_valid) begin
                        mem_rd_addr  <= ref_idx_n[ADDR_W-1:0];
                        mem_rd_valid <= 1'b1;
                        pref_issued  <= 1'b1;
                        pref_beat    <= 5'd0;
                    end
                    if (c_in_valid && c_in_ready) begin
                        if (beat == 5'd15) begin
                            beat        <= 5'd0;
                            wr_beat     <= 5'd0;
                            mem_wr_addr <= curr_idx[ADDR_W-1:0];
                            state       <= WRITE;
                        end else begin
                            beat <= beat + 5'd1;
                        end
                    end
                end

                WRITE: begin
                    // (the prefetch collector above also runs in WRITE)
                    // The stream written here is the next block's prev —
                    // shadow it into the cache so the prev read disappears.
                    if (c_out_valid && c_out_ready) begin
                        cache_q[wr_beat] <= c_out_data;
                        if (c_out_last) begin
                            cache_valid <= 1'b1;
                            state       <= ADVANCE;
                        end else begin
                            wr_beat <= wr_beat + 5'd1;
                        end
                    end
                end

                ADVANCE: begin
                    // Finish collecting a prefetch that outlived the write.
                    if (pref_issued && !pref_ready) begin
                        state <= ADVANCE;
                    end else if (index_r >= segment_length
                              || index_r + 32'd1 == segment_length) begin
                        pref_issued  <= 1'b0;
                        pref_ready   <= 1'b0;
                        pref_accepted<= 1'b0;
                        if (lanes > 32'd1) begin
                            sync_req <= 1'b1;
                            state    <= SLICE_SYNC;
                        end else begin
                            if (slice_r + 32'd1 == 32'd4) begin
                                slice_r <= 32'd0;
                                pass_r  <= pass_r + 32'd1;
                            end else begin
                                slice_r <= slice_r + 32'd1;
                            end
                            index_r <= 32'd0;
                            state   <= SEG_PREP;
                        end
                    end else begin
                        index_r <= index_r + 32'd1;
                        if (independent && ((index_r + 32'd1) & 32'd127) == 32'd0) begin
                            // New 128-block window, same Z: increment counter.
                            pref_issued  <= 1'b0;
                            pref_ready   <= 1'b0;
                            pref_accepted<= 1'b0;
                            a_start      <= 1'b1;
                            state       <= ADDR_WAIT;
                        end else begin
                            state <= DISPATCH;
                        end
                    end
                end

                SLICE_SYNC: begin
                    sync_req <= 1'b1;
                    if (sync_ack) begin
                        sync_req <= 1'b0;
                        if (slice_r + 32'd1 == 32'd4) begin
                            slice_r <= 32'd0;
                            pass_r  <= pass_r + 32'd1;
                        end else begin
                            slice_r <= slice_r + 32'd1;
                        end
                        index_r <= 32'd0;
                        state   <= SEG_PREP;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
