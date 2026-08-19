// SPDX-License-Identifier: MIT
// Local AXI4 bus type for the F1 DDR channels.
//
// This is ONLY used when building/simulating standalone (no AWS HDK
// present). In a real HDK build, define `AXI_BUS_T_DEFINED` first (or
// `include` your HDK's cl_dram_dma_pkg.sv / axi_bus_defines.vh before
// this file) so the shell's exact `axi_bus_t` is used instead -- the
// connect module and CL top must share the shell's interface type.
//
// Member widths mirror rtl/argon2/argon2_fill_axi.sv: id = 6, address =
// 64, data = 512. The F1 sh_ddr bus is a 512-bit AXI4 master interface.

`ifndef AXI_BUS_T_DEFINED
`define AXI_BUS_T_DEFINED

interface axi_bus_t;
    // write address
    logic [5:0]  awid;
    logic [63:0] awaddr;
    logic [7:0]  awlen;
    logic [2:0]  awsize;
    logic [1:0]  awburst;
    logic        awlock;
    logic [3:0]  awcache;
    logic [2:0]  awprot;
    logic [3:0]  awqos;
    logic        awvalid;
    logic        awready;
    // write data
    logic [511:0] wdata;
    logic [63:0]  wstrb;
    logic         wlast;
    logic         wvalid;
    logic         wready;
    // write response
    logic [1:0]  bresp;
    logic         bvalid;
    logic         bready;
    logic [5:0]  bid;
    // read address
    logic [5:0]  arid;
    logic [63:0] araddr;
    logic [7:0]  arlen;
    logic [2:0]  arsize;
    logic [1:0]  arburst;
    logic         arlock;
    logic [3:0]  arcache;
    logic [2:0]  arprot;
    logic [3:0]  arqos;
    logic         arvalid;
    logic         arready;
    // read data
    logic [5:0]  rid;
    logic [511:0] rdata;
    logic [1:0]  rresp;
    logic         rlast;
    logic         rvalid;
endinterface

`endif
