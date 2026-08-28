// SPDX-License-Identifier: MIT
// Multi-context lane concentrator: N independent p=1 fill controllers
// onto ONE memory channel port.
//
// This is lever 2 of docs/PERFORMANCE.md ("ranked levers, measured"): a
// single argon2 lane already sits at the single-outstanding-read capacity
// of its DDR4 channel (tb_ddr4_ceiling: 1.004 cand/s at 1 read in flight
// vs the lane's 1.044), but the channel itself serves ~1.41 cand/s with 2
// reads in flight. N contexts sharing a channel each present their own
// single outstanding read, so the concentrator converts per-lane latency
// tolerance into channel throughput — measured +~35% cand/s per channel
// at 200 MHz (see tb_conc_perf / docs/PERFORMANCE.md).
//
// Function:
//   * lane i's context-local block address is offset by i*ctx_len into the
//     shared channel memory (contexts occupy disjoint contiguous regions;
//     there is no cross-context hazard, every RAW guard stays inside the
//     unchanged argon2_fill_ctrl per lane);
//   * reads are issued round-robin onto one channel command slot with an
//     in-flight lane-tag FIFO — the channel returns bursts in issue order
//     (argon2_axi_mm drives one AXI ID), so the FIFO head routes every
//     returning beat back to the owning lane;
//   * writes arbitrate with a BURST-LOCKED round-robin: the grant is held
//     from a lane's first beat of a block until its wr_last beat is
//     accepted, so beats of two blocks never interleave on the channel
//     (AXI bursts must be contiguous — the same rule the block-fabric
//     write path needs; see the "blockers" note in docs/PERFORMANCE.md).
//
// Lane-port contract (identical to argon2_mem_xbar, which the fill
// controller was designed against):
//   1. A read request is ACCEPTED THE CYCLE IT IS OFFERED whenever the
//      lane's slot is empty and the lane has no burst in flight
//      (!q_valid[i] && !lbusy[i]).
//   2. A lane never sees two responses interleaved: a queued request of
//      lane i is not issued while a burst tagged to lane i is still in
//      flight.
//   3. 16 data beats per request, at least one cycle after acceptance.
//
// p=1 jobs drive mem_rd_owner = 0 always (see argon2_fill_ctrl), so no
// owner routing is needed here: the requester port index IS the context.

