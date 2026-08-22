// SPDX-License-Identifier: MIT
// Argon2 reference-block index (RFC 9106 §3.4 / PHC `index_alpha`).
//
//   x  = J1² >> 32
//   y  = |W| · x >> 32
//   zz = |W| − 1 − y
//   z  = (start + zz) mod lane_length
//
// Combinational aside from the two 32×32 multiplies (DSP). J2 → lane is
// done by the fill controller (needs pass/slice for the first-slice rule).

`timescale 1ns / 1ps

module argon2_index (
    input  logic [31:0] j1,
    input  logic [31:0] ref_area,      // |W|
    input  logic [31:0] start_position,
    input  logic [31:0] lane_length,
    output logic [31:0] ref_index
);
    logic [63:0] j1_sq;
    logic [63:0] area_x;
    logic [31:0] rel;
    logic [32:0] sum;

    always_comb begin
        j1_sq = j1 * j1;
        area_x = ref_area * j1_sq[63:32];
        rel = ref_area - 32'd1 - area_x[63:32];
        // start_position + rel  (mod lane_length). For every legal input
        // start_position < lane_length (it is a segment boundary: 0 or
        // (slice+1)*segment_length <= 3/4 lane_length) and rel < lane_length
        // (ref_area < lane_length for every output of argon2_ref_area — the
        // lone 0xFFFF_FFFF sentinel is the pass-0/slice-0/!same-lane/index-0
        // branch, a combination the fill controller never produces since
        // pass-0 slice-0 is always same-lane), so the sum is in
        // [0, 2*lane_length) and the modulo collapses to ONE conditional
        // subtract. This replaces a 32-bit divider (runtime divisor => the
        // synthesizer builds a full divider, a 250 MHz closure killer) with
        // a compare + subtract. Bit-identical for every legal input.
        sum = {1'b0, start_position} + {1'b0, rel};
        if (sum >= {1'b0, lane_length})
            ref_index = sum - {1'b0, lane_length};
        else
            ref_index = sum[31:0];
    end
endmodule

// Combinational |W| / start_position helper matching PHC index_alpha.
module argon2_ref_area (
    input  logic [31:0] pass,
    input  logic [31:0] slice,
    input  logic [31:0] index,           // position inside the segment
    input  logic [31:0] lane_length,
    input  logic [31:0] segment_length,
    input  logic        same_lane,
    output logic [31:0] ref_area,
    output logic [31:0] start_position
);
    always_comb begin
        if (pass == 32'd0) begin
            start_position = 32'd0;
            if (slice == 32'd0)
                ref_area = index - 32'd1;
            else if (same_lane)
                ref_area = slice * segment_length + index - 32'd1;
            else
                ref_area = slice * segment_length + ((index == 32'd0) ? 32'hFFFF_FFFF : 32'd0);
        end else begin
            start_position = (slice == 32'd3) ? 32'd0 : (slice + 32'd1) * segment_length;
            if (same_lane)
                ref_area = lane_length - segment_length + index - 32'd1;
            else
                ref_area = lane_length - segment_length + ((index == 32'd0) ? 32'hFFFF_FFFF : 32'd0);
        end
    end
endmodule
