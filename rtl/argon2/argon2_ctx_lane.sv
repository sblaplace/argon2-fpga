// SPDX-License-Identifier: MIT
// One compute lane of the many-context engine.
//
// A lane owns one argon2_fill_ctrl (the unchanged, bit-identical fill
// algorithm) and adapts its single-outstanding block port to the tagged
// requester port of argon2_block_fabric.  The scheduler (argon2_multi_ctx)
// assigns one independent p=1 context at a time: `start` latches the
// context descriptor, the fill controller runs it to completion, and `done`
// pulses so the scheduler can retire the context and reuse the lane.
//
// Address mapping: the fill controller speaks a private 0..memory_blocks-1
// block space; the lane adds the context's global base so the fabric can
// stripe the block across the shared HBM partitions.  The read port is
// single-outstanding (the fill controller serializes all of its reads), so
// one requester slot is exactly enough.  The write port needs a beat index
// that the fill controller does not carry, so the lane regenerates it with
// a 0..15 counter reset by `mem_wr_last`.

`timescale 1ns / 1ps

module argon2_ctx_lane #(
    parameter int ADDR_W    = 32,
    parameter int CONTEXT_W = 16,
    parameter int N_P       = 1
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic                    start,     // pulse: latch descriptor + launch
    input  logic [31:0]             passes,
    input  logic [31:0]             lane_length,
    input  logic [31:0]             memory_blocks,
    input  logic [1:0]              type_i,
    input  logic [ADDR_W-1:0]       base,      // global block base of this context
    input  logic [CONTEXT_W-1:0]    ctx_id,
    output logic                    busy,
    output logic                    done,      // pulse when the context finishes

    // Fabric requester port (this lane is one requester).
    output logic                    rd_valid,
    input  logic                    rd_ready,
    output logic [CONTEXT_W-1:0]    rd_context,
    output logic [15:0]             rd_request,
    output logic [ADDR_W-1:0]       rd_block_addr,
    input  logic                    rsp_valid,
    output logic                    rsp_ready,
    input  logic [15:0]             rsp_request,
    input  logic [3:0]              rsp_beat,
    input  logic                    rsp_last,
    input  logic                    rsp_error,
    input  logic [511:0]            rsp_data,
    output logic                    wr_valid,
    input  logic                    wr_ready,
    output logic [CONTEXT_W-1:0]    wr_context,
    output logic [ADDR_W-1:0]       wr_block_addr,
    output logic [3:0]              wr_beat,
    output logic                    wr_last,
    output logic [511:0]            wr_data
);
    logic running;
    logic [31:0]       passes_r, len_r, mem_r;
    logic [1:0]        type_r;
    logic [ADDR_W-1:0] base_r;
    logic [CONTEXT_W-1:0] ctx_r;
    logic [3:0]        wr_beat_r;
    logic [15:0]       rd_seq_r;

    logic              fill_start, fill_done;
    logic [4:0]        fill_state;
    logic              mem_rd_valid, mem_rd_ready, mem_rd_data_v, mem_rd_last;
    logic [ADDR_W-1:0] mem_rd_addr;
    logic [511:0]      mem_rd_data;
    logic              mem_wr_valid, mem_wr_ready, mem_wr_last;
    logic [ADDR_W-1:0] mem_wr_addr;
    logic [511:0]      mem_wr_data;

    argon2_fill_ctrl #(.ADDR_W(ADDR_W), .N_P(N_P)) u_fill (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (fill_start),
        .busy          (),
        .done          (fill_done),
        .state_o       (fill_state),
        .passes        (passes_r),
        .lanes         (32'd1),
        .lane_id       (32'd0),
        .lane_length   (len_r),
        .memory_blocks (mem_r),
        .type_i        (type_r),
        .sync_req      (),
        .sync_ack      (1'b1),
        .mem_rd_valid  (mem_rd_valid),
        .mem_rd_ready  (mem_rd_ready),
        .mem_rd_addr   (mem_rd_addr),
        .mem_rd_owner  (),
        .mem_rd_data_v (mem_rd_data_v),
        .mem_rd_data   (mem_rd_data),
        .mem_rd_last   (mem_rd_last),
        .mem_wr_valid  (mem_wr_valid),
        .mem_wr_ready  (mem_wr_ready),
        .mem_wr_addr   (mem_wr_addr),
        .mem_wr_data   (mem_wr_data),
        .mem_wr_last   (mem_wr_last)
    );

    // ---- fabric adapter ---------------------------------------------------
    assign rd_valid      = running && mem_rd_valid;
    assign rd_context    = ctx_r;
    assign rd_request    = rd_seq_r;
    assign rd_block_addr = ADDR_W'(base_r + ADDR_W'(mem_rd_addr));
    assign mem_rd_ready  = running && rd_ready;
    assign mem_rd_data_v = rsp_valid;
    assign mem_rd_data   = rsp_data;
    assign mem_rd_last   = rsp_last;
    assign rsp_ready     = 1'b1;   // a lane is always ready to take a beat

    assign wr_valid      = running && mem_wr_valid;
    assign wr_context    = ctx_r;
    assign wr_block_addr = ADDR_W'(base_r + ADDR_W'(mem_wr_addr));
    assign wr_beat       = wr_beat_r;
    assign wr_last       = mem_wr_last;
    assign wr_data       = mem_wr_data;
    assign mem_wr_ready  = running && wr_ready;

    assign busy = running;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            running    <= 1'b0;
            fill_start <= 1'b0;
            done       <= 1'b0;
            passes_r   <= 32'd0;
            len_r      <= 32'd0;
            mem_r      <= 32'd0;
            type_r     <= 2'd0;
            base_r     <= '0;
            ctx_r      <= '0;
            wr_beat_r  <= 4'd0;
            rd_seq_r   <= 16'd0;
        end else begin
            fill_start <= 1'b0;
            done       <= 1'b0;
            if (start && !running) begin
                running    <= 1'b1;
                fill_start <= 1'b1;
                passes_r   <= passes;
                len_r      <= lane_length;
                mem_r      <= memory_blocks;
                type_r     <= type_i;
                base_r     <= base;
                ctx_r      <= ctx_id;
                wr_beat_r  <= 4'd0;
                rd_seq_r   <= 16'd0;
            end
            if (running && fill_done) begin
                running <= 1'b0;
                done    <= 1'b1;
            end
            if (running && mem_rd_valid && mem_rd_ready)
                rd_seq_r <= rd_seq_r + 16'd1;
            if (wr_valid && wr_ready)
                wr_beat_r <= wr_last ? 4'd0 : wr_beat_r + 4'd1;
        end
    end

endmodule
