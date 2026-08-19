# Performance model: how fast is the core, really?

The bring-up checklist assumes the DDR channels are the limit. Before
spending an F1 on it, this document answers the question in simulation:
**run the real RTL against a cycle-accurate DDR4 timing model and count
cycles.** All numbers below are measured, not estimated.

Run it:

```bash
make -C sim SIM=verilator perf                         # N_P=1 (small-area core)
make -C sim SIM=verilator PERF_NP=8 perf                # N_P=8 (parallel-P core, argon2i)
make -C sim SIM=verilator PERF_NP=8 PERF_BLKS=16384 perf # 16 MiB working set
make -C sim SIM=verilator PERF_NP=8 PERF_TYPE=0 perf     # argon2d
make -C sim SIM=verilator PERF_NP=8 PERF_TYPE=2 perf     # argon2id
```

`sim/tb_perf.sv` runs the same p=1, m'=NBLK, t=3 job (TYPE_I selectable)
twice:

* **IDEAL** — zero-latency, infinite-bandwidth memory. The pure
  compute + FSM floor (also ~what a BRAM-only stage-1 bring-up sees).
* **DDR4** — `sim/tb_ddr4_ram.sv`, a cycle-accurate DDR4-2400 channel:
  tRCD/tCL/tRP/tWL, per-bank open rows (1 KiB rows = 1 argon2 block),
  read↔write turnaround, tRFC/tREFI refresh, write responses only after
  commit, and read-priority scheduling with a write-starvation bound.
  512-bit AXI at 200 MHz = 12.8 GB/s, which caps the model as it does
  the real F1 shell.

The bench prints cycles/block, blocks/s, projected cand/s for the
1 GiB / t=3 reference job (3·2²⁰ compressions per candidate), measured
AXI traffic, port utilization, and an FSM-state cycle histogram.

## Results (t=3, p=1, 200 MHz, m' = 4 MiB, PERF_TYPE=1 argon2i unless noted)

| Config                              | cyc/blk | cand/s, 1 lane | F1 ×4 lanes | DDR port busy |
|-------------------------------------|---------|----------------|-------------|---------------|
| original core (HEAD, e5bde14)       | 301.6   | 0.211          | 0.84        | ~15%          |
| + FSM cache / dest fixes, N_P=1     | 249.2   | 0.255          | 1.02        | 15%           |
| N_P=2                               | 143.6   | 0.443          | 1.77        | 23%           |
| N_P=4                               | 92.6    | 0.686          | 2.75        | 34%           |
| **N_P=8 (prev, no write FIFO)**     | 68.7    | 0.926          | 3.70        | 47%           |
| **N_P=8 + 32-deep write FIFO (now)**| **67.9**| **0.937**     | **3.75**    | 48%           |

Per-lane IDEAL floor at N_P=8 is now **62.3 cyc/blk (1.02 cand/s)**
— down from 64.3 — the core is within ~9% of its own compute floor,
and the DDR port is less than half busy: **the lane is
compute/latency-bound, not memory-bound**, exactly the opposite of the
README's original assumption.

