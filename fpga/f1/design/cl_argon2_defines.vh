// SPDX-License-Identifier: MIT
// Parameters and OCL register-map for the F1 argon2 CL.
//
// Addresses are byte offsets into the 4 KiB OCL BAR. The OCL bus is
// 32-bit, so every register below is one 32-bit word (addr = idx*4).

`ifndef CL_ARGON2_DEFINES_VH
`define CL_ARGON2_DEFINES_VH

// Number of independent DDR channels on f1.2xlarge / VU9P.
`define A2_NUM_DDR 4

// AXI geometry shared with rtl/argon2/argon2_fill_axi.sv
`define A2_AXI_ID_W   6
`define A2_AXI_ADDR_W 64
`define A2_AXI_DATA_W 512
`define A2_BLK_ADDR_W 32

// ---- OCL register map (word index) -------------------------------------
// 0x000 GLOBAL_START  WO  any write pulses start on all 4 lanes at once
// 0x004 CONTROL       RW  bit0 = p4_mode (join lanes into one p=4 job),
//                           bit1 = soft_reset (write pulses a 1-cycle reset)
// 0x008 STATUS        RO  busy[3:0] in bits[3:0], done[3:0] in bits[7:4]
// 0x010+8*L  lane L control block (L = 0..3):
//       +0  LANE_CTRL   RW  type_i[1:0], lanes[7:0] (informational)
//       +1  PASSES      RW  t   (time cost)
//       +2  LANE_LENGTH RW  q   (blocks per lane)
//       +3  MEMORY_BLKS RW  m'  (blocks in the working set)
//       +4  BASE_LO     RW  base byte address (low 32)
//       +5  BASE_HI     RW  base byte address (high 32)
//       +6,+7 reserved
`define A2_OCL_GLOBAL_START 8'd0
`define A2_OCL_CONTROL       8'd1
`define A2_OCL_STATUS        8'd2
`define A2_OCL_LANE_BASE     8'd16   // 0x10
`define A2_OCL_LANE_STRIDE   8'd8

`define A2_OCL_NREG          8'd64    // 256 bytes of register space

`endif
