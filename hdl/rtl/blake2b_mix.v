// blake2b_mix.v
//
// The core BLAKE2b G mixing step — argon2's compression primitive.
// This is the fundamental 4-op transform at the heart of every argon2
// block-fill. Versions here are combinational and fully synthesizable
// (pure always-@* adder/rotate logic, no memories, no latches beyond the
// intentional combinational feedback through the intermediate regs).
//
// The transform (all 64-bit, mod-2^64 for the adds):
//
//     a := a + b + x
//     d := (d ^ a) >>> 32        (rotate-right by 32, i.e. word swap)
//     c := c + d
//     b := (b ^ c) >>> 24        (rotate-right by 24)
//
// NOTE: This is a KNOWN-ANSWER test point that locks in the primitive while
// the surrounding RTL/address logic is still being written. The golden
// vectors are asserted in tb_blake2b_mix.v and should be re-derived from an
// independent reference (e.g. RFC 7693 full BLAKE2b) once the complete round
// function lands.
//
// Latency: 0 (combinational). Purpose: prove the iverilog toolchain + the
// self-checking testbench runner in CI before any hardened pipeline exists.
//
module blake2b_mix(
    input  wire [63:0] a_in,
    input  wire [63:0] b_in,
    input  wire [63:0] c_in,
    input  wire [63:0] d_in,
    input  wire [63:0] x,          // message word being mixed in
    output reg  [63:0] a_out,
    output reg  [63:0] b_out,
    output reg  [63:0] c_out,
    output reg  [63:0] d_out
);

reg [63:0] a, b, c, d;

always @* begin
    a = a_in + b_in + x;                          // mod-2^64 add (wraps)
    d = (d_in ^ a);
    d = (d[31:0] << 32) | (d[63:32]);             // rotr64 by 32 == word swap
    c = c_in + d;
    b = (b_in ^ c);
    b = (b[23:0] << 40) | (b[63:24]);              // rotr64 by 24: low 24 -> top
    a_out = a;
    b_out = b;
    c_out = c;
    d_out = d;
end

endmodule
