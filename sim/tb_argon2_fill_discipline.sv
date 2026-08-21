// SPDX-License-Identifier: MIT
// State-discipline gate for the fill controller.
//
// The known-answer KATs (tb_argon2_fill, tb_argon2_fill_rfc, tb_argon2_axi)
// verify the fill controller produces bit-identical output and completes.
// They do NOT however detect a *silent throughput* regression: an FSM change
// that keeps output correct but stops overlapping pass-0 independent blocks
// leaves the KATs green while slash across-clone cand/s. That is the exact
// failure class PR #12 attempted to change and instead broke.
//
// This bench locks the structural discipline:
//   * Overlap is pass-0-only: nxt_ok requires !with_xor (see
//     argon2_fill_ctrl), so pass-0 interior independent blocks chain / skip
//     COMPRESS, while boundary/dependent pass-0 blocks still go serial.
//   * pass > 0 (dest-xor) blocks CANNOT chain (with_xor kills nxt_ok); they
//     always take the serial COMPRESS->WRITE path.
//   Therefore pass>0 must spend strictly MORE cycles in COMPRESS than pass-0.
//   If pass-0 overlap is ever lost (interior blocks also go serial), pass-0
//   COMPRESS rises toward pass>0 and this assert fails — catching the exact
//   silent-throughput regression the KATs miss.
//
// It reuses the existing KAT vectors, so it also re-asserts bit-identical
// output and completion; the discipline assertions are on top. If a future
// optimization legitimately extends overlap into pass>0, the "pass>0 uses
// COMPRESS" assert must be updated together with the perf numbers — the
// point is to force that decision to be explicit, not to forbid it.
//
// Build/run:  make -C sim discipline      (adds ->SIM target)
`timescale 1ns / 1ps

module tb_argon2_fill_discipline #(
    parameter int N_P = 1
);
    // state_o encoding (matches tb_perf histogram names)
    localparam [4:0] COMPRESS = 5'd10;
    localparam [4:0] WRITE    = 5'd11;

    localparam int NBLK   = 8;
    localparam int NBEAT  = 16;
    localparam int RD_LAT = 12;
    localparam int ADDR_W = 32;

    logic              clk, rst_n, start, busy, done;
    logic [31:0]       passes, lanes, lane_id, lane_length, memory_blocks;
    logic [1:0]        type_i;
    logic [4:0]        state_o;

    logic              mem_rd_valid, mem_rd_ready, mem_rd_data_v, mem_rd_last;
    logic [ADDR_W-1:0] mem_rd_addr;
    logic [511:0]      mem_rd_data;
    logic              mem_wr_valid, mem_wr_ready, mem_wr_last;
    logic [ADDR_W-1:0] mem_wr_addr;
    logic [511:0]      mem_wr_data;

    argon2_fill_ctrl #(.ADDR_W(ADDR_W), .N_P(N_P)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .passes(passes), .lanes(lanes), .lane_id(lane_id),
        .lane_length(lane_length), .memory_blocks(memory_blocks),
        .type_i(type_i),
        .sync_req(), .sync_ack(1'b1),
        .mem_rd_valid(mem_rd_valid), .mem_rd_ready(mem_rd_ready),
        .mem_rd_addr(mem_rd_addr),
        .mem_rd_data_v(mem_rd_data_v), .mem_rd_data(mem_rd_data),
        .mem_rd_last(mem_rd_last),
        .mem_wr_valid(mem_wr_valid), .mem_wr_ready(mem_wr_ready),
        .mem_wr_addr(mem_wr_addr), .mem_wr_data(mem_wr_data),
        .mem_wr_last(mem_wr_last),
        .state_o(state_o)
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
    longint  p0_compress, p1_compress;      // COMPRESS-state cycles, per pass
    logic    seen_pass1;

    // Pass-r tracking: hierarchical ref to the internal pass register. The
    // bench could instead re-derive pass from pass_r via the exposed state_o /
    // memory addresses, but the direct ref is unambiguous. (Icarus resolves
    // <tb>.<dut>.<reg> with a constant scope; same pattern as tb_cl_argon2.)
    // +count on each posedge while busy.
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p0_compress <= 0; p1_compress <= 0; seen_pass1 <= 1'b0;
        end else if (busy) begin
            if (dut.pass_r == 32'd0) seen_pass1 <= 1'b0;
            else                     seen_pass1 <= 1'b1;
            // Count COMPRESS-state cycles; attribute by the pass these are
            // logically in (pass>0 declared the moment pass_r != 0).
            if (state_o == COMPRESS) begin
                if (dut.pass_r == 32'd0) p0_compress <= p0_compress + 1;
                else                     p1_compress <= p1_compress + 1;
            end
        end
    end

    task automatic run_job(
        input [1:0] typ, input string init_f, input string exp_f, input string name
    );
        integer mismatches;
        integer timed_out;
        $display("discipline %s", name);
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

        p0_compress = 0; p1_compress = 0; seen_pass1 = 1'b0;
        cycles = 0;
        while (!done && cycles < 200000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        timed_out = 0;
        if (!done) begin
            $display("FAIL %s timeout", name);
            errors = errors + 1;
            timed_out = 1;
        end
        if (timed_out == 0) begin
        @(posedge clk);
        @(posedge clk);

        // bit-identical KAT (re-asserting correctness on the same vectors)
        mismatches = 0;
        for (i = 0; i < NBLK * NBEAT; i = i + 1) begin
            if (mem[i] !== exp[i]) mismatches = mismatches + 1;
        end
        if (mismatches != 0) begin
            $display("FAIL %s KAT: %0d beat(s) differ", name, mismatches);
            errors = errors + 1;
        end

        // structural discipline. These are INVARIANTS of the design, not
        // timing-derived constants (they hold for any memory latency / N_P):
        //   * overlap is pass-0-only — nxt_ok requires !with_xor (see
        //     argon2_fill_ctrl), so pass-1/dest-xor blocks can NEVER chain
        //     and always take the serial COMPRESS->WRITE path.
        //   * pass-0 interior independent blocks DO overlap (skip COMPRESS).
        //   Therefore pass-1 must spend strictly MORE cycles in COMPRESS than
        //   pass-0. If pass-0 overlap is lost (interior blocks also go
        //   serial), pass-0 COMPRESS rises to ~pass-1 and this fails.
        //   (If a future optimization legitimately extends overlap into
        //   pass>0, this assert must be updated together with the perf
        //   numbers — that is the point: make the decision explicit.)
        $display("  %s: pass0 COMPRESS=%0d pass1 COMPRESS=%0d cycles=%0d",
                 name, p0_compress, p1_compress, cycles);
        if (!(p0_compress < p1_compress)) begin
            $display("  FAIL %s pass1 COMPRESS (%0d) not > pass0 (%0d) - pass-0 overlap lost or pass-1 wrongly chained", name, p1_compress, p0_compress);
            errors = errors + 1;
        end
        if (p1_compress == 0) begin
            $display("  FAIL %s pass1 never entered COMPRESS - dest-xor serial path not used", name);
            errors = errors + 1;
        end
        if (mismatches == 0 && p0_compress < p1_compress && p1_compress != 0)
            $display("  %s PASS", name);
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
            $display("tb_argon2_fill_discipline PASS");
            $finish;
        end else begin
            $display("tb_argon2_fill_discipline FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule