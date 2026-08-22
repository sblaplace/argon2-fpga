// SPDX-License-Identifier: MIT
// Incremental BLAKE2b hasher (unkeyed, digest_len 1..64).
// Feed 128-byte blocks via start; set last on the final (zero-padded) block.
//
// This is the H / H' engine. The host can also run H' in software — the
// bandwidth-critical path is argon2_compress, not this module.

`timescale 1ns / 1ps
`ifndef BLAKE2B_PKG_SVH
`include "blake2b_pkg.svh"
`endif

module blake2b_core #(
    parameter int DIGEST_LEN = 64
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        init,
    input  logic        absorb,      // pulse with a 128-byte block
    input  logic        last,        // this absorb is the final block
    input  logic [63:0] t0_i,        // byte counter low (includes this block)
    input  logic [63:0] t1_i,        // byte counter high
    input  logic [63:0] m_i [0:15],
    output logic        ready,
    output logic        digest_valid,
    output logic [63:0] digest [0:7]
);
    logic [63:0] h     [0:7];
    logic [63:0] h_next[0:7];
    logic        comp_start;
    logic        comp_done;

    blake2b_compress u_f (
        .clk   (clk),
        .rst_n (rst_n),
        .start (comp_start),
        .h_i   (h),
        .m_i   (m_i),
        .t0_i  (t0_i),
        .t1_i  (t1_i),
        .last_i(last),
        .done  (comp_done),
        .h_o   (h_next)
    );

    typedef enum logic [1:0] { IDLE, BUSY } state_t;
    state_t state;
    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= IDLE;
            ready         <= 1'b0;
            digest_valid  <= 1'b0;
            comp_start    <= 1'b0;
            for (i = 0; i < 8; i = i + 1) begin
                h[i]      <= 64'd0;
                digest[i] <= 64'd0;
            end
        end else begin
            comp_start   <= 1'b0;
            digest_valid <= 1'b0;
            case (state)
                IDLE: begin
                    ready <= 1'b1;
                    if (init) begin
                        h[0] <= `BLAKE2B_IV0 ^ (64'h0000000001010000 | DIGEST_LEN[7:0]);
                        h[1] <= `BLAKE2B_IV1;
                        h[2] <= `BLAKE2B_IV2;
                        h[3] <= `BLAKE2B_IV3;
                        h[4] <= `BLAKE2B_IV4;
                        h[5] <= `BLAKE2B_IV5;
                        h[6] <= `BLAKE2B_IV6;
                        h[7] <= `BLAKE2B_IV7;
                        ready <= 1'b1;
                    end else if (absorb && ready) begin
                        comp_start <= 1'b1;
                        ready      <= 1'b0;
                        state      <= BUSY;
                    end
                end
                BUSY: begin
                    ready <= 1'b0;
                    if (comp_done) begin
                        for (i = 0; i < 8; i = i + 1)
                            h[i] <= h_next[i];
                        if (last) begin
                            for (i = 0; i < 8; i = i + 1)
                                digest[i] <= h_next[i];
                            digest_valid <= 1'b1;
                        end
                        state <= IDLE;
                        ready <= 1'b1;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
