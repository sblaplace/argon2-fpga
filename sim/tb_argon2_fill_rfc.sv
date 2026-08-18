// SPDX-License-Identifier: MIT
// RFC 9106 §5 known-answer fill: p=4, m=32 KiB, t=3, official
// password / salt / secret / AD. Four fill controllers share one
// working set and join at each slice barrier.
`timescale 1ns / 1ps

module tb_argon2_fill_rfc;
    localparam int NBLK   = 32;
    localparam int NBEAT  = 16;
    localparam int P      = 4;
    localparam int RD_LAT = 12;
    localparam int ADDR_W = 32;

    logic        clk, rst_n, start, busy, done;
    logic [31:0] passes, lane_length, memory_blocks;
    logic [1:0]  type_i;

    logic [P-1:0]             mem_rd_valid, mem_rd_ready, mem_rd_data_v, mem_rd_last;
    logic [P-1:0][ADDR_W-1:0] mem_rd_addr;
    logic [P-1:0][511:0]      mem_rd_data;
    logic [P-1:0]             mem_wr_valid, mem_wr_ready, mem_wr_last;
    logic [P-1:0][ADDR_W-1:0] mem_wr_addr;
    logic [P-1:0][511:0]      mem_wr_data;

    argon2_fill_job #(.ADDR_W(ADDR_W), .LANES(P)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .passes(passes), .lane_length(lane_length),
        .memory_blocks(memory_blocks), .type_i(type_i),
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

    logic [P-1:0]        rd_busy;
    logic [P-1:0][31:0]  rd_blk;
    logic [P-1:0][4:0]   rd_beat;
    logic [P-1:0][7:0]   rd_wait;
    logic [P-1:0][4:0]   wr_beat;

    integer p;

    always #5 clk = ~clk;

    assign mem_wr_ready = {P{1'b1}};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mem_rd_ready  <= {P{1'b1}};
            mem_rd_data_v <= '0;
            mem_rd_last   <= '0;
            mem_rd_data   <= '0;
            rd_busy       <= '0;
            rd_blk        <= '0;
            rd_beat       <= '0;
            rd_wait       <= '0;
            wr_beat       <= '0;
        end else begin
            for (p = 0; p < P; p = p + 1) begin
                mem_rd_data_v[p] <= 1'b0;
                mem_rd_last[p]   <= 1'b0;

                if (!rd_busy[p]) begin
                    mem_rd_ready[p] <= 1'b1;
                    if (mem_rd_valid[p] && mem_rd_ready[p]) begin
                        rd_blk[p]        <= mem_rd_addr[p];
                        rd_wait[p]       <= RD_LAT[7:0];
                        rd_beat[p]       <= 5'd0;
                        rd_busy[p]       <= 1'b1;
                        mem_rd_ready[p]  <= 1'b0;
                    end
                end else if (rd_wait[p] != 8'd0) begin
                    rd_wait[p] <= rd_wait[p] - 8'd1;
                end else begin
                    mem_rd_data_v[p] <= 1'b1;
                    mem_rd_data[p]   <= mem[rd_blk[p] * NBEAT + rd_beat[p]];
                    mem_rd_last[p]   <= (rd_beat[p] == 5'd15);
                    if (rd_beat[p] == 5'd15)
                        rd_busy[p] <= 1'b0;
                    else
                        rd_beat[p] <= rd_beat[p] + 5'd1;
                end

                if (mem_wr_valid[p] && mem_wr_ready[p]) begin
                    mem[mem_wr_addr[p] * NBEAT + wr_beat[p]] <= mem_wr_data[p];
                    wr_beat[p] <= mem_wr_last[p] ? 5'd0 : (wr_beat[p] + 5'd1);
                end
            end
        end
    end

    integer errors, cycles, i;

    task automatic run_job(
        input [1:0] typ, input string init_f, input string exp_f, input string name
    );
        integer mismatches;
        $display("rfc %s …", name);
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
        while (!done && cycles < 1000000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!done) begin
            $display("FAIL %s timeout", name);
            errors = errors + 1;
        end else begin
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
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        passes = 32'd3;
        lane_length = 32'd8;
        memory_blocks = 32'd32;
        type_i = 2'd1;
        errors = 0;
        repeat (6) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        run_job(2'd1, "gen/rfc_i_init.hex",  "gen/rfc_i_exp.hex",  "argon2i");
        run_job(2'd0, "gen/rfc_d_init.hex",  "gen/rfc_d_exp.hex",  "argon2d");
        run_job(2'd2, "gen/rfc_id_init.hex", "gen/rfc_id_exp.hex", "argon2id");

        if (errors == 0) begin
            $display("tb_argon2_fill_rfc PASS");
            $finish;
        end else begin
            $display("tb_argon2_fill_rfc FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
