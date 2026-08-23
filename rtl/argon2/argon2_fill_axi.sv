// SPDX-License-Identifier: MIT
// Single-lane fill core with an AXI4-MM memory port.
//
// This is the unit that sits on one F1 sh_ddr / HBM pseudo-channel.
// Multi-channel jobs instantiate several of these and join sync_req /
// sync_ack (or wrap the block-port argon2_fill_job and attach one
// argon2_axi_mm per lane).

`timescale 1ns / 1ps

module argon2_fill_axi #(
    parameter int AXI_ADDR_W = 64,
    parameter int AXI_ID_W   = 6,
    parameter int AXI_DATA_W = 512,
    parameter int BLK_ADDR_W = 32,
    parameter int N_P        = 1   // parallel P units in the compression G
) (
    input  logic                      clk,
    input  logic                      rst_n,

    input  logic                      start,
    output logic                      busy,
    output logic                      done,
    input  logic [31:0]               passes,
    input  logic [31:0]               lanes,
    input  logic [31:0]               lane_id,
    input  logic [31:0]               lane_length,
    input  logic [31:0]               memory_blocks,
    input  logic [1:0]                type_i,
    output logic                      sync_req,
    input  logic                      sync_ack,
    input  logic [AXI_ADDR_W-1:0]     base_addr,

    output logic [4:0]                state_o,

    output logic [AXI_ID_W-1:0]       m_axi_awid,
    output logic [AXI_ADDR_W-1:0]     m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [1:0]                m_axi_awburst,
    output logic                      m_axi_awlock,
    output logic [3:0]                m_axi_awcache,
    output logic [2:0]                m_axi_awprot,
    output logic [3:0]                m_axi_awqos,
    output logic                      m_axi_awvalid,
    input  logic                      m_axi_awready,

    output logic [AXI_DATA_W-1:0]     m_axi_wdata,
    output logic [AXI_DATA_W/8-1:0]   m_axi_wstrb,
    output logic                      m_axi_wlast,
    output logic                      m_axi_wvalid,
    input  logic                      m_axi_wready,

    input  logic [AXI_ID_W-1:0]       m_axi_bid,
    input  logic [1:0]                m_axi_bresp,
    input  logic                      m_axi_bvalid,
    output logic                      m_axi_bready,

    output logic [AXI_ID_W-1:0]       m_axi_arid,
    output logic [AXI_ADDR_W-1:0]     m_axi_araddr,
    output logic [7:0]                m_axi_arlen,
    output logic [2:0]                m_axi_arsize,
    output logic [1:0]                m_axi_arburst,
    output logic                      m_axi_arlock,
    output logic [3:0]                m_axi_arcache,
    output logic [2:0]                m_axi_arprot,
    output logic [3:0]                m_axi_arqos,
    output logic                      m_axi_arvalid,
    input  logic                      m_axi_arready,

    input  logic [AXI_ID_W-1:0]       m_axi_rid,
    input  logic [AXI_DATA_W-1:0]     m_axi_rdata,
    input  logic [1:0]                m_axi_rresp,
    input  logic                      m_axi_rlast,
    input  logic                      m_axi_rvalid,
    output logic                      m_axi_rready
);
    logic                      mem_rd_valid, mem_rd_ready, mem_rd_data_v, mem_rd_last;
    logic                      mem_wr_valid, mem_wr_ready, mem_wr_last;
    logic [BLK_ADDR_W-1:0]     mem_rd_addr, mem_wr_addr;
    logic [AXI_DATA_W-1:0]     mem_rd_data, mem_wr_data;

    argon2_fill_ctrl #(.ADDR_W(BLK_ADDR_W), .N_P(N_P)) u_fill (
        .clk           (clk),
        .rst_n         (rst_n),
        .start         (start),
        .busy          (busy),
        .done          (done),
        .passes        (passes),
        .lanes         (lanes),
        .lane_id       (lane_id),
        .lane_length   (lane_length),
        .memory_blocks (memory_blocks),
        .type_i        (type_i),
        .sync_req      (sync_req),
        .sync_ack      (sync_ack),
        .state_o       (state_o),
        .mem_rd_valid  (mem_rd_valid),
        .mem_rd_ready  (mem_rd_ready),
        .mem_rd_addr   (mem_rd_addr),
        .mem_rd_owner  (),   // p=1 unit: no crossbar, owner always 0
        .mem_rd_data_v (mem_rd_data_v),
        .mem_rd_data   (mem_rd_data),
        .mem_rd_last   (mem_rd_last),
        .mem_wr_valid  (mem_wr_valid),
        .mem_wr_ready  (mem_wr_ready),
        .mem_wr_addr   (mem_wr_addr),
        .mem_wr_data   (mem_wr_data),
        .mem_wr_last   (mem_wr_last)
    );

    argon2_axi_mm #(
        .AXI_ADDR_W (AXI_ADDR_W),
        .AXI_ID_W   (AXI_ID_W),
        .AXI_DATA_W (AXI_DATA_W),
        .BLK_ADDR_W (BLK_ADDR_W)
    ) u_axi (
        .clk           (clk),
        .rst_n         (rst_n),
        .base_addr     (base_addr),
        .mem_rd_valid  (mem_rd_valid),
        .mem_rd_ready  (mem_rd_ready),
        .mem_rd_addr   (mem_rd_addr),
        .mem_rd_data_v (mem_rd_data_v),
        .mem_rd_data   (mem_rd_data),
        .mem_rd_last   (mem_rd_last),
        .mem_wr_valid  (mem_wr_valid),
        .mem_wr_ready  (mem_wr_ready),
        .mem_wr_addr   (mem_wr_addr),
        .mem_wr_data   (mem_wr_data),
        .mem_wr_last   (mem_wr_last),
        .m_axi_awid    (m_axi_awid),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awlock  (m_axi_awlock),
        .m_axi_awcache (m_axi_awcache),
        .m_axi_awprot  (m_axi_awprot),
        .m_axi_awqos   (m_axi_awqos),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bid     (m_axi_bid),
        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),
        .m_axi_arid    (m_axi_arid),
        .m_axi_araddr  (m_axi_araddr),
        .m_axi_arlen   (m_axi_arlen),
        .m_axi_arsize  (m_axi_arsize),
        .m_axi_arburst (m_axi_arburst),
        .m_axi_arlock  (m_axi_arlock),
        .m_axi_arcache (m_axi_arcache),
        .m_axi_arprot  (m_axi_arprot),
        .m_axi_arqos   (m_axi_arqos),
        .m_axi_arvalid (m_axi_arvalid),
        .m_axi_arready (m_axi_arready),
        .m_axi_rid     (m_axi_rid),
        .m_axi_rdata   (m_axi_rdata),
        .m_axi_rresp   (m_axi_rresp),
        .m_axi_rlast   (m_axi_rlast),
        .m_axi_rvalid  (m_axi_rvalid),
        .m_axi_rready  (m_axi_rready)
    );
endmodule
