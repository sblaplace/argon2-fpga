// SPDX-License-Identifier: MIT
// F1 CL top for argon2-fpga.
//
// Drop-in replacement for the HDK `cl_dram_dma` example top. It presents
// the standard F1 shell interface:
//   * clk_main_a0 / rst_main_n  -- main 250 MHz clock and reset
//   * four DDR AXI4 master buses (DDR_AXI_*, one bit-slice per channel)
//   * the OCL AXI4-lite slave (sh_ocl_*) used to program jobs
//   * FLR / peek / DDR-stat tie-offs
//
// The functional logic lives in cl_argon2_core (HDK-independent); this
// file only adapts the shell buses onto it. `A2_CL_TOP` and
// `A2_DEFAULT_N_P` may be pre-defined by a generated wrapper
// (`fpga/f1/emit_hdk_top.py`) so the same source can build as the HDK's
// example top at the N_P point you want.
//
// NOTE ON THE DDR PORTS: the buses are FLAT vectors, one bit (or word)
// slice per channel -- channel n is index n of each DDR_AXI_* signal.
// This is deliberately interface-free so the design elaborates in ANY
// simulator (Icarus 11 has no interface-port elaboration) and lints
// without the HDK. For a real HDK build, write a thin wrapper that maps
// DDR_AXI_*.w[0..3] onto the shell's per-channel ports (or its
// `axi_bus_t` members) -- see fpga/f1/README.md.

`timescale 1ns / 1ps

`ifndef CL_ARGON2_DEFINES_VH
`include "cl_argon2_defines.vh"
`endif

`ifndef A2_CL_TOP
`define A2_CL_TOP cl_argon2
`endif

`ifndef A2_DEFAULT_N_P
`define A2_DEFAULT_N_P 1
`endif

