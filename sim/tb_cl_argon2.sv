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

    // ---- four DDR AXI4 master buses (flat, channel n = bit n) ---------
    logic [NUM_DDR-1:0]        ddr_awvalid, ddr_awready, ddr_wvalid, ddr_wlast, ddr_wready;
    logic [NUM_DDR-1:0]        ddr_bready, ddr_bvalid, ddr_arvalid, ddr_arready;
    logic [NUM_DDR-1:0]        ddr_rvalid, ddr_rlast, ddr_rready;
    logic [NUM_DDR-1:0][ADDR_W-1:0]  ddr_awaddr, ddr_araddr;
    logic [NUM_DDR-1:0][DATA_W-1:0]  ddr_wdata, ddr_rdata;
    logic [NUM_DDR-1:0][7:0]   ddr_awlen, ddr_arlen;
    logic [NUM_DDR-1:0][2:0]   ddr_awsize, ddr_arsize;
    logic [NUM_DDR-1:0][1:0]   ddr_awburst, ddr_arburst;
    logic [NUM_DDR-1:0]        ddr_awlock, ddr_arlock;
    logic [NUM_DDR-1:0][3:0]   ddr_awcache, ddr_arcache, ddr_awqos, ddr_arqos;
    logic [NUM_DDR-1:0][2:0]   ddr_awprot, ddr_arprot;
    logic [NUM_DDR-1:0][ID_W-1:0] ddr_awid, ddr_arid, ddr_bid, ddr_rid;
    logic [NUM_DDR-1:0][1:0]   ddr_bresp, ddr_rresp;
    logic [NUM_DDR-1:0][DATA_W/8-1:0] ddr_wstrb;

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
        .DDR_AXI_awvalid(ddr_awvalid), .DDR_AXI_awaddr(ddr_awaddr),
        .DDR_AXI_awlen(ddr_awlen), .DDR_AXI_awsize(ddr_awsize),
        .DDR_AXI_awburst(ddr_awburst), .DDR_AXI_awlock(ddr_awlock),
        .DDR_AXI_awcache(ddr_awcache), .DDR_AXI_awprot(ddr_awprot),
        .DDR_AXI_awqos(ddr_awqos), .DDR_AXI_awid(ddr_awid),
        .DDR_AXI_wdata(ddr_wdata), .DDR_AXI_wstrb(ddr_wstrb),
        .DDR_AXI_wlast(ddr_wlast), .DDR_AXI_wvalid(ddr_wvalid),
        .DDR_AXI_bready(ddr_bready),
        .DDR_AXI_araddr(ddr_araddr), .DDR_AXI_arlen(ddr_arlen),
        .DDR_AXI_arsize(ddr_arsize), .DDR_AXI_arburst(ddr_arburst),
        .DDR_AXI_arlock(ddr_arlock), .DDR_AXI_arcache(ddr_arcache),
        .DDR_AXI_arprot(ddr_arprot), .DDR_AXI_arqos(ddr_arqos),
        .DDR_AXI_arid(ddr_arid), .DDR_AXI_arvalid(ddr_arvalid),
        .DDR_AXI_rready(ddr_rready),
        .DDR_AXI_awready(ddr_awready), .DDR_AXI_wready(ddr_wready),
        .DDR_AXI_bvalid(ddr_bvalid), .DDR_AXI_bid(ddr_bid),
        .DDR_AXI_bresp(ddr_bresp), .DDR_AXI_arready(ddr_arready),
        .DDR_AXI_rvalid(ddr_rvalid), .DDR_AXI_rid(ddr_rid),
        .DDR_AXI_rdata(ddr_rdata), .DDR_AXI_rresp(ddr_rresp),
        .DDR_AXI_rlast(ddr_rlast),
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
        .s_axi_awid(ddr_awid[0]), .s_axi_awaddr(ddr_awaddr[0]), .s_axi_awlen(ddr_awlen[0]),
        .s_axi_awsize(ddr_awsize[0]), .s_axi_awvalid(ddr_awvalid[0]), .s_axi_awready(ddr_awready[0]),
        .s_axi_wdata(ddr_wdata[0]), .s_axi_wstrb(ddr_wstrb[0]), .s_axi_wlast(ddr_wlast[0]),
        .s_axi_wvalid(ddr_wvalid[0]), .s_axi_wready(ddr_wready[0]),
        .s_axi_bid(ddr_bid[0]), .s_axi_bresp(ddr_bresp[0]), .s_axi_bvalid(ddr_bvalid[0]), .s_axi_bready(ddr_bready[0]),
        .s_axi_arid(ddr_arid[0]), .s_axi_araddr(ddr_araddr[0]), .s_axi_arlen(ddr_arlen[0]),
        .s_axi_arvalid(ddr_arvalid[0]), .s_axi_arready(ddr_arready[0]),
        .s_axi_rid(ddr_rid[0]), .s_axi_rdata(ddr_rdata[0]), .s_axi_rresp(ddr_rresp[0]),
        .s_axi_rlast(ddr_rlast[0]), .s_axi_rvalid(ddr_rvalid[0]), .s_axi_rready(ddr_rready[0])
    );
    tb_axi_ram #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
                 .NBLK(NBLK), .RD_LAT(12)) ram1 (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(ddr_awid[1]), .s_axi_awaddr(ddr_awaddr[1]), .s_axi_awlen(ddr_awlen[1]),
        .s_axi_awsize(ddr_awsize[1]), .s_axi_awvalid(ddr_awvalid[1]), .s_axi_awready(ddr_awready[1]),
        .s_axi_wdata(ddr_wdata[1]), .s_axi_wstrb(ddr_wstrb[1]), .s_axi_wlast(ddr_wlast[1]),
        .s_axi_wvalid(ddr_wvalid[1]), .s_axi_wready(ddr_wready[1]),
        .s_axi_bid(ddr_bid[1]), .s_axi_bresp(ddr_bresp[1]), .s_axi_bvalid(ddr_bvalid[1]), .s_axi_bready(ddr_bready[1]),
        .s_axi_arid(ddr_arid[1]), .s_axi_araddr(ddr_araddr[1]), .s_axi_arlen(ddr_arlen[1]),
        .s_axi_arvalid(ddr_arvalid[1]), .s_axi_arready(ddr_arready[1]),
        .s_axi_rid(ddr_rid[1]), .s_axi_rdata(ddr_rdata[1]), .s_axi_rresp(ddr_rresp[1]),
        .s_axi_rlast(ddr_rlast[1]), .s_axi_rvalid(ddr_rvalid[1]), .s_axi_rready(ddr_rready[1])
    );
    tb_axi_ram #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
                 .NBLK(NBLK), .RD_LAT(12)) ram2 (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(ddr_awid[2]), .s_axi_awaddr(ddr_awaddr[2]), .s_axi_awlen(ddr_awlen[2]),
        .s_axi_awsize(ddr_awsize[2]), .s_axi_awvalid(ddr_awvalid[2]), .s_axi_awready(ddr_awready[2]),
        .s_axi_wdata(ddr_wdata[2]), .s_axi_wstrb(ddr_wstrb[2]), .s_axi_wlast(ddr_wlast[2]),
        .s_axi_wvalid(ddr_wvalid[2]), .s_axi_wready(ddr_wready[2]),
        .s_axi_bid(ddr_bid[2]), .s_axi_bresp(ddr_bresp[2]), .s_axi_bvalid(ddr_bvalid[2]), .s_axi_bready(ddr_bready[2]),
        .s_axi_arid(ddr_arid[2]), .s_axi_araddr(ddr_araddr[2]), .s_axi_arlen(ddr_arlen[2]),
        .s_axi_arvalid(ddr_arvalid[2]), .s_axi_arready(ddr_arready[2]),
        .s_axi_rid(ddr_rid[2]), .s_axi_rdata(ddr_rdata[2]), .s_axi_rresp(ddr_rresp[2]),
        .s_axi_rlast(ddr_rlast[2]), .s_axi_rvalid(ddr_rvalid[2]), .s_axi_rready(ddr_rready[2])
    );
    tb_axi_ram #(.ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W),
                 .NBLK(NBLK), .RD_LAT(12)) ram3 (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(ddr_awid[3]), .s_axi_awaddr(ddr_awaddr[3]), .s_axi_awlen(ddr_awlen[3]),
        .s_axi_awsize(ddr_awsize[3]), .s_axi_awvalid(ddr_awvalid[3]), .s_axi_awready(ddr_awready[3]),
        .s_axi_wdata(ddr_wdata[3]), .s_axi_wstrb(ddr_wstrb[3]), .s_axi_wlast(ddr_wlast[3]),
        .s_axi_wvalid(ddr_wvalid[3]), .s_axi_wready(ddr_wready[3]),
        .s_axi_bid(ddr_bid[3]), .s_axi_bresp(ddr_bresp[3]), .s_axi_bvalid(ddr_bvalid[3]), .s_axi_bready(ddr_bready[3]),
        .s_axi_arid(ddr_arid[3]), .s_axi_araddr(ddr_araddr[3]), .s_axi_arlen(ddr_arlen[3]),
        .s_axi_arvalid(ddr_arvalid[3]), .s_axi_arready(ddr_arready[3]),
        .s_axi_rid(ddr_rid[3]), .s_axi_rdata(ddr_rdata[3]), .s_axi_rresp(ddr_rresp[3]),
        .s_axi_rlast(ddr_rlast[3]), .s_axi_rvalid(ddr_rvalid[3]), .s_axi_rready(ddr_rready[3])
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

    // Icarus doesn't support unpacked-array task ports, so select the
    // RAM by channel number and read words through this helper.
    function automatic logic [511:0] ram_word(input integer ch, input integer idx);
        case (ch)
            0: ram_word = ram0.mem[idx];
            1: ram_word = ram1.mem[idx];
            2: ram_word = ram2.mem[idx];
            3: ram_word = ram3.mem[idx];
            default: ram_word = 512'd0;
        endcase
    endfunction

    task automatic check_ram(input integer ch, input string name);
        int m;
        logic [511:0] got;
        m = 0;
        for (int i = 0; i < NW; i = i + 1) begin
            got = ram_word(ch, i);
            if (got !== exp[i]) begin
                if (m < 4)
                    $display("FAIL %s beat %0d got %0128h exp %0128h",
                             name, i, got, exp[i]);
                m = m + 1;
            end
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
        $display("[dbg] GLOBAL_START written");

        // Poll STATUS until all four report done. Any real run finishes in
        // a few thousand polls; the cap just keeps a broken run fast.
        done = 4'b0; to = 0;
        while (done != 4'b1111 && to < 20000) begin
            ocl_read(32'h08, st);
            done = st[7:4];
            to = to + 1;
        end

        if (done != 4'b1111) begin
            $display("FAIL timeout (STATUS=0x%08h, polls=%0d)", st, to);
            // Postmortem: read the lane config back through the OCL and
            // peek at each lane's fill FSM state directly.
`ifndef VERILATOR
            // Icarus (like most tools) requires constant scope indices in
            // hierarchical references, so unroll the four lanes.
            for (int L = 0; L < NUM_DDR; L = L + 1) begin
                logic [31:0] base;
                logic [31:0] lc, ps, ll, mb;
                logic [4:0]  fst;
                base = 32'h40 + (32'(L) * 32'h20);
                ocl_read(base + 32'h00, lc);
                ocl_read(base + 32'h04, ps);
                ocl_read(base + 32'h08, ll);
                ocl_read(base + 32'h0C, mb);
                case (L)
                    0: fst = dut.u_core.lane[0].u_fill.state_o;
                    1: fst = dut.u_core.lane[1].u_fill.state_o;
                    2: fst = dut.u_core.lane[2].u_fill.state_o;
                    3: fst = dut.u_core.lane[3].u_fill.state_o;
                    default: fst = 5'd31;
                endcase
                $display("[dbg] lane%0d LANE_CTRL=%08h PASSES=%08h LEN=%08h BLKS=%08h state=%0d busy=%b done=%b",
                         L, lc, ps, ll, mb, fst,
                         dut.u_core.lane_busy[L],
                         dut.u_core.lane_done[L]);
            end
`endif
            errors = errors + 1;
        end else begin
            $display("all four lanes done in %0d OCL polls", to);
        end

        check_ram(0, "lane0");
        check_ram(1, "lane1");
        check_ram(2, "lane2");
        check_ram(3, "lane3");

        if (errors == 0)
            $display("tb_cl_argon2: PASS");
        else
            $display("tb_cl_argon2: FAIL (%0d)", errors);
        $finish;
    end
endmodule
