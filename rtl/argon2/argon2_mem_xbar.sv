// SPDX-License-Identifier: MIT
// Partitioned-memory read crossbar for multi-lane argon2 fill.
//
// The floorplan thesis (README / docs/ARCHITECTURE.md) gives every lane its
// own memory channel: lane i's 1 KiB blocks live in channel i's memory at
// LOCAL block index `addr - i*lane_length`. Writes never leave the home
// channel (a lane only ever writes its own region), but the *reference*
// block of argon2 p>1 may live in any lane's region, so lane i's reads must
// be routed to the owning channel and the response returned to lane i.
//
// This module is that router. It sits between `argon2_fill_job` (N fill
// controllers with independent block ports) and N single-outstanding memory
// ports (`argon2_axi_mm` + DDR/HBM channel, or a behavioral RAM):
//
//                 read req (global blk idx + owner hint)
//   lane i  ───────────────────────────────────────────▶ channel owner
//      ▲                                                     │
//      └──────────── 16 x 512-bit beats, tag-routed ◀────────┘
//   lane i write ─────────────── 1:1 (addr translated) ──▶ channel i
//
// The owner hint comes from the fill controller (`mem_rd_owner`), which
// knows the reference lane at issue time. That keeps the router free of the
// runtime division `addr / lane_length` (the 250 MHz closure rule — see
// docs/TIMING_250MHZ.md) and free of any assumption that lane_length is a
// power of two: the local index is a single subtract from a per-channel
// constant-times-lane_length base.
//
// Lane-port contract (this is what argon2_fill_ctrl was designed against,
// so the crossbar MUST reproduce it, not the other way round):
//   1. A read request is ACCEPTED THE CYCLE IT IS OFFERED — the memories
//      the controller grew up with (sim RAMs, argon2_axi_mm) take a command
//      immediately and stream the burst later. If the crossbar held
//      `rd_valid` off for many arbitration cycles, the controller could
//      advance into a state that reuses or mutates the still-pending
//      request (e.g. the early dest hook, DREF_SETTLE) — observed as two
//      collectors eating one burst. So: every lane gets a 1-deep request
//      queue that is always ready when empty, and arbitration happens
//      BEHIND it.
//   2. A lane has ONE read stream: the controller may deliberately abandon
//      an in-flight response (stale dependent reads are discarded at
//      DREF_SETTLE / WRITE re-arm) and immediately offer the next request.
//      With a single RAM that was naturally safe — the port cannot take a
//      new command until the old burst finishes. The crossbar preserves it:
//      a queued request is not issued to any channel while a burst tagged
//      to that lane is still commanding / returning, so two responses can
//      never interleave on the lane's data port.
//   3. 16 data_v/data/last beats per request, at least one cycle after
//      command acceptance (true for argon2_axi_mm and every bench RAM).
//
// No producer-side hazard logic is needed. Cross-lane references only ever
// target the reference lane's COMPLETED slices (argon2_ref_area: pass 0,
// slice > 0, !same_lane -> slice*segment_length; pass > 0, !same_lane ->
// lane_length - segment_length, i.e. everything but the current slice),
// and `argon2_fill_ctrl` drains its write FIFO before raising sync_req at
// the slice barrier — so a block in another lane's region is always
// committed before any lane can reference it. Own-lane recency hazards
// (write FIFO / last-written cache) stay inside the fill controller, where
// they are already handled.
//
// Arbitration: round-robin per channel, so a lane cannot starve behind the
// other lanes' remote references. Deadlock-free: grants only ever move
// queues forward, and every response finishes (there is no back-pressure
// on the return path).

