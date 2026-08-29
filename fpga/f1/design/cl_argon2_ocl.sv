// SPDX-License-Identifier: MIT
// AXI4-lite OCL register slave for the F1 argon2 CL.
//
// The F1 shell presents the OCL bus to the CL as a flat 32-bit AXI4
// interface (sh_ocl_*). This module is the slave side: it accepts
// writes from the host, stores them in a 32-bit register file, and
// returns either the stored value or an external "status" override
// (driven by the fill cores) for read-only registers.
//
// Host writes are byte-strobed (wstrb). A one-hot `reg_wr` pulse marks
// the cycle a register is committed, so the parent can detect e.g. a
// GLOBAL_START write and generate a start pulse.

`timescale 1ns / 1ps

module cl_argon2_ocl #(parameter int NREG = 128, parameter int ADDRW = 12) (
    input  logic        clk,
    input  logic        rst_n,

    // ---- AXI4 (OCL) slave, flat sh_ocl_* signals -----------------------
    input  logic        awvalid,
    input  logic [31:0] awaddr,
    input  logic [15:0] awid,
    input  logic        wvalid,
    input  logic [31:0] wdata,
    input  logic [15:0] wstrb,
    output logic        awready,
    output logic        wready,
    output logic [15:0] bid,
    output logic [1:0]  bresp,
    output logic        bvalid,
    input  logic        bready,

    input  logic        arvalid,
    input  logic [31:0] araddr,
    input  logic [15:0] arid,
    output logic        arready,
    output logic [15:0] rid,
    output logic [31:0] rdata,
    output logic [1:0]  rresp,
    output logic        rlast,
    output logic        rvalid,
    input  logic        rready,

    // ---- Register file -------------------------------------------------
    output logic [31:0] regf      [0:NREG-1],  // written by host
    output logic [NREG-1:0] reg_wr,            // one-hot, single cycle
    input  logic [31:0] reg_in    [0:NREG-1],  // external RO overrides
    input  logic [NREG-1:0] reg_in_sel         // 1 => read returns reg_in
);

    // The OCL bus is byte-addressed, 32 bits per word: word index is the
    // byte address shifted right by 2. aw_addr/ar_addr are captured from
    // awaddr/araddr, so index the register file with bits [AW+1:2].
    localparam int AW = $clog2(NREG);   // word index width

    // ----- write channel -----
    logic              aw_cap, w_cap;
    logic [ADDRW-1:0]  aw_addr;
    logic [31:0]       w_data;
    logic [3:0]        w_strb;
    logic              commit;
    logic [31:0]       w_merge;   // RMW temp: Icarus can't bit-select a
                                  // register-file word in place

    assign awready = !aw_cap;
    assign wready  = !w_cap;
    assign commit  = aw_cap && w_cap && !bvalid;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_cap <= 1'b0;
            w_cap  <= 1'b0;
            bvalid <= 1'b0;
            reg_wr <= '0;
            for (int k = 0; k < NREG; k = k + 1)
                regf[k] <= 32'd0;
        end else begin
            reg_wr <= '0;
            if (awready && awvalid) begin
                aw_addr <= awaddr;
                aw_cap  <= 1'b1;
            end
            if (wready && wvalid) begin
                w_data <= wdata;
                w_strb <= wstrb[3:0];
                w_cap  <= 1'b1;
            end
            if (commit) begin
                w_merge = regf[aw_addr[AW+1:2]];
                for (int b = 0; b < 4; b++)
                    if (w_strb[b])
                        w_merge[b*8 +: 8] = w_data[b*8 +: 8];
                regf[aw_addr[AW+1:2]] <= w_merge;
                reg_wr[aw_addr[AW+1:2]] <= 1'b1;
                aw_cap <= 1'b0;
                w_cap  <= 1'b0;
                bvalid <= 1'b1;
            end
            if (bvalid && bready)
                bvalid <= 1'b0;
        end
    end

    assign bid   = 16'd0;
    assign bresp = 2'b00;

    // ----- read channel -----
    logic              ar_cap;
    logic [ADDRW-1:0]  ar_addr;
    logic [31:0]       rdata_comb;

    assign arready = !ar_cap && !rvalid;
    assign rdata_comb = reg_in_sel[ar_addr[AW+1:2]]
                      ? reg_in[ar_addr[AW+1:2]]
                      : regf[ar_addr[AW+1:2]];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ar_cap <= 1'b0;
            rvalid <= 1'b0;
        end else begin
            if (arready && arvalid) begin
                ar_addr <= araddr;
                ar_cap  <= 1'b1;
            end
            if (ar_cap && !rvalid) begin
                rdata <= rdata_comb;
                rresp <= 2'b00;
                rvalid <= 1'b1;
                ar_cap <= 1'b0;
            end else if (rvalid && rready) begin
                rvalid <= 1'b0;
            end
        end
    end

    assign rid   = 16'd0;
    assign rlast = 1'b1;

endmodule
