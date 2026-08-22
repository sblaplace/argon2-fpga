// SPDX-License-Identifier: MIT
// Functional core of the F1 argon2 CL (HDK-independent).
//
// Instantiates one argon2_fill_axi per DDR channel and an OCL register
// slave, and joins the lanes' slice barriers when p4_mode is set:
//
//   * p4_mode = 0  -> four independent p=1 jobs (one candidate per
//                     channel). Each core owns lane_id 0 in its own
//                     private memory region.
//   * p4_mode = 1  -> one p=4 job spread across the four channels.
//                     Core L walks lane L of the same job; the four
//                     slice barriers are AND-joined (exactly the
//                     argon2_fill_job barrier, see rtl/argon2/).
//
// The DDR ports are AXI4 *master* (m_ddr_* outputs driven by the core,
// *_ready / b* / r* inputs driven by the DDR controller). The OCL ports
// are the flat AXI4-lite *slave* signals presented by the F1 shell.
//
// This module is deliberately free of any HDK `axi_bus_t` / `cl_ports`
// dependency so it can be simulated or linted standalone; the HDK top
// (cl_argon2.sv) adapts the shell buses onto these flat ports.

`timescale 1ns / 1ps

`ifndef CL_ARGON2_DEFINES_VH
`include "cl_argon2_defines.vh"
`endif