module `A2_CL_TOP #(
    parameter int NUM_DDR = `A2_NUM_DDR,
    parameter int N_P     = `A2_DEFAULT_N_P   // parallel P units in the compression G
) (
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

    // ---- four DDR AXI4 master buses (channel n = bit n) ---------------
    // CL drives the command/address/write side; the DDR controller
    // drives the ready/response side.
    output logic [NUM_DDR-1:0]                    DDR_AXI_awvalid,
    output logic [NUM_DDR-1:0][`A2_AXI_ADDR_W-1:0] DDR_AXI_awaddr,
    output logic [NUM_DDR-1:0][7:0]               DDR_AXI_awlen,
    output logic [NUM_DDR-1:0][2:0]               DDR_AXI_awsize,
    output logic [NUM_DDR-1:0][1:0]               DDR_AXI_awburst,
    output logic [NUM_DDR-1:0]                    DDR_AXI_awlock,
    output logic [NUM_DDR-1:0][3:0]               DDR_AXI_awcache,
    output logic [NUM_DDR-1:0][2:0]               DDR_AXI_awprot,
    output logic [NUM_DDR-1:0][3:0]               DDR_AXI_awqos,
    output logic [NUM_DDR-1:0][`A2_AXI_ID_W-1:0]  DDR_AXI_awid,
    output logic [NUM_DDR-1:0][`A2_AXI_DATA_W-1:0] DDR_AXI_wdata,
    output logic [NUM_DDR-1:0][`A2_AXI_DATA_W/8-1:0] DDR_AXI_wstrb,
    output logic [NUM_DDR-1:0]                    DDR_AXI_wlast,
    output logic [NUM_DDR-1:0]                    DDR_AXI_wvalid,
    output logic [NUM_DDR-1:0]                    DDR_AXI_bready,
    output logic [NUM_DDR-1:0][`A2_AXI_ADDR_W-1:0] DDR_AXI_araddr,
    output logic [NUM_DDR-1:0][7:0]               DDR_AXI_arlen,
    output logic [NUM_DDR-1:0][2:0]               DDR_AXI_arsize,
    output logic [NUM_DDR-1:0][1:0]               DDR_AXI_arburst,
    output logic [NUM_DDR-1:0]                    DDR_AXI_arlock,
    output logic [NUM_DDR-1:0][3:0]               DDR_AXI_arcache,
    output logic [NUM_DDR-1:0][2:0]               DDR_AXI_arprot,
    output logic [NUM_DDR-1:0][3:0]               DDR_AXI_arqos,
    output logic [NUM_DDR-1:0][`A2_AXI_ID_W-1:0]  DDR_AXI_arid,
    output logic [NUM_DDR-1:0]                    DDR_AXI_arvalid,
    output logic [NUM_DDR-1:0]                    DDR_AXI_rready,

    input  logic [NUM_DDR-1:0]                    DDR_AXI_awready,
    input  logic [NUM_DDR-1:0]                    DDR_AXI_wready,
    input  logic [NUM_DDR-1:0]                    DDR_AXI_bvalid,
    input  logic [NUM_DDR-1:0][`A2_AXI_ID_W-1:0]  DDR_AXI_bid,
    input  logic [NUM_DDR-1:0][1:0]               DDR_AXI_bresp,
    input  logic [NUM_DDR-1:0]                    DDR_AXI_arready,
    input  logic [NUM_DDR-1:0]                    DDR_AXI_rvalid,
    input  logic [NUM_DDR-1:0][`A2_AXI_ID_W-1:0]  DDR_AXI_rid,
    input  logic [NUM_DDR-1:0][`A2_AXI_DATA_W-1:0] DDR_AXI_rdata,
    input  logic [NUM_DDR-1:0][1:0]               DDR_AXI_rresp,
    input  logic [NUM_DDR-1:0]                    DDR_AXI_rlast,

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

    // Reset for the argon2 logic: main reset ANDed with FLR.
    logic rst_n;
    assign rst_n = &rst_main_n & ~sh_cl_flr_assert;

    // Release the DDR controllers (active-low).
    assign cl_sh_ddr_areset_n = {NUM_DDR{1'b1}};

    // Peek is unused in this CL.
    assign cl_sh_peek_ack  = 16'd0;
    assign cl_sh_peek_data = 32'd0;

    // ---- Functional core (pure pass-through of the flat DDR buses) ----
    cl_argon2_core #(.NUM_DDR(NUM_DDR), .N_P(N_P)) u_core (
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

        .m_ddr_awvalid(DDR_AXI_awvalid), .m_ddr_awaddr(DDR_AXI_awaddr),
        .m_ddr_awlen(DDR_AXI_awlen), .m_ddr_awsize(DDR_AXI_awsize),
        .m_ddr_awburst(DDR_AXI_awburst), .m_ddr_awlock(DDR_AXI_awlock),
        .m_ddr_awcache(DDR_AXI_awcache), .m_ddr_awprot(DDR_AXI_awprot),
        .m_ddr_awqos(DDR_AXI_awqos), .m_ddr_awid(DDR_AXI_awid),
        .m_ddr_wdata(DDR_AXI_wdata), .m_ddr_wstrb(DDR_AXI_wstrb),
        .m_ddr_wlast(DDR_AXI_wlast), .m_ddr_wvalid(DDR_AXI_wvalid),
        .m_ddr_bready(DDR_AXI_bready),
        .m_ddr_araddr(DDR_AXI_araddr), .m_ddr_arlen(DDR_AXI_arlen),
        .m_ddr_arsize(DDR_AXI_arsize), .m_ddr_arburst(DDR_AXI_arburst),
        .m_ddr_arlock(DDR_AXI_arlock), .m_ddr_arcache(DDR_AXI_arcache),
        .m_ddr_arprot(DDR_AXI_arprot), .m_ddr_arqos(DDR_AXI_arqos),
        .m_ddr_arid(DDR_AXI_arid), .m_ddr_arvalid(DDR_AXI_arvalid),
        .m_ddr_rready(DDR_AXI_rready),
        .m_ddr_awready(DDR_AXI_awready), .m_ddr_wready(DDR_AXI_wready),
        .m_ddr_bvalid(DDR_AXI_bvalid), .m_ddr_bid(DDR_AXI_bid),
        .m_ddr_bresp(DDR_AXI_bresp), .m_ddr_arready(DDR_AXI_arready),
        .m_ddr_rvalid(DDR_AXI_rvalid), .m_ddr_rid(DDR_AXI_rid),
        .m_ddr_rdata(DDR_AXI_rdata), .m_ddr_rresp(DDR_AXI_rresp),
        .m_ddr_rlast(DDR_AXI_rlast)
    );

endmodule
