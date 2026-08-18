// SPDX-License-Identifier: MIT
// BLAKE2b compression F: 12 registered rounds. Handshake: start / done.
// Used by Argon2 only for H / H' (init + tag), not for the memory fill.

`timescale 1ns / 1ps
`include "blake2b_pkg.svh"

module blake2b_compress (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        start,
    input  logic [63:0] h_i [0:7],
    input  logic [63:0] m_i [0:15],
    input  logic [63:0] t0_i,
    input  logic [63:0] t1_i,
    input  logic        last_i,
    output logic        done,
    output logic [63:0] h_o [0:7]
);
    typedef enum logic [1:0] { IDLE, RUN, FINISH } state_t;
    state_t state;

    logic [3:0]  round;
    logic [63:0] v     [0:15];
    logic [63:0] v_next[0:15];
    logic [63:0] m     [0:15];
    logic [63:0] h_snap[0:7];

    blake2b_round u_round (
        .v_i    (v),
        .m_i    (m),
        .round_i(round),
        .v_o    (v_next)
    );

    integer i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
            round <= 4'd0;
            done  <= 1'b0;
            for (i = 0; i < 16; i = i + 1) begin
                v[i] <= 64'd0;
                m[i] <= 64'd0;
            end
            for (i = 0; i < 8; i = i + 1)
                h_o[i] <= 64'd0;
        end else begin
            done <= 1'b0;
            case (state)
                IDLE: begin
                    if (start) begin
                        for (i = 0; i < 8; i = i + 1) begin
                            v[i]     <= h_i[i];
                            v[i + 8] <= 64'd0; // filled below
                        end
                        v[0]  <= h_i[0];
                        v[1]  <= h_i[1];
                        v[2]  <= h_i[2];
                        v[3]  <= h_i[3];
                        v[4]  <= h_i[4];
                        v[5]  <= h_i[5];
                        v[6]  <= h_i[6];
                        v[7]  <= h_i[7];
                        v[8]  <= `BLAKE2B_IV0;
                        v[9]  <= `BLAKE2B_IV1;
                        v[10] <= `BLAKE2B_IV2;
                        v[11] <= `BLAKE2B_IV3;
                        v[12] <= `BLAKE2B_IV4 ^ t0_i;
                        v[13] <= `BLAKE2B_IV5 ^ t1_i;
                        v[14] <= last_i ? (`BLAKE2B_IV6 ^ {64{1'b1}}) : `BLAKE2B_IV6;
                        v[15] <= `BLAKE2B_IV7;
                        for (i = 0; i < 16; i = i + 1)
                            m[i] <= m_i[i];
                        for (i = 0; i < 8; i = i + 1)
                            h_snap[i] <= h_i[i];
                        round <= 4'd0;
                        state <= RUN;
                    end
                end
                RUN: begin
                    for (i = 0; i < 16; i = i + 1)
                        v[i] <= v_next[i];
                    if (round == 4'd11) begin
                        state <= FINISH;
                    end else begin
                        round <= round + 4'd1;
                    end
                end
                FINISH: begin
                    // After the 12th round, v holds the post-round state.
                    // The last assignment in RUN already stored v_next of round 11.
                    for (i = 0; i < 8; i = i + 1)
                        h_o[i] <= h_snap[i] ^ v[i] ^ v[i + 8];
                    done  <= 1'b1;
                    state <= IDLE;
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
