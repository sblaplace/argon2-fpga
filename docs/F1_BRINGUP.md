# AWS F1 Hello-World Bring-Up

This is the checklist for the first real hardware run on `f1.2xlarge` (VU9P, 4× DDR4-2400). It is ordered so each stage proves one variable before the next adds a new one — you never debug DRAM, logic, and the host at the same time.

All RTL already passes the Python golden model (`make test` → 25 tests, RFC 9106 §5) and the eight Icarus/Verilator self-checks (`make -C sim`, `make -C sim SIM=verilator`). The vectors for those checks are dumped from `ref/` into `sim/gen/` by `python3 -m tests.dump_vectors` and the top-level CL bench `sim/tb_cl_argon2.sv` already runs a 4-channel argon2i job against behavioral `tb_axi_ram`s.

The job below moves that same bench from simulation to the wire.

## 0. What hello-world proves

| # | What runs | Where | Success criterion | Why it matters |
|---|-----------|-------|-------------------|----------------|
| 1 | 32 KiB RFC vector in BRAM | CL logic only, no DDR | Whole working set matches `sim/gen/rfc_i_exp.hex` | The fill pipeline is bit-correct before DRAM is involved |
| 2 | DDR bandwidth microbench | `sh_ddr` AXI, no argon2 logic | Each channel ≈ 12-15 GB/s bursts, 4 channels isolated (no cross-interference) | Bandwidth × channel count is the only number that matters (see `docs/ARCHITECTURE.md`) |
| 3a | 8 KiB p=1 KAT on 1 DDR | 1× `argon2_fill_axi` + 1× DDR + OCL | Same working-set match as `sim/tb_argon2_axi.sv`, but through DDR | Address generation, 512-bit 16-beat bursts, prefetch, and AXI are correct on the wire |
| 3b | 8 KiB p=1 job on 4 DDRs (independent) | 4× `argon2_fill_axi`, p4_mode=0 | Four lanes each match `sim/gen/fill_i_exp.hex` (`tb_cl_argon2` in sim) | Replication and OCL fan-out work; this is the “4 candidates per FPGA” mode |
| 3c (deferred) | 32 KiB p=4 job across 4 DDRs | Add owner-channel read crossbar, response tags, and slice barrier | Working set matches `sim/gen/rfc_i_exp.hex` with p=4 | Argon2 references other lanes; a barrier alone cannot connect partitioned memories |

Per-argon2 bandwidth at 1 GiB / t=4 / p=1 is ≈ 4 GB random + 4 GB sequential reads + 4 GB writes ≈ 12 GB of DRAM traffic. A single Kintex SODIMM (≈ 5 GB/s random) caps a huge fabric at ~1 cand/s; each independent F1 DDR channel at ~10-12 GB/s random should sustain ~1-1.2 cand/s, so `f1.2xlarge` is a ~4 cand/s machine and an HBM2 Alveo U50 (32 pseudo-channels) is a ~tens cand/s machine. The bring-up measures the ceiling before we try to beat it.

## 1. Prerequisites (once)

On the F1 instance (Amazon Linux 2 / Ubuntu with the HDK):

```bash
# HDK and SDK
git clone https://github.com/aws/aws-fpga.git $AWS_FPGA_REPO_DIR
source $AWS_FPGA_REPO_DIR/hdk_setup.sh
source $AWS_FPGA_REPO_DIR/sdk_setup.sh

# This repo
git clone https://github.com/sblaplace/argon2-fpga.git
cd argon2-fpga
make test                        # 25 tests, no simulator
python3 -m tests.dump_vectors    # sim/gen/*.hex
# optional full sim (needs iverilog or verilator)
sudo yum install -y iverilog    # or: sudo apt install iverilog verilator
make -C sim cl                  # tb_cl_argon2: 4× 8 KiB argon2i in sim
```

The golden vectors are locked to RFC 9106 §5 (p=4 / m=32 KiB / t=3 / H0+tags in `tests/test_argon2.py`). If your host is not an F1 instance yet, `sim/tb_cl_argon2.sv` + `tb_axi_ram` is the complete CL exercised with a 12-cycle read latency — the same prefetch/compress/write ordering that runs on DDR.

## 2. Stage 1 — One-channel KAT in BRAM (no DDR)

Do this inside the CL before you trust the shell.

