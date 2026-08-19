# AWS F1 Hello-World Bring-Up

This is the checklist for the first real hardware run on `f1.2xlarge` (VU9P, 4× DDR4-2400). It is ordered so each stage proves one variable before the next adds a new one — you never debug DRAM, logic, and the host at the same time.

All RTL already passes the Python golden model (`make test` → 25 tests, RFC 9106 §5) and the eight Icarus/Verilator self-checks (`make -C sim`, `make -C sim SIM=verilator`). The vectors for those checks are dumped from `ref/` into `sim/gen/` by `python3 -m tests.dump_vectors` and the top-level CL bench `sim/tb_cl_argon2.sv` already runs a 4-channel argon2i job against behavioral `tb_axi_ram`s.

The job below moves that same bench from simulation to the wire.

## 0. What hello-world proves

| # | What runs | Where | Success criterion | Why it matters |
|---|-----------|-------|-------------------|----------------|
| 1 | 32 KiB RFC vector in BRAM | CL logic only, no DDR | Whole working set matches `sim/gen/rfc_i_exp.hex` | The fill pipeline is bit-correct before DRAM is involved |
| 2 | DDR bandwidth microbench | `sh_ddr` AXI, no argon2 logic | Each channel ≈ 12-15 GB/s bursts, 4 channels isolated (no cross-interference) | Bandwidth × channel count is the only number that matters (see `docs/ARCHITECTURE.md`) |
| 3a | 32 KiB RFC vector on 1 DDR | 1× `argon2_fill_axi` + 1× DDR + OCL | Same working-set match as #1, but through DDR | Address generation, 512-bit 16-beat bursts, prefetch, and AXI are correct on the wire |
| 3b | 8 KiB p=1 job on 4 DDRs (independent) | 4× `argon2_fill_axi`, p4_mode=0 | Four lanes each match `sim/gen/fill_i_exp.hex` (`tb_cl_argon2` in sim) | Replication and OCL fan-out work; this is the “4 candidates per FPGA” mode |
| 3c | 32 KiB p=4 job across 4 DDRs | 4× `argon2_fill_axi`, p4_mode=1, slice barrier | Working set matches `sim/gen/rfc_i_exp.hex` with p=4 | The partitioned-bandwidth thesis — one job, four isolated ports, barrier at each slice |

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

### 4a. Single DDR, RFC 32 KiB vector

This is `sim/tb_argon2_axi.sv` moved to the wire with one `argon2_fill_axi`:

```bash
gcc -I$AWS_FPGA_REPO_DIR/sdk/userspace/include \
    -L$AWS_FPGA_REPO_DIR/sdk/userspace/lib -lfpga_mgmt -lfpga_pci \
    fpga/f1/host/argon2_cl.c -o argon2_cl

# Program lane 0 for the RFC 32 KiB p=1 slice (q = m'/p = 8) as a smoke:
sudo ./argon2_cl --type i --passes 3 --lane-len 8 --mem-blocks 32 --base 0 \
                 --channel 0 --init sim/gen/rfc_i_init.hex --expect sim/gen/rfc_i_exp.hex

# Then the real RFC p=4 vector via the CL's p4_mode (all 4 DDRs, one job):
sudo ./argon2_cl --type i --passes 3 --lane-len 8 --mem-blocks 32 --p4 \
                 --base 0 --init sim/gen/rfc_i_init.hex --expect sim/gen/rfc_i_exp.hex
```

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

All four lanes share one `GLOBAL_START` pulse so a p=4 job begins in lockstep. The per-lane `sync_req` / `sync_ack` barrier is AND-joined in `cl_argon2_core` (`sync_ack = {4{&sync_req}}`) — exactly the `argon2_fill_job` barrier — so slices stay aligned without host intervention.

4. Poll `STATUS` until `done == 0xF` (independent mode) or `done == 0xF` in p4_mode (all four lanes finish their slice at the same time).
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

### 4c. One p=4 job across four channels

Set `CONTROL[0] = 1` (p4_mode). Now core *L* walks lane *L* of the same job:

```
CONTROL = 0x01
for L in 0..3:
  LANE_CTRL[L] = type_i | (4 << 8)   // lanes=4 (informational)
  PASSES[L]    = 3
  LANE_LENGTH[L] = 8                 // q = m'/p = 32/4
  MEMORY_BLKS[L] = 32                // m' = 32
  BASE_LO/HI[L]  = shared_base       // all four point into the same job's regions
write GLOBAL_START
poll STATUS
```

Only the slice barrier crosses channels — one bit per lane, AND-joined. No data crosses channels. This is the thesis in `README.md`: **N independent ports = N full-rate instances**, and a single p=4 job is just four cooperating instances.

### Host driver notes

