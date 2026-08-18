// SPDX-License-Identifier: MIT
// Combinational checks for index_alpha / ref_area vs. tests/test_index.py.
`timescale 1ns / 1ps

module tb_argon2_index;
    logic [31:0] pass, slice, index, lane_length, segment_length, j1;
    logic        same_lane;
    logic [31:0] ref_area, start_pos, z;

    argon2_ref_area u_area (
        .pass(pass), .slice(slice), .index(index),
        .lane_length(lane_length), .segment_length(segment_length),
        .same_lane(same_lane),
        .ref_area(ref_area), .start_position(start_pos)
    );

    argon2_index u_idx (
        .j1(j1), .ref_area(ref_area), .start_position(start_pos),
        .lane_length(lane_length), .ref_index(z)
    );

    integer errors;

    task automatic check(input [31:0] exp, input string name);
        #1;
        if (z !== exp) begin
            $display("FAIL %s got %0d exp %0d (area=%0d start=%0d)",
                     name, z, exp, ref_area, start_pos);
            errors = errors + 1;
        end
    endtask

    initial begin
        errors = 0;
        lane_length    = 32;
        segment_length = 8;
        same_lane      = 1;

        // pass=0, slice=0, index=5, J1=0 → |W|=4, rel=3, z=3
        pass = 0; slice = 0; index = 5; j1 = 32'd0;
        check(32'd3, "first_segment_grows");

        // J1 = all-ones → maps to the start of W
        j1 = 32'hFFFF_FFFF;
        check(32'd0, "j1_all_ones");

        // pass=1, slice=0, index=3, J1=0 → |W|=26, rel=25, start=8, z=1
        pass = 1; slice = 0; index = 3; j1 = 32'd0;
        check(32'd1, "later_pass_wraps");

        if (errors == 0) begin
            $display("tb_argon2_index PASS");
            $finish;
        end else begin
            $display("tb_argon2_index FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
