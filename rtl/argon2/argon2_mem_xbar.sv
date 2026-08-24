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
// controllers with independent block ports) and N memory ports (`argon2_axi_mm`
// + DDR/HBM channel, or a behavioral RAM):
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
// Multi-outstanding read support:
//   Each channel tracks in-flight read bursts in a tag FIFO (up to
//   MAX_INFLIGHT entries per channel). A channel can accept and issue
//   subsequent read commands to memory while previous reads are still
//   awaiting DRAM latency or returning data beats, eliminating inter-burst
//   pipeline bubbles. Responses from each channel are routed to the requesting
//   lane according to the head of the channel's tag FIFO.
//
// Lane-port contract:
//   1. A read request is ACCEPTED THE CYCLE IT IS OFFERED whenever the
//      lane's request slot is empty (`!q_valid[i]`), decoupling the lane
//      from channel arbitration.
//   2. A lane has ONE read stream: a queued request of lane i is not
//      issued to any channel while a burst tagged to lane i is still in
//      flight on any channel (`lbusy[i]`), ensuring responses from different
//      channels never collide or interleave on lane i's data port.
//   3. 16 data_v/data/last beats per request, at least one cycle after
//      command acceptance.
//
// Arbitration: round-robin per channel among ready lane requests.

`timescale 1ns / 1ps

module argon2_mem_xbar #(
    parameter int ADDR_W       = 32,
    parameter int LANES        = 4,        // lanes == channels; 2..16
    parameter int MAX_INFLIGHT = 4         // in-flight bursts per channel
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
    localparam int PW = (MAX_INFLIGHT > 1) ? $clog2(MAX_INFLIGHT) : 1;

    // ---- write path: lane i -> channel i, global -> local index ---------
    for (genvar i = 0; i < LANES; i++) begin : g_wr
        assign c_wr_valid[i] = l_wr_valid[i];
        assign c_wr_addr[i]  = ADDR_W'(64'(l_wr_addr[i])
                                      - 64'(i) * 64'(lane_length));
        assign c_wr_data[i]  = l_wr_data[i];
        assign c_wr_last[i]  = l_wr_last[i];
        assign l_wr_ready[i] = c_wr_ready[i];
    end

    // ---- read path: per-lane 1-deep request queue -----------------------
    logic [LANES-1:0]  q_valid;
    logic [ADDR_W-1:0] q_addr  [0:LANES-1];
    logic [OW-1:0]     q_owner [0:LANES-1];

    for (genvar i = 0; i < LANES; i++) begin : g_q
        assign l_rd_ready[i] = !q_valid[i] && !lbusy[i];
    end

    // ---- per-channel in-flight tag FIFO & command register --------------
    logic [OW-1:0]             tag_fifo [0:LANES-1][0:MAX_INFLIGHT-1];
    logic [MAX_INFLIGHT-1:0]   tag_v    [0:LANES-1];
    logic [PW-1:0]             tag_wr_ptr [0:LANES-1];
    logic [PW-1:0]             tag_rd_ptr [0:LANES-1];
    logic [3:0]                tag_cnt    [0:LANES-1];

    logic                      cmd_valid [0:LANES-1];
    logic [ADDR_W-1:0]         cmd_addr  [0:LANES-1];
    logic [OW-1:0]             cmd_tag   [0:LANES-1];
    logic [OW-1:0]             rr        [0:LANES-1];   // round-robin pointer

    // lbusy[i]: a burst tagged to lane i is commanding or returning on some
    // channel. A queued request of lane i must not be issued until lbusy[i]
    // clears (contract #2).
    logic [LANES-1:0] lbusy;
    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            lbusy[i] = 1'b0;
            for (int c = 0; c < LANES; c++) begin
                for (int e = 0; e < MAX_INFLIGHT; e++) begin
                    if (tag_v[c][e] && (tag_fifo[c][e] == OW'(i)))
                        lbusy[i] = 1'b1;
                end
                if (cmd_valid[c] && (cmd_tag[c] == OW'(i)))
                    lbusy[i] = 1'b1;
            end
        end
    end

    // Arbitration: cand[c*LANES+i] = lane i has a queued request owned by
    // channel c, channel c can take another command, and lane i is not busy.
    logic [LANES*LANES-1:0] cand, grant;

    function automatic logic [LANES-1:0] xrot(
        input logic [LANES-1:0] v, input int n
    );
        int s;
        s = n % LANES;
        xrot = (v << s) | (v >> (LANES - s));
    endfunction

    always_comb begin
        logic [LANES-1:0] cv, rot_mask;
        for (int c = 0; c < LANES; c++) begin
            for (int i = 0; i < LANES; i++)
                cand[c*LANES + i] = q_valid[i] && !lbusy[i]
                                    && (32'(q_owner[i]) == 32'(c));
            cv = cand[c*LANES +: LANES];
            rot_mask = xrot(cv, int'(rr[c])) & (~xrot(cv, int'(rr[c])) + 1'b1);
            grant[c*LANES +: LANES] = xrot(rot_mask, LANES - int'(rr[c]));
        end
    end

    // Channel command outputs
    for (genvar c = 0; c < LANES; c++) begin : g_cmd_out
        assign c_rd_valid[c] = cmd_valid[c];
        assign c_rd_addr[c]  = cmd_addr[c];
    end

    // Response routing: channel c streams data to tag_fifo[c][tag_rd_ptr[c]]
    always_comb begin
        for (int i = 0; i < LANES; i++) begin
            l_rd_data_v[i] = 1'b0;
            l_rd_last[i]   = 1'b0;
            l_rd_data[i]   = '0;
            for (int c = 0; c < LANES; c++) begin
                if (tag_v[c][tag_rd_ptr[c]] && (tag_fifo[c][tag_rd_ptr[c]] == OW'(i))) begin
                    l_rd_data_v[i] = c_rd_data_v[c];
                    l_rd_last[i]   = c_rd_last[c];
                    l_rd_data[i]   = c_rd_data[c];
                end
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_valid <= '0;
            for (int i = 0; i < LANES; i++) begin
                q_addr[i]  <= '0;
                q_owner[i] <= '0;
            end
            for (int c = 0; c < LANES; c++) begin
                tag_v[c]      <= '0;
                tag_wr_ptr[c] <= '0;
                tag_rd_ptr[c] <= '0;
                tag_cnt[c]    <= '0;
                cmd_valid[c]  <= 1'b0;
                cmd_addr[c]   <= '0;
                cmd_tag[c]    <= '0;
                rr[c]         <= '0;
                for (int e = 0; e < MAX_INFLIGHT; e++)
                    tag_fifo[c][e] <= '0;
            end
        end else begin
            // Queue fill (lane-side handshake)
            for (int i = 0; i < LANES; i++) begin
                if (l_rd_valid[i] && l_rd_ready[i]) begin
                    q_valid[i] <= 1'b1;
                    q_addr[i]  <= l_rd_addr[i];
                    q_owner[i] <= l_rd_owner[i][OW-1:0];
                end
            end

            // Channel arbitration, command issue, and response tracking
            for (int c = 0; c < LANES; c++) begin
                logic cmd_accepted, resp_done;
                cmd_accepted = cmd_valid[c] && c_rd_ready[c];
                resp_done    = c_rd_data_v[c] && c_rd_last[c] && tag_v[c][tag_rd_ptr[c]];

                // Advance response pointer when current burst finishes
                if (resp_done) begin
                    tag_v[c][tag_rd_ptr[c]] <= 1'b0;
                    tag_rd_ptr[c] <= (tag_rd_ptr[c] == PW'(MAX_INFLIGHT - 1)) ? '0 : (tag_rd_ptr[c] + 1'b1);
                end

                // Push tag into in-flight FIFO when memory accepts command
                if (cmd_accepted) begin
                    tag_fifo[c][tag_wr_ptr[c]] <= cmd_tag[c];
                    tag_v[c][tag_wr_ptr[c]]    <= 1'b1;
                    tag_wr_ptr[c] <= (tag_wr_ptr[c] == PW'(MAX_INFLIGHT - 1)) ? '0 : (tag_wr_ptr[c] + 1'b1);
                    cmd_valid[c]  <= 1'b0;
                end

                // Update in-flight tag count
                tag_cnt[c] <= tag_cnt[c] + (cmd_accepted ? 4'd1 : 4'd0) - (resp_done ? 4'd1 : 4'd0);

                // Arbitrate new command when command slot is free and tag FIFO has room
                if (!cmd_valid[c] || cmd_accepted) begin
                    if (|cand[c*LANES +: LANES] && (tag_cnt[c] + (cmd_accepted ? 4'd0 : 4'd1) < 4'(MAX_INFLIGHT))) begin
                        for (int k = LANES-1; k >= 0; k--) begin
                            if (grant[c*LANES + k]) begin
                                cmd_valid[c] <= 1'b1;
                                cmd_tag[c]   <= OW'(k);
                                cmd_addr[c]  <= ADDR_W'(64'(q_addr[k]) - 64'(c) * 64'(lane_length));
                                q_valid[k]   <= 1'b0;   // pop lane queue
                                rr[c]        <= OW'((32'(k) + 32'd1) % LANES);
                            end
                        end
                    end
                end
            end
        end
    end

endmodule
