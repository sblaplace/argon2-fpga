// SPDX-License-Identifier: MIT
// Partitioned-memory p=4 known-answer fill.
//
// The RFC p=4 bench (tb_argon2_fill_rfc) runs four fill controllers against
// ONE shared simulation RAM, so cross-lane reference reads never leave the
// "memory". This bench is the real partitioned floorplan: four controllers,
// argon2_mem_xbar (read router + tagged returns, global->local address
// translation), and FOUR separate memories, one per lane/channel, each
// addressed by LOCAL block index exactly as a dedicated DDR4 channel / HBM
// pseudo-channel would be.
//
// What that adds over the shared-RAM bench:
//   * cross-lane references physically traverse the router and come back
//     tagged (75% of all refs for p=4 in steady state);
//   * the write path's global->local translation is checked (a lane writing
//     another channel's address space would corrupt the expected matrix);
//   * the no-hazard assumption is validated: cross-lane refs only target
//     slices committed before the barrier (see argon2_mem_xbar header).
//
// Geometries: the RFC 9106 §5 official 32 KiB / p=4 / t=3 vector (i/d/id)
// plus p4sweep_* (m' 64/128 x t 1/3, and m'=48 t=2 whose lane_length 12 /
// segment_length 3 is NOT a power of two — the crossbar addressing must not
// care). Vectors from tests/dump_vectors.py.

