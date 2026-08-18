// SPDX-License-Identifier: MIT
// Known-answer fill: p=1, m=8 KiB, t=2, password/somesalt.
// Exercises argon2i (addr-gen + prefetch), argon2d (J from prev), argon2id
// (switches after the first half of pass 0), dest-xor on pass 1, and the
// empty first segment (q/4 == 2).
`timescale 1ns / 1ps

module tb_argon2_fill;
    localparam int NBLK   = 8;
    localparam int NBEAT  = 16;
    localparam int RD_LAT = 12;
    localparam int ADDR_W = 32;

    logic              clk, rst_n, start, busy, done;
    logic [31:0]       passes, lanes, lane_id, lane_length, memory_blocks;
    logic [1:0]        type_i;

    logic              mem_rd_valid, mem_rd_ready, mem_rd_data_v, mem_rd_last;
    logic [ADDR_W-1:0] mem_rd_addr;
    logic [511:0]      mem_rd_data;
    logic              mem_wr_valid, mem_wr_ready, mem_wr_last;
    logic [ADDR_W-1:0] mem_wr_addr;
    logic [511:0]      mem_wr_data;

    argon2_fill_ctrl #(.ADDR_W(ADDR_W)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .passes(passes), .lanes(lanes), .lane_id(lane_id),
        .lane_length(lane_length), .memory_blocks(memory_blocks),
        .type_i(type_i),
        .mem_rd_valid(mem_rd_valid), .mem_rd_ready(mem_rd_ready),
        .mem_rd_addr(mem_rd_addr),
        .mem_rd_data_v(mem_rd_data_v), .mem_rd_data(mem_rd_data),
        .mem_rd_last(mem_rd_last),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready),
        .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
        .mem_wr_last(mem_wr_last)
    );

    logic [511:0] mem [0:NBLK*NBEAT-1];
    logic [511:0] exp [0:NBLK*NBEAT-1];

    logic        rd_busy;
    logic [31:0] rd_blk;
    logic [4:0]  rd_beat;
    logic [7:0]  rd_wait;
    logic [4:0]  wr_beat;

    always #5 clk = ~clk;

    assign mem_wr_ready = 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rd_ready  <= 1'b1;
            mem_rd_data_v <= 1'b0;
            mem_rd_last   <= 1'b0;
            mem_rd_data   <= '0;
            rd_busy       <= 1'b0;
            rd_blk        <= 32'd0;
            rd_beat       <= 5'd0;
            rd_wait       <= 8'd0;
            wr_beat       <= 5'd0;
        end else begin
            mem_rd_data_v <= 1'b0;
            mem_rd_last   <= 1'b0;

            if (!rd_busy) begin
                mem_rd_ready <= 1'b1;
                if (mem_rd_valid && mem_rd_ready) begin
                    rd_blk       <= mem_rd_addr;
                    rd_wait      <= RD_LAT[7:0];
                    rd_beat      <= 5'd0;
                    rd_busy      <= 1'b1;
                    mem_rd_ready <= 1'b0;
                end
            end else if (rd_wait != 8'd0) begin
                rd_wait <= rd_wait - 8'd1;
            end else begin
                mem_rd_data_v <= 1'b1;
                mem_rd_data   <= mem[rd_blk * NBEAT + rd_beat];
                mem_rd_last   <= (rd_beat == 5'd15);
                if (rd_beat == 5'd15)
                    rd_busy <= 1'b0;
                else
                    rd_beat <= rd_beat + 5'd1;
            end

            if (mem_wr_valid && mem_wr_ready) begin
                mem[mem_wr_addr * NBEAT + wr_beat] <= mem_wr_data;
                wr_beat <= mem_wr_last ? 5'd0 : (wr_beat + 5'd1);
            end
        end
    end

    integer errors, cycles, i;

    task automatic run_job(
        input [1:0] typ, input string init_f, input string exp_f, input string name
    );
        integer mismatches;
        $display("fill %s …", name);
        rst_n = 1'b0;
        start = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        $readmemh(init_f, mem);
        $readmemh(exp_f, exp);
        type_i = typ;
        start  = 1'b1;
        @(posedge clk);
        start  = 1'b0;

        cycles = 0;
        while (!done && cycles < 200000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!done) begin
            $display("FAIL %s timeout", name);
            errors = errors + 1;
            disable run_job;
        end

        // Let the last write NBA settle.
        @(posedge clk);
        @(posedge clk);

        mismatches = 0;
        for (i = 0; i < NBLK * NBEAT; i = i + 1) begin
            if (mem[i] !== exp[i]) begin
                if (mismatches < 4)
                    $display("FAIL %s beat %0d got %0128h exp %0128h",
                             name, i, mem[i], exp[i]);
                mismatches = mismatches + 1;
            end
        end
        if (mismatches != 0) begin
            $display("FAIL %s %0d beat(s) differ (%0d cycles)",
                     name, mismatches, cycles);
            errors = errors + 1;
        end else begin
            $display("  %s PASS (%0d cycles)", name, cycles);
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        passes = 32'd2;
        lanes = 32'd1;
        lane_id = 32'd0;
        lane_length = 32'd8;
        memory_blocks = 32'd8;
        type_i = 2'd1;
        errors = 0;
        repeat (6) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        run_job(2'd1, "gen/fill_i_init.hex",  "gen/fill_i_exp.hex",  "argon2i");
        run_job(2'd0, "gen/fill_d_init.hex",  "gen/fill_d_exp.hex",  "argon2d");
        run_job(2'd2, "gen/fill_id_init.hex", "gen/fill_id_exp.hex", "argon2id");

        if (errors == 0) begin
            $display("tb_argon2_fill PASS");
            $finish;
        end else begin
            $display("tb_argon2_fill FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
