// SPDX-License-Identifier: MIT
// Permutation P (RFC 9106 §3.6): 4 parallel BlaMka GBs, then 4 diagonal GBs.
// 16 × 64-bit words in, 16 out. Latency = 4 + 1 + 4 = 9 cycles.

`timescale 1ns / 1ps

module argon2_p (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        in_valid,
    input  logic [63:0] v_i [0:15],
    output logic        out_valid,
    output logic [63:0] v_o [0:15]
);
    typedef enum logic [1:0] { IDLE, COL, DIAG } state_t;
    state_t state;

    logic        g_in_valid;
    logic        g_out_valid;
    logic [63:0] ga_i [0:3];
    logic [63:0] gb_i [0:3];
    logic [63:0] gc_i [0:3];
    logic [63:0] gd_i [0:3];
    logic [63:0] ga_o [0:3];
    logic [63:0] gb_o [0:3];
    logic [63:0] gc_o [0:3];
    logic [63:0] gd_o [0:3];

    logic [63:0] v [0:15];
    integer i;

    genvar gi;
    generate
        for (gi = 0; gi < 4; gi = gi + 1) begin : gbox
            blamka_g u_g (
                .clk      (clk),
                .rst_n    (rst_n),
                .in_valid (g_in_valid),
                .a_i      (ga_i[gi]),
                .b_i      (gb_i[gi]),
                .c_i      (gc_i[gi]),
                .d_i      (gd_i[gi]),
                .out_valid(g_out_valid), // all four share the same latency
                .a_o      (ga_o[gi]),
                .b_o      (gb_o[gi]),
                .c_o      (gc_o[gi]),
                .d_o      (gd_o[gi])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= IDLE;
            g_in_valid <= 1'b0;
            out_valid  <= 1'b0;
            for (i = 0; i < 16; i = i + 1)
                v[i] <= 64'd0;
            for (i = 0; i < 16; i = i + 1)
                v_o[i] <= 64'd0;
        end else begin
            g_in_valid <= 1'b0;
            out_valid  <= 1'b0;
            case (state)
                IDLE: begin
                    if (in_valid) begin
                        for (i = 0; i < 16; i = i + 1)
                            v[i] <= v_i[i];
                        // Column GBs: (0,4,8,12), (1,5,9,13), (2,6,10,14), (3,7,11,15)
                        ga_i[0] <= v_i[0];  gb_i[0] <= v_i[4];  gc_i[0] <= v_i[8];  gd_i[0] <= v_i[12];
                        ga_i[1] <= v_i[1];  gb_i[1] <= v_i[5];  gc_i[1] <= v_i[9];  gd_i[1] <= v_i[13];
                        ga_i[2] <= v_i[2];  gb_i[2] <= v_i[6];  gc_i[2] <= v_i[10]; gd_i[2] <= v_i[14];
                        ga_i[3] <= v_i[3];  gb_i[3] <= v_i[7];  gc_i[3] <= v_i[11]; gd_i[3] <= v_i[15];
                        g_in_valid <= 1'b1;
                        state      <= COL;
                    end
                end
                COL: begin
                    if (g_out_valid) begin
                        v[0]  <= ga_o[0]; v[4]  <= gb_o[0]; v[8]  <= gc_o[0]; v[12] <= gd_o[0];
                        v[1]  <= ga_o[1]; v[5]  <= gb_o[1]; v[9]  <= gc_o[1]; v[13] <= gd_o[1];
                        v[2]  <= ga_o[2]; v[6]  <= gb_o[2]; v[10] <= gc_o[2]; v[14] <= gd_o[2];
                        v[3]  <= ga_o[3]; v[7]  <= gb_o[3]; v[11] <= gc_o[3]; v[15] <= gd_o[3];
                        // Diagonal GBs: (0,5,10,15), (1,6,11,12), (2,7,8,13), (3,4,9,14)
                        ga_i[0] <= ga_o[0]; gb_i[0] <= gb_o[1]; gc_i[0] <= gc_o[2]; gd_i[0] <= gd_o[3];
                        ga_i[1] <= ga_o[1]; gb_i[1] <= gb_o[2]; gc_i[1] <= gc_o[3]; gd_i[1] <= gd_o[0];
                        ga_i[2] <= ga_o[2]; gb_i[2] <= gb_o[3]; gc_i[2] <= gc_o[0]; gd_i[2] <= gd_o[1];
                        ga_i[3] <= ga_o[3]; gb_i[3] <= gb_o[0]; gc_i[3] <= gc_o[1]; gd_i[3] <= gd_o[2];
                        g_in_valid <= 1'b1;
                        state      <= DIAG;
                    end
                end
                DIAG: begin
                    if (g_out_valid) begin
                        v_o[0]  <= ga_o[0]; v_o[5]  <= gb_o[0]; v_o[10] <= gc_o[0]; v_o[15] <= gd_o[0];
                        v_o[1]  <= ga_o[1]; v_o[6]  <= gb_o[1]; v_o[11] <= gc_o[1]; v_o[12] <= gd_o[1];
                        v_o[2]  <= ga_o[2]; v_o[7]  <= gb_o[2]; v_o[8]  <= gc_o[2]; v_o[13] <= gd_o[2];
                        v_o[3]  <= ga_o[3]; v_o[4]  <= gb_o[3]; v_o[9]  <= gc_o[3]; v_o[14] <= gd_o[3];
                        out_valid <= 1'b1;
                        state     <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
