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
    cl_argon2_core.sv     # functional core: 4× (argon2_lane_conc + fill) + OCL + slice-sync
    cl_argon2_ocl.sv      # AXI4-lite OCL register slave (host programming)
    cl_argon2_defines.vh  # params + OCL register map
```

`cl_argon2_core` is deliberately **HDK-independent**: it has flat AXI4
master ports (one per channel) and a flat AXI4-lite OCL slave port, so it
can be simulated/linted on its own. `cl_argon2.sv` presents the shell port
list with the four DDR buses as **flat vector ports** (`DDR_AXI_*`, one
bit/word slice per channel — interface-free so any simulator, including
Icarus, can elaborate the design standalone). A real HDK build writes a
thin wrapper (or edits this top) mapping `DDR_AXI_*.w[n]` onto the
shell's `DDRx_AXI` ports / `axi_bus_t` members.

## Topology

* **Multi-context concentration (default, `CTXS_PER_CH=3`)** — each DDR4
  channel multiplexes 3 independent p=1 contexts through `argon2_lane_conc`
  and an AXI-MM adapter (`argon2_axi_mm`). Across 4 DDR channels, this runs
  **12 simultaneous contexts**, boosting aggregate F1 throughput from ~4.18
  cand/s to **~6.53 cand/s (+56%)** by saturating DDR4 channel bandwidth.
  When `CTXS_PER_CH=1`, the core falls back to single-context `argon2_fill_axi`
  per channel (4 total contexts).
* **p4_mode = 0** — independent p=1 jobs. Each context runs its own
  candidate against its own private DDR region (`lane_id = 0`).
* **p4_mode = 1 is not hardware-ready** — the slice barriers are AND-joined,
  but Argon2 can reference blocks in another lane. The shared-RAM
  `argon2_fill_job` bench naturally permits those reads; four physically
  separate DDR ports need an owner-channel read crossbar and response tags.
  Until that router exists, the host rejects `--p4` and only independent
  p=1 mode is supported on F1.

All lanes/contexts share one `start` pulse (a write to `GLOBAL_START`).

## OCL register map (byte addresses, 32-bit words)

| Addr | Name | R/W | Meaning |
|------|------|-----|---------|
| 0x000 | GLOBAL_START | WO  | any write pulses start on all active contexts |
| 0x004 | CONTROL | RW  | bit0 = p4_mode; bit1 = soft_reset (pulse) |
| 0x008 | STATUS | RO  | `busy[15:0]` in bits[15:0], `done[15:0]` in bits[31:16] (bits[7:4] also mirror done for 4-lane legacy compat) |
| 0x040 + 0x20·L | LANE_CTRL  | RW | `type_i[1:0]`, `lanes[7:0]` (informational) |
| 0x044 + 0x20·L | PASSES     | RW | t (time cost) |
| 0x048 + 0x20·L | LANE_LENGTH| RW | q (blocks per lane) |
| 0x04C + 0x20·L | MEMORY_BLKS| RW | m' (working-set blocks) |
| 0x050 + 0x20·L | BASE_LO    | RW | base byte address, low 32 |
| 0x054 + 0x20·L | BASE_HI    | RW | base byte address, high 32 |

`type_i`: 0 = argon2d, 1 = argon2i, 2 = argon2id.

The OCL bus is byte-addressed; word index *k* lives at byte `k*4`. Lane/context index
*L* (`0 <= L < NUM_DDR * CTXS_PER_CH`, up to 15) is mapped to DDR channel `L / CTXS_PER_CH`
and channel context `L % CTXS_PER_CH`. The byte address of context L's register block
is `(16 + L*8)*4 = 0x40 + 0x20·L`.

## Building in the AWS HDK

1. Copy this tree into the example, e.g.
   `cp -r fpga/f1/design $AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_dram_dma/design/argon2`
   and rename `cl_argon2.sv` to the example's top module name, **or** set
   the example's top module to `cl_argon2` (edit the example's build
   manifest). Keep `rtl/` next to it on the include/compile path.
2. The DDR buses are flat `DDR_AXI_*` vectors (channel n = bit n) so the
   design elaborates without the HDK. For a real build, connect
   `DDR_AXI_*.w[n]` onto your HDK's per-channel `DDRx_AXI` ports /
   `axi_bus_t` members from `cl_dram_dma_pkg.sv`. **Diff the port list
   against your HDK's `cl_ports.vh` / example top** — if your release adds
   signals the example doesn't (e.g. an OCL `awlen`/`awsize`, or DDR
   `awregion`), add them to the port list and tie them off.
3. Emit an HDK top and build:
   ```
   source $AWS_FPGA_REPO_DIR/hdk_setup.sh
   ./fpga/f1/build.sh emit-top --np 8 --top-module cl_dram_dma \
       --out $AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_dram_dma/design/cl_dram_dma.sv
   cd $AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_dram_dma
   aws_build_dcp_from_cl -foreground
   ```
   `./fpga/f1/build.sh dcp --np 8` wraps the same flow and saves a
   `cl_dram_dma.sv.argon2.bak` backup before overwriting the example top.

`cl_argon2` and `cl_argon2_core` take an `N_P` parameter (parallel P
units per compression G). Default 1 is the small core; build with
`N_P = 8` for the performance point measured in
[`docs/PERFORMANCE.md`](../docs/PERFORMANCE.md) (~1.03 cand/s/lane at
200 MHz; ~8× the DSPs of N_P=1, still ~2 kDSP for all four lanes on a
VU9P). The full KAT suite runs at both points
(`./fpga/f1/build.sh sim --np 8`, or `make -C sim SIM=verilator NP=8 all cl`).

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
3. **Full p=1 job on one port**, then **four independent p=1 jobs**.
   Add and verify the cross-channel read router before attempting p=4.

## Not yet done (stubs / TODO)

* A CL-owned PCIS data mover is not included. The CL drives the DRAM AXI
  ports, while `host/argon2_cl.c` uses the AWS SDK DMA API to preload and
  read back each DDR region before and after a job. This polling/DMA path is
  sufficient for bring-up but should be validated against the selected HDK
  release's BAR/channel mapping.
* Interrupt / `cl_sh_app_irq` to signal `done` to the host (polling
  STATUS works for bring-up).

## Simulation

`sim/tb_cl_argon2.sv` is a top-level bench: it instantiates the full
`cl_argon2` shell with four `tb_axi_ram` DDR models and an OCL BFM, runs a
known-answer argon2i (m=8 KiB, t=2) job on all 12 contexts (3 per channel)
in independent p=1 mode, and compares each context's working set against
the RFC-golden vector. Run it from `sim/`:

```
make vectors     # dump gen/fill_i_*_exp.hex from ref/
make cl          # build + run tb_cl_argon2 (iverilog) — or: make SIM=verilator cl
```

The per-channel path is also exercised in isolation by `sim/tb_argon2_axi.sv`,
and the concentrator is exercised in isolation by `sim/tb_argon2_conc.sv`.