`timescale 1ns / 1ps

module argon2_mem_xbar #(
    parameter int ADDR_W = 32,
    parameter int LANES  = 4        // lanes == channels; 2..16
) (
    input  logic                     clk,
    input  logic                     rst_n,
    input  logic [31:0]              lane_length,  // blocks per lane (runtime)

    // ---- lane (requester) side: argon2_fill_ctrl block ports + owner ----
    output logic [LANES-1:0]             l_rd_ready,
    input  logic [LANES-1:0]             l_rd_valid,
    input  logic [LANES-1:0][ADDR_W-1:0] l_rd_addr,   // global block index
    input  logic [LANES-1:0][3:0]        l_rd_owner,  // owning channel
    output logic [LANES-1:0]             l_rd_data_v,
    output logic [LANES-1:0][511:0]      l_rd_data,
    output logic [LANES-1:0]             l_rd_last,

    input  logic [LANES-1:0]             l_wr_valid,
    output logic [LANES-1:0]             l_wr_ready,
    input  logic [LANES-1:0][ADDR_W-1:0] l_wr_addr,
    input  logic [LANES-1:0][511:0]      l_wr_data,
    input  logic [LANES-1:0]             l_wr_last,

    // ---- channel (owner memory) side: same protocol, LOCAL block index --
    output logic [LANES-1:0]             c_rd_valid,
    input  logic [LANES-1:0]             c_rd_ready,
    output logic [LANES-1:0][ADDR_W-1:0] c_rd_addr,
    input  logic [LANES-1:0]             c_rd_data_v,
    input  logic [LANES-1:0][511:0]      c_rd_data,
    input  logic [LANES-1:0]             c_rd_last,

    output logic [LANES-1:0]             c_wr_valid,
    input  logic [LANES-1:0]             c_wr_ready,
    output logic [LANES-1:0][ADDR_W-1:0] c_wr_addr,
    output logic [LANES-1:0][511:0]      c_wr_data,
    output logic [LANES-1:0]             c_wr_last
);
    localparam int OW = (LANES > 1) ? $clog2(LANES) : 1;

    // ---- write path: lane i -> channel i, global -> local index ---------
    for (genvar i = 0; i < LANES; i++) begin : g_wr
        assign c_wr_valid[i] = l_wr_valid[i];
        assign c_wr_addr[i]  = ADDR_W'(64'(l_wr_addr[i])
                                      - 64'(i) * 64'(lane_length));
        assign c_wr_data[i]  = l_wr_data[i];
        assign c_wr_last[i]  = l_wr_last[i];
        assign l_wr_ready[i] = c_wr_ready[i];
    end

    // ---- read path -------------------------------------------------------
    // Per-lane 1-deep request queue: accepts the controller's request the
    // cycle it is offered (contract #1), decoupling the lane port from
    // channel arbitration.
    logic [LANES-1:0]           q_valid;
    logic [LANES-1:0][ADDR_W-1:0] q_addr;
    logic [LANES-1:0][OW-1:0]   q_owner;

    // Per-channel FSM: IDLE (arbitrate a queued request) -> CMD -> RESP.
    localparam logic [1:0] X_IDLE = 2'd0, X_CMD = 2'd1, X_RESP = 2'd2;
    logic [1:0]        st    [0:LANES-1];
    logic [OW-1:0]     tag   [0:LANES-1];   // requester of the burst in flight
    logic [ADDR_W-1:0] caddr [0:LANES-1];   // local block index
    logic [OW-1:0]     rr    [0:LANES-1];   // round-robin pointer

    // lbusy[i]: a burst tagged to lane i is commanding / returning on some
    // channel. A queued request of lane i must not be issued until lbusy[i]
    // clears (contract #2).
    logic [LANES-1:0] lbusy;
    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            lbusy[i] = 1'b0;
            for (int c = 0; c < LANES; c++)
                if (st[c] != X_IDLE && (32'(tag[c]) == 32'(i)))
                    lbusy[i] = 1'b1;
        end
    end

    // Queue fill: ready only when the lane's read stream is fully drained
    // (no queued request, no burst in flight) — the same "free" a direct
    // single-ported RAM exposes. One entry suffices: the fill controller
    // offers at most one request at a time; after a discard it may offer
    // the next while the abandoned burst still returns, and that offer
    // simply waits here until the tail ends.
    for (genvar i = 0; i < LANES; i++) begin : g_q
        assign l_rd_ready[i] = !q_valid[i] && !lbusy[i];
    end

    // Arbitration: cand[c][i] = lane i has a queued request owned by c and
    // is free to be issued. Round-robin winner per channel.
    logic [LANES-1:0][LANES-1:0] cand, grant;

    function automatic logic [LANES-1:0] xrot(
        input logic [LANES-1:0] v, input int n
    );
        int s;
        s = n % LANES;
        xrot = (v << s) | (v >> (LANES - s));
    endfunction

    always_comb begin
        logic [LANES-1:0] rot_req, rot_mask;
        for (int c = 0; c < LANES; c++) begin
            for (int i = 0; i < LANES; i++)
                cand[c][i] = q_valid[i] && !lbusy[i]
                             && (32'(q_owner[i]) == 32'(c));
            rot_mask = xrot(cand[c], int'(rr[c])) & (~xrot(cand[c], int'(rr[c])) + 1'b1);
            grant[c] = xrot(rot_mask, LANES - int'(rr[c]));
        end
    end

    // Channel-side command + response routing.
    always_comb begin
        for (int c = 0; c < LANES; c++) begin
            c_rd_valid[c] = (st[c] == X_CMD);
            c_rd_addr[c]  = caddr[c];
        end
        for (int i = 0; i < LANES; i++) begin
            l_rd_data_v[i] = 1'b0;
            l_rd_last[i]   = 1'b0;
            l_rd_data[i]   = '0;
            for (int c = 0; c < LANES; c++) begin
                if (st[c] == X_RESP && (32'(tag[c]) == 32'(i))) begin
                    l_rd_data_v[i] = c_rd_data_v[c];
                    l_rd_last[i]   = c_rd_last[c];
                    l_rd_data[i]   = c_rd_data[c];
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int i = 0; i < LANES; i++) begin
                q_valid[i]  <= 1'b0;
                q_addr[i]   <= '0;
                q_owner[i]  <= '0;
            end
            for (int c = 0; c < LANES; c++) begin
                st[c]    <= X_IDLE;
                tag[c]   <= '0;
                caddr[c] <= '0;
                rr[c]    <= '0;
            end
        end else begin
            // Queue fill (lane-side handshake).
            for (int i = 0; i < LANES; i++) begin
                if (l_rd_valid[i] && l_rd_ready[i]) begin
                    q_valid[i] <= 1'b1;
                    q_addr[i]  <= l_rd_addr[i];
                    q_owner[i] <= l_rd_owner[i][OW-1:0];
                end
            end
            for (int c = 0; c < LANES; c++) begin
                case (st[c])
                    X_IDLE: begin
                        if (|cand[c]) begin
                            // grant[c] is one-hot: exactly one match fires.
                            for (int k = LANES-1; k >= 0; k--) begin
                                if (grant[c][k]) begin
                                    tag[c] <= OW'(k);
                                    caddr[c] <= ADDR_W'(64'(q_addr[k])
                                                       - 64'(c) * 64'(lane_length));
                                    q_valid[k] <= 1'b0;   // pop the queue entry
                                end
                            end
                            st[c] <= X_CMD;
                        end
                    end
                    X_CMD: begin
                        // Present the command until the channel accepts it.
                        if (c_rd_ready[c]) st[c] <= X_RESP;
                    end
                    X_RESP: begin
                        // Route the 16 beats to tag[c]; done on the last.
                        if (c_rd_data_v[c] && c_rd_last[c]) begin
                            rr[c] <= OW'((32'(tag[c]) + 32'd1) % LANES);
                            st[c] <= X_IDLE;
                        end
                    end
                    default: st[c] <= X_IDLE;
                endcase
            end
        end
    end

endmodule
