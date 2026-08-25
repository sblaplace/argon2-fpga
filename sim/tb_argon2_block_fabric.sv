// SPDX-License-Identifier: MIT
// Self-checking baseline test for argon2_block_fabric.
//
// The partition model adds a small, different latency per partition and holds
// response beats until the fabric accepts them.  This exercises tagging,
// partition mapping, arbitration, backpressure, and ordered 16-beat bursts.

`timescale 1ns / 1ps

module tb_argon2_block_fabric #(
    parameter int N_P = 1   // unused; keeps the suite's -PN_P override uniform
);
    localparam int RQ = 8;
    localparam int PP = 8;
    localparam int DW = 512;

    logic clk, rst_n;
    logic [RQ-1:0] rd_ready, rd_valid;
    logic [RQ-1:0][15:0] rd_context, rd_request;
    logic [RQ-1:0][31:0] rd_block_addr;
    logic [RQ-1:0] rsp_valid, rsp_ready, rsp_last, rsp_error;
    logic [RQ-1:0][15:0] rsp_context, rsp_request;
    logic [RQ-1:0][3:0] rsp_beat;
    logic [RQ-1:0][DW-1:0] rsp_data;
    logic [RQ-1:0] wr_ready, wr_valid, wr_last;
    logic [RQ-1:0][15:0] wr_context;
    logic [RQ-1:0][31:0] wr_block_addr;
    logic [RQ-1:0][3:0] wr_beat;
    logic [RQ-1:0][DW-1:0] wr_data;

    logic [PP-1:0] mem_rd_valid, mem_rd_ready;
    logic [PP-1:0][15:0] mem_rd_context;
    logic [PP-1:0][31:0] mem_rd_block_addr;
    logic [PP-1:0] mem_data_valid, mem_data_ready, mem_data_last, mem_data_error;
    logic [PP-1:0][3:0] mem_data_beat;
    logic [PP-1:0][DW-1:0] mem_data;
    logic [PP-1:0] mem_wr_valid, mem_wr_ready, mem_wr_last;
    logic [PP-1:0][15:0] mem_wr_context;
    logic [PP-1:0][31:0] mem_wr_block_addr;
    logic [PP-1:0][3:0] mem_wr_beat;
    logic [PP-1:0][DW-1:0] mem_wr_data;

    logic [PP-1:0] pending;
    logic [PP-1:0][2:0] delay;
    logic [PP-1:0][3:0] beat;
    logic [PP-1:0][15:0] saved_context;
    logic [PP-1:0][31:0] saved_addr;
    integer got;
    integer rsp_cnt;

    always #5 clk = ~clk;

    argon2_block_fabric #(
        .ADDR_W(32), .CONTEXT_W(16), .REQUEST_W(16), .DATA_W(DW),
        .REQUESTERS(RQ), .PARTITIONS(PP)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .rd_ready(rd_ready), .rd_valid(rd_valid),
        .rd_context(rd_context), .rd_request(rd_request),
        .rd_block_addr(rd_block_addr),
        .wr_ready(wr_ready), .wr_valid(wr_valid),
        .wr_context(wr_context), .wr_block_addr(wr_block_addr),
        .wr_beat(wr_beat), .wr_last(wr_last), .wr_data(wr_data),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_context(rsp_context), .rsp_request(rsp_request),
        .rsp_beat(rsp_beat), .rsp_last(rsp_last), .rsp_data(rsp_data),
        .rsp_error(rsp_error),
        .mem_rd_valid(mem_rd_valid), .mem_rd_ready(mem_rd_ready),
        .mem_rd_context(mem_rd_context), .mem_rd_block_addr(mem_rd_block_addr),
        .mem_data_valid(mem_data_valid), .mem_data_ready(mem_data_ready),
        .mem_data_beat(mem_data_beat), .mem_data_last(mem_data_last),
        .mem_data(mem_data), .mem_data_error(mem_data_error),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready),
        .mem_wr_context(mem_wr_context), .mem_wr_block_addr(mem_wr_block_addr),
        .mem_wr_beat(mem_wr_beat), .mem_wr_last(mem_wr_last), .mem_wr_data(mem_wr_data)
    );

    function automatic [511:0] expected_data(
        input logic [15:0] ctx,
        input logic [31:0] local_addr,
        input integer p,
        input integer b
    );
        begin
            expected_data = '0;
            expected_data[15:0] = ctx;
            expected_data[31:16] = local_addr[15:0];
            expected_data[35:32] = b[3:0];
            expected_data[43:40] = p[3:0];
        end
    endfunction

    always_comb begin
        mem_rd_ready = '1;
        mem_data_valid = '0;
        mem_data_beat = beat;
        mem_data_last = '0;
        mem_data_error = '0;
        mem_data = '0;
        for (int p = 0; p < PP; p++) begin
            mem_data_valid[p] = pending[p] && (delay[p] == '0);
            mem_data_last[p]  = pending[p] && (beat[p] == 4'd15);
            mem_data[p] = expected_data(saved_context[p], saved_addr[p], p, beat[p]);
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pending <= '0;
            delay <= '0;
            beat <= '0;
            saved_context <= '0;
            saved_addr <= '0;
        end else begin
            for (int p = 0; p < PP; p++) begin
                if (mem_rd_valid[p] && mem_rd_ready[p]) begin
                    pending[p] <= 1'b1;
                    delay[p] <= p[2:0] + 3'd1;
                    beat[p] <= 4'd0;
                    saved_context[p] <= mem_rd_context[p];
                    saved_addr[p] <= mem_rd_block_addr[p];
                end else if (pending[p] && (delay[p] != 0)) begin
                    delay[p] <= delay[p] - 1'b1;
                end else if (pending[p] && mem_data_valid[p] &&
                             mem_data_ready[p] && mem_data_last[p]) begin
                    pending[p] <= 1'b0;
                end else if (pending[p] && mem_data_valid[p] &&
                             mem_data_ready[p]) begin
                    beat[p] <= beat[p] + 1'b1;
                end
            end
        end
    end

    // Deliberately apply a deterministic response backpressure pattern: one
    // requester in three is held for a beat, rotating on a free-running
    // counter. Tying the pattern to `got` would deadlock — a held last beat
    // can't advance `got`, which keeps it held — so the rotation is time
    // based instead, guaranteeing every burst eventually drains.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) rsp_cnt <= 0;
        else        rsp_cnt <= rsp_cnt + 1;
    end

    always_comb begin
        rsp_ready = '0;
        for (int r = 0; r < RQ; r++)
            rsp_ready[r] = ((r + rsp_cnt) % 3) != 1;
    end

    always_ff @(posedge clk) begin
        if (rst_n) begin
            for (int r = 0; r < RQ; r++) begin
                if (rsp_valid[r] && rsp_ready[r]) begin
                    if (rsp_error[r] || rsp_context[r] !== rd_context[r] ||
                        rsp_request[r] !== rd_request[r] ||
                        rsp_data[r] !== expected_data(rd_context[r], rd_block_addr[r] >> 3,
                                                     (rd_context[r] + rd_block_addr[r]) & (PP - 1), rsp_beat[r])) begin
                        $display("FAIL response requester=%0d beat=%0d", r, rsp_beat[r]);
                        $finish;
                    end
                    if (rsp_last[r] !== (rsp_beat[r] == 4'd15)) begin
                        $display("FAIL last requester=%0d beat=%0d", r, rsp_beat[r]);
                        $finish;
                    end
                    if (rsp_last[r]) got <= got + 1;
                end
            end
        end
    end

    task automatic send_request(input integer r);
        begin
            // Distinct context and a block whose partition = (ctx + block)
            // & (PP-1) lands on r: ctx = 0x1000 + r, block = 8*r gives
            // partition r and local address r. Spreading requesters across
            // partitions keeps an independent response stream per partition,
            // so the deliberate rsp_ready backpressure below cannot deadlock
            // a single outstanding burst.
            rd_context[r] = 16'(16'h1000 + r);
            rd_request[r] = 16'(16'h4000 + r);
            rd_block_addr[r] = 32'(8 * r);
            rd_valid[r] = 1'b1;
            while (!rd_ready[r]) @(posedge clk);
            @(posedge clk);
            rd_valid[r] = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        rd_valid = '0;
        rd_context = '0;
        rd_request = '0;
        rd_block_addr = '0;
        wr_valid = '0;
        wr_context = '0;
        wr_block_addr = '0;
        wr_beat = '0;
        wr_last = '0;
        wr_data = '0;
        mem_wr_ready = '1;
        got = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;

        for (int r = 0; r < RQ; r++)
            send_request(r);

        wait (got == RQ);
        $display("tb_argon2_block_fabric: PASS (%0d tagged 16-beat reads)", got);
        $finish;
    end
endmodule
