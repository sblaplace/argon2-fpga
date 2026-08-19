// SPDX-License-Identifier: MIT
// Argon2i / first-half Argon2id address generator (RFC 9106 §3.4.1).
//
//   Z  = LE64(pass) || LE64(lane) || LE64(slice) || LE64(m')
//        || LE64(t) || LE64(y) || LE64(counter) || ZERO
//   A  = G(ZERO, G(ZERO, Z))          // 128 × (J1 || J2)
//
// Each `start` increments the counter and produces one 128-address window.
// `init` loads a new Z and resets the counter to 0. init+start in the same
// cycle is legal (counter goes 0 → 1 with the new Z).
//
// Two lookups so the fill controller can prefetch the next random read
// while the current block is still in G / write.

`timescale 1ns / 1ps

module argon2_addr_gen #(
    parameter int N_P = 1   // parallel P units in the compression G
) (
    input  logic        clk,
    input  logic        rst_n,

    input  logic        init,
    input  logic [31:0] pass,
    input  logic [31:0] lane,
    input  logic [31:0] slice,
    input  logic [31:0] memory_blocks,
    input  logic [31:0] time_cost,
    input  logic [31:0] type_i,

    input  logic        start,
    output logic        busy,
    output logic        done,

    input  logic [6:0]  rd_idx,
    output logic [63:0] rd_j,
    input  logic [6:0]  rd_idx_b,
    output logic [63:0] rd_j_b
);
    typedef enum logic [2:0] {
        IDLE,
        LOAD1,
        WAIT1,
        LOAD2,
        WAIT2
    } state_t;
    state_t state;

    logic [63:0] z_pass, z_lane, z_slice, z_m, z_t, z_y, z_ctr;
    logic [63:0] scratch [0:127];
    logic [63:0] addr    [0:127];
    logic [4:0]  beat;

    logic         c_in_valid, c_in_ready, c_in_last;
    logic [511:0] c_in_y;
    logic         c_out_valid, c_out_ready, c_out_last;
    logic [511:0] c_out_data;

    argon2_compress #(.N_P(N_P)) u_g (
        .clk      (clk),
        .rst_n    (rst_n),
        .in_valid (c_in_valid),
        .in_ready (c_in_ready),
        .in_x     (512'd0),
        .in_y     (c_in_y),
        .in_last  (c_in_last),
        .with_xor (1'b0),
        .in_dest  (512'd0),
        .out_valid(c_out_valid),
        .out_ready(c_out_ready),
        .out_data (c_out_data),
        .out_last (c_out_last)
    );

    always_comb begin
        rd_j   = addr[rd_idx];
        rd_j_b = addr[rd_idx_b];
        if (state == LOAD1) begin
            if (beat == 5'd0)
                c_in_y = {64'd0, z_ctr, z_y, z_t, z_m, z_slice, z_lane, z_pass};
            else
                c_in_y = 512'd0;
        end else begin
            c_in_y = {
                scratch[beat*8 + 7], scratch[beat*8 + 6],
                scratch[beat*8 + 5], scratch[beat*8 + 4],
                scratch[beat*8 + 3], scratch[beat*8 + 2],
                scratch[beat*8 + 1], scratch[beat*8 + 0]
            };
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            busy        <= 1'b0;
            done        <= 1'b0;
            beat        <= 5'd0;
            c_in_valid  <= 1'b0;
            c_in_last   <= 1'b0;
            c_out_ready <= 1'b0;
            z_pass      <= 64'd0;
            z_lane      <= 64'd0;
            z_slice     <= 64'd0;
            z_m         <= 64'd0;
            z_t         <= 64'd0;
            z_y         <= 64'd0;
            z_ctr       <= 64'd0;
        end else begin
            done        <= 1'b0;
            c_out_ready <= 1'b0;

            if (init) begin
                z_pass  <= {32'd0, pass};
                z_lane  <= {32'd0, lane};
                z_slice <= {32'd0, slice};
                z_m     <= {32'd0, memory_blocks};
                z_t     <= {32'd0, time_cost};
                z_y     <= {32'd0, type_i};
                z_ctr   <= 64'd0;
            end

            case (state)
                IDLE: begin
                    busy       <= 1'b0;
                    c_in_valid <= 1'b0;
                    if (start) begin
                        // Increment after a possible same-cycle init.
                        z_ctr       <= (init ? 64'd0 : z_ctr) + 64'd1;
                        beat        <= 5'd0;
                        busy        <= 1'b1;
                        c_in_valid  <= 1'b0;
                        state       <= LOAD1;
                    end
                end

                LOAD1, LOAD2: begin
                    c_in_last  <= (beat == 5'd15);
                    c_in_valid <= 1'b1;
                    if (c_in_valid && c_in_ready) begin
                        if (beat == 5'd15) begin
                            c_in_valid <= 1'b0;
                            beat       <= 5'd0;
                            state      <= (state == LOAD1) ? WAIT1 : WAIT2;
                        end else begin
                            beat <= beat + 5'd1;
                        end
                    end
                end

                WAIT1, WAIT2: begin
                    c_out_ready <= 1'b1;
                    if (c_out_valid && c_out_ready) begin
                        if (state == WAIT1) begin
                            scratch[beat*8 + 0] <= c_out_data[63:0];
                            scratch[beat*8 + 1] <= c_out_data[127:64];
                            scratch[beat*8 + 2] <= c_out_data[191:128];
                            scratch[beat*8 + 3] <= c_out_data[255:192];
                            scratch[beat*8 + 4] <= c_out_data[319:256];
                            scratch[beat*8 + 5] <= c_out_data[383:320];
                            scratch[beat*8 + 6] <= c_out_data[447:384];
                            scratch[beat*8 + 7] <= c_out_data[511:448];
                        end else begin
                            addr[beat*8 + 0] <= c_out_data[63:0];
                            addr[beat*8 + 1] <= c_out_data[127:64];
                            addr[beat*8 + 2] <= c_out_data[191:128];
                            addr[beat*8 + 3] <= c_out_data[255:192];
                            addr[beat*8 + 4] <= c_out_data[319:256];
                            addr[beat*8 + 5] <= c_out_data[383:320];
                            addr[beat*8 + 6] <= c_out_data[447:384];
                            addr[beat*8 + 7] <= c_out_data[511:448];
                        end
                        if (c_out_last || beat == 5'd15) begin
                            beat <= 5'd0;
                            if (state == WAIT1) begin
                                state <= LOAD2;
                            end else begin
                                busy  <= 1'b0;
                                done  <= 1'b1;
                                state <= IDLE;
                            end
                        end else begin
                            beat <= beat + 5'd1;
                        end
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end
endmodule