*The bench `sim/tb_argon2_axi.sv` already does it*: it attaches a single `argon2_fill_axi` to one `tb_axi_ram` preloaded with `fill_i_init.hex` and checks the result against `fill_i_exp.hex`. That is the reference for what the CL should see when you preload a BRAM.

On hardware, synthesize the same 32 KiB vector (RFC §5) into a BRAM ROM inside the CL or preload it via OCL from host memory, run one pass through `argon2_fill_ctrl`, and compare the working set word-for-word. No `sh_ddr` involved — if this fails, the bug is in G / index / FSM, not in DRAM.

```bash
# In sim, this already passes on both backends:
make -C sim axi        # 8 KiB through argon2_fill_axi + tb_axi_ram
make -C sim rfc        # 32 KiB p=4 through argon2_fill_job (slice barrier)
```

## 3. Stage 2 — DDR bandwidth microbench

Before running argon2 on DRAM, prove each `sh_ddr` port actually hits its isolated bandwidth with the same 512-bit / 16-beat bursts the fill core uses.

The `cl_dram_dma` example the CL is based on already contains the microbench: each DDR does 512-bit, 16-beat bursts (`awlen=15`, `awsize=6` (64 B), `awburst=01` INCR) with independent read and write channels so a prefetch can overlap a write.

Steps on the F1 shell:

1. Build the vanilla `cl_dram_dma` (no argon2) and run its host `test_dram_dma` — record per-channel read/write GB/s.
2. Swap in `cl_argon2` (keep the same `filelist.f` bursts: 512-bit, `wstrb=64'hFFFF`, `awlen=15`) and re-run the same traffic pattern through `argon2_axi_mm`. You should see the same per-channel number, and — crucially — all four channels in parallel should be ~4× one channel with no drop (isolated ports, no shared SODIMM).

Use the new host helper at `fpga/f1/host/bw_test.c` for step 2:

```bash
gcc -I$AWS_FPGA_REPO_DIR/sdk/userspace/include \
    -L$AWS_FPGA_REPO_DIR/sdk/userspace/lib -lfpga_mgmt -lfpga_pci \
    fpga/f1/host/bw_test.c -o bw_test

sudo ./bw_test --channel 0 --bytes $((32*1024)) --burst 16
sudo ./bw_test --all --bytes $((1<<30)) --burst 16   # 1 GiB, 4 channels
```

