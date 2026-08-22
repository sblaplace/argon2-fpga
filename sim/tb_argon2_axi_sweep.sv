// SPDX-License-Identifier: MIT
// Geometry-sweep known-answer fill through the full AXI stack.
//
// The original KATs all run at m'=8 (lane_length 8, segment_length 2) — a
// geometry in which several scheduling paths are structurally unreachable
// (the dependent early-ref reference area is identical for the same_lane and
// !same_lane mappings when index <= 1, and the write-FIFO RAW window never
// overlaps a short-enough reference distance). Two latent bugs hid there:
//
//   * the early dependent ref computed its reference area with same_lane
//     unconnected (always the !same_lane formula) — wrong for every
//     p=1 geometry with segment_length > 2;
//   * a prefetched reference to a recently written block could read memory
//     before the block's write committed (the wb-hit check was masked by a
//     cache hit that nothing ever forwarded from).
//
// This bench sweeps m' in {16, 32, 64, 128} × t in {1, 2, 3} × type i/d/id
// against ref/-generated vectors, exercising early-dep areas, write-FIFO
// RAW distances, cross-segment early dest reads and multi-window addressing
// at every scale. Vectors: gen/sweep_* from tests/dump_vectors.py.
`timescale 1ns / 1ps

module tb_argon2_axi_sweep #(
    parameter int N_P = 1
);
    localparam int NBLK   = 128;   // largest geometry in the sweep
    localparam int NBEAT  = 16;
    localparam int ADDR_W = 64;
    localparam int ID_W   = 6;
    localparam int DATA_W = 512;

    logic        clk, rst_n, start, busy, done, sync_req;
    logic [31:0] passes, lanes, lane_id, lane_length, memory_blocks;
    logic [1:0]  type_i;

    logic [ID_W-1:0]     awid, arid, bid, rid;
    logic [ADDR_W-1:0]   awaddr, araddr;
    logic [7:0]          awlen, arlen;
    logic [2:0]          awsize, arsize, awprot, arprot;
    logic [1:0]          awburst, arburst, bresp, rresp;
    logic                awlock, arlock;
    logic [3:0]          awcache, arcache, awqos, arqos;
    logic                awvalid, awready, wvalid, wready, wlast;
    logic                bvalid, bready, arvalid, arready;
    logic                rvalid, rready, rlast;
    logic [DATA_W-1:0]   wdata, rdata;
    logic [DATA_W/8-1:0] wstrb;

    argon2_fill_axi #(
        .AXI_ADDR_W(ADDR_W), .AXI_ID_W(ID_W), .AXI_DATA_W(DATA_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .passes(passes), .lanes(lanes), .lane_id(lane_id),
        .lane_length(lane_length), .memory_blocks(memory_blocks),
        .type_i(type_i), .sync_req(sync_req), .sync_ack(1'b1),
        .base_addr(64'd0),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awlock(awlock), .m_axi_awcache(awcache),
        .m_axi_awprot(awprot), .m_axi_awqos(awqos),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb), .m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arlock(arlock), .m_axi_arcache(arcache),
        .m_axi_arprot(arprot), .m_axi_arqos(arqos),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    tb_axi_ram #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .NBLK(NBLK), .RD_LAT(12)
    ) ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(awsize), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wlast(wlast), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );

    always #5 clk = ~clk;

    logic [511:0] exp [0:NBLK*NBEAT-1];

    integer errors, cycles, i;

    task automatic run_job(
        input [1:0] typ, input int nblk, input int npass,
        input string init_f, input string exp_f, input string name
    );
        integer mismatches, first_bad;
        $display("sweep %s", name);
        rst_n = 1'b0;
        start = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        $readmemh(init_f, ram.mem);
        $readmemh(exp_f, exp);
        type_i = typ;
        passes = npass;
        lane_length = nblk;
        memory_blocks = nblk;
        start  = 1'b1;
        @(posedge clk);
        start  = 1'b0;

        cycles = 0;
        while (!done && cycles < 4000000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!done) begin
            $display("FAIL %s timeout", name);
            errors = errors + 1;
        end else begin
            // Drain a pending B after the last WLAST.
            repeat (8) @(posedge clk);
            mismatches = 0;
            first_bad = -1;
            for (i = 0; i < nblk * NBEAT; i = i + 1) begin
                if (ram.mem[i] !== exp[i]) begin
                    if (first_bad < 0) first_bad = i;
                    mismatches = mismatches + 1;
                end
            end
            if (mismatches != 0) begin
                $display("  %-12s FAIL %0d beats differ, first at block %0d beat %0d (%0d cyc)",
                         name, mismatches, first_bad/NBEAT, first_bad%NBEAT, cycles);
                errors = errors + 1;
            end else begin
                $display("  %-12s PASS (%0d cyc)", name, cycles);
            end
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        passes = 32'd3;
        lanes = 32'd1;
        lane_id = 32'd0;
        lane_length = 32'd128;
        memory_blocks = 32'd128;
        type_i = 2'd1;
        errors = 0;
        repeat (6) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        run_job(2'd0, 16, 1, "gen/sweep_d_m16t1_init.hex",  "gen/sweep_d_m16t1_exp.hex",  "d m16 t1");
        run_job(2'd2, 16, 1, "gen/sweep_id_m16t1_init.hex", "gen/sweep_id_m16t1_exp.hex", "id m16 t1");
        run_job(2'd0, 16, 2, "gen/sweep_d_m16t2_init.hex",  "gen/sweep_d_m16t2_exp.hex",  "d m16 t2");
        run_job(2'd2, 16, 2, "gen/sweep_id_m16t2_init.hex", "gen/sweep_id_m16t2_exp.hex", "id m16 t2");
        run_job(2'd1, 16, 3, "gen/sweep_i_m16t3_init.hex",  "gen/sweep_i_m16t3_exp.hex",  "i m16 t3");
        run_job(2'd0, 16, 3, "gen/sweep_d_m16t3_init.hex",  "gen/sweep_d_m16t3_exp.hex",  "d m16 t3");
        run_job(2'd2, 16, 3, "gen/sweep_id_m16t3_init.hex", "gen/sweep_id_m16t3_exp.hex", "id m16 t3");
        run_job(2'd1, 32, 3, "gen/sweep_i_m32t3_init.hex",  "gen/sweep_i_m32t3_exp.hex",  "i m32 t3");
        run_job(2'd0, 32, 3, "gen/sweep_d_m32t3_init.hex",  "gen/sweep_d_m32t3_exp.hex",  "d m32 t3");
        run_job(2'd1, 64, 3, "gen/sweep_i_m64t3_init.hex",  "gen/sweep_i_m64t3_exp.hex",  "i m64 t3");
        run_job(2'd0, 64, 3, "gen/sweep_d_m64t3_init.hex",  "gen/sweep_d_m64t3_exp.hex",  "d m64 t3");
        run_job(2'd1, 128, 3, "gen/sweep_i_m128t3_init.hex", "gen/sweep_i_m128t3_exp.hex", "i m128 t3");
        run_job(2'd0, 128, 3, "gen/sweep_d_m128t3_init.hex", "gen/sweep_d_m128t3_exp.hex", "d m128 t3");
        run_job(2'd2, 128, 3, "gen/sweep_id_m128t3_init.hex", "gen/sweep_id_m128t3_exp.hex", "id m128 t3");

        if (errors == 0) begin
            $display("tb_argon2_axi_sweep PASS");
            $finish;
        end else begin
            $display("tb_argon2_axi_sweep FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
