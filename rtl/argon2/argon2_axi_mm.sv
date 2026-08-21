// SPDX-License-Identifier: MIT
// Block-addressed fill-controller port → AXI4-MM (512-bit).
//
// One 16-beat INCR burst per 1 KiB Argon2 block. One outstanding read.

`timescale 1ns / 1ps

module argon2_axi_mm #(
    parameter int AXI_ADDR_W = 64,
    parameter int AXI_ID_W   = 6,
    parameter int AXI_DATA_W = 512,
    parameter int BLK_ADDR_W = 32
) (
    input  logic                      clk,
    input  logic                      rst_n,
    input  logic [AXI_ADDR_W-1:0]     base_addr,

    input  logic                      mem_rd_valid,
    output logic                      mem_rd_ready,
    input  logic [BLK_ADDR_W-1:0]     mem_rd_addr,
    output logic                      mem_rd_data_v,
    output logic [AXI_DATA_W-1:0]     mem_rd_data,
    output logic                      mem_rd_last,

    input  logic                      mem_wr_valid,
    output logic                      mem_wr_ready,
    input  logic [BLK_ADDR_W-1:0]     mem_wr_addr,
    input  logic [AXI_DATA_W-1:0]     mem_wr_data,
    input  logic                      mem_wr_last,

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
    localparam int AXI_SIZE = $clog2(AXI_DATA_W / 8);

    logic rd_pend;
    logic wr_aw_sent;
    logic wr_b_wait;

    assign mem_rd_ready = !rd_pend && !m_axi_arvalid;
    assign m_axi_rready = rd_pend;
    assign mem_rd_data_v = m_axi_rvalid && m_axi_rready;
    assign mem_rd_data   = m_axi_rdata;
    assign mem_rd_last   = m_axi_rlast;

    assign mem_wr_ready = wr_aw_sent && m_axi_wready && !wr_b_wait;
    assign m_axi_wvalid = mem_wr_valid && wr_aw_sent && !wr_b_wait;
    assign m_axi_wdata  = mem_wr_data;
    assign m_axi_wlast  = mem_wr_last;
    assign m_axi_wstrb  = '1;
    assign m_axi_bready = wr_b_wait;

    assign m_axi_awid    = '0;
    assign m_axi_awlen   = 8'd15;
    assign m_axi_awsize  = 3'(AXI_SIZE);
    assign m_axi_awburst = 2'b01;
    assign m_axi_awlock  = 1'b0;
    assign m_axi_awcache = 4'b0011;
    assign m_axi_awprot  = 3'b000;
    assign m_axi_awqos   = 4'b0000;

    assign m_axi_arid    = '0;
    assign m_axi_arlen   = 8'd15;
    assign m_axi_arsize  = 3'(AXI_SIZE);
    assign m_axi_arburst = 2'b01;
    assign m_axi_arlock  = 1'b0;
    assign m_axi_arcache = 4'b0011;
    assign m_axi_arprot  = 3'b000;
    assign m_axi_arqos   = 4'b0000;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_pend       <= 1'b0;
            m_axi_arvalid <= 1'b0;
            m_axi_araddr  <= '0;
            wr_aw_sent    <= 1'b0;
            wr_b_wait     <= 1'b0;
            m_axi_awvalid <= 1'b0;
            m_axi_awaddr  <= '0;
        end else begin
            if (mem_rd_valid && mem_rd_ready) begin
                m_axi_arvalid <= 1'b1;
                m_axi_araddr  <= base_addr + (AXI_ADDR_W'(mem_rd_addr) << 10);
                rd_pend       <= 1'b1;
            end else if (m_axi_arvalid && m_axi_arready) begin
                m_axi_arvalid <= 1'b0;
            end

            if (m_axi_rvalid && m_axi_rready && m_axi_rlast)
                rd_pend <= 1'b0;

            if (mem_wr_valid && !wr_aw_sent && !wr_b_wait && !m_axi_awvalid) begin
                m_axi_awvalid <= 1'b1;
                m_axi_awaddr  <= base_addr + (AXI_ADDR_W'(mem_wr_addr) << 10);
            end else if (m_axi_awvalid && m_axi_awready) begin
                m_axi_awvalid <= 1'b0;
                wr_aw_sent    <= 1'b1;
            end

            if (m_axi_wvalid && m_axi_wready && m_axi_wlast) begin
                wr_aw_sent <= 1'b0;
                wr_b_wait  <= 1'b1;
            end
            if (m_axi_bvalid && m_axi_bready)
                wr_b_wait <= 1'b0;
        end
    end
endmodule