`timescale 1ns / 1ps

// One channel's memory: local block index, rfc-style 12-cycle read latency,
// write commits on the beat handshake.
module tb_p4_ram #(
    parameter int LL     = 32,   // blocks this channel holds
    parameter int RD_LAT = 12
) (
    input  logic        clk,
    input  logic        rst_n,
    input  logic        rd_valid,
    output logic        rd_ready,
    input  logic [31:0] rd_addr,
    output logic        rd_data_v,
    output logic [511:0] rd_data,
    output logic        rd_last,
    input  logic        wr_valid,
    output logic        wr_ready,
    input  logic [31:0] wr_addr,
    input  logic [511:0] wr_data,
    input  logic        wr_last
);
    localparam int NBEAT = 16;
    logic [511:0] mem [0:LL*NBEAT-1];

    logic        rd_busy;
    logic [31:0] rd_blk;
    logic [4:0]  rd_beat;
    logic [7:0]  rd_wait;
    logic [4:0]  wr_beat;

    assign wr_ready = 1'b1;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_ready  <= 1'b1;
            rd_data_v <= 1'b0;
            rd_last   <= 1'b0;
            rd_data   <= '0;
            rd_busy   <= 1'b0;
            rd_blk    <= '0;
            rd_beat   <= '0;
            rd_wait   <= '0;
            wr_beat   <= '0;
        end else begin
            rd_data_v <= 1'b0;
            rd_last   <= 1'b0;

            if (!rd_busy) begin
                rd_ready <= 1'b1;
                if (rd_valid && rd_ready) begin
                    rd_blk   <= rd_addr;
                    rd_wait  <= RD_LAT[7:0];
                    rd_beat  <= 5'd0;
                    rd_busy  <= 1'b1;
                    rd_ready <= 1'b0;
                end
            end else if (rd_wait != 8'd0) begin
                rd_wait <= rd_wait - 8'd1;
            end else begin
                rd_data_v <= 1'b1;
                rd_data   <= mem[rd_blk * NBEAT + rd_beat];
                rd_last   <= (rd_beat == 5'd15);
                if (rd_beat == 5'd15) rd_busy <= 1'b0;
                else                  rd_beat <= rd_beat + 5'd1;
            end

            if (wr_valid && wr_ready) begin
                mem[wr_addr * NBEAT + wr_beat] <= wr_data;
                wr_beat <= wr_last ? 5'd0 : (wr_beat + 5'd1);
            end
        end
    end
endmodule

module tb_argon2_p4 #(
    parameter int N_P = 1
);
    localparam int P      = 4;
    localparam int NBEAT  = 16;
    localparam int ADDR_W = 32;
    localparam int MAXBLK = 128;        // largest swept geometry (m')
    localparam int MAXLL  = MAXBLK / P; // blocks per channel at max geometry

    logic        clk, rst_n, start, busy, done;
    logic [31:0] passes, lane_length, memory_blocks;
    logic [1:0]  type_i;

    logic [P-1:0]             j_rd_valid, j_rd_ready, j_rd_data_v, j_rd_last;
    logic [P-1:0][ADDR_W-1:0] j_rd_addr;
    logic [P-1:0][3:0]        j_rd_owner;
    logic [P-1:0][511:0]      j_rd_data;
    logic [P-1:0]             j_wr_valid, j_wr_ready, j_wr_last;
    logic [P-1:0][ADDR_W-1:0] j_wr_addr;
    logic [P-1:0][511:0]      j_wr_data;

    argon2_fill_job #(.ADDR_W(ADDR_W), .LANES(P), .N_P(N_P)) job (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .passes(passes), .lane_length(lane_length),
        .memory_blocks(memory_blocks), .type_i(type_i),
        .mem_rd_valid(j_rd_valid), .mem_rd_ready(j_rd_ready),
        .mem_rd_addr(j_rd_addr), .mem_rd_owner(j_rd_owner),
        .mem_rd_data_v(j_rd_data_v), .mem_rd_data(j_rd_data),
        .mem_rd_last(j_rd_last),
        .mem_wr_valid(j_wr_valid), .mem_wr_ready(j_wr_ready),
        .mem_wr_addr(j_wr_addr), .mem_wr_data(j_wr_data),
        .mem_wr_last(j_wr_last)
    );

    logic [P-1:0]             c_rd_valid, c_rd_ready, c_rd_data_v, c_rd_last;
    logic [P-1:0][ADDR_W-1:0] c_rd_addr;
    logic [P-1:0][511:0]      c_rd_data;
    logic [P-1:0]             c_wr_valid, c_wr_ready, c_wr_last;
    logic [P-1:0][ADDR_W-1:0] c_wr_addr;
    logic [P-1:0][511:0]      c_wr_data;

    argon2_mem_xbar #(.ADDR_W(ADDR_W), .LANES(P)) xb (
        .clk(clk), .rst_n(rst_n), .lane_length(lane_length),
        .l_rd_valid(j_rd_valid), .l_rd_ready(j_rd_ready),
        .l_rd_addr(j_rd_addr), .l_rd_owner(j_rd_owner),
        .l_rd_data_v(j_rd_data_v), .l_rd_data(j_rd_data),
        .l_rd_last(j_rd_last),
        .l_wr_valid(j_wr_valid), .l_wr_ready(j_wr_ready),
        .l_wr_addr(j_wr_addr), .l_wr_data(j_wr_data), .l_wr_last(j_wr_last),
        .c_rd_valid(c_rd_valid), .c_rd_ready(c_rd_ready),
        .c_rd_addr(c_rd_addr), .c_rd_data_v(c_rd_data_v),
        .c_rd_data(c_rd_data), .c_rd_last(c_rd_last),
        .c_wr_valid(c_wr_valid), .c_wr_ready(c_wr_ready),
        .c_wr_addr(c_wr_addr), .c_wr_data(c_wr_data), .c_wr_last(c_wr_last)
    );

    for (genvar g = 0; g < P; g++) begin : chan
        tb_p4_ram #(.LL(MAXLL)) ram (
            .clk(clk), .rst_n(rst_n),
            .rd_valid(c_rd_valid[g]), .rd_ready(c_rd_ready[g]),
            .rd_addr(c_rd_addr[g][31:0]),
            .rd_data_v(c_rd_data_v[g]), .rd_data(c_rd_data[g]),
            .rd_last(c_rd_last[g]),
            .wr_valid(c_wr_valid[g]), .wr_ready(c_wr_ready[g]),
            .wr_addr(c_wr_addr[g][31:0]), .wr_data(c_wr_data[g]),
            .wr_last(c_wr_last[g])
        );
    end

    // Global image scratch (init / expected) and per-channel compare.
    logic [511:0] gfull [0:MAXBLK*NBEAT-1];

    always #5 clk = ~clk;

    integer errors, cycles;

    // The simulator requires constant generate-block selection, so
    // per-channel memory access goes through case-unrolled helpers.
    task automatic chan_set(input int c, input int k, input logic [511:0] d);
        case (c)
            0: chan[0].ram.mem[k] = d;
            1: chan[1].ram.mem[k] = d;
            2: chan[2].ram.mem[k] = d;
            3: chan[3].ram.mem[k] = d;
        endcase
    endtask

    function automatic logic [511:0] chan_get(input int c, input int k);
        case (c)
            0: chan_get = chan[0].ram.mem[k];
            1: chan_get = chan[1].ram.mem[k];
            2: chan_get = chan[2].ram.mem[k];
            3: chan_get = chan[3].ram.mem[k];
        endcase
    endfunction

    task automatic run_job(
        input [1:0] typ, input int nblk, input int npass,
        input string init_f, input string exp_f, input string name
    );
        integer mismatches, ll, k, c;
        begin
            ll = nblk / P;
            $display("p4 %s", name);
            rst_n = 1'b0;
            start = 1'b0;
            repeat (4) @(posedge clk);
            rst_n = 1'b1;
            @(posedge clk);
            // Slice the global init image into each channel's local memory:
            // global block c*ll + q belongs to channel c at local index q.
            for (k = 0; k < MAXBLK * NBEAT; k++) gfull[k] = '0;
            $readmemh(init_f, gfull);
            for (c = 0; c < P; c++)
                for (k = 0; k < ll * NBEAT; k++)
                    chan_set(c, k, gfull[c * ll * NBEAT + k]);
            $readmemh(exp_f, gfull);

            type_i        = typ;
            passes        = npass;
            lane_length   = ll;
            memory_blocks = nblk;
            start         = 1'b1;
            @(posedge clk);
            start         = 1'b0;

            cycles = 0;
            while (!done && cycles < 4000000) begin
                @(posedge clk);
                cycles = cycles + 1;
            end
            if (!done) begin
                $display("FAIL %s timeout (stuck at state=%0d..%0d)", name,
                         job.lane[0].u_fill.state_o, job.lane[3].u_fill.state_o);
                errors = errors + 1;
            end else begin
                @(posedge clk);
                @(posedge clk);
                mismatches = 0;
                for (c = 0; c < P; c++) begin
                    for (k = 0; k < ll * NBEAT; k++) begin
                        if (chan_get(c, k) !== gfull[c * ll * NBEAT + k]) begin
                            if (mismatches < 4)
                                $display("FAIL %s chan %0d beat %0d got %0128h exp %0128h",
                                         name, c, k, chan_get(c, k),
                                         gfull[c * ll * NBEAT + k]);
                            mismatches = mismatches + 1;
                        end
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

        // RFC 9106 §5 official vector: m=32, p=4, t=3.
        run_job(2'd1, 32, 3, "gen/rfc_i_init.hex",  "gen/rfc_i_exp.hex",  "rfc argon2i");
        run_job(2'd0, 32, 3, "gen/rfc_d_init.hex",  "gen/rfc_d_exp.hex",  "rfc argon2d");
        run_job(2'd2, 32, 3, "gen/rfc_id_init.hex", "gen/rfc_id_exp.hex", "rfc argon2id");

        // Geometry sweep: lane_length 16 / 32 (segment_length 4 / 8) and the
        // non-power-of-two m'=48 (lane_length 12, segment_length 3).
        run_job(2'd1, 64, 1, "gen/p4sweep_i_m64t1_init.hex",  "gen/p4sweep_i_m64t1_exp.hex",  "argon2i m64 t1");
        run_job(2'd1, 64, 3, "gen/p4sweep_i_m64t3_init.hex",  "gen/p4sweep_i_m64t3_exp.hex",  "argon2i m64 t3");
        run_job(2'd0, 64, 1, "gen/p4sweep_d_m64t1_init.hex",  "gen/p4sweep_d_m64t1_exp.hex",  "argon2d m64 t1");
        run_job(2'd0, 64, 3, "gen/p4sweep_d_m64t3_init.hex",  "gen/p4sweep_d_m64t3_exp.hex",  "argon2d m64 t3");
        run_job(2'd2, 64, 1, "gen/p4sweep_id_m64t1_init.hex", "gen/p4sweep_id_m64t1_exp.hex", "argon2id m64 t1");
        run_job(2'd2, 64, 3, "gen/p4sweep_id_m64t3_init.hex", "gen/p4sweep_id_m64t3_exp.hex", "argon2id m64 t3");
        run_job(2'd1, 128, 1, "gen/p4sweep_i_m128t1_init.hex",  "gen/p4sweep_i_m128t1_exp.hex",  "argon2i m128 t1");
        run_job(2'd1, 128, 3, "gen/p4sweep_i_m128t3_init.hex",  "gen/p4sweep_i_m128t3_exp.hex",  "argon2i m128 t3");
        run_job(2'd0, 128, 1, "gen/p4sweep_d_m128t1_init.hex",  "gen/p4sweep_d_m128t1_exp.hex",  "argon2d m128 t1");
        run_job(2'd0, 128, 3, "gen/p4sweep_d_m128t3_init.hex",  "gen/p4sweep_d_m128t3_exp.hex",  "argon2d m128 t3");
        run_job(2'd2, 128, 1, "gen/p4sweep_id_m128t1_init.hex", "gen/p4sweep_id_m128t1_exp.hex", "argon2id m128 t1");
        run_job(2'd2, 128, 3, "gen/p4sweep_id_m128t3_init.hex", "gen/p4sweep_id_m128t3_exp.hex", "argon2id m128 t3");
        run_job(2'd2, 48, 2, "gen/p4sweep_id_m48t2_init.hex", "gen/p4sweep_id_m48t2_exp.hex", "argon2id m48 t2 (non-pow2)");

        if (errors == 0) begin
            $display("tb_argon2_p4 PASS");
            $finish;
        end else begin
            $display("tb_argon2_p4 FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
