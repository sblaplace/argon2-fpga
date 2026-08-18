// SPDX-License-Identifier: MIT
// p-lane fill: one argon2_fill_ctrl per lane, AND-joined at each slice.
//
// Memory ports stay independent (one channel per lane). Cross-lane
// traffic is only the 1-bit slice barrier — that is the whole point of
// the partitioned-bandwidth floorplan.
//
// `LANES` is an elaboration parameter and must match the job's p.

`timescale 1ns / 1ps

module argon2_fill_job #(
    parameter int ADDR_W = 32,
    parameter int LANES  = 4
) (
    input  logic clk,
    input  logic rst_n,

    input  logic        start,
    output logic        busy,
    output logic        done,
    input  logic [31:0] passes,
    input  logic [31:0] lane_length,
    input  logic [31:0] memory_blocks,
    input  logic [1:0]  type_i,

    output logic [LANES-1:0]             mem_rd_valid,
    input  logic [LANES-1:0]             mem_rd_ready,
    output logic [LANES-1:0][ADDR_W-1:0] mem_rd_addr,
    input  logic [LANES-1:0]             mem_rd_data_v,
    input  logic [LANES-1:0][511:0]      mem_rd_data,
    input  logic [LANES-1:0]             mem_rd_last,

    output logic [LANES-1:0]             mem_wr_valid,
    input  logic [LANES-1:0]             mem_wr_ready,
    output logic [LANES-1:0][ADDR_W-1:0] mem_wr_addr,
    output logic [LANES-1:0][511:0]      mem_wr_data,
    output logic [LANES-1:0]             mem_wr_last
);
    logic [LANES-1:0] lane_busy, lane_done, sync_req, sync_ack;
    logic [LANES-1:0] seen;
    logic             running;

    assign sync_ack = {LANES{&sync_req}};
    assign busy     = running | (|lane_busy);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seen    <= '0;
            running <= 1'b0;
            done    <= 1'b0;
        end else begin
            done <= 1'b0;
            if (start) begin
                seen    <= '0;
                running <= 1'b1;
            end else if (running) begin
                seen <= seen | lane_done;
                if ((&(seen | lane_done)) && !(|lane_busy)) begin
                    running <= 1'b0;
                    done    <= 1'b1;
                end
            end
        end
    end

    genvar gi;
    generate
        for (gi = 0; gi < LANES; gi++) begin : lane
            argon2_fill_ctrl #(.ADDR_W(ADDR_W)) u_fill (
                .clk           (clk),
                .rst_n         (rst_n),
                .start         (start),
                .busy          (lane_busy[gi]),
                .done          (lane_done[gi]),
                .passes        (passes),
                .lanes         (32'(LANES)),
                .lane_id       (32'(gi)),
                .lane_length   (lane_length),
                .memory_blocks (memory_blocks),
                .type_i        (type_i),
                .sync_req      (sync_req[gi]),
                .sync_ack      (sync_ack[gi]),
                .mem_rd_valid  (mem_rd_valid[gi]),
                .mem_rd_ready  (mem_rd_ready[gi]),
                .mem_rd_addr   (mem_rd_addr[gi]),
                .mem_rd_data_v (mem_rd_data_v[gi]),
                .mem_rd_data   (mem_rd_data[gi]),
                .mem_rd_last   (mem_rd_last[gi]),
                .mem_wr_valid  (mem_wr_valid[gi]),
                .mem_wr_ready  (mem_wr_ready[gi]),
                .mem_wr_addr   (mem_wr_addr[gi]),
                .mem_wr_data   (mem_wr_data[gi]),
                .mem_wr_last   (mem_wr_last[gi])
            );
        end
    endgenerate
endmodule
