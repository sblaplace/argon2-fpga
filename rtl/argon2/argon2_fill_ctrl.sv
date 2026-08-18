// SPDX-License-Identifier: MIT
// Single-lane fill controller (the bandwidth-critical loop).
//
// Assumes B[0] and B[1] have already been written (H' of H0). Walks
// columns 2 .. lane_length-1 for each pass / slice, issuing:
//   1. compute (lane, index) of the reference block   [argon2i: prefetchable]
//   2. read prev block (usually sequential, cacheable)
//   3. read ref  block (random)
//   4. G(prev, ref) [⊕ dest on later passes]
//   5. write dest
//
// Memory port is block-addressed: the interconnect (AWS F1 CL_DRAM_DMA,
// AXI-MM, HBM) is responsible for bursting 1024-byte blocks. One
// outstanding read is enough to start; a production core should issue
// the argon2i reference read a full memory-latency early.

`timescale 1ns / 1ps

module argon2_fill_ctrl #(
    parameter int ADDR_W = 32
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
    output logic              mem_wr_last
);
    localparam int SYNC = 4;

    typedef enum logic [3:0] {
        IDLE,
        NEXT_POS,
        ISSUE_PREV,
        COLLECT_PREV,
        ISSUE_REF,
        COLLECT_REF,
        COMPRESS,
        WRITE
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
    logic [4:0]   beat;

    // Compress streaming
    logic         c_in_valid, c_in_ready, c_in_last;
    logic [511:0] c_in_x, c_in_y, c_in_dest;
    logic         c_out_valid, c_out_ready, c_out_last;
    logic [511:0] c_out_data;

    argon2_compress u_g (
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

    // Index datapath
    logic [31:0] j1, ref_area, start_pos, z;
    logic        same_lane;

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

    // Address-block PRNG for argon2i / first half of argon2id is left to
    // a follow-on module (argon2_addr_gen). For argon2d, J1||J2 is the
    // first 64 bits of the previous block — wired here.
    logic [63:0] prev_word0;

    always_comb begin
        segment_length = lane_length >> 2; // / SYNC
        independent = (type_i == 2'd1) ||
                      (type_i == 2'd2 && pass_r == 32'd0 && slice_r < 32'd2);
        with_xor = (pass_r != 32'd0);
        curr_idx = lane_id * lane_length + slice_r * segment_length + index_r;
        prev_idx = (curr_idx % lane_length == 32'd0)
                 ? (curr_idx + lane_length - 32'd1)
                 : (curr_idx - 32'd1);
        prev_word0 = prev_q[0][63:0];
        j1 = prev_word0[31:0];
        ref_lane = ((pass_r == 32'd0) && (slice_r == 32'd0))
                 ? lane_id
                 : prev_word0[63:32] % lanes;
        same_lane = (ref_lane == lane_id);
        ref_idx = ref_lane * lane_length + z;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            busy         <= 1'b0;
            done         <= 1'b0;
            mem_rd_valid <= 1'b0;
            mem_wr_valid <= 1'b0;
            c_in_valid   <= 1'b0;
            c_out_ready  <= 1'b0;
            pass_r       <= 32'd0;
            slice_r      <= 32'd0;
            index_r      <= 32'd0;
            beat         <= 5'd0;
        end else begin
            done        <= 1'b0;
            c_out_ready <= 1'b0;

            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    if (start) begin
                        busy    <= 1'b1;
                        pass_r  <= 32'd0;
                        slice_r <= 32'd0;
                        index_r <= 32'd2; // B[0], B[1] already filled
                        state   <= NEXT_POS;
                    end
                end

                NEXT_POS: begin
                    if (pass_r == passes) begin
                        busy  <= 1'b0;
                        done  <= 1'b1;
                        state <= IDLE;
                    end else begin
                        beat         <= 5'd0;
                        mem_rd_addr  <= prev_idx[ADDR_W-1:0];
                        mem_rd_valid <= 1'b1;
                        state        <= ISSUE_PREV;
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
                            beat         <= 5'd0;
                            mem_rd_addr  <= ref_idx[ADDR_W-1:0];
                            mem_rd_valid <= 1'b1;
                            state        <= ISSUE_REF;
                        end else begin
                            beat <= beat + 5'd1;
                        end
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
                            beat  <= 5'd0;
                            state <= COMPRESS;
                        end else begin
                            beat <= beat + 5'd1;
                        end
                    end
                end

                COMPRESS: begin
                    // Hold a beat until G accepts it so data and valid
                    // line up on the same cycle. Dest-xor (pass > 0)
                    // currently feeds zeros — a production core must
                    // also read the destination block.
                    c_in_x     <= prev_q[beat];
                    c_in_y     <= ref_q[beat];
                    c_in_dest  <= 512'd0;
                    c_in_last  <= (beat == 5'd15);
                    c_in_valid <= 1'b1;
                    if (c_in_valid && c_in_ready) begin
                        if (beat == 5'd15) begin
                            c_in_valid  <= 1'b0;
                            beat        <= 5'd0;
                            mem_wr_addr <= curr_idx[ADDR_W-1:0];
                            state       <= WRITE;
                        end else begin
                            beat <= beat + 5'd1;
                        end
                    end
                end

                WRITE: begin
                    c_out_ready  <= mem_wr_ready;
                    mem_wr_valid <= c_out_valid;
                    mem_wr_data  <= c_out_data;
                    mem_wr_last  <= c_out_last;
                    if (c_out_valid && mem_wr_ready && c_out_last) begin
                        mem_wr_valid <= 1'b0;
                        // Advance (index, slice, pass).
                        if (index_r + 32'd1 == segment_length) begin
                            index_r <= (pass_r == 32'd0 && slice_r + 32'd1 == 32'd0)
                                     ? 32'd2 : 32'd0;
                            // After slice 0 of pass 0, subsequent segments
                            // start at 0. (The ternary above is never 2 —
                            // kept as documentation of the first-segment rule,
                            // which is applied only at job start.)
                            index_r <= 32'd0;
                            if (slice_r + 32'd1 == 32'd4) begin
                                slice_r <= 32'd0;
                                pass_r  <= pass_r + 32'd1;
                            end else begin
                                slice_r <= slice_r + 32'd1;
                            end
                        end else begin
                            index_r <= index_r + 32'd1;
                        end
                        state <= NEXT_POS;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

    // Silence unused (address-gen hook).
    logic _unused_independent;
    assign _unused_independent = independent;
endmodule
