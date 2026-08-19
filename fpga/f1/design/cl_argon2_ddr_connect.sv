// SPDX-License-Identifier: MIT
// Adapter from one F1 DDR `axi_bus_t` (the shell bus) to the flat AXI4
// master signals of cl_argon2_core. Keeps cl_argon2_core HDK-free.
//
// The core drives the *-valid/address/write members and samples the
// *-ready/response members; this module forwards them onto the shell
// bus. No buffering -- it is a pure wire adapter.

`timescale 1ns / 1ps

`include "cl_argon2_axi_if.sv"

module cl_argon2_ddr_connect (
    axi_bus_t            ddr,

    // core master outputs (drive the DDR)
    input  logic        awvalid,
    input  logic [63:0] awaddr,
    input  logic [7:0]  awlen,
    input  logic [2:0]  awsize,
    input  logic [1:0]  awburst,
    input  logic        awlock,
    input  logic [3:0]  awcache,
    input  logic [2:0]  awprot,
    input  logic [3:0]  awqos,
    input  logic [5:0]  awid,
    input  logic [511:0] wdata,
    input  logic [63:0] wstrb,
    input  logic        wlast,
    input  logic        wvalid,
    input  logic        bready,
    input  logic [63:0] araddr,
    input  logic [7:0]  arlen,
    input  logic [2:0]  arsize,
    input  logic [1:0]  arburst,
    input  logic        arlock,
    input  logic [3:0]  arcache,
    input  logic [2:0]  arprot,
    input  logic [3:0]  arqos,
    input  logic [5:0]  arid,
    input  logic        arvalid,
    input  logic        rready,

    // core inputs (from the DDR controller)
    output logic        awready,
    output logic        wready,
    output logic        bvalid,
    output logic [5:0]  bid,
    output logic [1:0]  bresp,
    output logic        arready,
    output logic        rvalid,
    output logic [5:0]  rid,
    output logic [511:0] rdata,
    output logic [1:0]  rresp,
    output logic        rlast
);

    // master-driven
    assign ddr.awvalid = awvalid;
    assign ddr.awaddr  = awaddr;
    assign ddr.awlen   = awlen;
    assign ddr.awsize  = awsize;
    assign ddr.awburst = awburst;
    assign ddr.awlock  = awlock;
    assign ddr.awcache = awcache;
    assign ddr.awprot  = awprot;
    assign ddr.awqos   = awqos;
    assign ddr.awid    = awid;
    assign ddr.wdata   = wdata;
    assign ddr.wstrb   = wstrb;
    assign ddr.wlast   = wlast;
    assign ddr.wvalid  = wvalid;
    assign ddr.bready  = bready;
    assign ddr.araddr  = araddr;
    assign ddr.arlen   = arlen;
    assign ddr.arsize  = arsize;
    assign ddr.arburst = arburst;
    assign ddr.arlock  = arlock;
    assign ddr.arcache = arcache;
    assign ddr.arprot  = arprot;
    assign ddr.arqos   = arqos;
    assign ddr.arid    = arid;
    assign ddr.arvalid = arvalid;
    assign ddr.rready  = rready;

    // responses
    assign awready = ddr.awready;
    assign wready  = ddr.wready;
    assign bvalid  = ddr.bvalid;
    assign bid     = ddr.bid;
    assign bresp   = ddr.bresp;
    assign arready = ddr.arready;
    assign rvalid  = ddr.rvalid;
    assign rid     = ddr.rid;
    assign rdata   = ddr.rdata;
    assign rresp   = ddr.rresp;
    assign rlast   = ddr.rlast;

endmodule
