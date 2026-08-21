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
    logic [511:0] dest_work_q [0:15];
    logic [511:0] pref_q [0:15];
    logic [511:0] cache_q [0:15];
    logic [ADDR_W-1:0] cache_addr;
    logic         cache_valid;
    logic         dstream;
    logic [4:0]   beat;
    logic [4:0]   pref_beat;
    logic         pref_issued, pref_ready, pref_accepted;
    logic         dest_issued, dest_accepted, dest_done;
    logic [4:0]   dest_beat;

    // Dependent early next-ref.
    logic [511:0] dep_q [0:15];
    logic [4:0]   dep_beat;
    logic         dep_issued, dep_accepted, dep_ready;
    logic         dep_seen;
    logic [63:0]  dep_j1;
    logic [31:0]  dep_ridx;
    logic [31:0]  dep_idx;
    logic [31:0]  dep_area, dep_spos, dep_z;
    logic         dep_can, dep_self;

    // Overlapped next-block send.
    logic        nxt_latched;
    logic [4:0]  nxt_beat;
    logic        nxt_sent;
    logic        nxt_skip;

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
    logic wb_hit_ref_eff, wb_hit_ref_n_eff;

    always_comb begin
        wb_hit_ref = 1'b0;
        wb_hit_ref_n = 1'b0;
        for (int ii=0; ii<WB_DEPTH; ii = ii + 1) begin
            logic in_fifo;
            in_fifo = 1'b0;
            if (wb_count != 0) begin
                if (wb_wptr >= wb_rptr) in_fifo = (ii >= wb_rptr && ii < wb_wptr);
                else in_fifo = (ii >= wb_rptr || ii < wb_wptr);
            end
            if (in_fifo) begin
                if (wb_addr[ii] == ref_idx) wb_hit_ref = 1'b1;
                if (wb_addr[ii] == ref_idx_n) wb_hit_ref_n = 1'b1;
            end
        end
    end
    assign cache_hit_ref   = cache_valid && (cache_addr == ref_idx);
    assign cache_hit_ref_n = cache_valid && (cache_addr == ref_idx_n);
    assign wb_hit_ref_eff   = wb_hit_ref   && !cache_hit_ref;
    assign wb_hit_ref_n_eff = wb_hit_ref_n && !cache_hit_ref_n;

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

    assign nxt_sending = nxt_latched && !nxt_sent;
    assign c_in_valid = (state == COMPRESS) ? (dstream ? mem_rd_data_v : 1'b1)
                       : (state == WRITE)   ? (nxt_sending && c_out_valid && c_out_ready)
                       : 1'b0;
    assign c_in_x     = (state == WRITE && nxt_sending) ? c_out_data : prev_q[beat[3:0]];
    assign c_in_y     = (state == WRITE && nxt_sending) ? ref_q[nxt_beat[3:0]] : ref_q[beat[3:0]];
    assign c_in_dest  = (state == WRITE && nxt_sending) ? (with_xor ? dest_work_q[nxt_beat[3:0]] : 512'd0)
                       : dstream ? mem_rd_data : (with_xor ? dest_work_q[beat[3:0]] : 512'd0);
    assign c_in_last  = (state == WRITE && nxt_sending) ? (nxt_beat == 5'd15) : (beat == 5'd15);
    assign c_out_ready = (state == WRITE) && (wb_count < WB_DEPTH);

    assign nxt_ok = independent && pref_ready && cache_valid
                  && (!with_xor || dest_done)
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
    logic        nxt_ok;
    logic        nxt_sending;
    logic        nxt_issue2;
    logic [31:0] ag_idx_n;
    logic [6:0]  ag_rdb;
    logic [31:0] index_n2;

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

    argon2_ref_area u_area_dep (
        .pass(pass_r), .slice(slice_r), .index(index_n),
        .lane_length(lane_length), .segment_length(segment_length),
        .same_lane(), .ref_area(dep_area), .start_position(dep_spos)
    );
    argon2_index u_idx_dep (
        .j1(dep_j1[31:0]), .ref_area(dep_area), .start_position(dep_spos),
        .lane_length(lane_length), .ref_index(dep_z)
    );

    logic [31:0] dep_j1_hi;
    assign dep_j1_hi = dep_j1[63:32];
    assign dep_ridx = ((pass_r == 32'd0) && (slice_r == 32'd0)) ?
                      (lane_id * lane_length + dep_z) :
                      ((dep_j1_hi % lanes) * lane_length + dep_z);

    assign dep_self = (dep_ridx == curr_idx + 32'd1);
    assign dep_can  = !independent && (pass_r == 32'd0) && (state == WRITE)
                   && dep_seen && (index_n < segment_length)
                   && !dep_issued && !dep_ready && !dep_accepted
                   && !dest_issued && !dest_accepted
                   && !pref_issued && !pref_accepted
                   && !mem_rd_valid && !dep_self;

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
    assign can_prefetch   = independent && (index_n < segment_length) && (index_n[6:0] != 7'd0) && !wb_hit_ref_n_eff;
    assign can_prefetch_n2 = independent && (index_n2 < segment_length)
                           && (index_n2[6:0] != 7'd0) && !wb_hit_ref_n_eff;

    always_ff @(posedge clk or negedge rst_n) begin
        logic rd_handshake;
        logic wb_push, wb_pop;
        logic [5:0] next_wb_count;
        if (!rst_n) begin
            state <= IDLE;
            done  <= 1'b0;
            mem_rd_valid <= 1'b0;
            a_init <= 1'b0; a_start <= 1'b0;
            pass_r <= 32'd0; slice_r <= 32'd0; index_r <= 32'd0;
            beat <= 5'd0;
            pref_beat <= 5'd0; pref_issued <= 1'b0; pref_ready <= 1'b0; pref_accepted <= 1'b0;
            dest_issued <= 1'b0; dest_accepted <= 1'b0; dest_done <= 1'b0; dest_beat <= 5'd0;
            nxt_latched <= 1'b0; nxt_beat <= 5'd0; nxt_sent <= 1'b0; nxt_skip <= 1'b0;
            cache_valid <= 1'b0; cache_addr <= '0;
            dstream <= 1'b0; sync_req <= 1'b0; mem_rd_addr <= '0;
            dep_beat <= 5'd0; dep_issued <= 1'b0; dep_accepted <= 1'b0; dep_ready <= 1'b0;
            dep_seen <= 1'b0; dep_j1 <= 64'd0; dep_idx <= 32'd0;
            wb_wptr <= 6'd0; wb_rptr <= 6'd0; wb_count <= 6'd0; wb_wbeat <= 5'd0;
        end else begin
            wb_push = (state == WRITE) && c_out_valid && c_out_ready;
            wb_pop  = mem_wr_valid && mem_wr_ready;
            next_wb_count = wb_count;
            if (wb_pop) begin
                wb_rptr <= (wb_rptr == WB_DEPTH-1) ? 6'd0 : wb_rptr + 6'd1;
                next_wb_count = next_wb_count - 6'd1;
            end
            if (wb_push) begin
                wb_data[wb_wptr] <= c_out_data;
                wb_addr[wb_wptr] <= curr_idx;
                wb_last[wb_wptr] <= c_out_last;
                cache_q[wb_wbeat] <= c_out_data;
                wb_wptr <= (wb_wptr == WB_DEPTH-1) ? 6'd0 : wb_wptr + 6'd1;
                next_wb_count = next_wb_count + 6'd1;
                if (c_out_last) begin
                    cache_addr <= curr_idx;
                    cache_valid <= 1'b1;
                    wb_wbeat <= 5'd0;
                end else wb_wbeat <= wb_wbeat + 5'd1;
            end
            wb_count <= next_wb_count;

            done <= 1'b0; a_init <= 1'b0; a_start <= 1'b0;

            // Address handshaking
            rd_handshake = mem_rd_valid && mem_rd_ready;
            if (rd_handshake) begin
                if (pref_issued && !pref_accepted) begin
                    pref_accepted <= 1'b1;
                    if (with_xor && !dest_last_blk && !dest_issued) begin
                        mem_rd_addr <= dest_next_addr; mem_rd_valid <= 1'b1;
                        dest_issued <= 1'b1; dest_beat <= 5'd0;
                    end else mem_rd_valid <= 1'b0;
                end else if (dest_issued && !dest_accepted) begin
                    dest_accepted <= 1'b1; mem_rd_valid <= 1'b0;
                end else if (dep_issued && !dep_accepted) begin
                    dep_accepted <= 1'b1; mem_rd_valid <= 1'b0;
                end else mem_rd_valid <= 1'b0;
            end

            // Background collection
            if (pref_issued && pref_accepted && !pref_ready) begin
                if (mem_rd_data_v) begin
                    pref_q[pref_beat[3:0]] <= mem_rd_data;
                    if (mem_rd_last || pref_beat == 15) begin
                        pref_ready <= 1'b1; pref_accepted <= 1'b0; pref_beat <= 5'd0;
                    end else pref_beat <= pref_beat + 1;
                end
            end
            if (dest_issued && dest_accepted && !dest_done && (pref_ready || !pref_issued)) begin
                if (mem_rd_data_v) begin
                    dest_q[dest_beat[3:0]] <= mem_rd_data;
                    if (mem_rd_last || dest_beat == 15) begin
                        dest_done <= 1'b1; dest_beat <= 5'd0;
                    end else dest_beat <= dest_beat + 1;
                end
            end
            if (dep_issued && dep_accepted && !dep_ready && (pref_ready || !pref_issued) && (dest_done || !dest_issued)) begin
                if (mem_rd_data_v) begin
                    dep_q[dep_beat[3:0]] <= mem_rd_data;
                    if (mem_rd_last || dep_beat == 15) begin
                        dep_ready <= 1'b1; dep_accepted <= 1'b0; dep_beat <= 5'd0;
                    end else dep_beat <= dep_beat + 1;
                end
            end

            case (state)
                IDLE: if (start) begin
                    pass_r <= 0; slice_r <= 0; index_r <= 2;
                    pref_issued <= 0; pref_ready <= 0; pref_accepted <= 0;
                    nxt_latched <= 0; nxt_beat <= 0; nxt_sent <= 0; nxt_skip <= 0;
                    cache_valid <= 0; wb_wptr <= 0; wb_rptr <= 0; wb_count <= 0; wb_wbeat <= 0;
                    state <= SEG_PREP;
                end
                SEG_PREP: if (pass_r == passes) begin
                    if (wb_count == 0) begin done <= 1; state <= IDLE; end
                end else if (index_r >= segment_length) state <= ADVANCE;
                else if (independent) begin a_init <= 1; a_start <= 1; state <= ADDR_WAIT; end
                else state <= DISPATCH;

                ADDR_WAIT: if (a_done) state <= (index_r >= segment_length) ? ADVANCE : DISPATCH;

                DISPATCH: begin
                    beat <= 0;
                    if (dep_ready && dep_idx != index_r) begin dep_ready <= 0; dep_issued <= 0; dep_seen <= 0; end
                    if (nxt_skip) begin
                        nxt_skip <= 0; nxt_latched <= 0; nxt_sent <= 0;
                        if (can_prefetch && !pref_issued && !pref_ready && !mem_rd_valid) begin
                            mem_rd_addr <= ref_idx_n; mem_rd_valid <= 1;
                            pref_issued <= 1; pref_beat <= 0;
                        end
                        state <= WRITE;
                    end else if (independent && pref_ready && (!with_xor || dest_done)) begin
                        // Consume background prefetch
                        for (int i=0; i<16; i++) ref_q[i] <= pref_q[i];
                        pref_ready <= 0; pref_issued <= 0; pref_accepted <= 0;
                        if (with_xor) begin
                            for (int i=0; i<16; i++) dest_work_q[i] <= dest_q[i];
                            dest_issued <= 0; dest_accepted <= 0; dest_done <= 0;
                        end
                        if (cache_valid) begin
                            for (int i=0; i<16; i++) prev_q[i] <= cache_q[i];
                            dstream <= 0; state <= COMPRESS;
                        end else begin
                            mem_rd_addr <= prev_idx; mem_rd_valid <= 1; state <= ISSUE_PREV;
                        end
                    end else if (independent) begin
                        if (pref_issued || dest_issued) begin
                             state <= DISPATCH; // Wait for background prefetch to finish
                        end else begin
                             // Foreground prefetch
                             mem_rd_addr <= ref_idx; mem_rd_valid <= 1; state <= ISSUE_REF;
                        end
                    end else if (!independent && dep_ready && dep_idx == index_r && cache_valid && pass_r == 0) begin
                        for (int i=0; i<16; i++) begin ref_q[i] <= dep_q[i]; prev_q[i] <= cache_q[i]; end
                        dep_ready <= 0; dep_issued <= 0; dep_seen <= 0; dstream <= 0; state <= COMPRESS;
                    end else if (cache_valid) begin
                        for (int i=0; i<16; i++) prev_q[i] <= cache_q[i];
                        dstream <= 0; state <= DREF_SETTLE;
                    end else if (pref_issued || dest_issued || dep_issued) state <= DISPATCH;
                    else begin mem_rd_addr <= prev_idx; mem_rd_valid <= 1; state <= ISSUE_PREV; end
                end

                DREF_SETTLE: if (pref_issued || dest_issued || dep_issued || wb_hit_ref_eff) state <= DREF_SETTLE;
                else begin
                    mem_rd_addr <= ref_idx; mem_rd_valid <= 1; state <= ISSUE_REF;
                    dep_ready <= 0; dep_issued <= 0; dep_seen <= 0;
                end

                DEST_WAIT: if (dest_done) begin
                    for (int i=0; i<16; i++) dest_work_q[i] <= dest_q[i];
                    dest_issued <= 0; dest_accepted <= 0; dest_done <= 0;
                    dstream <= 0; state <= COMPRESS;
                end

                ISSUE_REF: if (mem_rd_ready) state <= COLLECT_REF;
                COLLECT_REF: if (mem_rd_data_v) begin
                    ref_q[beat[3:0]] <= mem_rd_data;
                    if (mem_rd_last || beat == 15) begin
                        beat <= 0;
                        if (independent) begin
                             if (cache_valid) begin
                                  for (int i=0; i<16; i++) prev_q[i] <= cache_q[i];
                                  if (with_xor) begin
                                       if (dest_done) begin
                                            for (int i=0; i<16; i++) dest_work_q[i] <= dest_q[i];
                                            dest_issued <= 0; dest_accepted <= 0; dest_done <= 0;
                                            dstream <= 0; state <= COMPRESS;
                                       end else begin
                                            dstream <= 1; mem_rd_addr <= curr_idx;
                                            mem_rd_valid <= 1; state <= ISSUE_DEST;
                                       end
                                  end else begin dstream <= 0; state <= COMPRESS; end
                             end else begin
                                  mem_rd_addr <= prev_idx; mem_rd_valid <= 1; state <= ISSUE_PREV;
                             end
                        end else if (with_xor) begin
                            if (dest_done) begin
                                for (int i=0; i<16; i++) dest_work_q[i] <= dest_q[i];
                                dest_issued <= 0; dest_accepted <= 0; dest_done <= 0;
                                dstream <= 0; state <= COMPRESS;
                            end else begin
                                dstream <= 1; mem_rd_addr <= curr_idx;
                                mem_rd_valid <= 1; state <= ISSUE_DEST;
                            end
                        end else state <= COMPRESS;
                    end else beat <= beat + 1;
                end

                ISSUE_PREV: if (mem_rd_ready) state <= COLLECT_PREV;
                COLLECT_PREV: if (mem_rd_data_v) begin
                    prev_q[beat[3:0]] <= mem_rd_data;
                    if (mem_rd_last || beat == 15) begin
                        beat <= 0;
                        if (!independent) begin
                            if (wb_hit_ref_eff || pref_issued || dest_issued || dep_issued) state <= DREF_SETTLE;
                            else begin mem_rd_addr <= ref_idx; mem_rd_valid <= 1; state <= ISSUE_REF; end
                        end else if (with_xor) begin
                            if (dest_done) begin
                                for (int i=0; i<16; i++) dest_work_q[i] <= dest_q[i];
                                dest_issued <= 0; dest_accepted <= 0; dest_done <= 0;
                                dstream <= 0; state <= COMPRESS;
                            end else if (dest_issued) begin dstream <= 0; state <= DEST_WAIT; end
                            else begin dstream <= 1; mem_rd_addr <= curr_idx; mem_rd_valid <= 1; state <= ISSUE_DEST; end
                        end else state <= COMPRESS;
                    end else beat <= beat + 1;
                end

                ISSUE_DEST: if (mem_rd_ready) state <= dstream ? COMPRESS : COLLECT_DEST;
                COLLECT_DEST: if (mem_rd_data_v) begin
                    dest_q[beat[3:0]] <= mem_rd_data;
                    if (mem_rd_last || beat == 15) begin
                        beat <= 0; for (int i=0; i<16; i++) dest_work_q[i] <= dest_q[i];
                        dest_issued <= 0; dest_accepted <= 0; dest_done <= 0; state <= COMPRESS;
                    end else beat <= beat + 1;
                end

                COMPRESS: begin
                    if (can_prefetch && !pref_issued && !pref_ready && !mem_rd_valid) begin
                        mem_rd_addr <= ref_idx_n; mem_rd_valid <= 1; pref_issued <= 1; pref_beat <= 0;
                    end
                    if (c_in_valid && c_in_ready) begin
                        if (beat == 15) begin beat <= 0; wb_wbeat <= 0; state <= WRITE; dep_seen <= 0; dep_issued <= 0; dep_ready <= 0; dep_accepted <= 0; end
                        else beat <= beat + 1;
                    end
                end

                WRITE: begin
                    if (c_out_valid && c_out_ready && !c_out_last && !dep_seen) begin dep_j1 <= c_out_data[63:0]; dep_seen <= 1; dep_idx <= index_n; end
                    if (dep_can) begin mem_rd_addr <= dep_ridx; mem_rd_valid <= 1; dep_issued <= 1; dep_beat <= 0; end
                    if (nxt_ok && !nxt_latched && !c_out_valid) begin
                        nxt_latched <= 1; nxt_beat <= 0; nxt_sent <= 0;
                        for (int i=0; i<16; i++) ref_q[i] <= pref_q[i];
                        if (with_xor) for (int i=0; i<16; i++) dest_work_q[i] <= dest_q[i];
                        pref_ready <= 0; pref_issued <= 0; pref_accepted <= 0; pref_beat <= 0;
                        dest_done <= 0; dest_issued <= 0; dest_accepted <= 0; dest_beat <= 0;
                        if (can_prefetch_n2 && !mem_rd_valid) begin mem_rd_addr <= ref_idx_n; mem_rd_valid <= 1; pref_issued <= 1; pref_beat <= 0; end
                    end
                    if (nxt_sending && c_in_ready && c_out_valid && c_out_ready) begin
                        if (nxt_beat == 15) nxt_sent <= 1; else nxt_beat <= nxt_beat + 1;
                    end
                    if (c_out_valid && c_out_ready && c_out_last) begin
                        if (nxt_sending || nxt_sent) nxt_skip <= 1; nxt_latched <= 0; state <= ADVANCE;
                    end
                end

                ADVANCE: begin
                    if (dep_issued && !dep_ready && dep_idx == index_n) state <= ADVANCE;
                    else if (nxt_skip) begin index_r <= index_r + 1; state <= DISPATCH; end
                    else if ((pref_issued && !pref_ready) || (dest_issued && !dest_done)) state <= ADVANCE;
                    else if (index_r >= segment_length || index_r + 1 == segment_length) begin
                        if (wb_count != 0) state <= ADVANCE;
                        else begin
                            pref_issued <= 0; pref_ready <= 0; pref_accepted <= 0;
                            dep_issued <= 0; dep_ready <= 0; dep_accepted <= 0; dep_seen <= 0;
                            if (lanes > 1) begin sync_req <= 1; state <= SLICE_SYNC; end
                            else begin
                                if (slice_r + 1 == 4) begin slice_r <= 0; pass_r <= pass_r + 1; end else slice_r <= slice_r + 1;
                                index_r <= 0; state <= SEG_PREP;
                            end
                        end
                    end else begin
                        index_r <= index_r + 1;
                        if (independent && ((index_r + 1) & 127) == 0) begin
                            pref_issued <= 0; pref_ready <= 0; pref_accepted <= 0;
                            a_start <= 1; state <= ADDR_WAIT;
                        end else state <= DISPATCH;
                    end
                end

                SLICE_SYNC: begin
                    sync_req <= 1;
                    if (sync_ack) begin
                        if (wb_count != 0) state <= SLICE_SYNC;
                        else begin
                            sync_req <= 0;
                            if (slice_r + 1 == 4) begin slice_r <= 0; pass_r <= pass_r + 1; end else slice_r <= slice_r + 1;
                            index_r <= 0; state <= SEG_PREP;
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