`timescale 1ns / 1ps

module argon2_lane_conc #(
    parameter int ADDR_W       = 32,
    parameter int LANES        = 2,       // contexts per channel, 2..16
    parameter int MAX_INFLIGHT = 4        // in-flight read bursts, 1..16
) (
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic [31:0]              ctx_len,   // blocks per context (runtime)

    // ---- lane (requester) side: argon2_fill_ctrl block ports -----------
    output logic [LANES-1:0]             l_rd_ready,
    input  logic [LANES-1:0]             l_rd_valid,
    input  logic [LANES-1:0][ADDR_W-1:0] l_rd_addr,   // context-local index
    output logic [LANES-1:0]             l_rd_data_v,
    output logic [LANES-1:0][511:0]      l_rd_data,
    output logic [LANES-1:0]             l_rd_last,

    input  logic [LANES-1:0]             l_wr_valid,
    output logic [LANES-1:0]             l_wr_ready,
    input  logic [LANES-1:0][ADDR_W-1:0] l_wr_addr,
    input  logic [LANES-1:0][511:0]      l_wr_data,
    input  logic [LANES-1:0]             l_wr_last,

    // ---- channel side: one block port (argon2_axi_mm mem side) ---------
    output logic                        c_rd_valid,
    input  logic                        c_rd_ready,
    output logic [ADDR_W-1:0]           c_rd_addr,
    input  logic                        c_rd_data_v,
    input  logic [511:0]                c_rd_data,
    input  logic                        c_rd_last,

    output logic                        c_wr_valid,
    input  logic                        c_wr_ready,
    output logic [ADDR_W-1:0]           c_wr_addr,
    output logic [511:0]                c_wr_data,
    output logic                        c_wr_last
);
    localparam int LW = (LANES <= 2) ? 1 : $clog2(LANES);

    initial begin
        if (LANES < 2 || LANES > 16)
            $error("argon2_lane_conc: LANES must be 2..16");
        if (MAX_INFLIGHT < 1 || MAX_INFLIGHT > 16)
            $error("argon2_lane_conc: MAX_INFLIGHT must be 1..16");
    end

    // Per-lane context base in the shared channel memory: i*ctx_len with i
    // an elaboration constant (shifts/adds only — no runtime multiplier,
    // per the 250 MHz closure rule). Used only at command/beat issue, off
    // the response path.
    logic [63:0] lane_base [0:LANES-1];
    for (genvar g = 0; g < LANES; g++) begin : g_base
        assign lane_base[g] = 64'(64'(g) * 64'(ctx_len));
    end

    // ---- read path: per-lane 1-deep request queue -----------------------
    logic [LANES-1:0]  q_valid;
    logic [ADDR_W-1:0] q_addr [0:LANES-1];

    logic              cmd_valid;
    logic [ADDR_W-1:0] cmd_addr;
    logic [LW-1:0]     cmd_tag;
    logic [LW-1:0]     rr;                 // round-robin start

    // In-flight tag FIFO: issue order == response order on one AXI ID.
    logic [LW-1:0] tag_fifo [0:MAX_INFLIGHT-1];
    logic          tag_v    [0:MAX_INFLIGHT-1];
    logic [3:0]    tag_wr_ptr, tag_rd_ptr, tag_cnt;

    // lbusy[i]: a read burst tagged to lane i is commanding or returning.
    // Lane i's queued request waits (contract #2) and lane i is not
    // offered another acceptance slot until it drains.
    logic [LANES-1:0] lbusy;
    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            lbusy[i] = 1'b0;
            for (int e = 0; e < MAX_INFLIGHT; e++)
                if (tag_v[e] && (tag_fifo[e] == LW'(i)))
                    lbusy[i] = 1'b1;
            if (cmd_valid && (cmd_tag == LW'(i)))
                lbusy[i] = 1'b1;
        end
    end

    for (genvar i = 0; i < LANES; i++) begin : g_rdy
        assign l_rd_ready[i] = !q_valid[i] && !lbusy[i];
    end

    // Rotating grant among queued, not-busy lanes (one channel).
    logic [LANES-1:0] grant;
    always_comb begin
        logic found;
        int s;
        grant = '0;
        found = 1'b0;
        s     = 0;
        for (int off = 0; off < LANES; off++) begin
            s = (int'(rr) + off) % LANES;
            if (!found && q_valid[s] && !lbusy[s]) begin
                grant[s] = 1'b1;
                found    = 1'b1;
            end
        end
    end

    assign c_rd_valid = cmd_valid;
    assign c_rd_addr  = cmd_addr;

    // Response routing: the FIFO head owns every beat on the channel.
    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            l_rd_data_v[i] = 1'b0;
            l_rd_data[i]   = '0;
            l_rd_last[i]   = 1'b0;
            if (tag_v[tag_rd_ptr] && (tag_fifo[tag_rd_ptr] == LW'(i))) begin
                l_rd_data_v[i] = c_rd_data_v;
                l_rd_data[i]   = c_rd_data;
                l_rd_last[i]   = c_rd_last;
`ifdef CONC_DEBUG
                if (c_rd_data_v)
                    $display("[conc %0t] BEAT->lane%0d last=%b data=%016h", $time, i, c_rd_last, c_rd_data[63:0]);
