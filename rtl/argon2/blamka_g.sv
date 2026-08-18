// SPDX-License-Identifier: MIT
// BlaMka GB (RFC 9106 §3.6) — 4-stage pipeline, one mix quarter per cycle.
//
//   a ← a + b + 2·trunc32(a)·trunc32(b)
//   d ← (d ⊕ a) >>> rot
//
// Four quarters with rotations 32, 24, 16, 63. The 32×32 multiply is the
// only departure from BLAKE2b G and is what we map onto DSP48 slices.
//
// Latency: 4 cycles from in_valid to out_valid. One GB / cycle if back-to-back.

`timescale 1ns / 1ps
`include "blake2b_pkg.svh"

module blamka_g (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [63:0] a_i,
    input  logic [63:0] b_i,
    input  logic [63:0] c_i,
    input  logic [63:0] d_i,
    output logic        out_valid,
    output logic [63:0] a_o,
    output logic [63:0] b_o,
    output logic [63:0] c_o,
    output logic [63:0] d_o
);
    function automatic logic [63:0] fbla(input logic [63:0] x, input logic [63:0] y);
        logic [63:0] prod;
        prod = x[31:0] * y[31:0];          // 32×32 → 64; Vivado → DSP48
        fbla = x + y + {prod[62:0], 1'b0}; // 2*prod  (mod 2^64)
    endfunction

    logic [63:0] a_s [0:3];
    logic [63:0] b_s [0:3];
    logic [63:0] c_s [0:3];
    logic [63:0] d_s [0:3];
    logic [3:0]  vpipe;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vpipe     <= 4'b0;
            out_valid <= 1'b0;
            a_o       <= 64'd0;
            b_o       <= 64'd0;
            c_o       <= 64'd0;
            d_o       <= 64'd0;
        end else begin
            vpipe <= {vpipe[2:0], in_valid};

            // Q0: a += b + 2ab_lo; d = ror32(d ⊕ a)
            a_s[0] <= fbla(a_i, b_i);
            b_s[0] <= b_i;
            c_s[0] <= c_i;
            d_s[0] <= `ROTR64((d_i ^ fbla(a_i, b_i)), 32);

            // Q1: c += d + 2cd_lo; b = ror24(b ⊕ c)
            a_s[1] <= a_s[0];
            c_s[1] <= fbla(c_s[0], d_s[0]);
            d_s[1] <= d_s[0];
            b_s[1] <= `ROTR64((b_s[0] ^ fbla(c_s[0], d_s[0])), 24);

            // Q2: a += b + 2ab_lo; d = ror16(d ⊕ a)
            a_s[2] <= fbla(a_s[1], b_s[1]);
            b_s[2] <= b_s[1];
            c_s[2] <= c_s[1];
            d_s[2] <= `ROTR64((d_s[1] ^ fbla(a_s[1], b_s[1])), 16);

            // Q3: c += d + 2cd_lo; b = ror63(b ⊕ c)
            a_o <= a_s[2];
            c_o <= fbla(c_s[2], d_s[2]);
            d_o <= d_s[2];
            b_o <= `ROTR64((b_s[2] ^ fbla(c_s[2], d_s[2])), 63);

            out_valid <= vpipe[2];
        end
    end
endmodule
