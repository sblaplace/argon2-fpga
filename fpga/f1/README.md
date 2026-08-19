# AWS F1 CL for argon2-fpga

This directory is the **F1 shell** — the Custom Logic (CL) top that drops
into the AWS FPGA HDK `cl_dram_dma` example and runs the argon2 fill core
on the four independent DDR4 channels of an `f1.2xlarge` (VU9P).

## What's here

```
fpga/f1/
  filelist.f            # standalone compile order (iverilog / verilator)
  design/
    cl_argon2.sv          # CL top — the F1 shell port list (drop-in for cl_dram_dma)
    cl_argon2_core.sv     # functional core: 4× argon2_fill_axi + OCL + slice-sync
    cl_argon2_ocl.sv      # AXI4-lite OCL register slave (host programming)
    cl_argon2_ddr_connect.sv  # adapts one shell axi_bus_t to the core's flat AXI
    cl_argon2_axi_if.sv   # local axi_bus_t (used only when no HDK is present)
    cl_argon2_defines.vh  # params + OCL register map
```

`cl_argon2_core` is deliberately **HDK-independent**: it has flat AXI4
master ports (one per channel) and a flat AXI4-lite OCL slave port, so it
can be simulated/linted on its own. `cl_argon2.sv` is the thin HDK-facing
adapter that maps the standard `cl_dram_dma` port list (four `DDRx_AXI`
`axi_bus_t` buses + flat `sh_ocl_*` + clock/reset/FLR) onto it.

## Topology

* **p4_mode = 0** — four independent p=1 jobs. Each channel runs its own
  candidate against its own private DDR region (`lane_id = 0`).
* **p4_mode = 1** — one p=4 job spread across the four channels. Core *L*
  walks lane *L* of the same job; the four slice barriers are AND-joined,
  exactly the `argon2_fill_job` barrier in `rtl/argon2/`. This is the
  partitioned-bandwidth design the whole project is built around.

All four cores share one `start` pulse (a write to `GLOBAL_START`) so a
p=4 job begins in lockstep.

## OCL register map (byte addresses, 32-bit words)

| Addr | Name | R/W | Meaning |
|------|------|-----|---------|
| 0x000 | GLOBAL_START | WO  | any write pulses start on all 4 lanes |
| 0x004 | CONTROL | RW  | bit0 = p4_mode; bit1 = soft_reset (pulse) |
| 0x008 | STATUS | RO  | `busy[3:0]` in bits[3:0], `done[3:0]` in bits[7:4] |
| 0x040 + 0x20·L | LANE_CTRL  | RW | `type_i[1:0]`, `lanes[7:0]` (informational) |
| 0x044 + 0x20·L | PASSES     | RW | t (time cost) |
| 0x048 + 0x20·L | LANE_LENGTH| RW | q (blocks per lane) |
| 0x04C + 0x20·L | MEMORY_BLKS| RW | m' (working-set blocks) |
| 0x050 + 0x20·L | BASE_LO    | RW | base byte address, low 32 |
| 0x054 + 0x20·L | BASE_HI    | RW | base byte address, high 32 |

`type_i`: 0 = argon2d, 1 = argon2i, 2 = argon2id.

The OCL bus is byte-addressed; word index *k* lives at byte `k*4`. The
register file is word-indexed internally (lane L's `LANE_CTRL` is word
`16 + L*8`), so the byte address of a lane register is `(16 + L*8 + offset)*4`
— hence the `0x40 + 0x20·L` base above.

## Building in the AWS HDK

1. Copy this tree into the example, e.g.
   `cp -r fpga/f1/design $AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_dram_dma/design/argon2`
   and rename `cl_argon2.sv` to the example's top module name, **or** set
   the example's top module to `cl_argon2` (edit the example's build
   manifest). Keep `rtl/` next to it on the include/compile path.
2. Make sure the `axi_bus_t` type matches your HDK release. By default
   `cl_argon2_axi_if.sv` provides a local `axi_bus_t`. For a real build,
   define `AXI_BUS_T_DEFINED` first (or `include` your HDK's
   `cl_dram_dma_pkg.sv` / `axi_bus_defines.vh` before `cl_argon2.sv`) so
   the shell's exact bus type is shared. **Diff the port list against your
   HDK's `cl_ports.vh` / example top** — if your release adds signals the
   example doesn't (e.g. an OCL `awlen`/`awsize`, or DDR `awregion`), add
   them to the port list and tie them off.
3. Build:
   ```
   source $AWS_FPGA_REPO_DIR/hdk_setup.sh
   cd $AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_dram_dma
   aws_build_dcp_from_cl -foreground
   ```

`cl_argon2` and `cl_argon2_core` take an `N_P` parameter (parallel P
units per compression G). Default 1 is the small core; build with
`N_P = 8` for the performance point measured in
[`docs/PERFORMANCE.md`](../docs/PERFORMANCE.md) (~0.93 cand/s/lane at
200 MHz; ~8× the DSPs of N_P=1, still ~2 kDSP for all four lanes on a
VU9P). The full KAT suite runs at both points
(`make -C sim SIM=verilator NP=8 all cl`).

## First bring-up (the next step)

Per `docs/ARCHITECTURE.md` step 3, bring it up in this order:

1. **One-channel KAT in BRAM.** The 32 KiB RFC 9106 §5 vector fits in
   BRAM. Replay it through a single `argon2_fill_axi` (the `sim/tb_argon2_axi`
   bench already does this against a behavioral RAM) before touching DDR.
   This proves the fill pipeline end-to-end on real CL logic.
2. **DDR bandwidth microbench.** Replace the BRAM model with the `sh_ddr`
   port and run `cl_dram_dma`-style traffic to confirm each channel hits
   its isolated bandwidth. The 16-beat / 512-bit bursts in `argon2_axi_mm`
   are sized for exactly this.
3. **Full job on one port**, then **p=4 across all four**.

## Not yet done (stubs / TODO)

* PCIS / host DMA path (`sh_cl_dma_pcis`) — currently the working set is
  assumed pre-loaded into each channel's region via the existing DMA; the
  CL only drives the DRAM AXI ports. (The host driver skeleton in
  `host/argon2_cl.c` documents the OCL programming; the DMA transfer is
  left as a TODO there.)
* Interrupt / `cl_sh_app_irq` to signal `done` to the host (polling
  STATUS works for bring-up).

## Simulation

`sim/tb_cl_argon2.sv` is a top-level bench: it instantiates the full
`cl_argon2` shell with four `tb_axi_ram` DDR models and an OCL BFM, runs a
known-answer argon2i (m=8 KiB, t=2) job on all four channels in independent
p=1 mode, and compares each channel's working set against the RFC-golden
vector. Run it from `sim/`:

```
make vectors     # dump gen/fill_i_*_exp.hex from ref/
make cl          # build + run tb_cl_argon2 (iverilog) — or: make SIM=verilator cl
```

The per-channel path is also exercised in isolation by `sim/tb_argon2_axi.sv`.