module cl_argon2_core #(
    parameter int NUM_DDR = `A2_NUM_DDR,
    parameter int N_P    = 1   // parallel P units in the compression G
) (
    input  logic clk,
    input  logic rst_n,           // active-low, already in the clk domain

    // ---- OCL AXI4-lite slave (flat sh_ocl_*) ---------------------------
    input  logic        ocl_awvalid,
    input  logic [31:0] ocl_awaddr,
    input  logic [15:0] ocl_awid,
    input  logic        ocl_wvalid,
    input  logic [31:0] ocl_wdata,
    input  logic [15:0] ocl_wstrb,
    output logic        ocl_awready,
    output logic        ocl_wready,
    output logic [15:0] ocl_bid,
    output logic [1:0]  ocl_bresp,
    output logic        ocl_bvalid,
    input  logic        ocl_bready,
    input  logic        ocl_arvalid,
    input  logic [31:0] ocl_araddr,
    input  logic [15:0] ocl_arid,
    output logic        ocl_arready,
    output logic [15:0] ocl_rid,
    output logic [31:0] ocl_rdata,
    output logic [1:0]  ocl_rresp,
    output logic        ocl_rlast,
    output logic        ocl_rvalid,
    input  logic        ocl_rready,

    // ---- Per-channel AXI4 master to DDR (core drives *) ----------------
    // * driven by the core (master command/address/write)
    output logic [NUM_DDR-1:0]        m_ddr_awvalid,
    output logic [NUM_DDR-1:0][`A2_AXI_ADDR_W-1:0]  m_ddr_awaddr,
    output logic [NUM_DDR-1:0][7:0]   m_ddr_awlen,
    output logic [NUM_DDR-1:0][2:0]   m_ddr_awsize,
    output logic [NUM_DDR-1:0][1:0]   m_ddr_awburst,
    output logic [NUM_DDR-1:0]        m_ddr_awlock,
    output logic [NUM_DDR-1:0][3:0]   m_ddr_awcache,
    output logic [NUM_DDR-1:0][2:0]   m_ddr_awprot,
    output logic [NUM_DDR-1:0][3:0]   m_ddr_awqos,
    output logic [NUM_DDR-1:0][`A2_AXI_ID_W-1:0]    m_ddr_awid,
    output logic [NUM_DDR-1:0][`A2_AXI_DATA_W-1:0]  m_ddr_wdata,
    output logic [NUM_DDR-1:0][`A2_AXI_DATA_W/8-1:0] m_ddr_wstrb,
    output logic [NUM_DDR-1:0]        m_ddr_wlast,
    output logic [NUM_DDR-1:0]        m_ddr_wvalid,
    output logic [NUM_DDR-1:0]        m_ddr_bready,
    output logic [NUM_DDR-1:0][`A2_AXI_ADDR_W-1:0]  m_ddr_araddr,
    output logic [NUM_DDR-1:0][7:0]   m_ddr_arlen,
    output logic [NUM_DDR-1:0][2:0]   m_ddr_arsize,
    output logic [NUM_DDR-1:0][1:0]   m_ddr_arburst,
    output logic [NUM_DDR-1:0]        m_ddr_arlock,
    output logic [NUM_DDR-1:0][3:0]   m_ddr_arcache,
    output logic [NUM_DDR-1:0][2:0]   m_ddr_arprot,
    output logic [NUM_DDR-1:0][3:0]   m_ddr_arqos,
    output logic [NUM_DDR-1:0][`A2_AXI_ID_W-1:0]    m_ddr_arid,
    output logic [NUM_DDR-1:0]        m_ddr_arvalid,
    output logic [NUM_DDR-1:0]        m_ddr_rready,
    // * driven by the DDR controller (responses)
    input  logic [NUM_DDR-1:0]        m_ddr_awready,
    input  logic [NUM_DDR-1:0]        m_ddr_wready,
    input  logic [NUM_DDR-1:0]        m_ddr_bvalid,
    input  logic [NUM_DDR-1:0][`A2_AXI_ID_W-1:0]    m_ddr_bid,
    input  logic [NUM_DDR-1:0][1:0]   m_ddr_bresp,
    input  logic [NUM_DDR-1:0]        m_ddr_arready,
    input  logic [NUM_DDR-1:0]        m_ddr_rvalid,
    input  logic [NUM_DDR-1:0][`A2_AXI_ID_W-1:0]    m_ddr_rid,
    input  logic [NUM_DDR-1:0][`A2_AXI_DATA_W-1:0]  m_ddr_rdata,
    input  logic [NUM_DDR-1:0][1:0]   m_ddr_rresp,
    input  logic [NUM_DDR-1:0]        m_ddr_rlast
);

    localparam int NREG = `A2_OCL_NREG;

    // ---- OCL register file ---------------------------------------------
    logic [31:0] ocl_regf   [0:NREG-1];
    logic [NREG-1:0] ocl_reg_wr;
    logic [31:0] status_reg [0:NREG-1];
    logic [NUM_DDR-1:0] lane_busy, lane_done;
    logic [NREG-1:0] status_sel;

    assign status_sel = (NREG'(1) << `A2_OCL_STATUS);   // only STATUS is RO

    // done is a single-cycle pulse from each fill core. Latch it until the
    // next GLOBAL_START so a host polling over PCIe (or an OCL read loop,
    // several cycles per poll) cannot miss a completed job.
    logic [NUM_DDR-1:0] done_latch;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_latch <= '0;
        end else if (start_pulse) begin
            done_latch <= '0;
        end else begin
            done_latch <= done_latch | lane_done;
        end
    end

    always_comb begin
        for (int k = 0; k < NREG; k = k + 1)
            status_reg[k] = 32'd0;
        status_reg[`A2_OCL_STATUS] = {24'd0, done_latch, lane_busy};
    end

    cl_argon2_ocl #(.NREG(NREG)) u_ocl (
        .clk        (clk),
        .rst_n      (rst_n),
        .awvalid    (ocl_awvalid),
        .awaddr     (ocl_awaddr),
        .awid       (ocl_awid),
        .wvalid     (ocl_wvalid),
        .wdata      (ocl_wdata),
        .wstrb      (ocl_wstrb),
        .awready    (ocl_awready),
        .wready     (ocl_wready),
        .bid        (ocl_bid),
        .bresp      (ocl_bresp),
        .bvalid     (ocl_bvalid),
        .bready     (ocl_bready),
        .arvalid    (ocl_arvalid),
        .araddr     (ocl_araddr),
        .arid       (ocl_arid),
        .arready    (ocl_arready),
        .rid        (ocl_rid),
        .rdata      (ocl_rdata),
        .rresp      (ocl_rresp),
        .rlast      (ocl_rlast),
        .rvalid     (ocl_rvalid),
        .rready     (ocl_rready),
        .regf       (ocl_regf),
        .reg_wr     (ocl_reg_wr),
        .reg_in     (status_reg),
        .reg_in_sel (status_sel)
    );

    // ---- Decode control registers --------------------------------------
    logic        start_pulse;
    logic        soft_reset;
    logic        p4_mode;
    logic        core_rst_n;

    assign start_pulse = ocl_reg_wr[`A2_OCL_GLOBAL_START];
    assign soft_reset  = ocl_reg_wr[`A2_OCL_CONTROL] && ocl_regf[`A2_OCL_CONTROL][1];
    assign p4_mode     = ocl_regf[`A2_OCL_CONTROL][0];
    assign core_rst_n  = rst_n & ~soft_reset;

    // ---- Slice-barrier join across lanes -------------------------------
    // Matches rtl/argon2/argon2_fill_job.sv: sync_ack = {LANES{&sync_req}}.
    logic [NUM_DDR-1:0] sync_req, sync_ack;
    assign sync_ack = p4_mode ? {NUM_DDR{&sync_req}} : {NUM_DDR{1'b1}};

    genvar L;
    generate
        for (L = 0; L < NUM_DDR; L++) begin : lane
            logic [31:0] lane_ctrl, passes, lane_length, memory_blocks;
            logic [31:0] base_lo, base_hi;
            logic [`A2_AXI_ADDR_W-1:0] base_addr;

            assign lane_ctrl     = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 0];
            assign passes        = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 1];
            assign lane_length   = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 2];
            assign memory_blocks = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 3];
            assign base_lo       = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 4];
            assign base_hi       = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 5];
            assign base_addr     = {base_hi, base_lo};

            argon2_fill_axi #(.AXI_ADDR_W(`A2_AXI_ADDR_W),
                              .AXI_ID_W(`A2_AXI_ID_W),
                              .AXI_DATA_W(`A2_AXI_DATA_W),
                              .BLK_ADDR_W(`A2_BLK_ADDR_W),
                              .N_P(N_P)) u_fill (
                .clk           (clk),
                .rst_n         (core_rst_n),
                .start         (start_pulse),
                .busy          (lane_busy[L]),
                .done          (lane_done[L]),
                // p4_mode joins the four channels into one p=4 job;
                // otherwise each channel runs an independent p=1 job.
                .passes        (passes),
                .lanes         (p4_mode ? 32'd4 : 32'd1),
                .lane_id       (p4_mode ? 32'(L) : 32'd0),
                .lane_length   (lane_length),
                .memory_blocks (memory_blocks),
                .type_i        (lane_ctrl[1:0]),
                .sync_req      (sync_req[L]),
                .sync_ack      (sync_ack[L]),
                .base_addr     (base_addr),

                .m_axi_awid    (m_ddr_awid[L]),
                .m_axi_awaddr  (m_ddr_awaddr[L]),
                .m_axi_awlen   (m_ddr_awlen[L]),
                .m_axi_awsize  (m_ddr_awsize[L]),
                .m_axi_awburst (m_ddr_awburst[L]),
                .m_axi_awlock  (m_ddr_awlock[L]),
                .m_axi_awcache (m_ddr_awcache[L]),
                .m_axi_awprot  (m_ddr_awprot[L]),
                .m_axi_awqos   (m_ddr_awqos[L]),
                .m_axi_awvalid (m_ddr_awvalid[L]),
                .m_axi_awready (m_ddr_awready[L]),
                .m_axi_wdata   (m_ddr_wdata[L]),
                .m_axi_wstrb   (m_ddr_wstrb[L]),
                .m_axi_wlast   (m_ddr_wlast[L]),
                .m_axi_wvalid  (m_ddr_wvalid[L]),
                .m_axi_wready  (m_ddr_wready[L]),
                .m_axi_bid     (m_ddr_bid[L]),
                .m_axi_bresp   (m_ddr_bresp[L]),
                .m_axi_bvalid  (m_ddr_bvalid[L]),
                .m_axi_bready  (m_ddr_bready[L]),
                .m_axi_arid    (m_ddr_arid[L]),
                .m_axi_araddr  (m_ddr_araddr[L]),
                .m_axi_arlen   (m_ddr_arlen[L]),
                .m_axi_arsize  (m_ddr_arsize[L]),
                .m_axi_arburst (m_ddr_arburst[L]),
                .m_axi_arlock  (m_ddr_arlock[L]),
                .m_axi_arcache (m_ddr_arcache[L]),
                .m_axi_arprot  (m_ddr_arprot[L]),
                .m_axi_arqos   (m_ddr_arqos[L]),
                .m_axi_arvalid (m_ddr_arvalid[L]),
                .m_axi_arready (m_ddr_arready[L]),
                .m_axi_rid     (m_ddr_rid[L]),
                .m_axi_rdata   (m_ddr_rdata[L]),
                .m_axi_rresp   (m_ddr_rresp[L]),
                .m_axi_rlast   (m_ddr_rlast[L]),
                .m_axi_rvalid  (m_ddr_rvalid[L]),
                .m_axi_rready  (m_ddr_rready[L])
            );
        end
    endgenerate

endmodule
