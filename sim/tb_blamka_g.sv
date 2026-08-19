// SPDX-License-Identifier: MIT
// Self-checking bench for the 4-stage BlaMka pipeline.
`timescale 1ns / 1ps

module tb_blamka_g #(
    parameter int N_P = 1   // unused: uniform -GN_P sweep across benches
);
    logic        clk, rst_n, in_valid, out_valid;
    logic [63:0] a, b, c, d;
    logic [63:0] ao, bo, co, d_o;

    blamka_g dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid),
        .a_i(a), .b_i(b), .c_i(c), .d_i(d),
        .out_valid(out_valid),
        .a_o(ao), .b_o(bo), .c_o(co), .d_o(d_o)
    );

    always #5 clk = ~clk;

    integer errors, cycles;

    initial begin
        clk = 0;
        rst_n = 0;
        in_valid = 0;
        a = 0; b = 0; c = 0; d = 0;
        errors = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        // Vector from ref.argon2.blamka_g on IV words.
        a = 64'h6a09e667f3bcc908;
        b = 64'hbb67ae8584caa73b;
        c = 64'h3c6ef372fe94f82b;
        d = 64'ha54ff53a5f1d36f1;
        in_valid = 1;
        @(posedge clk);
        in_valid = 0;

        cycles = 0;
        while (!out_valid && cycles < 20) begin
            @(posedge clk);
            cycles = cycles + 1;
        end

        if (!out_valid) begin
            $display("FAIL timeout");
            $fatal(1);
        end

        if (ao !== 64'h78d4d1cad50d4c4c) begin
            $display("FAIL a got %016h exp 78d4d1cad50d4c4c", ao);
            errors = errors + 1;
        end
        if (bo !== 64'h073211656ab2dd42) begin
            $display("FAIL b got %016h exp 073211656ab2dd42", bo);
            errors = errors + 1;
        end
        if (co !== 64'h0e07d1418f71c11e) begin
            $display("FAIL c got %016h exp 0e07d1418f71c11e", co);
            errors = errors + 1;
        end
        if (d_o !== 64'h91ed87bd6ec8520c) begin
            $display("FAIL d got %016h exp 91ed87bd6ec8520c", d_o);
            errors = errors + 1;
        end

        if (cycles < 3 || cycles > 4) begin
            $display("FAIL latency cycles=%0d (expect 3 or 4 after the issue beat)", cycles);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("tb_blamka_g PASS (latency=%0d)", cycles);
            $finish;
        end else begin
            $display("tb_blamka_g FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
