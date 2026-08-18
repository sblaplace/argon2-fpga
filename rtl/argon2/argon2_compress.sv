// SPDX-License-Identifier: MIT
// Argon2 compression G (RFC 9106 §3.5).
//
//   R = X ⊕ Y
//   Q = P_row(R)     // 8 independent P
//   Z = P_col(Q)     // 8 independent P
//   out = Z ⊕ R  [⊕ dest if with_xor, i.e. pass > 0]
//
// Blocks stream as 16 beats × 512 bits. One shared argon2_p is reused
// for all 16 permutations (~9 cycles each → ~160 cycles of compute).

`timescale 1ns / 1ps

module argon2_compress (
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

    typedef enum logic [2:0] { LOAD, KICK, WAIT_P, DRAIN } state_t;
    state_t state;

    logic [63:0] blk   [0:WORDS-1];
    logic [63:0] saved [0:WORDS-1];

    logic [4:0] beat;
    logic [4:0] group;     // 0..15 : rows 0..7 then cols 0..7
    logic         p_in_valid;
    logic         p_out_valid;
    logic [1023:0] p_in;
    logic [1023:0] p_out;

    argon2_p u_p (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (p_in_valid),
        .v_i      (p_in),
        .out_valid(p_out_valid),
        .v_o      (p_out)
    );

    integer i;
    logic [63:0] xv, yv, dv, rv;
    logic [3:0]  col;
    logic [4:0]  drain_idx;

    always_comb begin
        drain_idx = out_valid ? (beat + 5'd1) : 5'd0;
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= LOAD;
            beat       <= 5'd0;
            group      <= 5'd0;
            p_in_valid <= 1'b0;
            in_ready   <= 1'b1;
            out_valid  <= 1'b0;
            out_last   <= 1'b0;
            out_data   <= 512'd0;
        end else begin
            p_in_valid <= 1'b0;

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
                    in_ready <= 1'b0;
                    if (group < 5'd8) begin
                        for (i = 0; i < 16; i = i + 1)
                            p_in[64*i +: 64] <= blk[group*16 + i];
                    end else begin
                        col = group[3:0] - 4'd8;
                        p_in[64*0 +: 64] <= blk[2*col + 0];
                        p_in[64*1 +: 64] <= blk[2*col + 1];
                        p_in[64*2 +: 64] <= blk[2*col + 16];
                        p_in[64*3 +: 64] <= blk[2*col + 17];
                        p_in[64*4 +: 64] <= blk[2*col + 32];
                        p_in[64*5 +: 64] <= blk[2*col + 33];
                        p_in[64*6 +: 64] <= blk[2*col + 48];
                        p_in[64*7 +: 64] <= blk[2*col + 49];
                        p_in[64*8 +: 64] <= blk[2*col + 64];
                        p_in[64*9 +: 64] <= blk[2*col + 65];
                        p_in[64*10 +: 64] <= blk[2*col + 80];
                        p_in[64*11 +: 64] <= blk[2*col + 81];
                        p_in[64*12 +: 64] <= blk[2*col + 96];
                        p_in[64*13 +: 64] <= blk[2*col + 97];
                        p_in[64*14 +: 64] <= blk[2*col + 112];
                        p_in[64*15 +: 64] <= blk[2*col + 113];
                    end
                    p_in_valid <= 1'b1;
                    state      <= WAIT_P;
                end

                WAIT_P: begin
                    if (p_out_valid) begin
                        if (group < 5'd8) begin
                            for (i = 0; i < 16; i = i + 1)
                                blk[group*16 + i] <= p_out[64*i +: 64];
                        end else begin
                            col = group[3:0] - 4'd8;
                            blk[2*col + 0] <= p_out[64*0 +: 64];
                            blk[2*col + 1] <= p_out[64*1 +: 64];
                            blk[2*col + 16] <= p_out[64*2 +: 64];
                            blk[2*col + 17] <= p_out[64*3 +: 64];
                            blk[2*col + 32] <= p_out[64*4 +: 64];
                            blk[2*col + 33] <= p_out[64*5 +: 64];
                            blk[2*col + 48] <= p_out[64*6 +: 64];
                            blk[2*col + 49] <= p_out[64*7 +: 64];
                            blk[2*col + 64] <= p_out[64*8 +: 64];
                            blk[2*col + 65] <= p_out[64*9 +: 64];
                            blk[2*col + 80] <= p_out[64*10 +: 64];
                            blk[2*col + 81] <= p_out[64*11 +: 64];
                            blk[2*col + 96] <= p_out[64*12 +: 64];
                            blk[2*col + 97] <= p_out[64*13 +: 64];
                            blk[2*col + 112] <= p_out[64*14 +: 64];
                            blk[2*col + 113] <= p_out[64*15 +: 64];
                        end
                        if (group == 5'd15) begin
                            beat  <= 5'd0;
                            state <= DRAIN;
                        end else begin
                            group <= group + 5'd1;
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
