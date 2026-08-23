// SPDX-License-Identifier: MIT
// Single-lane fill controller with write FIFO decoupling.

`timescale 1ns / 1ps

module argon2_fill_ctrl #(
    parameter int ADDR_W = 32,
    parameter int N_P    = 1
) (
    input  logic              clk,
    input  logic              rst_n,
    input  logic              start,
    output logic              busy,
    output logic              done,
    input  logic [31:0]       passes,
    input  logic [31:0]       lanes,
    input  logic [31:0]       lane_id,
    input  logic [31:0]       lane_length,
    input  logic [31:0]       memory_blocks,
    input  logic [1:0]        type_i,
    output logic              sync_req,
    input  logic              sync_ack,
    output logic              mem_rd_valid,
    input  logic              mem_rd_ready,
    output logic [ADDR_W-1:0] mem_rd_addr,
    // Owning memory channel of the read currently on mem_rd_addr (the
    // reference LANE for ref / dependent-ref reads, lane_id for prev /
    // dest reads). Held stable with the address; used by argon2_mem_xbar
    // for partitioned-memory p>1 routing. 4 bits -> up to 16 lanes; 0 for
    // every p=1 job.
    output logic [3:0]        mem_rd_owner,
    input  logic              mem_rd_data_v,
    input  logic [511:0]      mem_rd_data,
    input  logic              mem_rd_last,
    output logic              mem_wr_valid,
    input  logic              mem_wr_ready,
    output logic [ADDR_W-1:0] mem_wr_addr,
    output logic [511:0]      mem_wr_data,
    output logic              mem_wr_last,
    output logic [4:0]        state_o
);
    localparam int SYNC = 4;
    typedef enum logic [4:0] {
        IDLE, SEG_PREP, ADDR_WAIT, DISPATCH, ISSUE_REF, COLLECT_REF,
        ISSUE_PREV, COLLECT_PREV, ISSUE_DEST, COLLECT_DEST, COMPRESS,
        WRITE, ADVANCE, SLICE_SYNC, DREF_SETTLE, DEST_WAIT
    } state_t;
    state_t state;

    logic [31:0] pass_r, slice_r, index_r;
    logic [31:0] segment_length;
    logic [31:0] curr_idx, prev_idx, ref_idx, ref_lane;
    logic        independent, with_xor;

    logic [511:0] prev_q [0:15];
    logic [511:0] ref_q  [0:15];
    logic [511:0] dest_q [0:15];
    logic [511:0] pref_q [0:15];
    logic [511:0] cache_q [0:15];
    logic [ADDR_W-1:0] cache_addr;
    logic         cache_valid;
    // dstream: what the COMPRESS-state load streams live from the read port
    // instead of collecting first (the read port is the serial resource).
    //   DSM_NONE : all inputs from registers
    //   DSM_DEST : dest-xor beats stream into the load (original behavior)
    //   DSM_REF  : dependent-ref beats stream into the load (buffered beats
    //              come from dep_q via the dep_cnt watermark, later beats
    //              straight off the port)
    localparam logic [1:0] DSM_NONE = 2'd0, DSM_DEST = 2'd1, DSM_REF = 2'd2;
    logic [1:0]     dstream;
    logic [4:0]   beat;
    logic [4:0]   pref_beat;
    logic         pref_issued, pref_ready, pref_accepted;
    logic         dest_issued, dest_accepted, dest_done;
    logic [4:0]   dest_beat;

    // Dependent early next-ref, issued on the SAME read port while K drains
    // (no second AXI stream; see docs/PERF "Rejected"). Any pass: once the
    // next block's dest-xor read is issued early (deterministic address, see
    // the COMPRESS-state hook), the port order at drain beat 0 is free for
    // the dep read in pass>0 too — the two requests serialize on the single
    // outstanding read, which is exactly the intended schedule.
    logic [511:0] dep_q [0:15];
    logic [4:0]   dep_beat;
    logic [4:0]   dep_cnt;           // beats collected so far (watermark, 0..16)
    logic         dep_issued, dep_accepted, dep_ready;
    logic         dep_seen;
    logic [63:0]  dep_j1;
    logic [31:0]  dep_idx;
    logic [31:0]  dep_area, dep_spos, dep_z, dep_ridx;
    logic         dep_can, dep_self;

    // Overlapped next-block send during WRITE (drain): while the compressor
    // drains block N it also accepts block N+1's data into its idle buffer
    // (see argon2_compress double-buffering). The send streams in lockstep
    // with the drain beats: prev forwards the current output beat, ref
    // comes from a copy of the prefetched block. Only used for independent
    // (argon2i/id) pass-0 mid-segment blocks where everything is ready
    // before the drain starts.
    logic        nxt_latched;   // overlap eligible, pref_q copied to ref_q
    logic [4:0]  nxt_beat;
    logic        nxt_sent;      // all 16 beats sent
    logic        nxt_skip;      // next DISPATCH must skip data setup

    // Write FIFO 32 deep streaming
    localparam int WB_DEPTH = 32;
    logic [511:0] wb_data [0:WB_DEPTH-1];
    logic [ADDR_W-1:0] wb_addr [0:WB_DEPTH-1];
    logic         wb_last [0:WB_DEPTH-1];
    logic [5:0]   wb_wptr, wb_rptr;
    logic [5:0]   wb_count;
    logic [4:0]   wb_wbeat;

    logic wb_hit_ref, wb_hit_ref_n;
    logic cache_hit_ref, cache_hit_ref_n;
    logic dep_wb_hit;   // early-dep target still uncommitted in the write FIFO

    always_comb begin
        wb_hit_ref = 1'b0;
        wb_hit_ref_n = 1'b0;
        dep_wb_hit = 1'b0;
        for (int ii=0; ii<WB_DEPTH; ii = ii + 1) begin
            logic in_fifo;
            in_fifo = 1'b0;
            if (wb_count != 0) begin
                if (wb_wptr >= wb_rptr) in_fifo = (ii >= wb_rptr && ii < wb_wptr);
                else in_fifo = (ii >= wb_rptr || ii < wb_wptr);
            end
            if (in_fifo) begin
                if (wb_addr[ii] == ref_idx[ADDR_W-1:0]) wb_hit_ref = 1'b1;
                if (wb_addr[ii] == ref_idx_n[ADDR_W-1:0]) wb_hit_ref_n = 1'b1;
                if (wb_addr[ii] == dep_ridx[ADDR_W-1:0]) dep_wb_hit = 1'b1;
            end
        end
    end
    // NOTE: wb hits are NOT masked by cache hits anywhere — a cache hit is
    // serviced by forwarding (DISPATCH / DREF_SETTLE), never by reading
    // memory that might still be mid-commit.
    assign cache_hit_ref   = cache_valid && (cache_addr == ref_idx[ADDR_W-1:0]);
    assign cache_hit_ref_n = cache_valid && (cache_addr == ref_idx_n[ADDR_W-1:0]);

    assign mem_wr_valid = (wb_count != 0);
    assign mem_wr_data  = wb_data[wb_rptr];
    assign mem_wr_addr  = wb_addr[wb_rptr];
    assign mem_wr_last  = wb_last[wb_rptr];

    assign state_o = state;
    assign busy    = (state != IDLE) || (wb_count != 0) || start;

    logic         c_in_valid, c_in_ready, c_in_last;
    logic [511:0] c_in_x, c_in_y, c_in_dest;
    logic         c_out_valid, c_out_ready, c_out_last;
    logic [511:0] c_out_data;

    // Streaming inputs to the compressor. During WRITE with the overlapped
    // send active (nxt_sending), the next block's data streams in lockstep
    // with the drain beats starting on the FIRST output beat: prev forwards
    // the current output beat (block N's output = block N+1's prev), ref
    // comes from the prefetched ref_q copy.
    assign nxt_sending = nxt_latched && !nxt_sent;
    // DSM_REF: the dependent-ref read is still returning while the load runs.
    // Beats already collected (beat < dep_cnt) replay from dep_q; the beat
    // currently on the port (which the collector is writing to dep_q in the
    // same cycle, at index dep_cnt) flows straight into the load.
    assign c_in_valid = (state == COMPRESS)
                       ? ((dstream == DSM_DEST) ? mem_rd_data_v
                          : (dstream == DSM_REF) ? ((beat < dep_cnt) || mem_rd_data_v)
                          : 1'b1)
                       : (state == WRITE)   ? (nxt_sending && c_out_valid && c_out_ready)
                       : 1'b0;
    assign c_in_x     = (state == WRITE && nxt_sending) ? c_out_data : prev_q[beat[3:0]];
    assign c_in_y     = (state == WRITE && nxt_sending) ? ref_q[nxt_beat[3:0]]
                       : (dstream == DSM_REF) ? ((beat < dep_cnt) ? dep_q[beat[3:0]] : mem_rd_data)
                       : ref_q[beat[3:0]];
    assign c_in_dest  = (state == WRITE && nxt_sending) ? (with_xor ? dest_q[nxt_beat[3:0]] : 512'd0)
                       : (dstream == DSM_DEST) ? mem_rd_data
                       : (with_xor ? dest_q[beat[3:0]] : 512'd0);
    assign c_in_last  = (state == WRITE && nxt_sending) ? (nxt_beat == 5'd15) : (beat == 5'd15);
    assign c_out_ready = (state == WRITE) && (wb_count < WB_DEPTH);

    // Overlap eligibility: independent addressing (argon2i / argon2id first
    // half), the next ref already prefetched, prev available from the write
    // cache, the dest-xor word ready when this is a dest pass (dest_done holds
    // the NEXT block's dest — it is cleared on COMPRESS entry and re-armed only
    // by the dest read issued after that block's ref prefetch completes), and
    // not at a segment or address-window boundary. Must be true before the
    // drain starts so the send is aligned with drain beat 0. For pass>0 the
    // next block's dest (dest_q) is consumed by the drain just like pass 0's
    // ref/prev, so the chain extends into the dest-xor path.
    assign nxt_ok = independent && pref_ready && cache_valid
                  && (dest_done || !with_xor)
                  && (index_r + 32'd1 < segment_length)
                  && (index_n[6:0] != 7'd0);

    argon2_compress #(.N_P(N_P)) u_g (
        .clk(clk), .rst_n(rst_n),
        .in_valid(c_in_valid), .in_ready(c_in_ready),
        .in_x(c_in_x), .in_y(c_in_y), .in_last(c_in_last),
        .with_xor(with_xor), .in_dest(c_in_dest),
        .out_valid(c_out_valid), .out_ready(c_out_ready),
        .out_data(c_out_data), .out_last(c_out_last)
    );

    logic [31:0] j1, ref_area, start_pos, z;
    logic        same_lane;
    logic [63:0] pseudo_rand, prev_word0, addr_word, addr_word_n;

    argon2_ref_area u_area (
        .pass(pass_r), .slice(slice_r), .index(index_r),
        .lane_length(lane_length), .segment_length(segment_length),
        .same_lane(same_lane), .ref_area(ref_area), .start_position(start_pos)
    );
    argon2_index u_idx (
        .j1(j1), .ref_area(ref_area), .start_position(start_pos),
        .lane_length(lane_length), .ref_index(z)
    );
    logic [31:0] index_n, j1_n, ref_area_n, start_pos_n, z_n, ref_lane_n, ref_idx_n;
    logic        same_lane_n, can_prefetch, can_prefetch_n2;
    logic        nxt_ok;         // overlap eligible before the drain starts
    logic        nxt_sending;    // comb: overlapped send in progress
    logic        nxt_issue2;     // comb: latch pulse (issue K+2 prefetch)
    logic [31:0] ag_idx_n;       // u_area_n index: K+1, or K+2 during the latch
    logic [6:0]  ag_rdb;         // addr_gen rd_idx_b: K+1, or K+2 during the latch
    logic [31:0] index_n2;       // K+2 (= index_r + 2)

    // During the overlap latch the second address port is redirected to
    // block K+2 so the K+2 prefetch can be issued before the drain even
    // starts, letting every independent block chain (not every other one).
    assign index_n2    = index_n + 32'd1;
    assign nxt_issue2  = nxt_ok && !nxt_latched && !c_out_valid;
    assign ag_idx_n    = nxt_issue2 ? index_n2 : index_n;
    assign ag_rdb      = nxt_issue2 ? index_n2[6:0] : index_n[6:0];

    argon2_ref_area u_area_n (
        .pass(pass_r), .slice(slice_r), .index(ag_idx_n),
        .lane_length(lane_length), .segment_length(segment_length),
        .same_lane(same_lane_n), .ref_area(ref_area_n), .start_position(start_pos_n)
    );
    argon2_index u_idx_n (
        .j1(j1_n), .ref_area(ref_area_n), .start_position(start_pos_n),
        .lane_length(lane_length), .ref_index(z_n)
    );

    // Same-lane rule for the dependent early read: in pass 0 / slice 0 the
    // reference lane is forced to the own lane (RFC 9106 §3.3); afterwards it
    // is J2 % lanes, exactly like the serial path (ref_lane).
    logic dep_same_lane;
    logic [31:0] dep_lane;
    assign dep_same_lane = ((pass_r == 32'd0) && (slice_r == 32'd0))
                         ? 1'b1 : ((dep_j1[63:32] % lanes) == lane_id);
    assign dep_lane = ((pass_r == 32'd0) && (slice_r == 32'd0))
                    ? lane_id : (dep_j1[63:32] % lanes);
    argon2_ref_area u_area_dep (
        .pass(pass_r), .slice(slice_r), .index(index_n),
        .lane_length(lane_length), .segment_length(segment_length),
        .same_lane(dep_same_lane), .ref_area(dep_area), .start_position(dep_spos)
    );
    argon2_index u_idx_dep (
        .j1(dep_j1[31:0]), .ref_area(dep_area), .start_position(dep_spos),
        .lane_length(lane_length), .ref_index(dep_z)
    );
    assign dep_ridx = dep_lane * lane_length + dep_z;
    // dep_self: target is the block being written right now (K — its beats
    // are entering the write FIFO this drain and the RAM copy is stale until
    // commit) or the not-yet-computed K+1. dep_wb_hit: target still sits
    // uncommitted in the write FIFO (RAM read would return stale data); the
    // normal serial path handles both cases (DREF_SETTLE waits for the FIFO
    // to drain, then reads committed memory).
    assign dep_self = (dep_ridx == curr_idx) || (dep_ridx == curr_idx + 32'd1);
    assign dep_can  = !independent && (state == WRITE)
                   && dep_seen && (index_n < segment_length)
                   && !dep_issued && !dep_ready && !dep_accepted
                   && !pref_issued && !pref_accepted
                   && !mem_rd_valid && !dep_self && !dep_wb_hit;

    logic a_init, a_start, a_busy, a_done;
    argon2_addr_gen #(.N_P(N_P)) u_addr (
        .clk(clk), .rst_n(rst_n), .init(a_init), .pass(pass_r), .lane(lane_id),
        .slice(slice_r), .memory_blocks(memory_blocks), .time_cost(passes),
        .type_i({30'd0, type_i}), .start(a_start), .busy(a_busy), .done(a_done),
        .rd_idx(index_r[6:0]), .rd_j(addr_word),
        .rd_idx_b(ag_rdb), .rd_j_b(addr_word_n)
    );

    assign segment_length = lane_length / SYNC;
    assign independent    = (type_i == 2'd1) || (type_i == 2'd2 && pass_r == 32'd0 && slice_r < 32'd2);
    assign with_xor       = (pass_r != 32'd0);
    assign curr_idx       = lane_id * lane_length + slice_r * segment_length + index_r;
    assign prev_idx       = (curr_idx % lane_length == 32'd0) ? (curr_idx + lane_length - 32'd1) : (curr_idx - 32'd1);

    logic [31:0] next_slice_base, dest_next_addr;
    logic        dest_last_blk;
    assign next_slice_base = (slice_r == 32'd3) ? (lane_id * lane_length) : (lane_id * lane_length + (slice_r + 32'd1) * segment_length);
    assign dest_next_addr  = (index_r + 32'd1 < segment_length) ? (curr_idx + 32'd1) : next_slice_base;
    assign dest_last_blk   = (pass_r + 32'd1 == passes) && (slice_r == 32'd3) && (index_r + 32'd1 >= segment_length);
    assign prev_word0     = prev_q[0][63:0];
    assign pseudo_rand    = independent ? addr_word : prev_word0;
    assign j1             = pseudo_rand[31:0];
    assign ref_lane       = ((pass_r == 32'd0) && (slice_r == 32'd0)) ? lane_id : pseudo_rand[63:32] % lanes;
    assign same_lane      = (ref_lane == lane_id);
    assign ref_idx        = ref_lane * lane_length + z;
    assign index_n        = index_r + 32'd1;
    assign j1_n           = addr_word_n[31:0];
    assign ref_lane_n     = ((pass_r == 32'd0) && (slice_r == 32'd0)) ? lane_id : addr_word_n[63:32] % lanes;
    assign same_lane_n    = (ref_lane_n == lane_id);
    assign ref_idx_n      = ref_lane_n * lane_length + z_n;
    // Prefetch safety: the prefetched target's final data must already be
    // committed in memory. That rules out (a) blocks whose write is still in
    // the write FIFO (raw wb hit — NOT masked by a cache hit: nothing ever
    // forwards ref data from the cache, so a masked hit would read stale
    // RAM), (b) the last-written block (cache hit — service it from the
    // cache at DISPATCH instead), and (c) blocks that are not even written
    // yet: the one being compressed (curr_idx) and, for the chained K+2
    // prefetch issued during the drain latch, also the block being streamed
    // into the compressor (index_n = K+1).
    assign can_prefetch   = independent && (index_n < segment_length)
                          && (index_n[6:0] != 7'd0)
                          && !wb_hit_ref_n && !cache_hit_ref_n
                          && (ref_idx_n != curr_idx);
    // Same rule for block K+2 (used to chain the overlapped prefetches).
    // With nxt_issue2 the second address port already points at K+2, so
    // wb_hit_ref_n / ref_idx_n reflect K+2 during the latch pulse.
    assign can_prefetch_n2 = independent && (index_n2 < segment_length)
                           && (index_n2[6:0] != 7'd0)
                           && !wb_hit_ref_n && !cache_hit_ref_n
                           && (ref_idx_n != curr_idx) && (ref_idx_n != index_n);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            done  <= 1'b0;
            mem_rd_valid <= 1'b0;
            a_init <= 1'b0;
            a_start <= 1'b0;
            pass_r <= 32'd0;
            slice_r <= 32'd0;
            index_r <= 32'd0;
            beat <= 5'd0;
            pref_beat <= 5'd0;
            pref_issued <= 1'b0;
            pref_ready <= 1'b0;
            pref_accepted <= 1'b0;
            dest_issued <= 1'b0;
            dest_accepted <= 1'b0;
            dest_done <= 1'b0;
            dest_beat <= 5'd0;
            nxt_latched <= 1'b0;
            nxt_beat    <= 5'd0;
            nxt_sent    <= 1'b0;
            nxt_skip    <= 1'b0;
            cache_valid <= 1'b0;
            cache_addr <= '0;
            dstream <= DSM_NONE;
            sync_req <= 1'b0;
            mem_rd_addr <= '0;
            mem_rd_owner <= 4'd0;
            dep_beat <= 5'd0;
            dep_cnt  <= 5'd0;
            dep_issued <= 1'b0; dep_accepted <= 1'b0; dep_ready <= 1'b0;
            dep_seen <= 1'b0; dep_j1 <= 64'd0; dep_idx <= 32'd0;
            wb_wptr <= 6'd0;
            wb_rptr <= 6'd0;
            wb_count <= 6'd0;
            wb_wbeat <= 5'd0;
        end else begin
            logic wb_push, wb_pop;
            logic [5:0] next_count, next_wptr, next_rptr;
            wb_push = (state == WRITE) && c_out_valid && c_out_ready;
            wb_pop  = mem_wr_valid && mem_wr_ready;

            next_wptr = wb_wptr;
            next_rptr = wb_rptr;
            next_count = wb_count;

            if (wb_pop) begin
                next_rptr = (wb_rptr == WB_DEPTH-1) ? 6'd0 : wb_rptr + 6'd1;
                next_count = next_count - 6'd1;
            end
            if (wb_push) begin
                wb_data[wb_wptr] <= c_out_data;
                wb_addr[wb_wptr] <= curr_idx[ADDR_W-1:0];
                wb_last[wb_wptr] <= c_out_last;
                cache_q[wb_wbeat] <= c_out_data;
                next_wptr = (wb_wptr == WB_DEPTH-1) ? 6'd0 : wb_wptr + 6'd1;
                next_count = next_count + 6'd1;
                if (c_out_last) begin
                    cache_addr <= curr_idx[ADDR_W-1:0];
                    cache_valid <= 1'b1;
                    wb_wbeat <= 5'd0;
                end else wb_wbeat <= wb_wbeat + 5'd1;
            end
            wb_wptr <= next_wptr;
            wb_rptr <= next_rptr;
            wb_count <= next_count;

            done <= 1'b0;
            a_init <= 1'b0;
            a_start <= 1'b0;

            if (pref_issued && !pref_accepted && mem_rd_valid && mem_rd_ready) begin
                pref_accepted <= 1'b1;
                mem_rd_valid <= 1'b0;
            end
            // DISPATCH is included because the nxt_skip fast path can reach
            // it while a chained prefetch's last beat is still returning;
            // the normal path only enters DISPATCH with prefetch idle or
            // pref_ready set, so this cannot double-collect.
            if ((state == COMPRESS || state == WRITE || state == ADVANCE || state == DISPATCH) && pref_issued && pref_accepted && !pref_ready) begin
                if (mem_rd_data_v) begin
                    pref_q[pref_beat] <= mem_rd_data;
                    if (mem_rd_last || pref_beat == 5'd15) begin
                        pref_ready <= 1'b1;
                        pref_accepted <= 1'b0;
                        pref_beat <= 5'd0;
                        if (with_xor && !dest_last_blk && !dest_issued && !mem_rd_valid) begin
                            mem_rd_addr <= dest_next_addr[ADDR_W-1:0];
                            mem_rd_owner <= lane_id[3:0];
                            mem_rd_valid <= 1'b1;
                            dest_issued <= 1'b1;
                            dest_beat <= 5'd0;
                        end
                    end else pref_beat <= pref_beat + 5'd1;
                end
            end
            if (dest_issued && !dest_accepted && mem_rd_valid && mem_rd_ready) begin
                dest_accepted <= 1'b1;
                mem_rd_valid <= 1'b0;
            end
            if (dest_issued && dest_accepted && !dest_done) begin
                if (mem_rd_data_v) begin
                    dest_q[dest_beat] <= mem_rd_data;
                    if (mem_rd_last || dest_beat == 5'd15) begin
                        dest_done <= 1'b1;
                        dest_beat <= 5'd0;
                    end else dest_beat <= dest_beat + 5'd1;
                end
            end

            if (dep_issued && !dep_accepted && mem_rd_valid && mem_rd_ready) begin
                dep_accepted <= 1'b1;
                mem_rd_valid <= 1'b0;
            end
            // Collect the early dep response in ANY state once accepted, so
            // a state transition mid-burst cannot drop its trailing beats.
            if (dep_issued && dep_accepted && !dep_ready) begin
                if (mem_rd_data_v) begin
                    dep_q[dep_beat] <= mem_rd_data;
                    dep_cnt <= dep_cnt + 5'd1;
                    if (mem_rd_last || dep_beat == 5'd15) begin
                        dep_ready    <= 1'b1;
                        dep_accepted <= 1'b0;
                        dep_beat     <= 5'd0;
                    end else dep_beat <= dep_beat + 5'd1;
                end
            end

            case (state)
                IDLE: begin
                    sync_req <= 1'b0;
                    if (start) begin
                        pass_r <= 32'd0;
                        slice_r <= 32'd0;
                        index_r <= 32'd2;
                        pref_issued <= 1'b0;
                        pref_ready <= 1'b0;
                        pref_accepted <= 1'b0;
                        nxt_latched <= 1'b0;
                        nxt_beat    <= 5'd0;
                        nxt_sent    <= 1'b0;
                        nxt_skip    <= 1'b0;
                        cache_valid <= 1'b0;
                        wb_wptr <= 6'd0;
                        wb_rptr <= 6'd0;
                        wb_count <= 6'd0;
                        wb_wbeat <= 5'd0;
                        state <= SEG_PREP;
                    end
                end
                SEG_PREP: begin
                    if (pass_r == passes) begin
                        if (wb_count != 0) state <= SEG_PREP;
                        else begin
                            done <= 1'b1;
                            state <= IDLE;
                        end
                    end else if (index_r >= segment_length) state <= ADVANCE;
                    else if (independent) begin
                        a_init <= 1'b1;
                        a_start <= 1'b1;
                        state <= ADDR_WAIT;
                    end else state <= DISPATCH;
                end
                ADDR_WAIT: begin
                    if (a_done) begin
                        if (index_r >= segment_length) state <= ADVANCE;
                        else state <= DISPATCH;
                    end
                end
                DISPATCH: begin
                    beat <= 5'd0;
                    if (dep_ready && (dep_idx != index_r)) begin
                        dep_ready  <= 1'b0;
                        dep_issued <= 1'b0;
                        dep_seen   <= 1'b0;
                        dep_idx    <= 32'd0;
                        dep_cnt    <= 5'd0;
                    end
                    if (nxt_skip) begin
                        // The next block was already streamed into the
                        // compressor during the previous drain (overlapped
                        // send): skip the data setup, issue the following
                        // block's prefetch here (there is no COMPRESS for
                        // this block), and wait for its drain.
                        nxt_skip    <= 1'b0;
                        nxt_latched <= 1'b0;
                        nxt_beat    <= 5'd0;
                        nxt_sent    <= 1'b0;
                        if (can_prefetch && !pref_issued && !pref_ready && !mem_rd_valid) begin
                            mem_rd_addr <= ref_idx_n[ADDR_W-1:0];
                            mem_rd_owner <= ref_lane_n[3:0];
                            mem_rd_valid <= 1'b1;
                            pref_issued <= 1'b1;
                            pref_beat <= 5'd0;
                        end
                        state <= WRITE;
                    end else if (independent && pref_ready) begin
                        for (int i=0;i<16;i = i + 1) ref_q[i] <= pref_q[i];
                        pref_ready <= 1'b0; pref_issued <= 1'b0; pref_accepted <= 1'b0;
                        if (cache_valid) begin
                            for (int i=0;i<16;i = i + 1) prev_q[i] <= cache_q[i];
                            if (with_xor) begin
                                if (dest_done) begin
                                    dstream <= DSM_NONE;
                                    state <= COMPRESS;
                                    dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                                end else if (dest_issued) begin
                                    dstream <= DSM_NONE;
                                    state <= DEST_WAIT;
                                end else begin
                                    dstream <= DSM_DEST;
                                    state <= ISSUE_DEST;
                                end
                            end else begin
                                dstream <= DSM_NONE;
                                state <= COMPRESS;
                                dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                            end
                        end else begin
                            state <= ISSUE_PREV;
                        end
                    end else if (independent) begin
                        if (cache_hit_ref) begin
                            // Ref is the last-written block: forward from the
                            // write-through cache (its write may still be in
                            // the FIFO / mid-commit at the slave — reading
                            // memory now could return stale data).
                            for (int i=0;i<16;i = i + 1) ref_q[i] <= cache_q[i];
                            if (cache_valid) begin
                                for (int i=0;i<16;i = i + 1) prev_q[i] <= cache_q[i];
                                if (with_xor) begin
                                    if (dest_done) begin
                                        dstream <= DSM_NONE;
                                        state <= COMPRESS;
                                        dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                                    end else if (dest_issued) begin
                                        dstream <= DSM_NONE;
                                        state <= DEST_WAIT;
                                    end else begin
                                        dstream <= DSM_DEST;
                                        state <= ISSUE_DEST;
                                    end
                                end else begin
                                    dstream <= DSM_NONE;
                                    state <= COMPRESS;
                                    dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                                end
                            end else begin
                                state <= ISSUE_PREV;
                            end
                        end else if (wb_hit_ref) state <= DISPATCH;  // wait FIFO drain (raw)
                        else begin
                            dstream <= DSM_NONE;
                            state <= ISSUE_REF;
                        end
                    end else if (!independent && dep_ready && (dep_idx == index_r)
                                 && cache_valid && (dest_done || !with_xor)) begin
                        for (int i=0;i<16;i = i + 1) begin
                            ref_q[i]  <= dep_q[i];
                            prev_q[i] <= cache_q[i];
                        end
                        dep_ready  <= 1'b0;
                        dep_issued <= 1'b0;
                        dep_seen   <= 1'b0;
                        dep_idx    <= 32'd0;
                        dstream    <= 1'b0;
                        // The early dest read for THIS block is consumed by
                        // the load below; clear the flags so the COMPRESS-state
                        // hook can issue the next block's dest read (dest_q
                        // itself keeps the data until a new read collects).
                        dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                        state      <= COMPRESS;
                    end else if (!independent && dep_issued && !dep_ready
                                 && (dep_idx == index_r) && cache_valid
                                 && (dest_done || !with_xor)) begin
                        // Fast dependent path: the early dep read is still
                        // in flight; stream its beats straight into the
                        // compressor load (DSM_REF) instead of waiting for
                        // the full burst and then reloading from dep_q.
                        // prev is forwarded from the write-through cache,
                        // dest (if any) was prefetched early. dep flags stay
                        // set — the collector keeps filling dep_q / dep_cnt
                        // and the COMPRESS load-end re-arm clears them.
                        for (int i=0;i<16;i = i + 1) prev_q[i] <= cache_q[i];
                        // dest_q data survives the flag clear (registers);
                        // releasing the flags lets the COMPRESS-state hook
                        // issue the following block's dest read right away —
                        // the request queues behind the in-flight dep beats
                        // on the single outstanding read, which is the
                        // intended port schedule.
                        dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                        dstream <= DSM_REF;
                        state   <= COMPRESS;
                    end else if (cache_valid) begin
                        for (int i=0;i<16;i = i + 1) prev_q[i] <= cache_q[i];
                        dstream <= DSM_NONE;
                        state <= DREF_SETTLE;
                    end else begin
                        dstream <= DSM_NONE;
                        state <= ISSUE_PREV;
                    end
                end
                DREF_SETTLE: begin
                    dep_ready <= 1'b0; dep_issued <= 1'b0; dep_seen <= 1'b0;
                    dep_idx <= 32'd0;
                    dep_cnt <= 5'd0;
                    if (cache_hit_ref) begin
                        // Ref is the last-written block: forward from the
                        // write-through cache instead of racing its commit.
                        for (int i=0;i<16;i = i + 1) ref_q[i] <= cache_q[i];
                        dstream <= DSM_NONE;
                        if (with_xor && !dest_done) begin
                            if (dest_issued) state <= DEST_WAIT;
                            else begin
                                dstream <= DSM_DEST;
                                state <= ISSUE_DEST;
                            end
                        end else begin
                            state <= COMPRESS;
                            dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                        end
                    end else if (wb_hit_ref) state <= DREF_SETTLE;  // wait drain (raw)
                    else state <= ISSUE_REF;
                end
                DEST_WAIT: begin
                    if (dest_done) begin
                        dstream <= DSM_NONE;
                        dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                        state <= COMPRESS;
                    end
                end
                ISSUE_REF: begin
                    // Place THIS state's request only when the port is free:
                    // an earlier hook-issued request (early dest / dep / K+2
                    // prefetch) may still be waiting for acceptance, and
                    // overwriting it would corrupt both collectors. The port
                    // is only accepted when the lane's stream has drained,
                    // so after placement the next beats on the port belong
                    // to this request.
                    if (!mem_rd_valid) begin
                        mem_rd_addr  <= ref_idx[ADDR_W-1:0];
                        mem_rd_owner <= ref_lane[3:0];
                        mem_rd_valid <= 1'b1;
                    end else if (mem_rd_ready) begin
                        mem_rd_valid <= 1'b0;
                        state <= COLLECT_REF;
                    end
                end
                COLLECT_REF: begin
                    if (mem_rd_data_v) begin
                        ref_q[beat] <= mem_rd_data;
                        if (mem_rd_last || beat == 5'd15) begin
                            beat <= 5'd0;
                            if (independent) begin
                                state <= ISSUE_PREV;
                            end else if (with_xor) begin
                                if (dest_done) begin
                                    dstream <= DSM_NONE;
                                    state <= COMPRESS;
                                    dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                                end else if (dest_issued) begin
                                    // Early dest read in flight: wait for it
                                    // instead of issuing a duplicate.
                                    dstream <= DSM_NONE;
                                    state <= DEST_WAIT;
                                end else begin
                                    dstream <= DSM_DEST;
                                    state <= ISSUE_DEST;
                                end
                            end else begin
                                state <= COMPRESS;
                                dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                            end
                        end else beat <= beat + 5'd1;
                    end
                end
                ISSUE_PREV: begin
                    // See ISSUE_REF: place only on a free port.
                    if (!mem_rd_valid) begin
                        mem_rd_addr  <= prev_idx[ADDR_W-1:0];
                        mem_rd_owner <= lane_id[3:0];
                        mem_rd_valid <= 1'b1;
                    end else if (mem_rd_ready) begin
                        mem_rd_valid <= 1'b0;
                        state <= COLLECT_PREV;
                    end
                end
                COLLECT_PREV: begin
                    if (mem_rd_data_v) begin
                        prev_q[beat] <= mem_rd_data;
                        if (mem_rd_last || beat == 5'd15) begin
                            beat <= 5'd0;
                            if (!independent) begin
                                if (wb_hit_ref || cache_hit_ref) state <= DREF_SETTLE;
                                else begin
                                    state <= ISSUE_REF;
                                end
                            end else if (with_xor) begin
                                if (dest_done) begin
                                    dstream <= DSM_NONE;
                                    state <= COMPRESS;
                                    dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                                end else if (dest_issued) begin
                                    dstream <= DSM_NONE;
                                    state <= DEST_WAIT;
                                end else begin
                                    dstream <= DSM_DEST;
                                    state <= ISSUE_DEST;
                                end
                            end else begin
                                state <= COMPRESS;
                                dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                            end
                        end else beat <= beat + 5'd1;
                    end
                end
                ISSUE_DEST: begin
                    // See ISSUE_REF: place only on a free port. Every
                    // ISSUE_DEST user reads the block's own position (the
                    // pass>0 dest-xor source).
                    if (!mem_rd_valid) begin
                        mem_rd_addr  <= curr_idx[ADDR_W-1:0];
                        mem_rd_owner <= lane_id[3:0];
                        mem_rd_valid <= 1'b1;
                    end else if (mem_rd_ready) begin
                        mem_rd_valid <= 1'b0;
                        state <= (dstream != DSM_NONE) ? COMPRESS : COLLECT_DEST;
                    end
                end
                COLLECT_DEST: begin
                    if (mem_rd_data_v) begin
                        dest_q[beat] <= mem_rd_data;
                        if (mem_rd_last || beat == 5'd15) begin
                            beat <= 5'd0;
                            state <= COMPRESS;
                            dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0;
                        end else beat <= beat + 5'd1;
                    end
                end
                COMPRESS: begin
                    if (can_prefetch && !pref_issued && !pref_ready && !mem_rd_valid) begin
                        mem_rd_addr <= ref_idx_n[ADDR_W-1:0];
                        mem_rd_owner <= ref_lane_n[3:0];
                        mem_rd_valid <= 1'b1;
                        pref_issued <= 1'b1;
                        pref_beat <= 5'd0;
                    end
                    // Dependent blocks: the dest-xor word for the NEXT block
                    // lives at a fully deterministic address (the next block's
                    // own position — no data dependence), and the read port is
                    // idle here in dependent mode. Issue it now so it is
                    // collected long before the next DISPATCH; the dependent
                    // ref read then goes out on the same port at drain beat 0
                    // (the single outstanding read serializes the two, which
                    // is the intended schedule). Mid-segment only: at segment
                    // boundaries the next block's dest is handled by the
                    // normal path.
                    if (!independent && with_xor && !dest_last_blk
                        && (index_n < segment_length)
                        && !dest_issued && !dest_accepted && !dest_done
                        && !mem_rd_valid) begin
                        mem_rd_addr  <= dest_next_addr[ADDR_W-1:0];
                        mem_rd_owner <= lane_id[3:0];
                        mem_rd_valid <= 1'b1;
                        dest_issued  <= 1'b1;
                        dest_beat    <= 5'd0;
                    end
                    if (c_in_valid && c_in_ready) begin
                        if (beat == 5'd15) begin
                            beat <= 5'd0;
                            wb_wbeat <= 5'd0;
                            state <= WRITE;
                            // Re-arm the dependent early-ref capture for this
                            // new block; any dep not consumed by the previous
                            // block is stale.
                            dep_seen   <= 1'b0;
                            dep_issued <= 1'b0;
                            dep_ready  <= 1'b0;
                            dep_accepted <= 1'b0;
                            dep_cnt    <= 5'd0;
                        end else beat <= beat + 5'd1;
                    end
                end
                WRITE: begin
                    if (c_out_valid && c_out_ready && !c_out_last && !dep_seen) begin
                        dep_j1   <= c_out_data[63:0];
                        dep_seen <= 1'b1;
                        dep_idx  <= index_n;
                    end
                    if (dep_can) begin
                        mem_rd_addr <= dep_ridx[ADDR_W-1:0];
                        mem_rd_owner <= dep_lane[3:0];
                        mem_rd_valid <= 1'b1;
                        dep_issued <= 1'b1;
                        dep_beat <= 5'd0;
                        dep_cnt  <= 5'd0;
                    end
                    // Latch overlap eligibility while the drain is still
                    // pending and copy the prefetched ref into ref_q (the
                    // block we will stream next). Never latch after the
                    // drain has started — the send must start on drain
                    // beat 0 so it finishes exactly with the drain.
                    if (nxt_ok && !nxt_latched && !c_out_valid) begin
                        nxt_latched <= 1'b1;
                        nxt_beat    <= 5'd0;
                        for (int i=0;i<16;i = i + 1) ref_q[i] <= pref_q[i];
                        // The prefetched ref for this block is consumed by
                        // the copy: clear the handshake flags so ADVANCE
                        // does not stall. For pass 0 immediately issue the
                        // K+2 prefetch (the second addr port is redirected
                        // to K+2 during this cycle): it completes before the
                        // next drain starts, so every independent block can
                        // overlap. K+2 prefetch is pass-0 ONLY: for a dest
                        // pass the dest address for K+2 would be wrong
                        // (dest_next_addr is curr_idx+1 = K+1 while index_r
                        // is still K here), so the next block's ref is issued
                        // from its own DISPATCH[nxt_skip] — where index_r has
                        // advanced — and dest_next_addr is then correct.
                        // dest_q keeps the next block's data for the drain,
                        // but dest_done is cleared so the block after that
                        // cannot chain on a stale (already-consumed) dest.
                        pref_ready    <= 1'b0;
                        pref_issued   <= 1'b0;
                        pref_accepted <= 1'b0;
                        pref_beat     <= 5'd0;
                        dest_issued   <= 1'b0;
                        dest_accepted <= 1'b0;
                        dest_done     <= 1'b0;
                        dest_beat     <= 5'd0;
                        if (can_prefetch_n2 && !with_xor && !mem_rd_valid) begin
                            mem_rd_addr <= ref_idx_n[ADDR_W-1:0];
                            mem_rd_owner <= ref_lane_n[3:0];
                            mem_rd_valid <= 1'b1;
                            pref_issued <= 1'b1;
                            pref_beat   <= 5'd0;
                        end
                    end

                    // Advance the send in lockstep with the drain beats,
                    // starting on the first output beat (nxt_sending is
                    // combinational, so the first beat transfers on the
                    // same cycle as the first drain handshake).
                    if (nxt_sending && c_in_ready && c_out_valid && c_out_ready) begin
                        if (nxt_beat == 5'd15) begin
                            nxt_sent <= 1'b1;
                        end else begin
                            nxt_beat <= nxt_beat + 5'd1;
                        end
                    end

                    if (c_out_valid && c_out_ready) begin
                        if (c_out_last) begin
                            // If the overlapped send finished with the drain,
                            // the next DISPATCH must skip the data setup.
                            if (nxt_sending) nxt_skip <= 1'b1;
                            nxt_latched <= 1'b0;
                            state       <= ADVANCE;
                        end
                    end
                end
                ADVANCE: begin
                    // Let an in-flight early dep for the next block finish
                    // before issuing any other read (single R channel) —
                    // UNLESS the DISPATCH fast path will consume it live:
                    // when prev is in the write-through cache and the dest
                    // (or no xor) is ready, the load itself streams the dep
                    // beats (DSM_REF), so waiting for dep_ready here would
                    // just serialize the read behind the load again.
                    if (dep_issued && !dep_ready && (dep_idx == index_n)
                        && !(cache_valid && (dest_done || !with_xor)))
                        state <= ADVANCE;
                    else if (nxt_skip) begin
                        // Overlapped block: no boundary can be pending (the
                        // overlap gating guarantees mid-segment / mid-window)
                        // and the in-flight K+2 prefetch is not consumed by
                        // DISPATCH[skip], so advance straight to it.
                        index_r <= index_r + 32'd1;
                        state   <= DISPATCH;
                    end else if (pref_issued && !pref_ready) state <= ADVANCE;
                    else if (index_r >= segment_length || index_r + 32'd1 == segment_length) begin
                        if (wb_count != 0) state <= ADVANCE;
                        else begin
                            pref_issued <= 1'b0; pref_ready <= 1'b0; pref_accepted <= 1'b0;
                            dep_issued <= 1'b0; dep_ready <= 1'b0; dep_accepted <= 1'b0;
                            dep_seen <= 1'b0; dep_idx <= 32'd0; dep_cnt <= 5'd0;
                            if (lanes > 32'd1) begin
                                sync_req <= 1'b1;
                                state <= SLICE_SYNC;
                            end else begin
                                if (slice_r + 32'd1 == 32'd4) begin
                                    slice_r <= 32'd0; pass_r <= pass_r + 32'd1;
                                end else slice_r <= slice_r + 32'd1;
                                index_r <= 32'd0;
                                state <= SEG_PREP;
                            end
                        end
                    end else begin
                        index_r <= index_r + 32'd1;
                        if (independent && ((index_r + 32'd1) & 32'd127) == 32'd0) begin
                            pref_issued <= 1'b0; pref_ready <= 1'b0; pref_accepted <= 1'b0;
                            a_start <= 1'b1;
                            state <= ADDR_WAIT;
                        end else state <= DISPATCH;
                    end
                end
                SLICE_SYNC: begin
                    sync_req <= 1'b1;
                    if (sync_ack) begin
                        if (wb_count != 0) state <= SLICE_SYNC;
                        else begin
                            sync_req <= 1'b0;
                            if (slice_r + 32'd1 == 32'd4) begin
                                slice_r <= 32'd0; pass_r <= pass_r + 32'd1;
                            end else slice_r <= slice_r + 32'd1;
                            index_r <= 32'd0;
                            state <= SEG_PREP;
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end

endmodule
