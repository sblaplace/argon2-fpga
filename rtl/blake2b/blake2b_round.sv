// SPDX-License-Identifier: MIT
// One BLAKE2b round: eight G mixes (4 column + 4 diagonal) with SIGMA schedule.

`timescale 1ns / 1ps

module blake2b_round (
    input  logic [63:0] v_i [0:15],
    input  logic [63:0] m_i [0:15],
    input  logic [3:0]  round_i,   // 0..11; SIGMA is indexed by round % 10
    output logic [63:0] v_o [0:15]
);
    // RFC 7693 SIGMA[0..9]
    function automatic logic [3:0] sigma(input logic [3:0] r, input logic [3:0] i);
        logic [3:0] rr;
        rr = (r >= 4'd10) ? (r - 4'd10) : r;
        case ({rr, i})
            {4'd0, 4'd0}:  sigma = 0;   {4'd0, 4'd1}:  sigma = 1;
            {4'd0, 4'd2}:  sigma = 2;   {4'd0, 4'd3}:  sigma = 3;
            {4'd0, 4'd4}:  sigma = 4;   {4'd0, 4'd5}:  sigma = 5;
            {4'd0, 4'd6}:  sigma = 6;   {4'd0, 4'd7}:  sigma = 7;
            {4'd0, 4'd8}:  sigma = 8;   {4'd0, 4'd9}:  sigma = 9;
            {4'd0, 4'd10}: sigma = 10;  {4'd0, 4'd11}: sigma = 11;
            {4'd0, 4'd12}: sigma = 12;  {4'd0, 4'd13}: sigma = 13;
            {4'd0, 4'd14}: sigma = 14;  {4'd0, 4'd15}: sigma = 15;

            {4'd1, 4'd0}:  sigma = 14;  {4'd1, 4'd1}:  sigma = 10;
            {4'd1, 4'd2}:  sigma = 4;   {4'd1, 4'd3}:  sigma = 8;
            {4'd1, 4'd4}:  sigma = 9;   {4'd1, 4'd5}:  sigma = 15;
            {4'd1, 4'd6}:  sigma = 13;  {4'd1, 4'd7}:  sigma = 6;
            {4'd1, 4'd8}:  sigma = 1;   {4'd1, 4'd9}:  sigma = 12;
            {4'd1, 4'd10}: sigma = 0;   {4'd1, 4'd11}: sigma = 2;
            {4'd1, 4'd12}: sigma = 11;  {4'd1, 4'd13}: sigma = 7;
            {4'd1, 4'd14}: sigma = 5;   {4'd1, 4'd15}: sigma = 3;

            {4'd2, 4'd0}:  sigma = 11;  {4'd2, 4'd1}:  sigma = 8;
            {4'd2, 4'd2}:  sigma = 12;  {4'd2, 4'd3}:  sigma = 0;
            {4'd2, 4'd4}:  sigma = 5;   {4'd2, 4'd5}:  sigma = 2;
            {4'd2, 4'd6}:  sigma = 15;  {4'd2, 4'd7}:  sigma = 13;
            {4'd2, 4'd8}:  sigma = 10;  {4'd2, 4'd9}:  sigma = 14;
            {4'd2, 4'd10}: sigma = 3;   {4'd2, 4'd11}: sigma = 6;
            {4'd2, 4'd12}: sigma = 7;   {4'd2, 4'd13}: sigma = 1;
            {4'd2, 4'd14}: sigma = 9;   {4'd2, 4'd15}: sigma = 4;

            {4'd3, 4'd0}:  sigma = 7;   {4'd3, 4'd1}:  sigma = 9;
            {4'd3, 4'd2}:  sigma = 3;   {4'd3, 4'd3}:  sigma = 1;
            {4'd3, 4'd4}:  sigma = 13;  {4'd3, 4'd5}:  sigma = 12;
            {4'd3, 4'd6}:  sigma = 11;  {4'd3, 4'd7}:  sigma = 14;
            {4'd3, 4'd8}:  sigma = 2;   {4'd3, 4'd9}:  sigma = 6;
            {4'd3, 4'd10}: sigma = 5;   {4'd3, 4'd11}: sigma = 10;
            {4'd3, 4'd12}: sigma = 4;   {4'd3, 4'd13}: sigma = 0;
            {4'd3, 4'd14}: sigma = 15;  {4'd3, 4'd15}: sigma = 8;

            {4'd4, 4'd0}:  sigma = 9;   {4'd4, 4'd1}:  sigma = 0;
            {4'd4, 4'd2}:  sigma = 5;   {4'd4, 4'd3}:  sigma = 7;
            {4'd4, 4'd4}:  sigma = 2;   {4'd4, 4'd5}:  sigma = 4;
            {4'd4, 4'd6}:  sigma = 10;  {4'd4, 4'd7}:  sigma = 15;
            {4'd4, 4'd8}:  sigma = 14;  {4'd4, 4'd9}:  sigma = 1;
            {4'd4, 4'd10}: sigma = 11;  {4'd4, 4'd11}: sigma = 12;
            {4'd4, 4'd12}: sigma = 6;   {4'd4, 4'd13}: sigma = 8;
            {4'd4, 4'd14}: sigma = 3;   {4'd4, 4'd15}: sigma = 13;

            {4'd5, 4'd0}:  sigma = 2;   {4'd5, 4'd1}:  sigma = 12;
            {4'd5, 4'd2}:  sigma = 6;   {4'd5, 4'd3}:  sigma = 10;
            {4'd5, 4'd4}:  sigma = 0;   {4'd5, 4'd5}:  sigma = 11;
            {4'd5, 4'd6}:  sigma = 8;   {4'd5, 4'd7}:  sigma = 3;
            {4'd5, 4'd8}:  sigma = 4;   {4'd5, 4'd9}:  sigma = 13;
            {4'd5, 4'd10}: sigma = 7;   {4'd5, 4'd11}: sigma = 5;
            {4'd5, 4'd12}: sigma = 15;  {4'd5, 4'd13}: sigma = 14;
            {4'd5, 4'd14}: sigma = 1;   {4'd5, 4'd15}: sigma = 9;

            {4'd6, 4'd0}:  sigma = 12;  {4'd6, 4'd1}:  sigma = 5;
            {4'd6, 4'd2}:  sigma = 1;   {4'd6, 4'd3}:  sigma = 15;
            {4'd6, 4'd4}:  sigma = 14;  {4'd6, 4'd5}:  sigma = 13;
            {4'd6, 4'd6}:  sigma = 4;   {4'd6, 4'd7}:  sigma = 10;
            {4'd6, 4'd8}:  sigma = 0;   {4'd6, 4'd9}:  sigma = 7;
            {4'd6, 4'd10}: sigma = 6;   {4'd6, 4'd11}: sigma = 3;
            {4'd6, 4'd12}: sigma = 9;   {4'd6, 4'd13}: sigma = 2;
            {4'd6, 4'd14}: sigma = 8;   {4'd6, 4'd15}: sigma = 11;

            {4'd7, 4'd0}:  sigma = 13;  {4'd7, 4'd1}:  sigma = 11;
            {4'd7, 4'd2}:  sigma = 7;   {4'd7, 4'd3}:  sigma = 14;
            {4'd7, 4'd4}:  sigma = 12;  {4'd7, 4'd5}:  sigma = 1;
            {4'd7, 4'd6}:  sigma = 3;   {4'd7, 4'd7}:  sigma = 9;
            {4'd7, 4'd8}:  sigma = 5;   {4'd7, 4'd9}:  sigma = 0;
            {4'd7, 4'd10}: sigma = 15;  {4'd7, 4'd11}: sigma = 4;
            {4'd7, 4'd12}: sigma = 8;   {4'd7, 4'd13}: sigma = 6;
            {4'd7, 4'd14}: sigma = 2;   {4'd7, 4'd15}: sigma = 10;

            {4'd8, 4'd0}:  sigma = 6;   {4'd8, 4'd1}:  sigma = 15;
            {4'd8, 4'd2}:  sigma = 14;  {4'd8, 4'd3}:  sigma = 9;
            {4'd8, 4'd4}:  sigma = 11;  {4'd8, 4'd5}:  sigma = 3;
            {4'd8, 4'd6}:  sigma = 0;   {4'd8, 4'd7}:  sigma = 8;
            {4'd8, 4'd8}:  sigma = 12;  {4'd8, 4'd9}:  sigma = 2;
            {4'd8, 4'd10}: sigma = 13;  {4'd8, 4'd11}: sigma = 7;
            {4'd8, 4'd12}: sigma = 1;   {4'd8, 4'd13}: sigma = 4;
            {4'd8, 4'd14}: sigma = 10;  {4'd8, 4'd15}: sigma = 5;

            {4'd9, 4'd0}:  sigma = 10;  {4'd9, 4'd1}:  sigma = 2;
            {4'd9, 4'd2}:  sigma = 8;   {4'd9, 4'd3}:  sigma = 4;
            {4'd9, 4'd4}:  sigma = 7;   {4'd9, 4'd5}:  sigma = 6;
            {4'd9, 4'd6}:  sigma = 1;   {4'd9, 4'd7}:  sigma = 5;
            {4'd9, 4'd8}:  sigma = 15;  {4'd9, 4'd9}:  sigma = 11;
            {4'd9, 4'd10}: sigma = 9;   {4'd9, 4'd11}: sigma = 14;
            {4'd9, 4'd12}: sigma = 3;   {4'd9, 4'd13}: sigma = 12;
            {4'd9, 4'd14}: sigma = 13;  {4'd9, 4'd15}: sigma = 0;

            default: sigma = 0;
        endcase
    endfunction

    logic [63:0] col [0:15];

    blake2b_g g0 (
        .a_i(v_i[0]),  .b_i(v_i[4]),  .c_i(v_i[8]),  .d_i(v_i[12]),
        .x_i(m_i[sigma(round_i, 0)]), .y_i(m_i[sigma(round_i, 1)]),
        .a_o(col[0]),  .b_o(col[4]),  .c_o(col[8]),  .d_o(col[12])
    );
    blake2b_g g1 (
        .a_i(v_i[1]),  .b_i(v_i[5]),  .c_i(v_i[9]),  .d_i(v_i[13]),
        .x_i(m_i[sigma(round_i, 2)]), .y_i(m_i[sigma(round_i, 3)]),
        .a_o(col[1]),  .b_o(col[5]),  .c_o(col[9]),  .d_o(col[13])
    );
    blake2b_g g2 (
        .a_i(v_i[2]),  .b_i(v_i[6]),  .c_i(v_i[10]), .d_i(v_i[14]),
        .x_i(m_i[sigma(round_i, 4)]), .y_i(m_i[sigma(round_i, 5)]),
        .a_o(col[2]),  .b_o(col[6]),  .c_o(col[10]), .d_o(col[14])
    );
    blake2b_g g3 (
        .a_i(v_i[3]),  .b_i(v_i[7]),  .c_i(v_i[11]), .d_i(v_i[15]),
        .x_i(m_i[sigma(round_i, 6)]), .y_i(m_i[sigma(round_i, 7)]),
        .a_o(col[3]),  .b_o(col[7]),  .c_o(col[11]), .d_o(col[15])
    );

    blake2b_g g4 (
        .a_i(col[0]),  .b_i(col[5]),  .c_i(col[10]), .d_i(col[15]),
        .x_i(m_i[sigma(round_i, 8)]),  .y_i(m_i[sigma(round_i, 9)]),
        .a_o(v_o[0]),  .b_o(v_o[5]),  .c_o(v_o[10]), .d_o(v_o[15])
    );
    blake2b_g g5 (
        .a_i(col[1]),  .b_i(col[6]),  .c_i(col[11]), .d_i(col[12]),
        .x_i(m_i[sigma(round_i, 10)]), .y_i(m_i[sigma(round_i, 11)]),
        .a_o(v_o[1]),  .b_o(v_o[6]),  .c_o(v_o[11]), .d_o(v_o[12])
    );
    blake2b_g g6 (
        .a_i(col[2]),  .b_i(col[7]),  .c_i(col[8]),  .d_i(col[13]),
        .x_i(m_i[sigma(round_i, 12)]), .y_i(m_i[sigma(round_i, 13)]),
        .a_o(v_o[2]),  .b_o(v_o[7]),  .c_o(v_o[8]),  .d_o(v_o[13])
    );
    blake2b_g g7 (
        .a_i(col[3]),  .b_i(col[4]),  .c_i(col[9]),  .d_i(col[14]),
        .x_i(m_i[sigma(round_i, 14)]), .y_i(m_i[sigma(round_i, 15)]),
        .a_o(v_o[3]),  .b_o(v_o[4]),  .c_o(v_o[9]),  .d_o(v_o[14])
    );
endmodule
