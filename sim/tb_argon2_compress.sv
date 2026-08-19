// SPDX-License-Identifier: MIT
// Self-checking bench for argon2_compress. Vector: G(IV×16, 0) from ref/.
`timescale 1ns / 1ps
`include "blake2b_pkg.svh"

module tb_argon2_compress #(
    parameter int N_P = 1   // parallel P units in the compression G
);
    logic         clk, rst_n;
    logic         in_valid, in_ready, in_last, with_xor;
    logic [511:0] in_x, in_y, in_dest;
    logic         out_valid, out_ready, out_last;
    logic [511:0] out_data;

    argon2_compress #(.N_P(N_P)) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_ready(in_ready),
        .in_x(in_x), .in_y(in_y), .in_last(in_last),
        .with_xor(with_xor), .in_dest(in_dest),
        .out_valid(out_valid), .out_ready(out_ready),
        .out_data(out_data), .out_last(out_last)
    );

    always #5 clk = ~clk;

    // IV repeated — every 512-bit beat is the eight IV words, word0 in [63:0].
    localparam logic [511:0] IV_BEAT = {
        `BLAKE2B_IV7, `BLAKE2B_IV6, `BLAKE2B_IV5, `BLAKE2B_IV4,
        `BLAKE2B_IV3, `BLAKE2B_IV2, `BLAKE2B_IV1, `BLAKE2B_IV0
    };

    integer errors, beats, cycles, i;

    task automatic expect_word(
        input [63:0] got, input [63:0] exp, input string name
    );
        if (got !== exp) begin
            $display("FAIL %s got %016h exp %016h", name, got, exp);
            errors = errors + 1;
        end
    endtask

    // Drive on the negedge and check in_ready *before* presenting a beat:
    // in_ready is registered, so if it is high at the negedge the beat is
    // taken on the following posedge. Waiting for in_ready *after* the last
    // beat would block until the whole G has already drained.
    task automatic feed_g(input integer xor_dest);
        integer b;
        with_xor = xor_dest;
        in_dest  = {16{32'hFFFF_FFFF}}; // 512 ones if xor_dest, ignored otherwise
        for (b = 0; b < 16; b = b + 1) begin
            @(negedge clk);
            while (!in_ready) @(negedge clk);
            in_x     = IV_BEAT;
            in_y     = 512'd0;
            in_last  = (b == 15);
            in_valid = 1'b1;
            @(posedge clk);
        end
        @(negedge clk);
        in_valid = 1'b0;
        in_last  = 1'b0;
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        in_valid = 0;
        in_last = 0;
        with_xor = 0;
        out_ready = 1;
        in_x = 0;
        in_y = 0;
        in_dest = 0;
        errors = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        feed_g(1'b0);

        beats = 0;
        cycles = 0;
        while (beats < 16 && cycles < 4000) begin
            @(negedge clk);
            cycles = cycles + 1;
            if (out_valid && out_ready) begin
                if (beats == 0) begin
                    expect_word(out_data[63:0],    64'hf2ab7d5a5688e6a3, "g[0]");
                    expect_word(out_data[127:64],  64'h5c9ad69f7837bdba, "g[1]");
                    expect_word(out_data[191:128], 64'h1e11f66e3f574f6d, "g[2]");
                    expect_word(out_data[255:192], 64'h2044bd036b4c1898, "g[3]");
                    expect_word(out_data[511:448], 64'h9637b3e44c5c081e, "g[7]");
                end
                if (beats == 15) begin
                    expect_word(out_data[63:0],    64'hd0012ffc6e5a8ba4, "g[120]");
                    expect_word(out_data[511:448], 64'h6a620def714cb9d6, "g[127]");
                    if (!out_last) begin
                        $display("FAIL last beat without out_last");
                        errors = errors + 1;
                    end
                end else if (out_last) begin
                    $display("FAIL out_last on beat %0d", beats);
                    errors = errors + 1;
                end
                beats = beats + 1;
            end
        end
        if (beats != 16) begin
            $display("FAIL expected 16 output beats, got %0d (cycles=%0d)",
                     beats, cycles);
            errors = errors + 1;
        end

        // Second G: dest XOR of all-ones must flip every bit of the tag.
        feed_g(1'b1);
        beats = 0;
        cycles = 0;
        while (beats < 16 && cycles < 4000) begin
            @(negedge clk);
            cycles = cycles + 1;
            if (out_valid && out_ready) begin
                if (beats == 0)
                    expect_word(out_data[63:0], 64'h0d5482a5a977195c, "g_xor[0]");
                beats = beats + 1;
            end
        end
        if (beats != 16) begin
            $display("FAIL xor-path expected 16 beats, got %0d", beats);
            errors = errors + 1;
        end

        if (errors == 0) begin
            $display("tb_argon2_compress PASS");
            $finish;
        end else begin
            $display("tb_argon2_compress FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
