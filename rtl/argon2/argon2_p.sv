// SPDX-License-Identifier: MIT
// Permutation P (RFC 9106 §3.6): 4 parallel BlaMka GBs, then 4 diagonal GBs.
// 16 × 64-bit words in, 16 out (word i in v[64*i +: 64]). Latency = 9 cycles.
// Ports are packed so Icarus can elaborate the hierarchy.

`timescale 1ns / 1ps

module argon2_p (
    input  logic          clk,
    input  logic          rst_n,
    input  logic          in_valid,
    input  logic [1023:0] v_i,
    output logic          out_valid,
    output logic [1023:0] v_o
);
    typedef enum logic [1:0] { IDLE, COL, DIAG } state_t;
    state_t state;

    logic        g_in_valid;
    logic [3:0]  g_out_valid;      // one per GB instance (equal latency);
    logic [63:0] ga_i [0:3];       // the FSM waits for ALL of them.
    logic [63:0] gb_i [0:3];
    logic [63:0] gc_i [0:3];
    logic [63:0] gd_i [0:3];
    logic [63:0] ga_o [0:3];
    logic [63:0] gb_o [0:3];
    logic [63:0] gc_o [0:3];
    logic [63:0] gd_o [0:3];

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
                .out_valid(g_out_valid[gi]),
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
            v_o        <= 1024'd0;
        end else begin
            g_in_valid <= 1'b0;
            out_valid  <= 1'b0;
            case (state)
                IDLE: begin
                    if (in_valid) begin
                        // Column GBs: (0,4,8,12), (1,5,9,13), (2,6,10,14), (3,7,11,15)
                        ga_i[0] <= v_i[64*0  +: 64];
                        gb_i[0] <= v_i[64*4  +: 64];
                        gc_i[0] <= v_i[64*8  +: 64];
                        gd_i[0] <= v_i[64*12 +: 64];
                        ga_i[1] <= v_i[64*1  +: 64];
                        gb_i[1] <= v_i[64*5  +: 64];
                        gc_i[1] <= v_i[64*9  +: 64];
                        gd_i[1] <= v_i[64*13 +: 64];
                        ga_i[2] <= v_i[64*2  +: 64];
                        gb_i[2] <= v_i[64*6  +: 64];
                        gc_i[2] <= v_i[64*10 +: 64];
                        gd_i[2] <= v_i[64*14 +: 64];
                        ga_i[3] <= v_i[64*3  +: 64];
                        gb_i[3] <= v_i[64*7  +: 64];
                        gc_i[3] <= v_i[64*11 +: 64];
                        gd_i[3] <= v_i[64*15 +: 64];
                        g_in_valid <= 1'b1;
                        state      <= COL;
                    end
                end
                COL: begin
                    if (&g_out_valid) begin
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
                    if (&g_out_valid) begin
                        v_o[64*0  +: 64] <= ga_o[0];
                        v_o[64*5  +: 64] <= gb_o[0];
                        v_o[64*10 +: 64] <= gc_o[0];
                        v_o[64*15 +: 64] <= gd_o[0];
                        v_o[64*1  +: 64] <= ga_o[1];
                        v_o[64*6  +: 64] <= gb_o[1];
                        v_o[64*11 +: 64] <= gc_o[1];
                        v_o[64*12 +: 64] <= gd_o[1];
                        v_o[64*2  +: 64] <= ga_o[2];
                        v_o[64*7  +: 64] <= gb_o[2];
                        v_o[64*8  +: 64] <= gc_o[2];
                        v_o[64*13 +: 64] <= gd_o[2];
                        v_o[64*3  +: 64] <= ga_o[3];
                        v_o[64*4  +: 64] <= gb_o[3];
                        v_o[64*9  +: 64] <= gc_o[3];
                        v_o[64*14 +: 64] <= gd_o[3];
                        out_valid <= 1'b1;
                        state     <= IDLE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
