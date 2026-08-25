// SPDX-License-Identifier: MIT
// Parameterized tagged block-read fabric for the HBM-scale architecture.
//
// This is deliberately memory-controller independent.  Requesters present a
// logical (context, block) address; the fabric stripes blocks across a power
// of two number of partitions and returns the 16-beat response to the tagged
// requester.  Each partition has one command slot and one ordered response
// stream.  It is a correctness-first baseline for the many-context design,
// not the final HBM scheduler.
//
// Mapping (PARTITIONS must be a power of two):
//   partition = (context_id + block_addr) & (PARTITIONS - 1)
//   local_addr = block_addr >> log2(PARTITIONS)
//
// The context ID is carried to the memory side so a later adapter can add a
// context base, or use a memory-side context table.  Keeping this mapping at
// block granularity avoids coupling the Argon2 controller to an HBM burst
// width or PHY.
//
// Multi-bit payload busses are declared as unpacked arrays (like the blake2b
// modules) because the per-partition / per-requester state is indexed by
// loop variables everywhere; Icarus cannot elaborate variable part-selects
// on packed 2-D arrays.

`timescale 1ns / 1ps

module argon2_block_fabric #(
    parameter int ADDR_W       = 32,
    parameter int CONTEXT_W    = 16,
    parameter int REQUEST_W    = 16,
    parameter int DATA_W       = 512,
    parameter int BEAT_W       = 4,
    parameter int REQUESTERS   = 32,
    parameter int PARTITIONS   = 32
) (
    input  logic clk,
    input  logic rst_n,

    // Requester side: one outstanding block request per requester.
    output logic [REQUESTERS-1:0]                    rd_ready,
    input  logic [REQUESTERS-1:0]                    rd_valid,
    input  logic [CONTEXT_W-1:0]                     rd_context [0:REQUESTERS-1],
    input  logic [REQUEST_W-1:0]                     rd_request [0:REQUESTERS-1],
    input  logic [ADDR_W-1:0]                        rd_block_addr [0:REQUESTERS-1],

    output logic [REQUESTERS-1:0]                    rsp_valid,
    input  logic [REQUESTERS-1:0]                    rsp_ready,
    output logic [CONTEXT_W-1:0]                     rsp_context [0:REQUESTERS-1],
    output logic [REQUEST_W-1:0]                     rsp_request [0:REQUESTERS-1],
    output logic [BEAT_W-1:0]                        rsp_beat [0:REQUESTERS-1],
    output logic [REQUESTERS-1:0]                    rsp_last,
    output logic [DATA_W-1:0]                        rsp_data [0:REQUESTERS-1],
    output logic [REQUESTERS-1:0]                    rsp_error,

    // Requester-side write stream. Beats of one block must be presented in
    // order; the fabric may arbitrate different requesters independently.
    output logic [REQUESTERS-1:0]                    wr_ready,
    input  logic [REQUESTERS-1:0]                    wr_valid,
    input  logic [CONTEXT_W-1:0]                     wr_context [0:REQUESTERS-1],
    input  logic [ADDR_W-1:0]                        wr_block_addr [0:REQUESTERS-1],
    input  logic [BEAT_W-1:0]                        wr_beat [0:REQUESTERS-1],
    input  logic [REQUESTERS-1:0]                    wr_last,
    input  logic [DATA_W-1:0]                        wr_data [0:REQUESTERS-1],

    // Partition side.  A partition memory must return beats in order for
    // the accepted command, and assert data_last on beat 15.
    output logic [PARTITIONS-1:0]                    mem_rd_valid,
    input  logic [PARTITIONS-1:0]                    mem_rd_ready,
    output logic [CONTEXT_W-1:0]                     mem_rd_context [0:PARTITIONS-1],
    output logic [ADDR_W-1:0]                        mem_rd_block_addr [0:PARTITIONS-1],
    input  logic [PARTITIONS-1:0]                    mem_data_valid,
    output logic [PARTITIONS-1:0]                    mem_data_ready,
    input  logic [BEAT_W-1:0]                        mem_data_beat [0:PARTITIONS-1],
    input  logic [PARTITIONS-1:0]                    mem_data_last,
    input  logic [DATA_W-1:0]                        mem_data [0:PARTITIONS-1],
    input  logic [PARTITIONS-1:0]                    mem_data_error,

    output logic [PARTITIONS-1:0]                    mem_wr_valid,
    input  logic [PARTITIONS-1:0]                    mem_wr_ready,
    output logic [CONTEXT_W-1:0]                     mem_wr_context [0:PARTITIONS-1],
    output logic [ADDR_W-1:0]                        mem_wr_block_addr [0:PARTITIONS-1],
    output logic [BEAT_W-1:0]                        mem_wr_beat [0:PARTITIONS-1],
    output logic [PARTITIONS-1:0]                    mem_wr_last,
    output logic [DATA_W-1:0]                        mem_wr_data [0:PARTITIONS-1]
);
    localparam int PART_W = (PARTITIONS <= 1) ? 1 : $clog2(PARTITIONS);
    localparam int RW     = (REQUESTERS <= 1) ? 1 : $clog2(REQUESTERS);

    // This baseline deliberately uses a power-of-two mapping.  A non-power
    // of two configuration would make the shift-based local address wrong.
    initial begin
        if (PARTITIONS < 1 || (PARTITIONS & (PARTITIONS - 1)) != 0)
            $error("argon2_block_fabric: PARTITIONS must be a power of two");
    end

    function automatic logic [PART_W-1:0] map_partition(
        input logic [CONTEXT_W-1:0] ctx,
        input logic [ADDR_W-1:0] block
    );
        logic [ADDR_W:0] mixed;
        begin
            mixed = {1'b0, block} + {{(ADDR_W+1-CONTEXT_W){1'b0}}, ctx};
            map_partition = mixed[PART_W-1:0];
        end
    endfunction

    function automatic logic [ADDR_W-1:0] map_local_addr(
        input logic [ADDR_W-1:0] block
    );
        begin
            map_local_addr = block >> PART_W;
        end
    endfunction

    logic [REQUESTERS-1:0] q_valid;
    logic [CONTEXT_W-1:0]  q_context [0:REQUESTERS-1];
    logic [REQUEST_W-1:0]  q_request [0:REQUESTERS-1];
    logic [ADDR_W-1:0]     q_addr [0:REQUESTERS-1];

    logic [PARTITIONS-1:0] cmd_valid;
    logic [CONTEXT_W-1:0]  cmd_context [0:PARTITIONS-1];
    logic [REQUEST_W-1:0]  cmd_request [0:PARTITIONS-1];
    logic [ADDR_W-1:0]     cmd_addr [0:PARTITIONS-1];
    logic [REQUESTERS-1:0] cmd_owner [0:PARTITIONS-1];
    logic [PARTITIONS-1:0] active;
    logic [CONTEXT_W-1:0]  active_context [0:PARTITIONS-1];
    logic [REQUEST_W-1:0]  active_request [0:PARTITIONS-1];
    logic [REQUESTERS-1:0] active_owner [0:PARTITIONS-1];
    logic [RW-1:0]         rr [0:PARTITIONS-1];   // round-robin start (reads)
    logic [RW-1:0]         wr_rr [0:PARTITIONS-1];

    logic [REQUESTERS-1:0] requester_busy;

    // A requester is busy from command issue until its response stream ends:
    // while its command sits in a partition's command slot (cmd_owner) or
    // while its response beats are returning (active_owner). A partition
    // holds a single outstanding request end-to-end (command then response),
    // so cmd_valid and active are never set at once; the two owner words
    // exist only to carry the owner across the cmd_valid -> active handoff
    // without a combinational path through the grant.
    always_comb begin
        requester_busy = '0;
        for (int p = 0; p < PARTITIONS; p++) begin
            if (cmd_valid[p])
                requester_busy = requester_busy | cmd_owner[p];
            if (active[p])
                requester_busy = requester_busy | active_owner[p];
        end
        for (int r = 0; r < REQUESTERS; r++)
            rd_ready[r] = !q_valid[r] && !requester_busy[r];
    end

    // Choose at most one queued requester for each partition.  The rotating
    // start index prevents a permanently ready low-numbered requester from
    // starving other contexts.
    logic [REQUESTERS-1:0] grant [0:PARTITIONS-1];
    logic [REQUESTERS-1:0] wr_grant [0:PARTITIONS-1];
    always_comb begin
        logic found;
        integer start, r;
        for (int p = 0; p < PARTITIONS; p++)
            grant[p] = '0;
        for (int p = 0; p < PARTITIONS; p++)
            wr_grant[p] = '0;
        wr_ready = '0;
        mem_wr_valid = '0;
        mem_wr_last = '0;
        for (int p = 0; p < PARTITIONS; p++) begin
            mem_wr_context[p] = '0;
            mem_wr_block_addr[p] = '0;
            mem_wr_beat[p] = '0;
            mem_wr_data[p] = '0;
        end

        for (int p = 0; p < PARTITIONS; p++) begin
            found = 1'b0;
            start = rr[p];
            for (int off = 0; off < REQUESTERS; off++) begin
                r = (start + off) % REQUESTERS;
                if (!found && q_valid[r] && !requester_busy[r] &&
                    (map_partition(q_context[r], q_addr[r]) == p)) begin
                    grant[p][r] = 1'b1;
                    found = 1'b1;
                end
            end

            found = 1'b0;
            start = wr_rr[p];
            for (int off = 0; off < REQUESTERS; off++) begin
                r = (start + off) % REQUESTERS;
                if (!found && wr_valid[r] &&
                    (map_partition(wr_context[r], wr_block_addr[r]) == p)) begin
                    wr_grant[p][r] = 1'b1;
                    found = 1'b1;
                    mem_wr_valid[p] = 1'b1;
                    mem_wr_context[p] = wr_context[r];
                    mem_wr_block_addr[p] = map_local_addr(wr_block_addr[r]);
                    mem_wr_beat[p] = wr_beat[r];
                    mem_wr_last[p] = wr_last[r];
                    mem_wr_data[p] = wr_data[r];
                    wr_ready[r] = mem_wr_ready[p];
                end
            end
        end
    end

    always_comb begin
        mem_rd_valid = cmd_valid;
        for (int p = 0; p < PARTITIONS; p++) begin
            mem_rd_context[p] = cmd_context[p];
            mem_rd_block_addr[p] = cmd_addr[p];
        end

        mem_data_ready = '0;
        rsp_valid = '0;
        rsp_last = '0;
        rsp_error = '0;
        for (int r = 0; r < REQUESTERS; r++) begin
            rsp_context[r] = '0;
            rsp_request[r] = '0;
            rsp_beat[r] = '0;
            rsp_data[r] = '0;
        end

        for (int p = 0; p < PARTITIONS; p++) begin
            if (active[p]) begin
                for (int r = 0; r < REQUESTERS; r++) begin
                    if (active_owner[p][r]) begin
                        mem_data_ready[p] = rsp_ready[r];
                        rsp_valid[r]      = mem_data_valid[p];
                        rsp_context[r]    = active_context[p];
                        rsp_request[r]    = active_request[p];
                        rsp_beat[r]       = mem_data_beat[p];
                        rsp_last[r]       = mem_data_last[p];
                        rsp_data[r]       = mem_data[p];
                        rsp_error[r]      = mem_data_error[p];
                    end
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_valid   <= '0;
            cmd_valid <= '0;
            active    <= '0;
            for (int r = 0; r < REQUESTERS; r++) begin
                q_context[r] <= '0;
                q_request[r] <= '0;
                q_addr[r]    <= '0;
            end
            for (int p = 0; p < PARTITIONS; p++) begin
                cmd_context[p]    <= '0;
                cmd_request[p]    <= '0;
                cmd_addr[p]       <= '0;
                cmd_owner[p]      <= '0;
                active_context[p] <= '0;
                active_request[p] <= '0;
                active_owner[p]   <= '0;
                rr[p]             <= '0;
                wr_rr[p]          <= '0;
            end
        end else begin
            for (int r = 0; r < REQUESTERS; r++) begin
                if (rd_valid[r] && rd_ready[r]) begin
                    q_valid[r]   <= 1'b1;
                    q_context[r] <= rd_context[r];
                    q_request[r] <= rd_request[r];
                    q_addr[r]    <= rd_block_addr[r];
                end
            end

            for (int p = 0; p < PARTITIONS; p++) begin
                logic cmd_fire;
                logic data_fire;
                cmd_fire  = cmd_valid[p] && mem_rd_ready[p];
                data_fire = active[p] && mem_data_valid[p] &&
                            mem_data_ready[p] && mem_data_last[p];

                if (data_fire)
                    active[p] <= 1'b0;

                if (cmd_fire)
                    cmd_valid[p] <= 1'b0;

                if (!cmd_valid[p] && !active[p]) begin
                    for (int r = 0; r < REQUESTERS; r++) begin
                        if (grant[p][r]) begin
                            cmd_valid[p]   <= 1'b1;
                            cmd_context[p] <= q_context[r];
                            cmd_request[p] <= q_request[r];
                            cmd_addr[p]    <= map_local_addr(q_addr[r]);
                            cmd_owner[p]   <= ({{(REQUESTERS-1){1'b0}}, 1'b1} << r);
                            q_valid[r]     <= 1'b0;
                            rr[p]          <= RW'((r == REQUESTERS-1) ? 0 : r + 1);
                        end
                    end
                end

                if (cmd_fire) begin
                    active[p]         <= 1'b1;
                    active_owner[p]   <= cmd_owner[p];
                    active_context[p] <= cmd_context[p];
                    active_request[p] <= cmd_request[p];
                end

                for (int r = 0; r < REQUESTERS; r++) begin
                    if (wr_grant[p][r] && mem_wr_ready[p])
                        wr_rr[p] <= RW'((r == REQUESTERS-1) ? 0 : r + 1);
                end
            end
        end
    end
endmodule
