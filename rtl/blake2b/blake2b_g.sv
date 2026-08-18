// SPDX-License-Identifier: MIT
// BLAKE2b G mix (RFC 7693 §3.1). Combinational; register at the parent.
//
//   a ← a + b + x;  d ← (d ⊕ a) >>> 32
//   c ← c + d;      b ← (b ⊕ c) >>> 24
//   a ← a + b + y;  d ← (d ⊕ a) >>> 16
//   c ← c + d;      b ← (b ⊕ c) >>> 63
//
// Argon2 compression does *not* use this module — see rtl/argon2/blamka_g.sv.

`timescale 1ns / 1ps
`include "blake2b_pkg.svh"

module blake2b_g (
    input  logic [63:0] a_i,
    input  logic [63:0] b_i,
    input  logic [63:0] c_i,
    input  logic [63:0] d_i,
    input  logic [63:0] x_i,
    input  logic [63:0] y_i,
    output logic [63:0] a_o,
    output logic [63:0] b_o,
    output logic [63:0] c_o,
    output logic [63:0] d_o
);
    logic [63:0] a1, b1, c1, d1;
    logic [63:0] a2, b2, c2, d2;

    always_comb begin
        a1 = a_i + b_i + x_i;
        d1 = `ROTR64((d_i ^ a1), 32);
        c1 = c_i + d1;
        b1 = `ROTR64((b_i ^ c1), 24);

        a2 = a1 + b1 + y_i;
        d2 = `ROTR64((d1 ^ a2), 16);
        c2 = c1 + d2;
        b2 = `ROTR64((b1 ^ c2), 63);

        a_o = a2;
        b_o = b2;
        c_o = c2;
        d_o = d2;
    end
endmodule
