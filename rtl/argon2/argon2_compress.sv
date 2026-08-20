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
//
// DOUBLE-BUFFERING: the block store is two 1 KiB buffers (blk/saved each
// [0:1]). While the compute buffer drains, the idle buffer can be loaded
// through the same input port (background load, lockstep with the drain
// beats). At drain end the buffers swap; if the idle buffer was fully
// loaded the compressor skips LOAD and kicks P directly, so an overlapped
// block costs only P + drain cycles. The fill controller drives this via
// the nxt_* path in argon2_fill_ctrl.

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

    // Double-buffered block storage: buffer [0] and [1]. buf_sel selects
    // which buffer is the compute/drain side; ld_buf selects the buffer
    // receiving load data (always the other one, except when a partial
    // background load is continued in LOAD). During DRAIN the compressor
    // also accepts input for the idle buffer, so LOAD of block N+1
    // overlaps DRAIN of block N.
    logic [63:0] blk   [0:WORDS-1][0:1];
    logic [63:0] saved [0:WORDS-1][0:1];
    logic        buf_sel;        // compute/drain buffer index
    logic        ld_buf;         // load target buffer index
    logic        load_done;      // load buffer fully loaded
    logic [4:0]  load_beat;      // beat counter for background load in DRAIN

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

    // Accept input during LOAD, or during DRAIN while the idle buffer is
    // not yet full (background load into the other buffer).
    assign in_ready = (state == LOAD) || (state == DRAIN && !load_done);

    // Gather the inputs for one wave: group g feeds P instance g%N_P.
    // g < 8 is a row permutation (16 consecutive words); g >= 8 is column
    // g-8 (words gathered from the column strides, see RFC 9106 §3.5).
    // Each P input is assembled in `pv` and stored with a single
    // whole-word write (portable across Icarus and Verilator).
    // P always reads/writes the compute buffer (buf_sel).
    always_comb begin
        for (int w = 0; w < N_P; w = w + 1) begin
            int g;
            int c;
            g = group + w;
            pv = 1024'd0;
            if (g < 8) begin
                for (int i2 = 0; i2 < 16; i2 = i2 + 1)
                    pv[64*i2 +: 64] = blk[g*16 + i2][buf_sel];
            end else if (g < 16) begin
                c = g - 8;
                pv[64*0  +: 64] = blk[2*c +  0][buf_sel];
                pv[64*1  +: 64] = blk[2*c +  1][buf_sel];
                pv[64*2  +: 64] = blk[2*c + 16][buf_sel];
                pv[64*3  +: 64] = blk[2*c + 17][buf_sel];
                pv[64*4  +: 64] = blk[2*c + 32][buf_sel];
                pv[64*5  +: 64] = blk[2*c + 33][buf_sel];
                pv[64*6  +: 64] = blk[2*c + 48][buf_sel];
                pv[64*7  +: 64] = blk[2*c + 49][buf_sel];
                pv[64*8  +: 64] = blk[2*c + 64][buf_sel];
                pv[64*9  +: 64] = blk[2*c + 65][buf_sel];
                pv[64*10 +: 64] = blk[2*c + 80][buf_sel];
                pv[64*11 +: 64] = blk[2*c + 81][buf_sel];
                pv[64*12 +: 64] = blk[2*c + 96][buf_sel];
                pv[64*13 +: 64] = blk[2*c + 97][buf_sel];
                pv[64*14 +: 64] = blk[2*c + 112][buf_sel];
                pv[64*15 +: 64] = blk[2*c + 113][buf_sel];
            end
            p_in[w] = pv;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state      <= LOAD;
            beat       <= 5'd0;
            load_beat  <= 5'd0;
            group      <= 5'd0;
            p_in_valid <= '0;
            out_valid  <= 1'b0;
            out_last   <= 1'b0;
            out_data   <= 512'd0;
            buf_sel    <= 1'b0;
            ld_buf     <= 1'b1;
            load_done  <= 1'b0;
        end else begin
            p_in_valid <= '0;

            case (state)
                LOAD: begin
                    out_valid <= 1'b0;
                    if (in_valid && in_ready) begin
                        for (i = 0; i < WPB; i = i + 1) begin
                            xv = in_x[64*i +: 64];
                            yv = in_y[64*i +: 64];
                            dv = in_dest[64*i +: 64];
                            rv = xv ^ yv;
                            // LOAD writes into the load buffer (ld_buf).
                            blk  [beat*WPB + i][ld_buf] <= rv;
                            saved[beat*WPB + i][ld_buf] <= with_xor ? (rv ^ dv) : rv;
                        end
                        if (in_last || beat == 5'd15) begin
                            load_done <= 1'b0;
                            load_beat <= 5'd0;
                            beat      <= 5'd0;
                            group     <= 5'd0;
                            // Swap: the just-loaded buffer becomes compute.
                            buf_sel   <= ld_buf;
                            ld_buf    <= buf_sel;
                            state     <= KICK;
                        end else begin
                            beat <= beat + 5'd1;
                        end
                    end
                end

                KICK: begin
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
                            // P results go back into the compute buffer.
                            if (g < 8) begin
                                for (int i2 = 0; i2 < 16; i2 = i2 + 1)
                                    blk[g*16 + i2][buf_sel] <= q[64*i2 +: 64];
                            end else if (g < 16) begin
                                c = g - 8;
                                blk[2*c +  0][buf_sel] <= q[64*0  +: 64];
                                blk[2*c +  1][buf_sel] <= q[64*1  +: 64];
                                blk[2*c + 16][buf_sel] <= q[64*2  +: 64];
                                blk[2*c + 17][buf_sel] <= q[64*3  +: 64];
                                blk[2*c + 32][buf_sel] <= q[64*4  +: 64];
                                blk[2*c + 33][buf_sel] <= q[64*5  +: 64];
                                blk[2*c + 48][buf_sel] <= q[64*6  +: 64];
                                blk[2*c + 49][buf_sel] <= q[64*7  +: 64];
                                blk[2*c + 64][buf_sel] <= q[64*8  +: 64];
                                blk[2*c + 65][buf_sel] <= q[64*9  +: 64];
                                blk[2*c + 80][buf_sel] <= q[64*10 +: 64];
                                blk[2*c + 81][buf_sel] <= q[64*11 +: 64];
                                blk[2*c + 96][buf_sel] <= q[64*12 +: 64];
                                blk[2*c + 97][buf_sel] <= q[64*13 +: 64];
                                blk[2*c + 112][buf_sel] <= q[64*14 +: 64];
                                blk[2*c + 113][buf_sel] <= q[64*15 +: 64];
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
                    //
                    // While draining the compute buffer, also accept the
                    // next block's input into the idle buffer (ld_buf) via
                    // the background load path, so the next block's LOAD
                    // overlaps this DRAIN.
                    //
                    // NOTE: the background load runs BEFORE the drain-exit
                    // logic. On the final cycle both fire: the background
                    // load sets load_done (last beat accepted) and the exit
                    // resets it (the just-drained buffer becomes the new
                    // idle target, which is empty). The exit must win, so
                    // it must be the LAST assignment in this case.
                    if (!load_done && in_valid && in_ready) begin
                        for (i = 0; i < WPB; i = i + 1) begin
                            xv = in_x[64*i +: 64];
                            yv = in_y[64*i +: 64];
                            dv = in_dest[64*i +: 64];
                            rv = xv ^ yv;
                            blk  [load_beat*WPB + i][ld_buf] <= rv;
                            saved[load_beat*WPB + i][ld_buf] <= with_xor ? (rv ^ dv) : rv;
                        end
                        if (in_last || load_beat == 5'd15) begin
                            load_done <= 1'b1;
                        end else begin
                            load_beat <= load_beat + 5'd1;
                        end
                    end

                    if (out_valid && out_ready && out_last) begin
                        out_valid <= 1'b0;
                        out_last  <= 1'b0;
                        load_beat <= 5'd0;
                        group     <= 5'd0;
                        // The background load's last beat is accepted in this
                        // same cycle, so load_done has not updated yet: treat
                        // an in-flight last-beat handshake as complete too.
                        if (load_done || (in_valid && in_ready && load_beat == 5'd15)) begin
                            // Background load finished: the load buffer
                            // becomes compute, skip LOAD, kick P.
                            beat      <= 5'd0;
                            load_done <= 1'b0;
                            buf_sel   <= ld_buf;
                            ld_buf    <= buf_sel;
                            state     <= KICK;
                        end else if (load_beat != 5'd0) begin
                            // Partial background load: continue loading into
                            // the same buffer (no swap), from load_beat on.
                            beat      <= load_beat;
                            state     <= LOAD;
                        end else begin
                            // No background load: fresh LOAD into the idle
                            // buffer (ld_buf stays !buf_sel).
                            beat      <= 5'd0;
                            state     <= LOAD;
                        end
                    end else if (!out_valid || out_ready) begin
                        beat <= out_valid ? (beat + 5'd1) : 5'd0;
                        out_data <= {
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 7][buf_sel]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 7][buf_sel],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 6][buf_sel]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 6][buf_sel],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 5][buf_sel]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 5][buf_sel],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 4][buf_sel]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 4][buf_sel],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 3][buf_sel]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 3][buf_sel],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 2][buf_sel]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 2][buf_sel],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 1][buf_sel]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 1][buf_sel],
                            blk[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 0][buf_sel]
                                ^ saved[(out_valid ? beat + 5'd1 : 5'd0)*WPB + 0][buf_sel]
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
