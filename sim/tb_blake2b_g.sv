// SPDX-License-Identifier: MIT
// Self-checking bench for blake2b_g. Vectors from ref/blake2b.py.
`timescale 1ns / 1ps
`include "blake2b_pkg.svh"

module tb_blake2b_g #(
    parameter int N_P = 1   // unused: uniform -GN_P sweep across benches
);
    logic [63:0] a, b, c, d, x, y;
    logic [63:0] ao, bo, co, d_o;

    blake2b_g dut (
        .a_i(a), .b_i(b), .c_i(c), .d_i(d),
        .x_i(x), .y_i(y),
        .a_o(ao), .b_o(bo), .c_o(co), .d_o(d_o)
    );

    integer errors;

    task automatic expect_eq(
        input [63:0] got, input [63:0] exp, input string name
    );
        if (got !== exp) begin
            $display("FAIL %s got %016h exp %016h", name, got, exp);
            errors = errors + 1;
        end
    endtask

    initial begin
        errors = 0;

        // Identity-ish: zeros stay zero.
        a = 0; b = 0; c = 0; d = 0; x = 0; y = 0;
        #1;
        expect_eq(ao, 64'd0, "zero.a");
        expect_eq(bo, 64'd0, "zero.b");
        expect_eq(co, 64'd0, "zero.c");
        expect_eq(d_o, 64'd0, "zero.d");

        // Vector dumped from ref.blake2b.blake2b_g
        // a,b,c,d = IV[0..3], x = 1, y = 2
        a = 64'h6a09e667f3bcc908;
        b = 64'hbb67ae8584caa73b;
        c = 64'h3c6ef372fe94f82b;
        d = 64'ha54ff53a5f1d36f1;
        x = 64'd1;
        y = 64'd2;
        #1;
        expect_eq(ao, 64'h3f6ececce71c1e40, "iv.a");
        expect_eq(bo, 64'hf4bad584d3b0d9bd, "iv.b");
        expect_eq(co, 64'he3a0531d074cc124, "iv.c");
        expect_eq(d_o, 64'h7f9718f488796722, "iv.d");

        if (errors == 0) begin
            $display("tb_blake2b_g PASS");
            $finish;
        end else begin
            $display("tb_blake2b_g FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
