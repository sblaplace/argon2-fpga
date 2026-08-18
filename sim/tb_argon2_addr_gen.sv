// SPDX-License-Identifier: MIT
// Argon2i address-generator KAT: first window of Z=(0,0,0,32,3,i).
`timescale 1ns / 1ps

module tb_argon2_addr_gen;
    logic        clk, rst_n, init, start, busy, done;
    logic [31:0] pass, lane, slice, memory_blocks, time_cost, type_i;
    logic [6:0]  rd_idx, rd_idx_b;
    logic [63:0] rd_j, rd_j_b;

    argon2_addr_gen dut (
        .clk(clk), .rst_n(rst_n),
        .init(init),
        .pass(pass), .lane(lane), .slice(slice),
        .memory_blocks(memory_blocks), .time_cost(time_cost), .type_i(type_i),
        .start(start), .busy(busy), .done(done),
        .rd_idx(rd_idx), .rd_j(rd_j),
        .rd_idx_b(rd_idx_b), .rd_j_b(rd_j_b)
    );

    always #5 clk = ~clk;

    integer errors, cycles;

    initial begin
        clk = 0;
        rst_n = 0;
        init = 0;
        start = 0;
        pass = 0;
        lane = 0;
        slice = 0;
        memory_blocks = 32;
        time_cost = 3;
        type_i = 32'd1;
        rd_idx = 0;
        rd_idx_b = 2;
        errors = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        init  = 1;
        start = 1;
        @(posedge clk);
        init  = 0;
        start = 0;

        cycles = 0;
        while (!done && cycles < 8000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!done) begin
            $display("FAIL timeout waiting for first window");
            $fatal(1);
        end

        rd_idx   = 7'd0;
        rd_idx_b = 7'd2;
        #1;
        if (rd_j !== 64'hd66f57259d654b1b) begin
            $display("FAIL addr[0] got %016h", rd_j);
            errors = errors + 1;
        end
        if (rd_j_b !== 64'h61c8e2257a13cb42) begin
            $display("FAIL addr[2] got %016h", rd_j_b);
            errors = errors + 1;
        end
        rd_idx = 7'd127;
        #1;
        if (rd_j !== 64'h9e16e7accfc9e85d) begin
            $display("FAIL addr[127] got %016h", rd_j);
            errors = errors + 1;
        end

        // Second window must differ (counter now 2).
        @(posedge clk);
        start = 1;
        @(posedge clk);
        start = 0;
        cycles = 0;
        while (!done && cycles < 8000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        rd_idx = 7'd0;
        #1;
        if (rd_j === 64'hd66f57259d654b1b) begin
            $display("FAIL second window reused first addr[0]");
            errors = errors + 1;
        end
        if (rd_j !== 64'h01000148591d8e18) begin
            $display("FAIL addr2[0] got %016h exp 01000148591d8e18", rd_j);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("tb_argon2_addr_gen PASS (first window in %0d cycles)", cycles);
            $finish;
        end else begin
            $display("tb_argon2_addr_gen FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
