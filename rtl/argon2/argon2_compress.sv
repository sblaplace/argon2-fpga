// SPDX-License-Identifier: MIT
// Argon2 compression G (RFC 9106 §3.5).
//
//   R = X ⊕ Y
//   Q = P_row(R)     // 8 independent P
//   Z = P_col(Q)     // 8 independent P
//   out = Z ⊕ R  [⊕ dest if with_xor, i.e. pass > 0]
//
// Blocks stream as 16 beats × 512 bits. N_P permutation units run in
// parallel; the 16 P applications are issued in waves of N_P. N_P must be
// 1, 2, 4, or 8: every wave must stay wholly within either the eight row
// permutations or the eight column permutations. Columns read the completed
// row result, so N_P=16 would incorrectly launch both phases together.
// Parallelism does not change the result for any supported N_P — only the
// cycle count:
//
//   N_P = 1  -> 16 waves × ~9 cycles ≈ 160 cycles of compute per block
//   N_P = 8  ->  2 waves × ~9 cycles ≈  18 cycles
//
// Area scales with N_P (one argon2_p ≈ 16 DSP48 multipliers). Default 1
// keeps the small, fully-verified core; perf builds use -GN_P=8.

`timescale 1ns / 1ps

module argon2_compress #(
    parameter int N_P = 1
) (
    input  logic         clk,
    input  logic         rst_n,

    input  logic         in_valid,
    output logic         in_ready,
    input  logic [511:0] in_x,
    input  logic [511:0] in_y,
    input  logic         in_last,
    input  logic         with_xor,
    input  logic [511:0] in_dest,

    output logic         out_valid,
    input  logic         out_ready,
    output logic [511:0] out_data,
    output logic         out_last
);
    localparam int WORDS = 128;
    localparam int WPB   = 8;

    // The scheduler advances by N_P and relies on a wave boundary exactly
    // between row groups 0..7 and column groups 8..15. Fail at elaboration
    // instead of silently producing a plausible-looking wrong hash.
    initial begin : validate_parameters
        if (!(N_P == 1 || N_P == 2 || N_P == 4 || N_P == 8))
            $fatal(1, "argon2_compress: N_P must be one of 1, 2, 4, or 8 (got %0d)", N_P);
    end

    typedef enum logic [2:0] { LOAD, KICK, WAIT_P, DRAIN } state_t;
    state_t state;

    logic [63:0] blk   [0:WORDS-1];
    logic [63:0] saved [0:WORDS-1];

    logic [4:0] beat;
    logic [4:0] group;          // first P-group of the current wave
    logic [N_P-1:0]         p_in_valid;
    logic [N_P-1:0]         p_out_valid;
    logic [N_P-1:0][1023:0] p_in;
    logic [N_P-1:0][1023:0] p_out;

    generate
        for (genvar gp = 0; gp < N_P; gp = gp + 1) begin : pg
            argon2_p u_p (
                .clk      (clk),
                .rst_n    (rst_n),
                .in_valid (p_in_valid[gp]),
                .v_i      (p_in[gp]),
                .out_valid(p_out_valid[gp]),
                .v_o      (p_out[gp])
            );
        end
    endgenerate

    integer i;
    logic [63:0] xv, yv, dv, rv;
    logic [4:0]  drain_idx;
    logic [1023:0] pv;   // gather temp: build a P input, then write the
    logic [1023:0] q;    // whole word (Icarus can't bit-select mem words)

    always_comb begin
        drain_idx = out_valid ? (beat + 5'd1) : 5'd0;
    end

    // Gather the inputs for one wave: group g feeds P instance g%N_P.
    // g < 8 is a row permutation (16 consecutive words); g >= 8 is column
    // g-8 (words gathered from the column strides, see RFC 9106 §3.5).
    // Each P input is assembled in `pv` and stored with a single
    // whole-word write (portable across Icarus and Verilator).
    always_comb begin
        for (int w = 0; w < N_P; w = w + 1) begin
            int g;
            int c;
            g = group + w;
            pv = 1024'd0;
            if (g < 8) begin
                for (int i2 = 0; i2 < 16; i2 = i2 + 1)
                    pv[64*i2 +: 64] = blk[g*16 + i2];
            end else if (g < 16) begin
                c = g - 8;
                pv[64*0  +: 64] = blk[2*c +  0];
                pv[64*1  +: 64] = blk[2*c +  1];
                pv[64*2  +: 64] = blk[2*c + 16];
                pv[64*3  +: 64] = blk[2*c + 17];
                pv[64*4  +: 64] = blk[2*c + 32];
                pv[64*5  +: 64] = blk[2*c + 33];
                pv[64*6  +: 64] = blk[2*c + 48];
                pv[64*7  +: 64] = blk[2*c + 49];
                pv[64*8  +: 64] = blk[2*c + 64];
                pv[64*9  +: 64] = blk[2*c + 65];
                pv[64*10 +: 64] = blk[2*c + 80];
                pv[64*11 +: 64] = blk[2*c + 81];
                pv[64*12 +: 64] = blk[2*c + 96];
                pv[64*13 +: 64] = blk[2*c + 97];
                pv[64*14 +: 64] = blk[2*c + 112];
                pv[64*15 +: 64] = blk[2*c + 113];
            end
            p_in[w] = pv;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= LOAD;
            beat       <= 5'd0;
            group      <= 5'd0;
            p_in_valid <= '0;
            in_ready   <= 1'b1;
            out_valid  <= 1'b0;
            out_last   <= 1'b0;
            out_data   <= 512'd0;
        end else begin
            p_in_valid <= '0;

            case (state)
                LOAD: begin
                    in_ready  <= 1'b1;
                    out_valid <= 1'b0;
                    if (in_valid && in_ready) begin
                        for (i = 0; i < WPB; i = i + 1) begin
                            xv = in_x[64*i +: 64];
                            yv = in_y[64*i +: 64];
                            dv = in_dest[64*i +: 64];
                            rv = xv ^ yv;
                            blk  [beat*WPB + i] <= rv;
                            saved[beat*WPB + i] <= with_xor ? (rv ^ dv) : rv;
                        end
                        if (in_last || beat == 5'd15) begin
                            beat     <= 5'd0;
                            group    <= 5'd0;
                            in_ready <= 1'b0;
                            state    <= KICK;
                        end else begin
                            beat <= beat + 5'd1;
                        end
                    end
                end

                KICK: begin
                    in_ready   <= 1'b0;
                    p_in_valid <= '1;
                    state      <= WAIT_P;
                end

                WAIT_P: begin
                    if (&p_out_valid) begin
                        for (int w = 0; w < N_P; w = w + 1) begin
                            int g;
                            int c;
                            q = p_out[w];
                            g = group + w;
                            if (g < 8) begin
                                for (int i2 = 0; i2 < 16; i2 = i2 + 1)
                                    blk[g*16 + i2] <= q[64*i2 +: 64];
                            end else if (g < 16) begin
                                c = g - 8;
                                blk[2*c +  0] <= q[64*0  +: 64];
                                blk[2*c +  1] <= q[64*1  +: 64];
                                blk[2*c + 16] <= q[64*2  +: 64];
                                blk[2*c + 17] <= q[64*3  +: 64];
                                blk[2*c + 32] <= q[64*4  +: 64];
                                blk[2*c + 33] <= q[64*5  +: 64];
                                blk[2*c + 48] <= q[64*6  +: 64];
                                blk[2*c + 49] <= q[64*7  +: 64];
                                blk[2*c + 64] <= q[64*8  +: 64];
                                blk[2*c + 65] <= q[64*9  +: 64];
                                blk[2*c + 80] <= q[64*10 +: 64];
                                blk[2*c + 81] <= q[64*11 +: 64];
                                blk[2*c + 96] <= q[64*12 +: 64];
                                blk[2*c + 97] <= q[64*13 +: 64];
                                blk[2*c + 112] <= q[64*14 +: 64];
                                blk[2*c + 113] <= q[64*15 +: 64];
                            end
                        end
                        if (group + N_P >= 16) begin
                            beat  <= 5'd0;
                            state <= DRAIN;
                        end else begin
                            group <= group + N_P;
                            state <= KICK;
                        end
                    end
                end

                DRAIN: begin
                    // Present beat 0 on entry (out_valid is 0), then advance
                    // only after the current beat is accepted. Finish on the
                    // handshake of the last beat — *not* on the cycle we
                    // first drive it, or a continuously-ready sink drops it.
                    if (out_valid && out_ready && out_last) begin
                        out_valid <= 1'b0;
                        out_last  <= 1'b0;
                        beat      <= 5'd0;
                        in_ready  <= 1'b1;
                        state     <= LOAD;
                    end else if (!out_valid || out_ready) begin
                        beat <= out_valid ? (beat + 5'd1) : 5'd0;
                        out_data <= {
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 7]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 7],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 6]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 6],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 5]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 5],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 4]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 4],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 3]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 3],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 2]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 2],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 1]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 1],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 0]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 0]
                        };
                        out_valid <= 1'b1;
                        out_last  <= ((out_valid ? beat + 5'd1 : 5'd0) == 5'd15);
                    end
                end

                default: state <= LOAD;
            endcase
        end
    end
endmodule
