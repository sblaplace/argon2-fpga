// SPDX-License-Identifier: MIT
// F1 CL top for argon2-fpga.
//
// Drop-in replacement for the HDK `cl_dram_dma` example top. It presents
// the standard F1 shell interface:
//   * clk_main_a0 / rst_main_n  -- main 250 MHz clock and reset
//   * four DDR AXI4 master buses (DDR0_AXI .. DDR3_AXI, type axi_bus_t)
//   * the OCL AXI4-lite slave (sh_ocl_*) used to program jobs
//   * FLR / peek / DDR-stat tie-offs
//
// The functional logic lives in cl_argon2_core (HDK-independent); this
// file only adapts the shell buses onto it.
//
// NOTE ON THE DDR BUS TYPE: this file uses the local `axi_bus_t` defined
// in cl_argon2_axi_if.sv. For a real HDK build, define `AXI_BUS_T_DEFINED`
// (or `include` your HDK's cl_dram_dma_pkg.sv / axi_bus_defines.vh FIRST)
// so the shell's exact `axi_bus_t` is shared by this top and the connect
// adapter. If your HDK release adds signals the example doesn't (e.g. an
// OCL awlen/awsize, or DDR awregion), add them to the port list and tie
// them off -- diff against your HDK's cl_ports.vh / example top.

