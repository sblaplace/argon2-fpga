// SPDX-License-Identifier: MIT
// Functional core of the F1 argon2 CL (HDK-independent).
//
// Instantiates CTXS_PER_CH argon2_fill_ctrl lanes per DDR channel
// (default 3, concentrating N independent p=1 contexts onto each channel
// via argon2_lane_conc for +56% cand/s), an AXI-MM adapter per channel,
// and an OCL register slave.
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
    parameter int NUM_DDR     = `A2_NUM_DDR,
    parameter int CTXS_PER_CH = `A2_DEFAULT_CTXS_PER_CH,
    parameter int N_P         = 1   // parallel P units in the compression G
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

    localparam int TOTAL_LANES = NUM_DDR * CTXS_PER_CH;
    localparam int NREG = `A2_OCL_NREG;

    // ---- OCL register file ---------------------------------------------
    logic [31:0] ocl_regf   [0:NREG-1];
    logic [NREG-1:0] ocl_reg_wr;
    logic [31:0] status_reg [0:NREG-1];
    logic [TOTAL_LANES-1:0] lane_busy, lane_done;
    logic [NREG-1:0] status_sel;

    assign status_sel = (NREG'(1) << `A2_OCL_STATUS);   // only STATUS is RO

    // done is a single-cycle pulse from each fill core. Latch it until the
    // next GLOBAL_START so a host polling over PCIe (or an OCL read loop,
    // several cycles per poll) cannot miss a completed job.
    logic [TOTAL_LANES-1:0] done_latch;

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
        if (TOTAL_LANES <= 4) begin
            status_reg[`A2_OCL_STATUS] = {12'd0, done_latch[3:0], 8'd0, done_latch[3:0], lane_busy[3:0]};
        end else begin
            status_reg[`A2_OCL_STATUS] = {16'(done_latch), 16'(lane_busy)};
        end
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
    logic [TOTAL_LANES-1:0] sync_req, sync_ack;
    assign sync_ack = p4_mode ? {TOTAL_LANES{&sync_req}} : {TOTAL_LANES{1'b1}};

    // ---- Lane registers ------------------------------------------------
    logic [31:0] lane_ctrl     [0:TOTAL_LANES-1];
    logic [31:0] passes        [0:TOTAL_LANES-1];
    logic [31:0] lane_length   [0:TOTAL_LANES-1];
    logic [31:0] memory_blocks [0:TOTAL_LANES-1];
    logic [31:0] base_lo       [0:TOTAL_LANES-1];
    logic [31:0] base_hi       [0:TOTAL_LANES-1];
    logic [`A2_AXI_ADDR_W-1:0] base_addr [0:TOTAL_LANES-1];

    genvar L;
    generate
        for (L = 0; L < TOTAL_LANES; L++) begin : reg_lane
            assign lane_ctrl[L]     = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 0];
            assign passes[L]        = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 1];
            assign lane_length[L]   = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 2];
            assign memory_blocks[L] = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 3];
            assign base_lo[L]       = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 4];
            assign base_hi[L]       = ocl_regf[`A2_OCL_LANE_BASE + L*`A2_OCL_LANE_STRIDE + 5];
            assign base_addr[L]     = {base_hi[L], base_lo[L]};
        end
    endgenerate

    // ---- Memory attachment per DDR channel ------------------------------
    genvar ch;
    generate
        if (CTXS_PER_CH == 1) begin : g_single_ctx
            for (ch = 0; ch < NUM_DDR; ch++) begin : channel
                localparam int idx = ch;
                argon2_fill_axi #(
                    .AXI_ADDR_W(`A2_AXI_ADDR_W),
                    .AXI_ID_W(`A2_AXI_ID_W),
                    .AXI_DATA_W(`A2_AXI_DATA_W),
                    .BLK_ADDR_W(`A2_BLK_ADDR_W),
                    .N_P(N_P)
                ) u_fill (
                    .clk           (clk),
                    .rst_n         (core_rst_n),
                    .start         (start_pulse && (passes[idx] != 0)),
                    .busy          (lane_busy[idx]),
                    .done          (lane_done[idx]),
                    .passes        (passes[idx]),
                    .lanes         (p4_mode ? 32'd4 : 32'd1),
                    .lane_id       (p4_mode ? 32'(ch) : 32'd0),
                    .lane_length   (lane_length[idx]),
                    .memory_blocks (memory_blocks[idx]),
                    .type_i        (lane_ctrl[idx][1:0]),
                    .sync_req      (sync_req[idx]),
                    .sync_ack      (sync_ack[idx]),
                    .base_addr     (base_addr[idx]),
                    .state_o       (),

                    .m_axi_awid    (m_ddr_awid[ch]),
                    .m_axi_awaddr  (m_ddr_awaddr[ch]),
                    .m_axi_awlen   (m_ddr_awlen[ch]),
                    .m_axi_awsize  (m_ddr_awsize[ch]),
                    .m_axi_awburst (m_ddr_awburst[ch]),
                    .m_axi_awlock  (m_ddr_awlock[ch]),
                    .m_axi_awcache (m_ddr_awcache[ch]),
                    .m_axi_awprot  (m_ddr_awprot[ch]),
                    .m_axi_awqos   (m_ddr_awqos[ch]),
                    .m_axi_awvalid (m_ddr_awvalid[ch]),
                    .m_axi_awready (m_ddr_awready[ch]),
                    .m_axi_wdata   (m_ddr_wdata[ch]),
                    .m_axi_wstrb   (m_ddr_wstrb[ch]),
                    .m_axi_wlast   (m_ddr_wlast[ch]),
                    .m_axi_wvalid  (m_ddr_wvalid[ch]),
                    .m_axi_wready  (m_ddr_wready[ch]),
                    .m_axi_bid     (m_ddr_bid[ch]),
                    .m_axi_bresp   (m_ddr_bresp[ch]),
                    .m_axi_bvalid  (m_ddr_bvalid[ch]),
                    .m_axi_bready  (m_ddr_bready[ch]),
                    .m_axi_arid    (m_ddr_arid[ch]),
                    .m_axi_araddr  (m_ddr_araddr[ch]),
                    .m_axi_arlen   (m_ddr_arlen[ch]),
                    .m_axi_arsize  (m_ddr_arsize[ch]),
                    .m_axi_arburst (m_ddr_arburst[ch]),
                    .m_axi_arlock  (m_ddr_arlock[ch]),
                    .m_axi_arcache (m_ddr_arcache[ch]),
                    .m_axi_arprot  (m_ddr_arprot[ch]),
                    .m_axi_arqos   (m_ddr_arqos[ch]),
                    .m_axi_arvalid (m_ddr_arvalid[ch]),
                    .m_axi_arready (m_ddr_arready[ch]),
                    .m_axi_rid     (m_ddr_rid[ch]),
                    .m_axi_rdata   (m_ddr_rdata[ch]),
                    .m_axi_rresp   (m_ddr_rresp[ch]),
                    .m_axi_rlast   (m_ddr_rlast[ch]),
                    .m_axi_rvalid  (m_ddr_rvalid[ch]),
                    .m_axi_rready  (m_ddr_rready[ch])
                );
            end
        end else begin : g_multi_ctx
            for (ch = 0; ch < NUM_DDR; ch++) begin : channel
                localparam int CH_BASE_LANE = ch * CTXS_PER_CH;

                logic [CTXS_PER_CH-1:0]                     l_rd_valid, l_rd_ready, l_rd_data_v, l_rd_last;
                logic [CTXS_PER_CH-1:0][`A2_BLK_ADDR_W-1:0] l_rd_addr;
                logic [CTXS_PER_CH-1:0][`A2_AXI_DATA_W-1:0] l_rd_data;
                logic [CTXS_PER_CH-1:0]                     l_wr_valid, l_wr_ready, l_wr_last;
                logic [CTXS_PER_CH-1:0][`A2_BLK_ADDR_W-1:0] l_wr_addr;
                logic [CTXS_PER_CH-1:0][`A2_AXI_DATA_W-1:0] l_wr_data;

                genvar g;
                for (g = 0; g < CTXS_PER_CH; g++) begin : ctx
                    localparam int idx = CH_BASE_LANE + g;

                    argon2_fill_ctrl #(
                        .ADDR_W(`A2_BLK_ADDR_W),
                        .N_P(N_P)
                    ) u_fill (
                        .clk           (clk),
                        .rst_n         (core_rst_n),
                        .start         (start_pulse && (passes[idx] != 0)),
                        .busy          (lane_busy[idx]),
                        .done          (lane_done[idx]),
                        .passes        (passes[idx]),
                        .lanes         (32'd1),
                        .lane_id       (32'd0),
                        .lane_length   (lane_length[idx]),
                        .memory_blocks (memory_blocks[idx]),
                        .type_i        (lane_ctrl[idx][1:0]),
                        .sync_req      (sync_req[idx]),
                        .sync_ack      (sync_ack[idx]),
                        .state_o       (),
                        .mem_rd_valid  (l_rd_valid[g]),
                        .mem_rd_ready  (l_rd_ready[g]),
                        .mem_rd_addr   (l_rd_addr[g]),
                        .mem_rd_owner  (),
                        .mem_rd_data_v (l_rd_data_v[g]),
                        .mem_rd_data   (l_rd_data[g]),
                        .mem_rd_last   (l_rd_last[g]),
                        .mem_wr_valid  (l_wr_valid[g]),
                        .mem_wr_ready  (l_wr_ready[g]),
                        .mem_wr_addr   (l_wr_addr[g]),
                        .mem_wr_data   (l_wr_data[g]),
                        .mem_wr_last   (l_wr_last[g])
                    );
                end

                logic                      c_rd_valid, c_rd_ready, c_rd_data_v, c_rd_last;
                logic [`A2_BLK_ADDR_W-1:0] c_rd_addr;
                logic [`A2_AXI_DATA_W-1:0] c_rd_data;
                logic                      c_wr_valid, c_wr_ready, c_wr_last;
                logic [`A2_BLK_ADDR_W-1:0] c_wr_addr;
                logic [`A2_AXI_DATA_W-1:0] c_wr_data;

                argon2_lane_conc #(
                    .ADDR_W(`A2_BLK_ADDR_W),
                    .LANES(CTXS_PER_CH),
                    .MAX_INFLIGHT(4)
                ) u_conc (
                    .clk        (clk),
                    .rst_n      (core_rst_n),
                    .ctx_len    (lane_length[CH_BASE_LANE]),
                    .l_rd_valid (l_rd_valid),
                    .l_rd_ready (l_rd_ready),
                    .l_rd_addr  (l_rd_addr),
                    .l_rd_data_v(l_rd_data_v),
                    .l_rd_data  (l_rd_data),
                    .l_rd_last  (l_rd_last),
                    .l_wr_valid (l_wr_valid),
                    .l_wr_ready (l_wr_ready),
                    .l_wr_addr  (l_wr_addr),
                    .l_wr_data  (l_wr_data),
                    .l_wr_last  (l_wr_last),
                    .c_rd_valid (c_rd_valid),
                    .c_rd_ready (c_rd_ready),
                    .c_rd_addr  (c_rd_addr),
                    .c_rd_data_v(c_rd_data_v),
                    .c_rd_data  (c_rd_data),
                    .c_rd_last  (c_rd_last),
                    .c_wr_valid (c_wr_valid),
                    .c_wr_ready (c_wr_ready),
                    .c_wr_addr  (c_wr_addr),
                    .c_wr_data  (c_wr_data),
                    .c_wr_last  (c_wr_last)
                );

                argon2_axi_mm #(
                    .AXI_ADDR_W (`A2_AXI_ADDR_W),
                    .AXI_ID_W   (`A2_AXI_ID_W),
                    .AXI_DATA_W (`A2_AXI_DATA_W),
                    .BLK_ADDR_W (`A2_BLK_ADDR_W),
                    .MAX_RD_PEND(4)
                ) u_axi (
                    .clk           (clk),
                    .rst_n         (core_rst_n),
                    .base_addr     (base_addr[CH_BASE_LANE]),
                    .mem_rd_valid  (c_rd_valid),
                    .mem_rd_ready  (c_rd_ready),
                    .mem_rd_addr   (c_rd_addr),
                    .mem_rd_data_v (c_rd_data_v),
                    .mem_rd_data   (c_rd_data),
                    .mem_rd_last   (c_rd_last),
                    .mem_wr_valid  (c_wr_valid),
                    .mem_wr_ready  (c_wr_ready),
                    .mem_wr_addr   (c_wr_addr),
                    .mem_wr_data   (c_wr_data),
                    .mem_wr_last   (c_wr_last),
                    .m_axi_awid    (m_ddr_awid[ch]),
                    .m_axi_awaddr  (m_ddr_awaddr[ch]),
                    .m_axi_awlen   (m_ddr_awlen[ch]),
                    .m_axi_awsize  (m_ddr_awsize[ch]),
                    .m_axi_awburst (m_ddr_awburst[ch]),
                    .m_axi_awlock  (m_ddr_awlock[ch]),
                    .m_axi_awcache (m_ddr_awcache[ch]),
                    .m_axi_awprot  (m_ddr_awprot[ch]),
                    .m_axi_awqos   (m_ddr_awqos[ch]),
                    .m_axi_awvalid (m_ddr_awvalid[ch]),
                    .m_axi_awready (m_ddr_awready[ch]),
                    .m_axi_wdata   (m_ddr_wdata[ch]),
                    .m_axi_wstrb   (m_ddr_wstrb[ch]),
                    .m_axi_wlast   (m_ddr_wlast[ch]),
                    .m_axi_wvalid  (m_ddr_wvalid[ch]),
                    .m_axi_wready  (m_ddr_wready[ch]),
                    .m_axi_bid     (m_ddr_bid[ch]),
                    .m_axi_bresp   (m_ddr_bresp[ch]),
                    .m_axi_bvalid  (m_ddr_bvalid[ch]),
                    .m_axi_bready  (m_ddr_bready[ch]),
                    .m_axi_arid    (m_ddr_arid[ch]),
                    .m_axi_araddr  (m_ddr_araddr[ch]),
                    .m_axi_arlen   (m_ddr_arlen[ch]),
                    .m_axi_arsize  (m_ddr_arsize[ch]),
                    .m_axi_arburst (m_ddr_arburst[ch]),
                    .m_axi_arlock  (m_ddr_arlock[ch]),
                    .m_axi_arcache (m_ddr_arcache[ch]),
                    .m_axi_arprot  (m_ddr_arprot[ch]),
                    .m_axi_arqos   (m_ddr_arqos[ch]),
                    .m_axi_arvalid (m_ddr_arvalid[ch]),
                    .m_axi_arready (m_ddr_arready[ch]),
                    .m_axi_rid     (m_ddr_rid[ch]),
                    .m_axi_rdata   (m_ddr_rdata[ch]),
                    .m_axi_rresp   (m_ddr_rresp[ch]),
                    .m_axi_rlast   (m_ddr_rlast[ch]),
                    .m_axi_rvalid  (m_ddr_rvalid[ch]),
                    .m_axi_rready  (m_ddr_rready[ch])
                );
            end
        end
    endgenerate

endmodule
