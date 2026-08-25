// SPDX-License-Identifier: MIT
// Many-context Argon2 engine: a pool of compute lanes shared by independent
// p=1 contexts over one logical HBM stack.
//
// This is step 3 of the HBM4 plan (docs/HBM4_ARCHITECTURE.md): a context
// scheduler around the existing, bit-identical argon2_fill_ctrl.  A context
// is one password attempt (its descriptor: passes, lane_length, memory
// blocks, type, and a global block base).  The scheduler round-robins idle
// lanes over pending contexts; each lane runs one context at a time and
// exposes a tagged requester port to a shared argon2_block_fabric, which
// stripes every block across PARTITIONS partitions of the logical HBM stack.
//
// The host writes descriptors (cfg_*), launches contexts (go_valid/go_addr),
// and observes completion (ctx_done pulses / ctx_busy levels).  Contexts are
// independent p=1 jobs: no cross-context barrier, no shared memory region.
// All correctness-critical RAW hazards stay inside the unchanged fill
// controller; this wrapper only multiplexes lanes and tags memory traffic.

`timescale 1ns / 1ps

module argon2_multi_ctx #(
    parameter int ADDR_W    = 32,   // global block address width (HBM space)
    parameter int CONTEXT_W = 16,   // context id width (also the fabric tag)
    parameter int LANES     = 8,    // compute lanes == resident contexts
    parameter int CONTEXTS  = 32,   // host-visible context descriptors
    parameter int PARTITIONS = 8,   // fabric partitions of the HBM stack
    parameter int N_P       = 1     // parallel P units in each lane's G
) (
    input  logic clk,
    input  logic rst_n,

    // ---- host control ----------------------------------------------------
    input  logic                    cfg_we,
    input  logic [CONTEXT_W-1:0]    cfg_addr,
    input  logic [31:0]             cfg_passes,
    input  logic [31:0]             cfg_lane_length,   // blocks per lane (== mem for p=1)
    input  logic [31:0]             cfg_memory_blocks,
    input  logic [1:0]              cfg_type,
    input  logic [ADDR_W-1:0]       cfg_base,          // global block base

    input  logic                    go_valid,
    input  logic [CONTEXT_W-1:0]    go_addr,
    output logic [CONTEXTS-1:0]     ctx_done,          // one-cycle completion pulse
    output logic [CONTEXTS-1:0]     ctx_busy,          // pending | running
    output logic                    all_idle,          // no pending and no running

    // ---- fabric partition side (attach the HBM memory model here) --------
    output logic [PARTITIONS-1:0]                    mem_rd_valid,
    input  logic [PARTITIONS-1:0]                    mem_rd_ready,
    output logic [PARTITIONS-1:0][CONTEXT_W-1:0]     mem_rd_context,
    output logic [PARTITIONS-1:0][ADDR_W-1:0]        mem_rd_block_addr,
    input  logic [PARTITIONS-1:0]                    mem_data_valid,
    output logic [PARTITIONS-1:0]                    mem_data_ready,
    input  logic [PARTITIONS-1:0][3:0]               mem_data_beat,
    input  logic [PARTITIONS-1:0]                    mem_data_last,
    input  logic [PARTITIONS-1:0][511:0]             mem_data,
    input  logic [PARTITIONS-1:0]                    mem_data_error,
    output logic [PARTITIONS-1:0]                    mem_wr_valid,
    input  logic [PARTITIONS-1:0]                    mem_wr_ready,
    output logic [PARTITIONS-1:0][CONTEXT_W-1:0]     mem_wr_context,
    output logic [PARTITIONS-1:0][ADDR_W-1:0]        mem_wr_block_addr,
    output logic [PARTITIONS-1:0][3:0]               mem_wr_beat,
    output logic [PARTITIONS-1:0]                    mem_wr_last,
    output logic [PARTITIONS-1:0][511:0]             mem_wr_data
);
    // ---- context descriptor table ----------------------------------------
    logic [CONTEXTS-1:0] d_pending, d_running;
    logic [31:0]       d_pass [0:CONTEXTS-1];
    logic [31:0]       d_len  [0:CONTEXTS-1];
    logic [31:0]       d_mem  [0:CONTEXTS-1];
    logic [1:0]        d_type [0:CONTEXTS-1];
    logic [ADDR_W-1:0] d_base [0:CONTEXTS-1];

    // ---- lane state ------------------------------------------------------
    integer            lane_ctx [0:LANES-1];   // context on lane i; -1 = idle
    logic [LANES-1:0]  lane_start;             // dispatch pulse to the lane
    logic [LANES-1:0]  lane_done;              // completion pulse from the lane
    integer            rr_ctx;                 // round-robin dispatch pointer

    // Lane parameter mux (combinational from the assigned descriptor).
    logic [31:0]       lane_pass [0:LANES-1];
    logic [31:0]       lane_len  [0:LANES-1];
    logic [31:0]       lane_mem  [0:LANES-1];
    logic [1:0]        lane_type [0:LANES-1];
    logic [ADDR_W-1:0] lane_base [0:LANES-1];
    logic [CONTEXT_W-1:0] lane_cid [0:LANES-1];

    // Fabric requester-side wiring (LANES requesters).
    logic [LANES-1:0] rd_valid, rd_ready;
    logic [LANES-1:0][CONTEXT_W-1:0] rd_context;
    logic [LANES-1:0][15:0] rd_request;
    logic [LANES-1:0][ADDR_W-1:0] rd_block_addr;
    logic [LANES-1:0] rsp_valid, rsp_ready;
    logic [LANES-1:0][15:0] rsp_request;
    logic [LANES-1:0][3:0] rsp_beat;
    logic [LANES-1:0] rsp_last, rsp_error;
    logic [LANES-1:0][511:0] rsp_data;
    logic [LANES-1:0] wr_valid, wr_ready, wr_last;
    logic [LANES-1:0][CONTEXT_W-1:0] wr_context;
    logic [LANES-1:0][ADDR_W-1:0] wr_block_addr;
    logic [LANES-1:0][3:0] wr_beat;
    logic [LANES-1:0][511:0] wr_data;

    assign ctx_busy = d_pending | d_running;
    assign all_idle = !(|ctx_busy);

    // ---- parameter mux ---------------------------------------------------
    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            if (lane_ctx[i] >= 0) begin
                lane_pass[i] = d_pass[lane_ctx[i]];
                lane_len[i]  = d_len[lane_ctx[i]];
                lane_mem[i]  = d_mem[lane_ctx[i]];
                lane_type[i] = d_type[lane_ctx[i]];
                lane_base[i] = d_base[lane_ctx[i]];
                lane_cid[i]  = CONTEXT_W'(lane_ctx[i]);
            end else begin
                lane_pass[i] = 32'd0;
                lane_len[i]  = 32'd0;
                lane_mem[i]  = 32'd0;
                lane_type[i] = 2'd0;
                lane_base[i] = '0;
                lane_cid[i]  = '0;
            end
        end
    end

    // ---- scheduler -------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d_pending  <= '0;
            d_running  <= '0;
            ctx_done   <= '0;
            rr_ctx     <= 0;
            lane_start <= '0;
            for (int c = 0; c < CONTEXTS; c++) begin
                d_pass[c] <= 32'd0;
                d_len[c]  <= 32'd0;
                d_mem[c]  <= 32'd0;
                d_type[c] <= 2'd0;
                d_base[c] <= '0;
            end
            for (int i = 0; i < LANES; i++)
                lane_ctx[i] <= -1;
        end else begin
            integer nxt, lid, k;
            ctx_done   <= '0;
            lane_start <= '0;

            // Descriptor write.
            if (cfg_we) begin
                d_pass[cfg_addr] <= cfg_passes;
                d_len[cfg_addr]  <= cfg_lane_length;
                d_mem[cfg_addr]  <= cfg_memory_blocks;
                d_type[cfg_addr] <= cfg_type;
                d_base[cfg_addr] <= cfg_base;
            end

            // Launch.
            if (go_valid && !d_pending[go_addr] && !d_running[go_addr])
                d_pending[go_addr] <= 1'b1;

            // Retire completed lanes.
            for (int i = 0; i < LANES; i++) begin
                if (lane_done[i] && lane_ctx[i] >= 0) begin
                    ctx_done[lane_ctx[i]] <= 1'b1;
                    d_running[lane_ctx[i]]  <= 1'b0;
                    lane_ctx[i]             <= -1;
                end
            end

            // Dispatch one pending context into one idle lane per cycle.
            nxt = -1;
            for (k = 0; k < CONTEXTS; k++) begin
                int c;
                c = (rr_ctx + k) % CONTEXTS;
                if (d_pending[c] && nxt == -1)
                    nxt = c;
            end
            lid = -1;
            for (int i = 0; i < LANES; i++)
                if (lane_ctx[i] == -1 && lid == -1)
                    lid = i;
            if (nxt != -1 && lid != -1) begin
                lane_ctx[lid]    <= nxt;
                d_pending[nxt]   <= 1'b0;
                d_running[nxt]   <= 1'b1;
                lane_start[lid]  <= 1'b1;
                rr_ctx <= (nxt == CONTEXTS - 1) ? 0 : nxt + 1;
            end
        end
    end

    // ---- compute lanes + fabric ------------------------------------------
    generate
        for (genvar i = 0; i < LANES; i++) begin : g_lane
            argon2_ctx_lane #(
                .ADDR_W(ADDR_W), .CONTEXT_W(CONTEXT_W), .N_P(N_P)
            ) lane (
                .clk           (clk),
                .rst_n         (rst_n),
                .start         (lane_start[i]),
                .passes        (lane_pass[i]),
                .lane_length   (lane_len[i]),
                .memory_blocks (lane_mem[i]),
                .type_i        (lane_type[i]),
                .base          (lane_base[i]),
                .ctx_id        (lane_cid[i]),
                .busy          (),
                .done          (lane_done[i]),
                .rd_valid      (rd_valid[i]),
                .rd_ready      (rd_ready[i]),
                .rd_context    (rd_context[i]),
                .rd_request    (rd_request[i]),
                .rd_block_addr (rd_block_addr[i]),
                .rsp_valid     (rsp_valid[i]),
                .rsp_ready     (rsp_ready[i]),
                .rsp_request   (rsp_request[i]),
                .rsp_beat      (rsp_beat[i]),
                .rsp_last      (rsp_last[i]),
                .rsp_error     (rsp_error[i]),
                .rsp_data      (rsp_data[i]),
                .wr_valid      (wr_valid[i]),
                .wr_ready      (wr_ready[i]),
                .wr_context    (wr_context[i]),
                .wr_block_addr (wr_block_addr[i]),
                .wr_beat       (wr_beat[i]),
                .wr_last       (wr_last[i]),
                .wr_data       (wr_data[i])
            );
        end
    endgenerate

    argon2_block_fabric #(
        .ADDR_W(ADDR_W), .CONTEXT_W(CONTEXT_W), .REQUEST_W(16), .DATA_W(512),
        .REQUESTERS(LANES), .PARTITIONS(PARTITIONS)
    ) u_fabric (
        .clk           (clk),
        .rst_n         (rst_n),
        .rd_ready      (rd_ready),
        .rd_valid      (rd_valid),
        .rd_context    (rd_context),
        .rd_request    (rd_request),
        .rd_block_addr (rd_block_addr),
        .rsp_valid     (rsp_valid),
        .rsp_ready     (rsp_ready),
        .rsp_context   (),
        .rsp_request   (rsp_request),
        .rsp_beat      (rsp_beat),
        .rsp_last      (rsp_last),
        .rsp_data      (rsp_data),
        .rsp_error     (rsp_error),
        .wr_ready      (wr_ready),
        .wr_valid      (wr_valid),
        .wr_context    (wr_context),
        .wr_block_addr (wr_block_addr),
        .wr_beat       (wr_beat),
        .wr_last       (wr_last),
        .wr_data       (wr_data),
        .mem_rd_valid  (mem_rd_valid),
        .mem_rd_ready  (mem_rd_ready),
        .mem_rd_context(mem_rd_context),
        .mem_rd_block_addr(mem_rd_block_addr),
        .mem_data_valid(mem_data_valid),
        .mem_data_ready(mem_data_ready),
        .mem_data_beat (mem_data_beat),
        .mem_data_last (mem_data_last),
        .mem_data      (mem_data),
        .mem_data_error(mem_data_error),
        .mem_wr_valid  (mem_wr_valid),
        .mem_wr_ready  (mem_wr_ready),
        .mem_wr_context(mem_wr_context),
        .mem_wr_block_addr(mem_wr_block_addr),
        .mem_wr_beat   (mem_wr_beat),
        .mem_wr_last   (mem_wr_last),
        .mem_wr_data   (mem_wr_data)
    );

endmodule