`timescale 1ns / 1ps

`include "cl_argon2_defines.vh"
`include "cl_argon2_axi_if.sv"

module cl_argon2 (
    // ---- clock / reset -------------------------------------------------
    input        clk_main_a0,
    input [15:0] rst_main_n,

    // ---- function-level reset (FLR) -----------------------------------
    input        sh_cl_flr_assert,

    // ---- shell->CL peek (optional, tied off) --------------------------
    input [15:0] sh_cl_peek_req,
    output [15:0] cl_sh_peek_ack,
    output [31:0] cl_sh_peek_data,

    // ---- DDR statistics from shell (optional, tied off) ---------------
    input [15:0] sh_cl_ddr_stat_id,
    input        sh_cl_ddr_stat_wr,
    input [31:0] sh_cl_ddr_stat_rd,
    input        sh_cl_ddr_stat_cs,
    input [7:0]  sh_cl_ddr_stat_addr,

    // ---- release DDR controller reset ---------------------------------
    output [3:0] cl_sh_ddr_areset_n,

    // ---- four DDR AXI4 master buses ----------------------------------
    axi_bus_t DDR0_AXI,
    axi_bus_t DDR1_AXI,
    axi_bus_t DDR2_AXI,
    axi_bus_t DDR3_AXI,

    // ---- OCL AXI4-lite slave (sh_ocl_*) -------------------------------
    input         sh_ocl_awvalid,
    input [31:0]  sh_ocl_awaddr,
    input [15:0]  sh_ocl_awid,
    input         sh_ocl_wvalid,
    input [31:0]  sh_ocl_wdata,
    input [15:0]  sh_ocl_wstrb,
    input         sh_ocl_bready,
    input         sh_ocl_arvalid,
    input [31:0]  sh_ocl_araddr,
    input [15:0]  sh_ocl_arid,
    input         sh_ocl_rready,
    output        sh_ocl_awready,
    output        sh_ocl_wready,
    output [15:0] sh_ocl_bid,
    output [1:0]  sh_ocl_bresp,
    output        sh_ocl_bvalid,
    output        sh_ocl_arready,
    output [15:0] sh_ocl_rid,
    output [31:0] sh_ocl_rdata,
    output [1:0]  sh_ocl_rresp,
    output        sh_ocl_rlast,
    output        sh_ocl_rvalid
);

    localparam int NUM_DDR = `A2_NUM_DDR;

    // Reset for the argon2 logic: main reset ANDed with FLR.
    logic rst_n;
    assign rst_n = &rst_main_n & ~sh_cl_flr_assert;

    // Release the DDR controllers (active-low).
    assign cl_sh_ddr_areset_n = {NUM_DDR{1'b1}};

    // Peek is unused in this CL.
    assign cl_sh_peek_ack  = 16'd0;
    assign cl_sh_peek_data = 32'd0;

    // ---- Flat AXI4 master signals between core and the DDR adapters --
    logic [NUM_DDR-1:0]        m_awvalid, m_awready, m_wvalid, m_wlast, m_wready;
    logic [NUM_DDR-1:0]        m_bready, m_bvalid, m_arvalid, m_arready;
    logic [NUM_DDR-1:0]        m_rvalid, m_rlast, m_rready;
    logic [NUM_DDR-1:0][`A2_AXI_ADDR_W-1:0]  m_awaddr, m_araddr;
    logic [NUM_DDR-1:0][`A2_AXI_DATA_W-1:0]  m_wdata, m_rdata;
    logic [NUM_DDR-1:0][7:0]   m_awlen, m_arlen;
    logic [NUM_DDR-1:0][2:0]   m_awsize, m_arsize;
    logic [NUM_DDR-1:0][1:0]   m_awburst, m_arburst;
    logic [NUM_DDR-1:0]        m_awlock, m_arlock;
    logic [NUM_DDR-1:0][3:0]   m_awcache, m_arcache, m_awqos, m_arqos;
    logic [NUM_DDR-1:0][2:0]   m_awprot, m_arprot;
    logic [NUM_DDR-1:0][`A2_AXI_ID_W-1:0] m_awid, m_arid, m_bid, m_rid;
    logic [NUM_DDR-1:0][1:0]   m_bresp, m_rresp;
    logic [NUM_DDR-1:0][`A2_AXI_DATA_W/8-1:0] m_wstrb;

    // ---- DDR bus adapters (shell axi_bus_t -> flat master) -----------
    cl_argon2_ddr_connect u_ddr0 (.ddr(DDR0_AXI),
        .awvalid(m_awvalid[0]), .awaddr(m_awaddr[0]), .awlen(m_awlen[0]),
        .awsize(m_awsize[0]), .awburst(m_awburst[0]), .awlock(m_awlock[0]),
        .awcache(m_awcache[0]), .awprot(m_awprot[0]), .awqos(m_awqos[0]),
        .awid(m_awid[0]), .wdata(m_wdata[0]), .wstrb(m_wstrb[0]), .wlast(m_wlast[0]),
        .wvalid(m_wvalid[0]), .bready(m_bready[0]), .araddr(m_araddr[0]),
        .arlen(m_arlen[0]), .arsize(m_arsize[0]), .arburst(m_arburst[0]),
        .arlock(m_arlock[0]), .arcache(m_arcache[0]), .arprot(m_arprot[0]),
        .arqos(m_arqos[0]), .arid(m_arid[0]), .arvalid(m_arvalid[0]), .rready(m_rready[0]),
        .awready(m_awready[0]), .wready(m_wready[0]), .bvalid(m_bvalid[0]),
        .bid(m_bid[0]), .bresp(m_bresp[0]), .arready(m_arready[0]),
        .rvalid(m_rvalid[0]), .rid(m_rid[0]), .rdata(m_rdata[0]),
        .rresp(m_rresp[0]), .rlast(m_rlast[0]));

    cl_argon2_ddr_connect u_ddr1 (.ddr(DDR1_AXI),
        .awvalid(m_awvalid[1]), .awaddr(m_awaddr[1]), .awlen(m_awlen[1]),
        .awsize(m_awsize[1]), .awburst(m_awburst[1]), .awlock(m_awlock[1]),
        .awcache(m_awcache[1]), .awprot(m_awprot[1]), .awqos(m_awqos[1]),
        .awid(m_awid[1]), .wdata(m_wdata[1]), .wstrb(m_wstrb[1]), .wlast(m_wlast[1]),
        .wvalid(m_wvalid[1]), .bready(m_bready[1]), .araddr(m_araddr[1]),
        .arlen(m_arlen[1]), .arsize(m_arsize[1]), .arburst(m_arburst[1]),
        .arlock(m_arlock[1]), .arcache(m_arcache[1]), .arprot(m_arprot[1]),
        .arqos(m_arqos[1]), .arid(m_arid[1]), .arvalid(m_arvalid[1]), .rready(m_rready[1]),
        .awready(m_awready[1]), .wready(m_wready[1]), .bvalid(m_bvalid[1]),
        .bid(m_bid[1]), .bresp(m_bresp[1]), .arready(m_arready[1]),
        .rvalid(m_rvalid[1]), .rid(m_rid[1]), .rdata(m_rdata[1]),
        .rresp(m_rresp[1]), .rlast(m_rlast[1]));

    cl_argon2_ddr_connect u_ddr2 (.ddr(DDR2_AXI),
        .awvalid(m_awvalid[2]), .awaddr(m_awaddr[2]), .awlen(m_awlen[2]),
        .awsize(m_awsize[2]), .awburst(m_awburst[2]), .awlock(m_awlock[2]),
        .awcache(m_awcache[2]), .awprot(m_awprot[2]), .awqos(m_awqos[2]),
        .awid(m_awid[2]), .wdata(m_wdata[2]), .wstrb(m_wstrb[2]), .wlast(m_wlast[2]),
        .wvalid(m_wvalid[2]), .bready(m_bready[2]), .araddr(m_araddr[2]),
        .arlen(m_arlen[2]), .arsize(m_arsize[2]), .arburst(m_arburst[2]),
        .arlock(m_arlock[2]), .arcache(m_arcache[2]), .arprot(m_arprot[2]),
        .arqos(m_arqos[2]), .arid(m_arid[2]), .arvalid(m_arvalid[2]), .rready(m_rready[2]),
        .awready(m_awready[2]), .wready(m_wready[2]), .bvalid(m_bvalid[2]),
        .bid(m_bid[2]), .bresp(m_bresp[2]), .arready(m_arready[2]),
        .rvalid(m_rvalid[2]), .rid(m_rid[2]), .rdata(m_rdata[2]),
        .rresp(m_rresp[2]), .rlast(m_rlast[2]));

    cl_argon2_ddr_connect u_ddr3 (.ddr(DDR3_AXI),
        .awvalid(m_awvalid[3]), .awaddr(m_awaddr[3]), .awlen(m_awlen[3]),
        .awsize(m_awsize[3]), .awburst(m_awburst[3]), .awlock(m_awlock[3]),
        .awcache(m_awcache[3]), .awprot(m_awprot[3]), .awqos(m_awqos[3]),
        .awid(m_awid[3]), .wdata(m_wdata[3]), .wstrb(m_wstrb[3]), .wlast(m_wlast[3]),
        .wvalid(m_wvalid[3]), .bready(m_bready[3]), .araddr(m_araddr[3]),
        .arlen(m_arlen[3]), .arsize(m_arsize[3]), .arburst(m_arburst[3]),
        .arlock(m_arlock[3]), .arcache(m_arcache[3]), .arprot(m_arprot[3]),
        .arqos(m_arqos[3]), .arid(m_arid[3]), .arvalid(m_arvalid[3]), .rready(m_rready[3]),
        .awready(m_awready[3]), .wready(m_wready[3]), .bvalid(m_bvalid[3]),
        .bid(m_bid[3]), .bresp(m_bresp[3]), .arready(m_arready[3]),
        .rvalid(m_rvalid[3]), .rid(m_rid[3]), .rdata(m_rdata[3]),
        .rresp(m_rresp[3]), .rlast(m_rlast[3]));

    // ---- Functional core ----------------------------------------------
    cl_argon2_core #(.NUM_DDR(NUM_DDR)) u_core (
        .clk        (clk_main_a0),
        .rst_n      (rst_n),

        .ocl_awvalid(sh_ocl_awvalid), .ocl_awaddr(sh_ocl_awaddr), .ocl_awid(sh_ocl_awid),
        .ocl_wvalid (sh_ocl_wvalid),  .ocl_wdata (sh_ocl_wdata),  .ocl_wstrb(sh_ocl_wstrb),
        .ocl_awready(sh_ocl_awready), .ocl_wready(sh_ocl_wready), .ocl_bid(sh_ocl_bid),
        .ocl_bresp  (sh_ocl_bresp),   .ocl_bvalid(sh_ocl_bvalid), .ocl_bready(sh_ocl_bready),
        .ocl_arvalid(sh_ocl_arvalid), .ocl_araddr(sh_ocl_araddr), .ocl_arid(sh_ocl_arid),
        .ocl_arready(sh_ocl_arready), .ocl_rid(sh_ocl_rid), .ocl_rdata(sh_ocl_rdata),
        .ocl_rresp  (sh_ocl_rresp),   .ocl_rlast (sh_ocl_rlast),  .ocl_rvalid(sh_ocl_rvalid),
        .ocl_rready (sh_ocl_rready),

        .m_ddr_awvalid(m_awvalid), .m_ddr_awaddr(m_awaddr), .m_ddr_awlen(m_awlen),
        .m_ddr_awsize(m_awsize), .m_ddr_awburst(m_awburst), .m_ddr_awlock(m_awlock),
        .m_ddr_awcache(m_awcache), .m_ddr_awprot(m_awprot), .m_ddr_awqos(m_awqos),
        .m_ddr_awid(m_awid), .m_ddr_wdata(m_wdata), .m_ddr_wstrb(m_wstrb),
        .m_ddr_wlast(m_wlast), .m_ddr_wvalid(m_wvalid), .m_ddr_bready(m_bready),
        .m_ddr_araddr(m_araddr), .m_ddr_arlen(m_arlen), .m_ddr_arsize(m_arsize),
        .m_ddr_arburst(m_arburst), .m_ddr_arlock(m_arlock), .m_ddr_arcache(m_arcache),
        .m_ddr_arprot(m_arprot), .m_ddr_arqos(m_arqos), .m_ddr_arid(m_arid),
        .m_ddr_arvalid(m_arvalid), .m_ddr_rready(m_rready),
        .m_ddr_awready(m_awready), .m_ddr_wready(m_wready), .m_ddr_bvalid(m_bvalid),
        .m_ddr_bid(m_bid), .m_ddr_bresp(m_bresp), .m_ddr_arready(m_arready),
        .m_ddr_rvalid(m_rvalid), .m_ddr_rid(m_rid), .m_ddr_rdata(m_rdata),
        .m_ddr_rresp(m_rresp), .m_ddr_rlast(m_rlast)
    );

endmodule
