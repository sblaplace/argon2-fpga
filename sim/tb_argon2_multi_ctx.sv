// SPDX-License-Identifier: MIT
// Many-context KAT: CONTEXTS independent p=1 contexts through one logical HBM
// stack (argon2_multi_ctx + argon2_block_fabric) against a data-storing,
// per-partition-latency memory model.  Each context gets its own init/exp hex
// pair (distinct password, so cross-context contamination is detectable), and
// the whole per-context working set is compared after the run.
//
// The memory model reconstructs the fabric's reversible block mapping
//   global = (local << PART_W) | ((partition - context) & (PARTITIONS-1))
// and stores each 512-bit beat by (global block, beat), so a read or write
// that the fabric misroutes lands on the wrong block and fails the compare.

`timescale 1ns / 1ps

module tb_argon2_multi_ctx #(
    parameter int N_P        = 1,
    parameter int LANES      = 8,
    parameter int CONTEXTS   = 32,
    parameter int PARTITIONS = 8
);
    localparam int ADDR_W  = 32;
    localparam int CW      = 16;
    localparam int NBLK    = 8;     // memory blocks per context (m'=8 KiB)
    localparam int NBEAT   = 16;
    localparam int NUM_BLOCKS = CONTEXTS * NBLK;
    localparam int PART_W  = (PARTITIONS <= 1) ? 1 : $clog2(PARTITIONS);
    localparam int RD_LAT  = 8;

    logic clk, rst_n;
    logic cfg_we, go_valid;
    logic [CW-1:0] cfg_addr, go_addr;
    logic [31:0]   cfg_passes, cfg_lane_length, cfg_memory_blocks;
    logic [1:0]    cfg_type;
    logic [ADDR_W-1:0] cfg_base;
    logic [CONTEXTS-1:0] ctx_done, ctx_busy;
    logic all_idle;

    logic [PARTITIONS-1:0] mem_rd_valid, mem_rd_ready;
    logic [CW-1:0]         mem_rd_context [0:PARTITIONS-1];
    logic [ADDR_W-1:0]     mem_rd_block_addr [0:PARTITIONS-1];
    logic [PARTITIONS-1:0] mem_data_valid, mem_data_ready, mem_data_last, mem_data_error;
    logic [3:0]            mem_data_beat [0:PARTITIONS-1];
    logic [511:0]          mem_data [0:PARTITIONS-1];
    logic [PARTITIONS-1:0] mem_wr_valid, mem_wr_ready, mem_wr_last;
    logic [CW-1:0]         mem_wr_context [0:PARTITIONS-1];
    logic [ADDR_W-1:0]     mem_wr_block_addr [0:PARTITIONS-1];
    logic [3:0]            mem_wr_beat [0:PARTITIONS-1];
    logic [511:0]          mem_wr_data [0:PARTITIONS-1];

    logic [511:0] mem [0:NUM_BLOCKS-1][0:NBEAT-1];
    logic [511:0] exp [0:NBLK*NBEAT-1];

    logic [PARTITIONS-1:0] rd_pending;
    integer rd_lat [0:PARTITIONS-1];
    logic [3:0] rd_beat [0:PARTITIONS-1];
    integer rd_blk [0:PARTITIONS-1];

    always #5 clk = ~clk;

    argon2_multi_ctx #(
        .ADDR_W(ADDR_W), .CONTEXT_W(CW), .LANES(LANES), .CONTEXTS(CONTEXTS),
        .PARTITIONS(PARTITIONS), .N_P(N_P)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_we(cfg_we), .cfg_addr(cfg_addr),
        .cfg_passes(cfg_passes), .cfg_lane_length(cfg_lane_length),
        .cfg_memory_blocks(cfg_memory_blocks), .cfg_type(cfg_type),
        .cfg_base(cfg_base),
        .go_valid(go_valid), .go_addr(go_addr),
        .ctx_done(ctx_done), .ctx_busy(ctx_busy), .all_idle(all_idle),
        .mem_rd_valid(mem_rd_valid), .mem_rd_ready(mem_rd_ready),
        .mem_rd_context(mem_rd_context), .mem_rd_block_addr(mem_rd_block_addr),
        .mem_data_valid(mem_data_valid), .mem_data_ready(mem_data_ready),
        .mem_data_beat(mem_data_beat), .mem_data_last(mem_data_last),
        .mem_data(mem_data), .mem_data_error(mem_data_error),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready),
        .mem_wr_context(mem_wr_context), .mem_wr_block_addr(mem_wr_block_addr),
        .mem_wr_beat(mem_wr_beat), .mem_wr_last(mem_wr_last),
        .mem_wr_data(mem_wr_data)
    );

    // ---- memory model ports ----------------------------------------------
    assign mem_rd_ready = '1;   // accept a read command every cycle
    assign mem_wr_ready = '1;   // accept a write beat every cycle

    // ---- read path -------------------------------------------------------
    always_comb begin
        mem_data_valid = '0;
        mem_data_last  = '0;
        mem_data_error = '0;
        for (int p = 0; p < PARTITIONS; p++) begin
            mem_data_valid[p] = rd_pending[p] && (rd_lat[p] <= 0);
            mem_data_last[p]  = rd_pending[p] && (rd_lat[p] <= 0) && (rd_beat[p] == 4'd15);
            mem_data_beat[p]  = rd_beat[p];
            mem_data[p]       = mem[rd_blk[p]][rd_beat[p]];
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        integer ctx_p, low;
        if (!rst_n) begin
            rd_pending <= '0;
            for (int p = 0; p < PARTITIONS; p++) begin
                rd_lat[p] <= 0;
                rd_beat[p] <= 4'd0;
                rd_blk[p]  <= 0;
            end
        end else begin
            for (int p = 0; p < PARTITIONS; p++) begin
                if (mem_rd_valid[p] && mem_rd_ready[p]) begin
                    ctx_p = mem_rd_context[p];
                    low = (p - ctx_p) & (PARTITIONS - 1);
                    rd_pending[p] <= 1'b1;
                    rd_lat[p]     <= RD_LAT;
                    rd_beat[p]    <= 4'd0;
                    rd_blk[p]     <= (int'(mem_rd_block_addr[p]) << PART_W) | low;
                end else if (rd_pending[p] && (rd_lat[p] > 0)) begin
                    rd_lat[p] <= rd_lat[p] - 1;
                end else if (rd_pending[p] && mem_data_valid[p] &&
                             mem_data_ready[p] && mem_data_last[p]) begin
                    rd_pending[p] <= 1'b0;
                end else if (rd_pending[p] && mem_data_valid[p] &&
                             mem_data_ready[p]) begin
                    rd_beat[p] <= rd_beat[p] + 4'd1;
                end
            end
        end
    end

    // ---- write path ------------------------------------------------------
    always_ff @(posedge clk) begin
        integer ctx_p, low, g;
        if (rst_n) begin
            for (int p = 0; p < PARTITIONS; p++) begin
                if (mem_wr_valid[p] && mem_wr_ready[p]) begin
                    ctx_p = mem_wr_context[p];
                    low = (p - ctx_p) & (PARTITIONS - 1);
                    g = (int'(mem_wr_block_addr[p]) << PART_W) | low;
                    mem[g][mem_wr_beat[p]] <= mem_wr_data[p];
                end
            end
        end
    end

    // ---- helpers ---------------------------------------------------------
    integer errors, cycles;

    task automatic run_type(
        input [1:0] typ, input string stem, input string name
    );
        string f;
        integer c, i, b, mismatches;
        $display("multi %s ...", name);
        // Reset the DUT and clear the fabric/memory state.
        rst_n = 1'b0; cfg_we = 1'b0; go_valid = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        // Seed every context region with its own init image.
        for (c = 0; c < CONTEXTS; c++) begin
            f = $sformatf("%s_c%0d_init.hex", stem, c);
            $readmemh(f, exp);
            for (i = 0; i < NBLK; i++)
                for (b = 0; b < NBEAT; b++)
                    mem[c*NBLK + i][b] = exp[i*NBEAT + b];
        end

        // Program descriptors and launch every context.
        for (c = 0; c < CONTEXTS; c++) begin
            cfg_addr         = CW'(c);
            cfg_passes       = 32'd2;
            cfg_lane_length  = 32'(NBLK);
            cfg_memory_blocks = 32'(NBLK);
            cfg_type         = typ;
            cfg_base         = ADDR_W'(c * NBLK);
            cfg_we           = 1'b1;
            @(posedge clk);
            cfg_we           = 1'b0;
            go_valid         = 1'b1;
            go_addr          = CW'(c);
            @(posedge clk);
            go_valid         = 1'b0;
        end

        // Run to completion.
        cycles = 0;
        while (!all_idle && cycles < 2000000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (!all_idle) begin
            $display("FAIL %s timeout (%0d cycles)", name, cycles);
            errors = errors + 1;
            return;
        end

        // A couple of settle cycles for the last write beats.
        repeat (2) @(posedge clk);

        // Compare every context's working set against its reference.
        mismatches = 0;
        for (c = 0; c < CONTEXTS; c++) begin
            f = $sformatf("%s_c%0d_exp.hex", stem, c);
            $readmemh(f, exp);
            for (i = 0; i < NBLK; i++) begin
                for (b = 0; b < NBEAT; b++) begin
                    if (mem[c*NBLK + i][b] !== exp[i*NBEAT + b]) begin
                        if (mismatches < 4)
                            $display("FAIL %s ctx %0d blk %0d beat %0d got %0128h exp %0128h",
                                     name, c, i, b, mem[c*NBLK+i][b], exp[i*NBEAT+b]);
                        mismatches = mismatches + 1;
                    end
                end
            end
        end

        if (mismatches != 0) begin
            $display("FAIL %s %0d beat(s) differ (%0d cycles)", name, mismatches, cycles);
            errors = errors + 1;
        end else begin
            $display("  %s PASS (%0d cycles, %0d contexts x %0d blocks)",
                     name, cycles, CONTEXTS, NBLK);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst_n = 1'b0;
        cfg_we = 1'b0;
        go_valid = 1'b0;
        errors = 0;
        repeat (6) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);

        run_type(2'd1, "gen/multi_i",  "argon2i");
        run_type(2'd0, "gen/multi_d",  "argon2d");
        run_type(2'd2, "gen/multi_id", "argon2id");

        if (errors == 0) begin
            $display("tb_argon2_multi_ctx PASS");
            $finish;
        end else begin
            $display("tb_argon2_multi_ctx FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