The per-block structure at N_P=8 (DDR4, from the FSM histogram,
m'=4096, t=3, argon2i):

```
DISPATCH     1    copy prefetch→ref, prev comes from the write cache
COMPRESS    16    load beats (dest-xor read was prefetched a block early)
WRITE       43    2×P waves (~18) + 16-beat push to FIFO (pop overlaps next)
ADVANCE      2.4
DEST_WAIT    4.0  residual waits for the early dest read
COLLECT_REF  0.3  etc.
────────────
~67.9 cyc/block
```

Ideal/Streaming experiment breakdown:

* Double-buffer that waited for full block before draining: IDEAL 63.1,
  DDR4 69.6 (worse, port busy 64% — write start delayed).
* **Streaming 32-deep FIFO (current): IDEAL 62.3, DDR4 67.9, port busy 48%**
  — saves ~2 cyc ideal, ~0.8 cyc DDR4 vs no-FIFO baseline.
* IDEAL_WR (instant write commits) experiment: 82→77.7 cyc/blk at N_P=1
  → adapter B-response worth only ~4 cyc.

### Type sweep (N_P=8, m'=1 MiB, t=3, DDR4)

| Type      | cyc/blk (DDR4) | cand/s/lane | F1×4 | Bottleneck |
|-----------|----------------|-------------|------|------------|
| argon2i   | 68 (67.9)      | 0.937       | 3.75 | WRITE/P    |
| argon2d   | ~107           | 0.593       | 2.37 | COLLECT_REF 30% — dependent ref, no prefetch |
| argon2id  | ~100           | 0.634       | 2.54 | mixed |

argon2i benefits from 128-block G prefetch (full compute-latency early).
argon2d has to wait for prev block to get J1||J2, then issue ref — the
random read latency is on the critical path. The cache still kills the
prev read, but ref remains.

The AXI bus ceiling at 200 MHz is 12.8 GB/s ÷ ~11.5 GB traffic per
1 GiB candidate ≈ **1.07 cand/s/lane** (the shell's 512-bit @ 250 MHz
raises it to ~1.33). The remaining gap from 0.94 to the ceiling is the
serial P→drain chain and AXI write handshakes.

## What the measurements forced

1. **The core was never memory-bound.** At HEAD, 80.7% of all cycles sat
   in WRITE — the FSM name for "waiting for the 16 serialized P
   permutations inside G" (~160 cycles/block). The 1 GiB t=3 projection
   was 0.21 cand/s/lane, 4–5× below the README's bandwidth-derived
   estimate. Fixes, in order of effect:
   * **N_P parallel P units** in `argon2_compress` (rows and columns of
     the 8×16 matrix are mutually independent — the RFC's 128 G's per
     block parallelize cleanly). N_P=8: ~160 → ~18 cycles of P per block.
     Bit-identical for every N_P (the full KAT suite runs at NP=8).
   * **Write-through prev cache**: the block just written is the next
     block's "prev" input — keep it in 1 KiB of registers instead of
     reading it back (killed the COLLECT_PREV read, ~30 cyc/blk).
   * **Early dest read**: the pass>0 dest-xor read for the next block is
     issued the moment the prefetch releases the read port, and its
     result lands in the background (~25 cyc/blk hidden).
   * **Dest streaming**: when the dest read has not landed by dispatch,
     its beats stream directly into the compression LOAD instead of a
     collect-then-load round trip.
   * **N_P plumbing in `argon2_addr_gen`** (each 128-address window is
     two counter-mode G's: 484 → 120 cycles per window).
   * **Streaming write FIFO (32 deep)**: the 16-beat drain now starts on
     first beat push and overlaps the next block's DISPATCH/COMPRESS.
     Includes RAW bypass: if a ref hits a pending write, stall until it
     drains; if it hits the cache (last block), use cache. Hit rate is
     negligible for 1 GiB (1/256k), but correctness is maintained.

2. **The write path is nearly free already** — an experiment with
   instant write commits (IDEAL_WR) gains only ~4 cyc/blk, so a
   multi-outstanding-write AXI adapter is not worth building. The FIFO
   itself saves another ~1 cyc DDR4 / ~2 cyc ideal.

3. **Four latent bugs in the F1 CL were found by running the benches**
   (the `cl` target had never elaborated in any simulator):
   * `sim/Makefile` listed a nonexistent `argon2_ref_area.sv`
     (the module lives in `argon2_index.sv`).
   * the standalone `axi_bus_t` interface was missing `rready`.
   * `cl_argon2_ocl` indexed the register file with the *low* address
     bits instead of byte-address >> 2 — every register above word 0
     aliased onto low words (spurious GLOBAL_START pulses, wrong lane
     config). Would have bricked the first real F1 run.
   * `done` was an unlatched 1-cycle pulse in STATUS; a host polling
     over PCIe could never see it. Now latched until the next start.

## Remaining headroom (in rough order)

* **250 MHz CL clock** (the F1 shell runs sh_ddr at 250 MHz in the
  reference designs): same cycle counts → ~1.17 cand/s/lane argon2i,
  ~4.7 F1. Needs a timing-closure pass (the BlaMka mult-add chain is the
  critical path).
* **Compress double-buffering**: LOAD of next block overlapping DRAIN of
  previous could hide another ~10-15 cyc, but needs 2× blk RAM in
  `argon2_compress`. Upper bound is AXI ceiling 1.07 @200 MHz.
* **Deeper P retiming** (the 2-wave × ~9-cycle P chain is the hard
  floor; 16 P units instead of 8 does not help — the column wave reads
  the row wave's output).
* 4× p=1 vs 1× p=4 cross-check once on hardware (they should match; the
  slice barrier is the only shared structure). The p=4 barrier is
  exercised functionally by `tb_cl_argon2` / RFC bench but not yet timed
  against the DDR4 model — need a p=4 perf bench.

## Model caveats

* The DDR4 model is single-command-per-cycle with realistic latencies
  but no bank-group/tCCD modeling; at 12.8 GB/s AXI vs 19.2 GB/s DRAM the
  bus is the slower side, so this is faithful for this core's traffic.
* p=1 lanes don't interact; the 4-lane number is 4× per-lane. The p=4
  slice barrier is exercised functionally by `tb_cl_argon2` / the RFC
  bench but not yet timed against the DDR4 model.
* Verilator 5.4x (pip wheel) is the reference simulator for these
  numbers; the bench also builds under Icarus (`make -C sim perf`).
* Write FIFO RAW handling stalls on hit; hit rate is ~1/lane_length, so
  performance impact is negligible, but it is required for correctness
  (ref could equal a recently written block).
