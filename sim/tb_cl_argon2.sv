// SPDX-License-Identifier: MIT
// Top-level bench for the F1 CL (cl_argon2).
//
// Four argon2_fill_axi cores sit behind the OCL register slave and four
// AXI4 DDR ports. This bench wires each DDR port to a behavioral
// tb_axi_ram, drives the OCL from a tiny BFM, and runs a known-answer
// argon2i job (m=8 KiB, t=2, password/somesalt) on all four channels in
// independent p=1 mode. Each channel's final working set is compared
// against the RFC-golden vector (gen/fill_i_exp.hex).
//
// Build/run:  make vectors && make cl        (iverilog)
//             make vectors && make SIM=verilator cl

`timescale 1ns / 1ps

`include "cl_argon2_axi_if.sv"

module tb_cl_argon2 #(
    parameter int N_P = 1   // parallel P units in the compression G
);
    localparam int NUM_DDR = 4;
    localparam int NBLK   = 8;
    localparam int NBEAT  = 16;
    localparam int NW     = NBLK * NBEAT;   // words (beats) per channel
    localparam int ADDR_W = 64;
    localparam int ID_W   = 6;
    localparam int DATA_W = 512;

    // ---- clock / reset --------------------------------------------------
    logic        clk;
    logic [15:0] rst_main_n;
    logic        sh_cl_flr_assert;
    logic        rst_n;
    assign rst_n = &rst_main_n;

    always #5 clk = ~clk;

    // ---- OCL AXI4-lite slave signals (BFM <-> CL) ----------------------
    logic        sh_ocl_awvalid;
    logic [31:0] sh_ocl_awaddr;
    logic [15:0] sh_ocl_awid;
    logic        sh_ocl_wvalid;
    logic [31:0] sh_ocl_wdata;
    logic [15:0] sh_ocl_wstrb;
    logic        sh_ocl_awready;
    logic        sh_ocl_wready;
    logic [15:0] sh_ocl_bid;
    logic [1:0]  sh_ocl_bresp;
    logic        sh_ocl_bvalid;
    logic        sh_ocl_bready;
    logic        sh_ocl_arvalid;
    logic [31:0] sh_ocl_araddr;
    logic [15:0] sh_ocl_arid;
    logic        sh_ocl_arready;
    logic [15:0] sh_ocl_rid;
    logic [31:0] sh_ocl_rdata;
    logic [1:0]  sh_ocl_rresp;
    logic        sh_ocl_rlast;
    logic        sh_ocl_rvalid;
    logic        sh_ocl_rready;

    // ---- shell tie-offs -------------------------------------------------
    logic [15:0] sh_cl_peek_req;
    wire  [15:0] cl_sh_peek_ack;
    wire  [31:0] cl_sh_peek_data;
    logic [15:0] sh_cl_ddr_stat_id;
    logic        sh_cl_ddr_stat_wr;
    logic [31:0] sh_cl_ddr_stat_rd;
    logic        sh_cl_ddr_stat_cs;
    logic [7:0]  sh_cl_ddr_stat_addr;
    wire  [3:0]  cl_sh_ddr_areset_n;

    // ---- four DDR AXI4 master buses ------------------------------------
    axi_bus_t ddr0 (), ddr1 (), ddr2 (), ddr3 ();

    // ---- DUT ------------------------------------------------------------
    cl_argon2 #(.N_P(N_P)) dut (
        .clk_main_a0      (clk),
        .rst_main_n       (rst_main_n),
        .sh_cl_flr_assert (sh_cl_flr_assert),
        .sh_cl_peek_req   (sh_cl_peek_req),
        .cl_sh_peek_ack   (cl_sh_peek_ack),
        .cl_sh_peek_data  (cl_sh_peek_data),
        .sh_cl_ddr_stat_id  (sh_cl_ddr_stat_id),
        .sh_cl_ddr_stat_wr  (sh_cl_ddr_stat_wr),
        .sh_cl_ddr_stat_rd  (sh_cl_ddr_stat_rd),
        .sh_cl_ddr_stat_cs  (sh_cl_ddr_stat_cs),
        .sh_cl_ddr_stat_addr(sh_cl_ddr_stat_addr),
        .cl_sh_ddr_areset_n(cl_sh_ddr_areset_n),
        .DDR0_AXI(ddr0), .DDR1_AXI(ddr1), .DDR2_AXI(ddr2), .DDR3_AXI(ddr3),
        .sh_ocl_awvalid(sh_ocl_awvalid), .sh_ocl_awaddr(sh_ocl_awaddr),
        .sh_ocl_awid   (sh_ocl_awid),
        .sh_ocl_wvalid (sh_ocl_wvalid),  .sh_ocl_wdata (sh_ocl_wdata),
        .sh_ocl_wstrb  (sh_ocl_wstrb),
        .sh_ocl_awready(sh_ocl_awready), .sh_ocl_wready(sh_ocl_wready),
        .sh_ocl_bid    (sh_ocl_bid),     .sh_ocl_bresp (sh_ocl_bresp),
        .sh_ocl_bvalid (sh_ocl_bvalid),  .sh_ocl_bready(sh_ocl_bready),
        .sh_ocl_arvalid(sh_ocl_arvalid), .sh_ocl_araddr(sh_ocl_araddr),
        .sh_ocl_arid   (sh_ocl_arid),
        .sh_ocl_arready(sh_ocl_arready), .sh_ocl_rid   (sh_ocl_rid),
        .sh_ocl_rdata  (sh_ocl_rdata),   .sh_ocl_rresp (sh_ocl_rresp),
        .sh_ocl_rlast  (sh_ocl_rlast),   .sh_ocl_rvalid(sh_ocl_rvalid),
        .sh_ocl_rready (sh_ocl_rready)
    );

    // ---- four behavioral DDR RAMs --------------------------------------
    tb_axi_ram #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
                 .NBLK(NBLK), .RD_LAT(12)) ram0 (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(ddr0.awid), .s_axi_awaddr(ddr0.awaddr), .s_axi_awlen(ddr0.awlen),
        .s_axi_awsize(ddr0.awsize), .s_axi_awvalid(ddr0.awvalid), .s_axi_awready(ddr0.awready),
        .s_axi_wdata(ddr0.wdata), .s_axi_wstrb(ddr0.wstrb), .s_axi_wlast(ddr0.wlast),
        .s_axi_wvalid(ddr0.wvalid), .s_axi_wready(ddr0.wready),
        .s_axi_bid(ddr0.bid), .s_axi_bresp(ddr0.bresp), .s_axi_bvalid(ddr0.bvalid), .s_axi_bready(ddr0.bready),
        .s_axi_arid(ddr0.arid), .s_axi_araddr(ddr0.araddr), .s_axi_arlen(ddr0.arlen),
        .s_axi_arvalid(ddr0.arvalid), .s_axi_arready(ddr0.arready),
        .s_axi_rid(ddr0.rid), .s_axi_rdata(ddr0.rdata), .s_axi_rresp(ddr0.rresp),
        .s_axi_rlast(ddr0.rlast), .s_axi_rvalid(ddr0.rvalid), .s_axi_rready(ddr0.rready)
    );
    tb_axi_ram #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
                 .NBLK(NBLK), .RD_LAT(12)) ram1 (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(ddr1.awid), .s_axi_awaddr(ddr1.awaddr), .s_axi_awlen(ddr1.awlen),
        .s_axi_awsize(ddr1.awsize), .s_axi_awvalid(ddr1.awvalid), .s_axi_awready(ddr1.awready),
        .s_axi_wdata(ddr1.wdata), .s_axi_wstrb(ddr1.wstrb), .s_axi_wlast(ddr1.wlast),
        .s_axi_wvalid(ddr1.wvalid), .s_axi_wready(ddr1.wready),
        .s_axi_bid(ddr1.bid), .s_axi_bresp(ddr1.bresp), .s_axi_bvalid(ddr1.bvalid), .s_axi_bready(ddr1.bready),
        .s_axi_arid(ddr1.arid), .s_axi_araddr(ddr1.araddr), .s_axi_arlen(ddr1.arlen),
        .s_axi_arvalid(ddr1.arvalid), .s_axi_arready(ddr1.arready),
        .s_axi_rid(ddr1.rid), .s_axi_rdata(ddr1.rdata), .s_axi_rresp(ddr1.rresp),
        .s_axi_rlast(ddr1.rlast), .s_axi_rvalid(ddr1.rvalid), .s_axi_rready(ddr1.rready)
    );
    tb_axi_ram #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
                 .NBLK(NBLK), .RD_LAT(12)) ram2 (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(ddr2.awid), .s_axi_awaddr(ddr2.awaddr), .s_axi_awlen(ddr2.awlen),
        .s_axi_awsize(ddr2.awsize), .s_axi_awvalid(ddr2.awvalid), .s_axi_awready(ddr2.awready),
        .s_axi_wdata(ddr2.wdata), .s_axi_wstrb(ddr2.wstrb), .s_axi_wlast(ddr2.wlast),
        .s_axi_wvalid(ddr2.wvalid), .s_axi_wready(ddr2.wready),
        .s_axi_bid(ddr2.bid), .s_axi_bresp(ddr2.bresp), .s_axi_bvalid(ddr2.bvalid), .s_axi_bready(ddr2.bready),
        .s_axi_arid(ddr2.arid), .s_axi_araddr(ddr2.araddr), .s_axi_arlen(ddr2.arlen),
        .s_axi_arvalid(ddr2.arvalid), .s_axi_arready(ddr2.arready),
        .s_axi_rid(ddr2.rid), .s_axi_rdata(ddr2.rdata), .s_axi_rresp(ddr2.rresp),
        .s_axi_rlast(ddr2.rlast), .s_axi_rvalid(ddr2.rvalid), .s_axi_rready(ddr2.rready)
    );
    tb_axi_ram #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
                 .NBLK(NBLK), .RD_LAT(12)) ram3 (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(ddr3.awid), .s_axi_awaddr(ddr3.awaddr), .s_axi_awlen(ddr3.awlen),
        .s_axi_awsize(ddr3.awsize), .s_axi_awvalid(ddr3.awvalid), .s_axi_awready(ddr3.awready),
        .s_axi_wdata(ddr3.wdata), .s_axi_wstrb(ddr3.wstrb), .s_axi_wlast(ddr3.wlast),
        .s_axi_wvalid(ddr3.wvalid), .s_axi_wready(ddr3.wready),
        .s_axi_bid(ddr3.bid), .s_axi_bresp(ddr3.bresp), .s_axi_bvalid(ddr3.bvalid), .s_axi_bready(ddr3.bready),
        .s_axi_arid(ddr3.arid), .s_axi_araddr(ddr3.araddr), .s_axi_arlen(ddr3.arlen),
        .s_axi_arvalid(ddr3.arvalid), .s_axi_arready(ddr3.arready),
        .s_axi_rid(ddr3.rid), .s_axi_rdata(ddr3.rdata), .s_axi_rresp(ddr3.rresp),
        .s_axi_rlast(ddr3.rlast), .s_axi_rvalid(ddr3.rvalid), .s_axi_rready(ddr3.rready)
    );

    // ---- OCL BFM --------------------------------------------------------
    task automatic ocl_write(input [31:0] addr, input [31:0] data);
        fork
            begin
                sh_ocl_awvalid = 1'b1; sh_ocl_awaddr = addr; sh_ocl_awid = 16'd0;
                while (!(sh_ocl_awvalid && sh_ocl_awready)) @(posedge clk);
                @(posedge clk); sh_ocl_awvalid = 1'b0;
            end
            begin
                sh_ocl_wvalid = 1'b1; sh_ocl_wdata = data; sh_ocl_wstrb = 16'hFFFF;
                while (!(sh_ocl_wvalid && sh_ocl_wready)) @(posedge clk);
                @(posedge clk); sh_ocl_wvalid = 1'b0;
            end
        join
        while (!sh_ocl_bvalid) @(posedge clk);
        sh_ocl_bready = 1'b1; @(posedge clk); sh_ocl_bready = 1'b0;
    endtask

    task automatic ocl_read(input [31:0] addr, output [31:0] data);
        sh_ocl_arvalid = 1'b1; sh_ocl_araddr = addr; sh_ocl_arid = 16'd0;
        while (!(sh_ocl_arvalid && sh_ocl_arready)) @(posedge clk);
        @(posedge clk); sh_ocl_arvalid = 1'b0;
        while (!sh_ocl_rvalid) @(posedge clk);
        data = sh_ocl_rdata;
        sh_ocl_rready = 1'b1; @(posedge clk); sh_ocl_rready = 1'b0;
    endtask

    // ---- test -----------------------------------------------------------
    logic [511:0] exp [0:NW-1];
    integer errors;
    integer to;
    logic [31:0] st;
    logic [3:0]  done;

    task automatic check_ram(input [511:0] mem [0:NW-1], input string name);
        int m;
        m = 0;
        for (int i = 0; i < NW; i = i + 1)
            if (mem[i] !== exp[i]) begin
                if (m < 4)
                    $display("FAIL %s beat %0d got %0128h exp %0128h",
                             name, i, mem[i], exp[i]);
                m = m + 1;
            end
        if (m != 0) begin
            $display("FAIL %s %0d beat(s) differ", name, m);
            errors = errors + 1;
        end else
            $display("PASS %s", name);
    endtask

    initial begin
        errors = 0;
        clk = 1'b0;
        rst_main_n = 16'd0;
        sh_cl_flr_assert = 1'b0;
        sh_cl_peek_req = 16'd0;
        sh_cl_ddr_stat_id = 16'd0; sh_cl_ddr_stat_wr = 1'b0;
        sh_cl_ddr_stat_rd = 32'd0; sh_cl_ddr_stat_cs = 1'b0; sh_cl_ddr_stat_addr = 8'd0;
        sh_ocl_awvalid = 1'b0; sh_ocl_wvalid = 1'b0; sh_ocl_bready = 1'b0;
        sh_ocl_arvalid = 1'b0; sh_ocl_rready = 1'b0; sh_ocl_awid = 16'd0;

        repeat (5) @(posedge clk);
        rst_main_n = 16'hFFFF;
        @(posedge clk);

        $readmemh("gen/fill_i_init.hex", ram0.mem);
        $readmemh("gen/fill_i_init.hex", ram1.mem);
        $readmemh("gen/fill_i_init.hex", ram2.mem);
        $readmemh("gen/fill_i_init.hex", ram3.mem);
        $readmemh("gen/fill_i_exp.hex",  exp);

        // Program all four lanes for an independent p=1 argon2i job.
        // p4_mode = 0 (CONTROL left at 0). Byte addresses use the
        // (16 + L*8 + off)*4 mapping from fpga/f1/README.md.
        for (int L = 0; L < NUM_DDR; L = L + 1) begin
            logic [31:0] base;
            base = 32'h40 + (32'(L) * 32'h20);
            ocl_write(base + 32'h00, 32'h0001); // LANE_CTRL: type_i=1, lanes=1
            ocl_write(base + 32'h04, 32'd2);    // PASSES = t = 2
            ocl_write(base + 32'h08, 32'd8);    // LANE_LENGTH = q = 8
            ocl_write(base + 32'h0C, 32'd8);    // MEMORY_BLKS = m' = 8
            ocl_write(base + 32'h10, 32'd0);    // BASE_LO
            ocl_write(base + 32'h14, 32'd0);    // BASE_HI
        end

        // Kick all lanes simultaneously.
        ocl_write(32'h00, 32'd1);

        // Poll STATUS until all four report done.
        done = 4'b0; to = 0;
        while (done != 4'b1111 && to < 2000000) begin
            ocl_read(32'h08, st);
            done = st[7:4];
            to = to + 1;
        end

        if (done != 4'b1111) begin
            $display("FAIL timeout (STATUS=0x%08h, polls=%0d)", st, to);
            errors = errors + 1;
        end else begin
            $display("all four lanes done in %0d OCL polls", to);
        end

        check_ram(ram0.mem, "lane0");
        check_ram(ram1.mem, "lane1");
        check_ram(ram2.mem, "lane2");
        check_ram(ram3.mem, "lane3");

        if (errors == 0)
            $display("tb_cl_argon2: PASS");
        else
            $display("tb_cl_argon2: FAIL (%0d)", errors);
        $finish;
    end
endmodule
