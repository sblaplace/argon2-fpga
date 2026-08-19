// SPDX-License-Identifier: MIT
// 8 KiB p=1 fill through argon2_fill_axi → AXI4-MM → tb_axi_ram.
// Same vectors as tb_argon2_fill; the adapter must be bit-identical.
`timescale 1ns / 1ps

module tb_argon2_axi #(
    parameter int N_P = 1   // parallel P units in the compression G
);
    localparam int NBLK   = 8;
    localparam int NBEAT  = 16;
    localparam int ADDR_W = 64;
    localparam int ID_W   = 6;
    localparam int DATA_W = 512;

    logic        clk, rst_n, start, busy, done, sync_req;
    logic [31:0] passes, lanes, lane_id, lane_length, memory_blocks;
    logic [1:0]  type_i;

    logic [ID_W-1:0]     awid, arid, bid, rid;
    logic [ADDR_W-1:0]   awaddr, araddr;
    logic [7:0]          awlen, arlen;
    logic [2:0]          awsize, arsize, awprot, arprot;
    logic [1:0]          awburst, arburst, bresp, rresp;
    logic                awlock, arlock;
    logic [3:0]          awcache, arcache, awqos, arqos;
    logic                awvalid, awready, wvalid, wready, wlast;
    logic                bvalid, bready, arvalid, arready;
    logic                rvalid, rready, rlast;
    logic [DATA_W-1:0]   wdata, rdata;
    logic [DATA_W/8-1:0] wstrb;

    argon2_fill_axi #(
        .AXI_ADDR_W(ADDR_W), .AXI_ID_W(ID_W), .AXI_DATA_W(DATA_W)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .done(done),
        .passes(passes), .lanes(lanes), .lane_id(lane_id),
        .lane_length(lane_length), .memory_blocks(memory_blocks),
        .type_i(type_i), .sync_req(sync_req), .sync_ack(1'b1),
        .base_addr(64'd0),
        .m_axi_awid(awid), .m_axi_awaddr(awaddr), .m_axi_awlen(awlen),
        .m_axi_awsize(awsize), .m_axi_awburst(awburst),
        .m_axi_awlock(awlock), .m_axi_awcache(awcache),
        .m_axi_awprot(awprot), .m_axi_awqos(awqos),
        .m_axi_awvalid(awvalid), .m_axi_awready(awready),
        .m_axi_wdata(wdata), .m_axi_wstrb(wstrb),
        .m_axi_wlast(wlast), .m_axi_wvalid(wvalid), .m_axi_wready(wready),
        .m_axi_bid(bid), .m_axi_bresp(bresp),
        .m_axi_bvalid(bvalid), .m_axi_bready(bready),
        .m_axi_arid(arid), .m_axi_araddr(araddr), .m_axi_arlen(arlen),
        .m_axi_arsize(arsize), .m_axi_arburst(arburst),
        .m_axi_arlock(arlock), .m_axi_arcache(arcache),
        .m_axi_arprot(arprot), .m_axi_arqos(arqos),
        .m_axi_arvalid(arvalid), .m_axi_arready(arready),
        .m_axi_rid(rid), .m_axi_rdata(rdata), .m_axi_rresp(rresp),
        .m_axi_rlast(rlast), .m_axi_rvalid(rvalid), .m_axi_rready(rready)
    );

    tb_axi_ram #(
        .ADDR_W(ADDR_W), .DATA_W(DATA_W), .ID_W(ID_W), .NBLK(NBLK), .RD_LAT(12)
    ) ram (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awid(awid), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(awsize), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb),
        .s_axi_wlast(wlast), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid), .s_axi_bresp(bresp),
        .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
    );

    logic [511:0] exp [0:NBLK*NBEAT-1];

    always #5 clk = ~clk;

    integer errors, cycles, i;

    task automatic run_job(
        input [1:0] typ, input string init_f, input string exp_f, input string name
    );
        integer mismatches;
        $display("axi %s …", name);
        rst_n = 1'b0;
        start = 1'b0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        @(posedge clk);
        $readmemh(init_f, ram.mem);
        $readmemh(exp_f, exp);
        type_i = typ;
        start  = 1'b1;
        @(posedge clk);
        start  = 1'b0;

        cycles = 0;
        while (!done && cycles < 400000) begin
            @(posedge clk);
            cycles = cycles + 1;
        end
        if (!done) begin
            $display("FAIL %s timeout", name);
            errors = errors + 1;
        end else begin
            // Drain a pending B after the last WLAST.
            repeat (8) @(posedge clk);

            mismatches = 0;
            for (i = 0; i < NBLK * NBEAT; i = i + 1) begin
                if (ram.mem[i] !== exp[i]) begin
                    if (mismatches < 4)
                        $display("FAIL %s beat %0d got %0128h exp %0128h",
                                 name, i, ram.mem[i], exp[i]);
                    mismatches = mismatches + 1;
                end
            end
            if (mismatches != 0) begin
                $display("FAIL %s %0d beat(s) differ (%0d cycles)",
                         name, mismatches, cycles);
                errors = errors + 1;
            end else begin
                $display("  %s PASS (%0d cycles)", name, cycles);
            end
        end
    endtask

    initial begin
        clk = 0;
        rst_n = 0;
        start = 0;
        passes = 32'd2;
        lanes = 32'd1;
        lane_id = 32'd0;
        lane_length = 32'd8;
        memory_blocks = 32'd8;
        type_i = 2'd1;
        errors = 0;
        repeat (6) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        run_job(2'd1, "gen/fill_i_init.hex",  "gen/fill_i_exp.hex",  "argon2i");
        run_job(2'd0, "gen/fill_d_init.hex",  "gen/fill_d_exp.hex",  "argon2d");
        run_job(2'd2, "gen/fill_id_init.hex", "gen/fill_id_exp.hex", "argon2id");

        if (errors == 0) begin
            $display("tb_argon2_axi PASS");
            $finish;
        end else begin
            $display("tb_argon2_axi FAIL (%0d)", errors);
            $fatal(1);
        end
    end
endmodule