Expected on `f1.2xlarge` (DDR4-2400, 64-bit DIMM per channel): ~12-15 GB/s sequential bursts per channel, ~8-10 GB/s for 1 KiB random (argon2's access size) — and 4× that when all channels fire together. If the 4-channel number collapses to ~1×, you have a shared-port bug (the one that caps the XC7K420T SODIMM board at ~1 cand/s).

## 4. Stage 3 — Full argon2 job on DDR

### 4a. Single DDR, 8 KiB p=1 KAT

This is `sim/tb_argon2_axi.sv` moved to the wire with one `argon2_fill_axi`.
The published 32 KiB RFC vector is a p=4 job and cannot be relabeled p=1;
run it in the four-channel step immediately afterward.

```bash
gcc -I$AWS_FPGA_REPO_DIR/sdk/userspace/include \
    -L$AWS_FPGA_REPO_DIR/sdk/userspace/lib -lfpga_mgmt -lfpga_pci \
    fpga/f1/host/argon2_cl.c -o argon2_cl

# Program channel 0 for the same p=1 KAT used by tb_argon2_axi:
sudo ./argon2_cl --type i --passes 2 --lane-len 8 --mem-blocks 8 --base 0 \
                 --channel 0 --init sim/gen/fill_i_init.hex --expect sim/gen/fill_i_exp.hex

```

Do not run the old `--p4` hardware command yet. The host rejects it until
cross-lane reference reads can be routed to the DDR channel that owns the
selected lane.

What `argon2_cl` does (see `fpga/f1/host/argon2_cl.c`):

1. `fpga_mgmt_init`, `fpga_pci_attach(slot, pf, id, write_combine, &handle)`
2. DMA the init working set into each channel's DDR region (`base + L * m'*1024`) via `fpga_pci_mem_write` / `sh_cl_dma_pcis` — for the 32 KiB vector this is 32 KiB, for a 1 GiB job it is 1 GiB per channel.
3. Write the OCL register file (byte addresses, 32-bit words):

```
0x000  GLOBAL_START  (WO, any write pulses start)
0x004  CONTROL       (bit0 = p4_mode, bit1 = soft_reset pulse)
0x008  STATUS        (RO: busy[3:0] in bits[3:0], done[3:0] in bits[7:4])
0x040 + 0x20*L:
  +0x00 LANE_CTRL   type_i[1:0] (0=d 1=i 2=id), lanes[7:0] (info)
  +0x04 PASSES      t
  +0x08 LANE_LENGTH q
  +0x0C MEMORY_BLKS m'
  +0x10 BASE_LO     base[31:0]
  +0x14 BASE_HI     base[63:32]
```

All four independent lanes share one `GLOBAL_START` pulse. The CL also contains the p4 slice barrier used by the shared-memory functional harness, but that mode is disabled until cross-channel reference reads are routed correctly.

4. Poll `STATUS` until `done == 0xF` in independent mode.
5. DMA the final working set back and `memcmp` against `*_exp.hex`.

### 4b. Four independent p=1 jobs (the scaling proof)

Same as above but with `p4_mode = 0`. Each channel is lane_id 0 in its own private `m'` region:

```
for L in 0..3:
  LANE_CTRL[L] = type_i | (1 << 8)   // lanes=1
  PASSES[L]    = 2                     // t=2 for the 8 KiB KAT
  LANE_LENGTH[L] = 8                  // q = 8
  MEMORY_BLKS[L] = 8                  // m' = 8
  BASE_LO/HI[L]  = channel_base[L]
write GLOBAL_START
poll STATUS until done == 0xF
```

This is exactly `sim/tb_cl_argon2.sv` — four copies of the 8 KiB argon2i KAT (`password`/`somesalt` / t=2 / m=8) running in parallel, each checked against `gen/fill_i_exp.hex`. On hardware each lane should return the same PASS and the measured cand/s should be ~4× one lane (no sharing).

### 4c. One p=4 job across four channels (deferred)

Do not set `CONTROL[0]` on hardware yet. Core L writes lane L locally, but a
reference selected by Argon2 may belong to any lane. The current CL sends
that global block address to core L's local DDR port, which reads the wrong
physical channel whenever `ref_lane != L`. The shared-memory RFC bench does
not expose this partitioning error.

The required next block is a 4×4 read crossbar: decode the owner lane from
`ref_idx / lane_length`, arbitrate requests at each DDR channel, tag the
requesting core, and route each returning 16-beat block back to that core.
Writes remain local, and the existing slice barrier remains valid. Re-enable
`--p4` only after the RFC p=4 KAT passes through a simulation model with four
truly separate memories.

### Host driver notes

* The CL only drives the DDR AXI ports. The working set must be DMAd into each channel's region beforehand and DMAd back afterward. The host driver in `argon2_cl.c` programs OCL with `fpga_pci_poke/peek` and uses `fpga_pci_dma_write/read` for preload/readback. Confirm its BAR and channel mapping against the exact AWS HDK release used for the build; a CL-owned PCIS data mover is not included.
* `BASE` is a byte address on the DDR AXI (64-bit). For contiguous per-channel regions use `base[L] = base0 + L * m' * 1024`.
* If `STATUS` is stuck at `busy != 0, done == 0` in supported p=1 mode, inspect the lane parameters and AXI response path. Do not use p4 mode until the cross-channel read router is implemented.
* Interrupts (`cl_sh_app_irq`) are not yet wired — polling `STATUS` is the bring-up path.

## 5. Building the CL bitstream

From an F1 instance with the HDK sourced:

```bash
source $AWS_FPGA_REPO_DIR/hdk_setup.sh
cd $AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_dram_dma

# Option A: drop fpga/f1/design/* into this example and build in place
# Emit a self-contained top wrapper for the performance point (N_P=8).
# The wrapper keeps the real sources in the repo checkout and makes the
# example compile a single top file named cl_dram_dma.
./fpga/f1/build.sh emit-top --np 8 --top-module cl_dram_dma \
    --out $AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_dram_dma/design/cl_dram_dma.sv

cd $AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_dram_dma
aws_build_dcp_from_cl -foreground

# Or let the helper emit the wrapper + build it in one step:
cd /path/to/argon2-fpga
./fpga/f1/build.sh dcp --np 8

# Or: standalone lint/sim without the HDK
./fpga/f1/build.sh lint --np 8
./fpga/f1/build.sh sim --np 8
```

**Timing closure at 250 MHz.** The core, OCL, and all four DDR AXI ports are synchronous on the shell's `clk_main_a0` (250 MHz) — no CDC and no `create_clock` to add (the shell SDC owns it). The one CL-specific synth setting is **DSP48 register-packing for the BlaMka multiply-add** via retiming: source `fpga/f1/build/synth_timing.tcl` into the HDK synthesis tcl (it sets `STEPS.SYNTH_DESIGN.ARGS.RETIMING true` on `synth_1`) before `launch_runs`. The worst pre-existing 200 MHz path — a 32-bit divider in `argon2_index` (3 instances) — is already removed (conditional subtract, bit-identical), so 250 MHz now rests on the BlaMka/DSP axis. Measured target and the full Vivado checklist: `docs/TIMING_250MHZ.md`.

The DCP → AFI flow (`create_fpga_image`, `fpga-load-local-image`) is the standard F1 flow — see `fpga/f1/README.md` and the HDK docs. The checklist above assumes you can already build and load `cl_dram_dma`; `cl_argon2` is a drop-in replacement for its top.

## 6. What to measure

Once 3a-3c PASS on the RFC vectors, scale to a bandwidth-sized job and measure:

* **1 GiB / t=4 / p=1** — the README's reference: ~4 M compresses, ~4 GB random refs. Time one `GLOBAL_START` → `done` and compute `cand/s = 1 / wall_seconds` per channel. The core runs on the shell's 250 MHz `clk_main_a0`; the measured projection (clock-parameterized perf model, `make -C sim perf250`) is **argon2id 1.240 / argon2d 1.210 / argon2i 1.135 cand/s per channel** — four channels ≈ **4.96 / 4.84 / 4.54 cand/s**. If the build does not yet close at 250 MHz, run the perf bench at the achieved fmax (`make -C sim PERF_MHZ=<fmax> perf`) to get the realistic per-channel number. Full closure map + checklist: `docs/TIMING_250MHZ.md`.
* **Four simultaneous 1 GiB p=1 jobs** — aggregate cand/s should be about 4× one channel. Measure p=4 only after the owner-channel read crossbar is implemented; its arbitration cost then becomes a separate result.
* **Burst counters** — add an AXI performance counter on `awlen==15` / `arlen==15` bursts per channel if you want to confirm 512-bit 16-beat is actually issuing.

These numbers are the gate for the next hardware (Alveo U50, 32 HBM pseudo-channels): the same `cl_argon2_core` with `NUM_DDR=32` and one `argon2_fill_axi` per pseudo-channel.

## 7. Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Icarus build fails with `unknown module type argon2_fill_axi` | Missing `rtl/` on the include path — add `-I../../rtl/include -I design` and `-f filelist.f` |
| `STATUS` never reaches `done==0xF` | Invalid lane parameters or a stalled AXI response; p4 mode is not currently supported on partitioned DDR |
| `done` asserts but data mismatch on beat 0 / 15 | Old `argon2_fill_ctrl` handshake bug (word 0 twice / word 15 never) — already fixed by driving `c_in_*` combinationally from `state`/`beat` |
| 4-channel BW ≈ 1-channel BW | Shared SODIMM or a single AXI interconnect — re-check `cl_sh_ddr_areset_n` and that each `DDR_AXI_*` channel slice is wired to a distinct `sh_ddr` port |
| OCL writes silently ignored | `awaddr` word vs. byte confusion — OCL BAR is byte-addressed, so word k is at byte `k*4`; lane L base is `(16 + L*8)*4 = 0x40 + 0x20*L` |

## 8. References

* `fpga/f1/README.md` — OCL register map and HDK integration notes
* `sim/tb_cl_argon2.sv` — 4-channel CL bench (the sim version of stage 3b)
* `sim/tb_argon2_axi.sv` — single-channel AXI bench (stage 3a in sim)
* `docs/ARCHITECTURE.md` — bandwidth thesis and per-core DSP/cycle budget
* RFC 9106 §5 — 32 KiB p=4 vectors (the KAT used in stages 1 and 3)