`endif
            end
        end
    end

    // ---- write path: burst-locked round-robin ---------------------------
    // The lock holds the grant from a lane's first accepted beat of a
    // block until its 16th (wr_last) beat is accepted, so a mid-burst
    // wr_valid gap on the winning lane cannot hand the port to another
    // lane's block mid-burst (AXI bursts must be contiguous).
    logic          wr_lock_v;
    logic [LW-1:0] wr_lock_id;
    logic [LW-1:0] wrr;

    logic [LANES-1:0] wr_sel;
    always_comb begin
        logic found;
        int s;
        wr_sel = '0;
        found  = 1'b0;
        s      = 0;
        if (wr_lock_v) begin
            wr_sel[wr_lock_id] = 1'b1;
        end else begin
            for (int off = 0; off < LANES; off++) begin
                s = (int'(wrr) + off) % LANES;
                if (!found && l_wr_valid[s]) begin
                    wr_sel[s] = 1'b1;
                    found     = 1'b1;
                end
            end
        end
    end

    logic wr_fire;
    assign wr_fire = c_wr_valid && c_wr_ready;

    always_comb begin
        c_wr_valid = 1'b0;
        c_wr_addr  = '0;
        c_wr_data  = '0;
        c_wr_last  = 1'b0;
        for (int i = 0; i < LANES; i++) begin
            l_wr_ready[i] = 1'b0;
            if (wr_sel[i]) begin
                c_wr_valid   = l_wr_valid[i];
                c_wr_addr    = ADDR_W'(lane_base[i] + 64'(l_wr_addr[i]));
                c_wr_data    = l_wr_data[i];
                c_wr_last    = l_wr_last[i];
                l_wr_ready[i] = c_wr_ready;
            end
        end
    end

    // ---- sequential -----------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_valid    <= '0;
            cmd_valid  <= 1'b0;
            cmd_addr   <= '0;
            cmd_tag    <= '0;
            rr         <= '0;
            tag_wr_ptr <= 4'd0;
            tag_rd_ptr <= 4'd0;
            tag_cnt    <= 4'd0;
            wr_lock_v  <= 1'b0;
            wr_lock_id <= '0;
            wrr        <= '0;
            for (int i = 0; i < LANES; i++)
                q_addr[i] <= '0;
            for (int e = 0; e < MAX_INFLIGHT; e++) begin
                tag_v[e]    <= 1'b0;
                tag_fifo[e] <= '0;
            end
        end else begin
            // Queue fill (lane-side handshake)
            for (int i = 0; i < LANES; i++) begin
                if (l_rd_valid[i] && l_rd_ready[i]) begin
                    q_valid[i] <= 1'b1;
                    q_addr[i]  <= l_rd_addr[i];
                end
            end

            // Command slot + tag FIFO (single channel)
            begin
                logic cmd_accepted, resp_done;
                cmd_accepted = cmd_valid && c_rd_ready;
                resp_done    = c_rd_data_v && c_rd_last && tag_v[tag_rd_ptr];

                if (resp_done) begin
                    tag_v[tag_rd_ptr] <= 1'b0;
                    tag_rd_ptr <= (tag_rd_ptr == 4'(MAX_INFLIGHT - 1))
                                  ? 4'd0 : (tag_rd_ptr + 4'd1);
                end

                if (cmd_accepted) begin
                    tag_fifo[tag_wr_ptr] <= cmd_tag;
                    tag_v[tag_wr_ptr]    <= 1'b1;
                    tag_wr_ptr <= (tag_wr_ptr == 4'(MAX_INFLIGHT - 1))
                                  ? 4'd0 : (tag_wr_ptr + 4'd1);
                    cmd_valid <= 1'b0;
                end

                tag_cnt <= tag_cnt + (cmd_accepted ? 4'd1 : 4'd0)
                                   - (resp_done    ? 4'd1 : 4'd0);

                if (!cmd_valid || cmd_accepted) begin
                    // Admit another command only if the FIFO has room for
                    // its FUTURE push: count this cycle's push (cmd_accepted)
                    // and pop (resp_done), not just the registered tag_cnt —
                    // otherwise tag_wr_ptr can wrap onto a live entry and two
                    // lanes' responses swap (silent 16-beat misroute).
                    if ((|grant) && (tag_cnt + (cmd_accepted ? 4'd1 : 4'd0)
                                     - (resp_done ? 4'd1 : 4'd0)
                                     < 4'(MAX_INFLIGHT))) begin
                        for (int k = LANES - 1; k >= 0; k--) begin
                            if (grant[k]) begin
                                cmd_valid <= 1'b1;
`ifdef CONC_DEBUG
                                $display("[conc %0t] CMD tag=%0d laddr=%0d -> gaddr=%0d", $time, k, q_addr[k], ADDR_W'(lane_base[k] + 64'(q_addr[k])));
`endif
                                cmd_tag   <= LW'(k);
                                cmd_addr  <= ADDR_W'(lane_base[k]
                                                    + 64'(q_addr[k]));
                                q_valid[k] <= 1'b0;
                                rr         <= LW'((k == LANES - 1) ? 0 : k + 1);
                            end
                        end
                    end
                end
            end

            // Write lock control
            if (wr_fire) begin
                for (int i = 0; i < LANES; i++) begin
                    if (wr_sel[i]) begin
                        wr_lock_id <= LW'(i);
                        if (c_wr_last) begin
                            // Block complete: release and rotate past i.
                            wr_lock_v <= 1'b0;
                            wrr       <= LW'((i == LANES - 1) ? 0 : i + 1);
                        end else begin
                            wr_lock_v <= 1'b1;
                        end
                    end
                end
            end
        end
    end
endmodule
