// SPDX-License-Identifier: MIT
// Throughput model for the tagged partition fabric.
//
// This is intentionally an HBM-like model rather than a JEDEC PHY model: it
// gives each partition an independent fixed read latency, accepts one read
// command at a time, and applies deterministic write backpressure.  It
// measures useful block reads, write beats, command utilization, and stalls.
// Use it to compare mappings and queue policies before attaching a vendor HBM
// controller.

`timescale 1ns / 1ps

module tb_hbm_fabric_perf #(
    parameter int REQUESTERS = 32,
    parameter int PARTITIONS = 32,
    parameter int READ_LAT   = 20,
    parameter int CYCLES     = 100000
);
    localparam int DW = 512;
    localparam int PW = (PARTITIONS <= 1) ? 1 : $clog2(PARTITIONS);

    logic clk, rst_n;
    logic [REQUESTERS-1:0] rd_ready, rd_valid;
    logic [REQUESTERS-1:0][15:0] rd_context, rd_request;
    logic [REQUESTERS-1:0][31:0] rd_block_addr;
    logic [REQUESTERS-1:0] rsp_valid, rsp_ready, rsp_last, rsp_error;
    logic [REQUESTERS-1:0][15:0] rsp_context, rsp_request;
    logic [REQUESTERS-1:0][3:0] rsp_beat;
    logic [REQUESTERS-1:0][DW-1:0] rsp_data;
    logic [REQUESTERS-1:0] wr_ready, wr_valid, wr_last;
    logic [REQUESTERS-1:0][15:0] wr_context;
    logic [REQUESTERS-1:0][31:0] wr_block_addr;
    logic [REQUESTERS-1:0][3:0] wr_beat;
    logic [REQUESTERS-1:0][DW-1:0] wr_data;

    logic [PARTITIONS-1:0] mem_rd_valid, mem_rd_ready;
    logic [PARTITIONS-1:0][15:0] mem_rd_context;
    logic [PARTITIONS-1:0][31:0] mem_rd_block_addr;
    logic [PARTITIONS-1:0] mem_data_valid, mem_data_ready, mem_data_last, mem_data_error;
    logic [PARTITIONS-1:0][3:0] mem_data_beat;
    logic [PARTITIONS-1:0][DW-1:0] mem_data;
    logic [PARTITIONS-1:0] mem_wr_valid, mem_wr_ready, mem_wr_last;
    logic [PARTITIONS-1:0][15:0] mem_wr_context;
    logic [PARTITIONS-1:0][31:0] mem_wr_block_addr;
    logic [PARTITIONS-1:0][3:0] mem_wr_beat;
    logic [PARTITIONS-1:0][DW-1:0] mem_wr_data;

    logic [REQUESTERS-1:0] rd_inflight;
    logic [REQUESTERS-1:0][31:0] next_block;
    logic [REQUESTERS-1:0][3:0] next_wr_beat;
    logic [PARTITIONS-1:0] read_pending;
    integer read_delay [0:PARTITIONS-1];
    logic [PARTITIONS-1:0][3:0] read_beat;
    integer cycles, blocks_done, rd_cmds, wr_beats, wr_stalls;

    always #5 clk = ~clk;

    argon2_block_fabric #(
        .ADDR_W(32), .CONTEXT_W(16), .REQUEST_W(16), .DATA_W(DW),
        .REQUESTERS(REQUESTERS), .PARTITIONS(PARTITIONS)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .rd_ready(rd_ready), .rd_valid(rd_valid),
        .rd_context(rd_context), .rd_request(rd_request),
        .rd_block_addr(rd_block_addr),
        .rsp_valid(rsp_valid), .rsp_ready(rsp_ready),
        .rsp_context(rsp_context), .rsp_request(rsp_request),
        .rsp_beat(rsp_beat), .rsp_last(rsp_last), .rsp_data(rsp_data),
        .rsp_error(rsp_error),
        .wr_ready(wr_ready), .wr_valid(wr_valid),
        .wr_context(wr_context), .wr_block_addr(wr_block_addr),
        .wr_beat(wr_beat), .wr_last(wr_last), .wr_data(wr_data),
        .mem_rd_valid(mem_rd_valid), .mem_rd_ready(mem_rd_ready),
        .mem_rd_context(mem_rd_context), .mem_rd_block_addr(mem_rd_block_addr),
        .mem_data_valid(mem_data_valid), .mem_data_ready(mem_data_ready),
        .mem_data_beat(mem_data_beat), .mem_data_last(mem_data_last),
        .mem_data(mem_data), .mem_data_error(mem_data_error),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready),
        .mem_wr_context(mem_wr_context), .mem_wr_block_addr(mem_wr_block_addr),
        .mem_wr_beat(mem_wr_beat), .mem_wr_last(mem_wr_last), .mem_wr_data(mem_wr_data)
    );

    // All requesters are continuously ready to receive.  The memory model
    // returns zero data because this bench measures transport, not Argon2.
    always_comb begin
        rsp_ready = '1;
        mem_rd_ready = '1;
        mem_data_valid = '0;
        mem_data_ready = '0;
        mem_data_beat = read_beat;
        mem_data_last = '0;
        mem_data = '0;
        mem_data_error = '0;
        for (int p = 0; p < PARTITIONS; p++) begin
            mem_data_valid[p] = read_pending[p] && (read_delay[p] == 0);
            mem_data_last[p] = read_pending[p] && (read_beat[p] == 4'd15);
        end
        // A repeating write-ready pattern approximates controller queue
        // pressure while remaining deterministic and reproducible.
        for (int p = 0; p < PARTITIONS; p++)
            mem_wr_ready[p] = ((cycles + p * 3) % 11) != 0;
        for (int p = 0; p < PARTITIONS; p++)
            mem_data_ready[p] = mem_data_valid[p];
    end

    always_comb begin
        for (int r = 0; r < REQUESTERS; r++) begin
            rd_valid[r] = !rd_inflight[r];
            rd_context[r] = 16'(16'h1000 + r);
            rd_request[r] = 16'(cycles + r);
            rd_block_addr[r] = next_block[r];
            wr_valid[r] = 1'b1;
            wr_context[r] = 16'(16'h1000 + r);
            wr_block_addr[r] = 32'(32'h100 + r * 32'h100000 + (next_block[r] >> 4));
            wr_beat[r] = next_wr_beat[r];
            wr_last[r] = (next_wr_beat[r] == 4'd15);
            wr_data[r] = '0;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_inflight <= '0;
            next_block <= '0;
            next_wr_beat <= '0;
            read_pending <= '0;
            blocks_done <= 0;
            rd_cmds <= 0;
            wr_beats <= 0;
            wr_stalls <= 0;
            cycles <= 0;
            for (int p = 0; p < PARTITIONS; p++) begin
                read_delay[p] <= 0;
                read_beat[p] <= '0;
            end
        end else begin
            cycles <= cycles + 1;
            if (cycles >= CYCLES) begin
                $display("HBM fabric: %0d cycles, %0d completed blocks, %0d read commands", cycles, blocks_done, rd_cmds);
                $display("HBM fabric: %0d write beats, %0d write-ready stalls", wr_beats, wr_stalls);
                $display("HBM fabric: %0.3f aggregate read blocks/cycle, %0.3f write GB/s at 1 GHz-equivalent",
                         blocks_done * 1.0 / (cycles != 0 ? cycles : 1),
                         wr_beats * 64.0 / (cycles != 0 ? cycles : 1));
                $finish;
            end

            for (int r = 0; r < REQUESTERS; r++) begin
                if (rd_valid[r] && rd_ready[r]) begin
                    rd_inflight[r] <= 1'b1;
                    next_block[r] <= next_block[r] + 1;
                    rd_cmds = rd_cmds + 1;
                end
                if (rsp_valid[r] && rsp_ready[r] && rsp_last[r]) begin
                    rd_inflight[r] <= 1'b0;
                    blocks_done = blocks_done + 1;
                end
                if (wr_valid[r] && !wr_ready[r])
                    wr_stalls = wr_stalls + 1;
                if (wr_valid[r] && wr_ready[r]) begin
                    wr_beats = wr_beats + 1;
                    if (wr_last[r]) next_wr_beat[r] <= '0;
                    else next_wr_beat[r] <= next_wr_beat[r] + 1'b1;
                end
            end

            for (int p = 0; p < PARTITIONS; p++) begin
                if (mem_rd_valid[p] && mem_rd_ready[p]) begin
                    read_pending[p] <= 1'b1;
                    read_delay[p] <= READ_LAT;
                    read_beat[p] <= '0;
                end else if (read_pending[p] && read_delay[p] > 0) begin
                    read_delay[p] <= read_delay[p] - 1;
                end else if (read_pending[p] && mem_data_valid[p] &&
                             mem_data_ready[p] && mem_data_last[p]) begin
                    read_pending[p] <= 1'b0;
                end else if (read_pending[p] && mem_data_valid[p] &&
                             mem_data_ready[p]) begin
                    read_beat[p] <= read_beat[p] + 1'b1;
                end
            end
        end
    end

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
    end
endmodule
