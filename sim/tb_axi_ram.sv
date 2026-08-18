// SPDX-License-Identifier: MIT
// AXI4-MM slave used by tb_argon2_axi. 512-bit beats, 16-beat bursts,
// programmable read latency. AW is held off one cycle and WREADY
// toggles so the adapter's backpressure paths actually fire.
`timescale 1ns / 1ps

module tb_axi_ram #(
    parameter int ADDR_W = 64,
    parameter int DATA_W = 512,
    parameter int ID_W   = 6,
    parameter int NBLK   = 8,
    parameter int RD_LAT = 12
) (
    input  logic                    clk,
    input  logic                    rst_n,

    input  logic [ID_W-1:0]         s_axi_awid,
    input  logic [ADDR_W-1:0]       s_axi_awaddr,
    input  logic [7:0]              s_axi_awlen,
    input  logic [2:0]              s_axi_awsize,
    input  logic                    s_axi_awvalid,
    output logic                    s_axi_awready,

    input  logic [DATA_W-1:0]       s_axi_wdata,
    input  logic [DATA_W/8-1:0]     s_axi_wstrb,
    input  logic                    s_axi_wlast,
    input  logic                    s_axi_wvalid,
    output logic                    s_axi_wready,

    output logic [ID_W-1:0]         s_axi_bid,
    output logic [1:0]              s_axi_bresp,
    output logic                    s_axi_bvalid,
    input  logic                    s_axi_bready,

    input  logic [ID_W-1:0]         s_axi_arid,
    input  logic [ADDR_W-1:0]       s_axi_araddr,
    input  logic [7:0]              s_axi_arlen,
    input  logic                    s_axi_arvalid,
    output logic                    s_axi_arready,

    output logic [ID_W-1:0]         s_axi_rid,
    output logic [DATA_W-1:0]       s_axi_rdata,
    output logic [1:0]              s_axi_rresp,
    output logic                    s_axi_rlast,
    output logic                    s_axi_rvalid,
    input  logic                    s_axi_rready
);
    localparam int NBEAT = 16;

    logic [DATA_W-1:0] mem [0:NBLK*NBEAT-1];

    logic        rd_busy;
    logic [31:0] rd_idx;
    logic [4:0]  rd_beat;
    logic [7:0]  rd_wait;
    logic [7:0]  rd_len;
    logic [ID_W-1:0] rd_id;

    logic        wr_have;
    logic        aw_seen;
    logic [31:0] wr_idx;
    logic [4:0]  wr_beat;
    logic [ID_W-1:0] wr_id;
    logic        w_gate;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s_axi_arready <= 1'b1;
            s_axi_awready <= 1'b0;
            s_axi_wready  <= 1'b0;
            s_axi_rvalid  <= 1'b0;
            s_axi_rlast   <= 1'b0;
            s_axi_rdata   <= '0;
            s_axi_rid     <= '0;
            s_axi_bvalid  <= 1'b0;
            s_axi_bid     <= '0;
            rd_busy       <= 1'b0;
            rd_idx        <= 32'd0;
            rd_beat       <= 5'd0;
            rd_wait       <= 8'd0;
            rd_len        <= 8'd0;
            rd_id         <= '0;
            wr_have       <= 1'b0;
            aw_seen       <= 1'b0;
            wr_idx        <= 32'd0;
            wr_beat       <= 5'd0;
            wr_id         <= '0;
            w_gate        <= 1'b1;
        end else begin
            s_axi_rvalid <= 1'b0;
            s_axi_rlast  <= 1'b0;
            w_gate       <= ~w_gate;

            // Read address: accept when idle.
            s_axi_arready <= !rd_busy;
            if (!rd_busy && s_axi_arvalid && s_axi_arready) begin
                rd_idx  <= s_axi_araddr[31:6];
                rd_len  <= s_axi_arlen;
                rd_beat <= 5'd0;
                rd_wait <= RD_LAT[7:0];
                rd_id   <= s_axi_arid;
                rd_busy <= 1'b1;
                s_axi_arready <= 1'b0;
            end else if (rd_busy && rd_wait != 8'd0) begin
                rd_wait <= rd_wait - 8'd1;
            end else if (rd_busy) begin
                s_axi_rvalid <= 1'b1;
                s_axi_rdata  <= mem[rd_idx + 32'(rd_beat)];
                s_axi_rid    <= rd_id;
                s_axi_rlast  <= (rd_beat == 5'(rd_len));
                if (s_axi_rready) begin
                    if (rd_beat == 5'(rd_len))
                        rd_busy <= 1'b0;
                    else
                        rd_beat <= rd_beat + 5'd1;
                end
            end

            // Write address: drop ready for one cycle after awvalid rises.
            if (!wr_have && !s_axi_bvalid) begin
                if (s_axi_awvalid && !aw_seen) begin
                    aw_seen       <= 1'b1;
                    s_axi_awready <= 1'b0;
                end else if (s_axi_awvalid && aw_seen) begin
                    s_axi_awready <= 1'b1;
                end else begin
                    s_axi_awready <= 1'b0;
                end
                if (s_axi_awvalid && s_axi_awready) begin
                    wr_have       <= 1'b1;
                    wr_idx        <= s_axi_awaddr[31:6];
                    wr_beat       <= 5'd0;
                    wr_id         <= s_axi_awid;
                    aw_seen       <= 1'b0;
                    s_axi_awready <= 1'b0;
                end
            end else begin
                s_axi_awready <= 1'b0;
            end

            s_axi_wready <= wr_have && !s_axi_bvalid && w_gate;
            if (wr_have && s_axi_wvalid && s_axi_wready) begin
                mem[wr_idx + 32'(wr_beat)] <= s_axi_wdata;
                if (s_axi_wlast) begin
                    wr_have      <= 1'b0;
                    s_axi_bvalid <= 1'b1;
                    s_axi_bid    <= wr_id;
                    s_axi_wready <= 1'b0;
                end else begin
                    wr_beat <= wr_beat + 5'd1;
                end
            end
            if (s_axi_bvalid && s_axi_bready)
                s_axi_bvalid <= 1'b0;
        end
    end
endmodule