* The CL only drives the DDR AXI ports. The working set must be DMAd into each channel's region beforehand and DMAd back afterward (via `sh_cl_dma_pcis`, exposed as `fpga_pci_mem_write/read` in the SDK). The skeleton in `argon2_cl.c` documents the TODO; the fleshed driver in this repo implements it with `fpga_pci_attach` + `fpga_pci_poke/peek` for OCL and `fpga_pci_dma_write/read` for the DDR preload.
* `BASE` is a byte address on the DDR AXI (64-bit). For contiguous per-channel regions use `base[L] = base0 + L * m' * 1024`.
* If you see `STATUS` stuck at `busy != 0, done == 0`, the slice barrier is deadlocked — usually `p4_mode` mismatched between lanes or one lane's `q` / `m'` typoed so it waits forever at `SLICE_SYNC`.
* Interrupts (`cl_sh_app_irq`) are not yet wired — polling `STATUS` is the bring-up path.

## 5. Building the CL bitstream

From an F1 instance with the HDK sourced:

```bash
source $AWS_FPGA_REPO_DIR/hdk_setup.sh
cd $AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_dram_dma

# Option A: drop fpga/f1/design/* into this example and build in place
cp -r /path/to/argon2-fpga/fpga/f1/design ./argon2
cp -r /path/to/argon2-fpga/rtl ./rtl
cp /path/to/argon2-fpga/fpga/f1/design/cl_argon2_defines.vh ./

# Edit the example manifest so the top is cl_argon2 (or rename cl_argon2.sv
# to the example's top name). Ensure axi_bus_t matches your HDK release:
# define AXI_BUS_T_DEFINED and include your HDK's cl_dram_dma_pkg.sv /
# axi_bus_defines.vh before cl_argon2.sv if needed (see fpga/f1/README.md).

aws_build_dcp_from_cl -foreground

# Or: standalone lint without the HDK
cd /path/to/argon2-fpga/fpga/f1
iverilog -g2012 -I../../rtl/include -I design -o /tmp/cl_argon2.out design/cl_argon2.sv -f filelist.f
verilator --lint-only -I../../rtl/include -I design -f filelist.f design/cl_argon2.sv
```

The DCP → AFI flow (`create_fpga_image`, `fpga-load-local-image`) is the standard F1 flow — see `fpga/f1/README.md` and the HDK docs. The checklist above assumes you can already build and load `cl_dram_dma`; `cl_argon2` is a drop-in replacement for its top.

## 6. What to measure

Once 3a-3c PASS on the RFC vectors, scale to a bandwidth-sized job and measure:

* **1 GiB / t=4 / p=1** — the README's reference: ~4 M compresses, ~4 GB random refs. Time one `GLOBAL_START` → `done` and compute `cand/s = 1 / wall_seconds` per channel. Expect ≈ 1-1.2 cand/s per DDR channel at 200 MHz (≈ 1.25 M G/s, ~1.2 GiB/s random) — four channels ≈ 4-5 cand/s.
* **4× 1 GiB p=1 vs. 1× 4 GiB p=4** — should be the same aggregate cand/s (partitioned ports don't care). If p=4 is slower, the slice barrier or the shared `base` is wrong.
* **Burst counters** — add an AXI performance counter on `awlen==15` / `arlen==15` bursts per channel if you want to confirm 512-bit 16-beat is actually issuing.

These numbers are the gate for the next hardware (Alveo U50, 32 HBM pseudo-channels): the same `cl_argon2_core` with `NUM_DDR=32` and one `argon2_fill_axi` per pseudo-channel.

## 7. Troubleshooting

| Symptom | Likely cause |
|---------|--------------|
| Icarus build fails with `unknown module type argon2_fill_axi` | Missing `rtl/` on the include path — add `-I../../rtl/include -I design` and `-f filelist.f` |
| `STATUS` never reaches `done==0xF` | `p4_mode` bit mismatched; or `LANE_LENGTH` / `MEMORY_BLKS` typoed so one lane waits at `SLICE_SYNC` forever |
| `done` asserts but data mismatch on beat 0 / 15 | Old `argon2_fill_ctrl` handshake bug (word 0 twice / word 15 never) — already fixed by driving `c_in_*` combinationally from `state`/`beat` |
| 4-channel BW ≈ 1-channel BW | Shared SODIMM or a single AXI interconnect — re-check `cl_sh_ddr_areset_n` and that each `DDR_AXI_*` channel slice is wired to a distinct `sh_ddr` port |
| OCL writes silently ignored | `awaddr` word vs. byte confusion — OCL BAR is byte-addressed, so word k is at byte `k*4`; lane L base is `(16 + L*8)*4 = 0x40 + 0x20*L` |

## 8. References

* `fpga/f1/README.md` — OCL register map and HDK integration notes
* `sim/tb_cl_argon2.sv` — 4-channel CL bench (the sim version of stage 3b)
* `sim/tb_argon2_axi.sv` — single-channel AXI bench (stage 3a in sim)
* `docs/ARCHITECTURE.md` — bandwidth thesis and per-core DSP/cycle budget
* RFC 9106 §5 — 32 KiB p=4 vectors (the KAT used in stages 1 and 3)
