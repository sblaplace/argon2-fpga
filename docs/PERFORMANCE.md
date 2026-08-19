# Performance model: how fast is the core, really?

The bring-up checklist assumes the DDR channels are the limit. Before
spending an F1 on it, this document answers the question in simulation:
**run the real RTL against a cycle-accurate DDR4 timing model and count
cycles.** All numbers below are measured, not estimated.

Run it:

```bash
make -C sim SIM=verilator perf            # N_P=1 (small-area core)
make -C sim SIM=verilator NP=8 perf       # N_P=8 (parallel-P core)
make -C sim PERF_BLKS=16384 NP=8 perf     # 16 MiB working set
```

`sim/tb_perf.sv` runs the same argon2i job (p=1, m' blocks, t=3, 200 MHz)
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

## Results (t=3, argon2i, p=1, 200 MHz, m' = 4 MiB)

| Config                              | cyc/blk | cand/s, 1 lane | F1 ×4 lanes | DDR port busy |
|-------------------------------------|---------|----------------|-------------|---------------|
| original core (HEAD, e5bde14)       | 301.6   | 0.211          | 0.84        | ~15%          |
| + FSM cache / dest fixes, N_P=1     | 249.2   | 0.255          | 1.02        | 15%           |
| N_P=2                               | 143.6   | 0.443          | 1.77        | 23%           |
| N_P=4                               | 92.6    | 0.686          | 2.75        | 34%           |
| **N_P=8 (recommended)**             | **68.7**| **0.926**      | **3.70**    | 47%           |

Per-lane IDEAL floor at N_P=8 is 64.3 cyc/blk (0.99 cand/s) — the core is
within ~7% of its own compute floor, and the DDR port is less than half
busy: **the lane is compute/latency-bound, not memory-bound**, exactly
the opposite of the README's original assumption.

The per-block structure at N_P=8 (DDR4, from the FSM histogram):

```
DISPATCH     1    copy prefetch→ref, prev comes from the write cache
COMPRESS    16    load beats (dest-xor read was prefetched a block early)
WRITE       46    2×P waves (~18) + 16-beat drain + write handshake
ADVANCE      2
DEST_WAIT    2.4  residual waits for the early dest read
────────────
~68 cyc/block
```

The AXI bus ceiling at 200 MHz is 12.8 GB/s ÷ ~11.5 GB traffic per
1 GiB candidate ≈ **1.07 cand/s/lane** (the shell's 512-bit @ 250 MHz
raises it to ~1.33). The remaining gap from 0.93 to the ceiling is the
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
2. **The write path is nearly free already** — an experiment with
   instant write commits (IDEAL_WR) gains only ~4 cyc/blk, so a
   multi-outstanding-write AXI adapter is not worth building.
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
  reference designs): same cycle counts → ~1.16 cand/s/lane, ~4.6 F1.
  Needs a timing-closure pass (the BlaMka mult-add chain is the
  critical path).
* **Write decoupling**: a FIFO so the 16-beat drain overlaps the next
  block's reads (measured upper bound ~10-15 cyc/blk; the adapter-side
  portion alone is only ~4).
* **Deeper P retiming** (the 2-wave × ~9-cycle P chain is the hard
  floor; 16 P units instead of 8 does not help — the column wave reads
  the row wave's output).
* 4× p=1 vs 1× p=4 cross-check once on hardware (they should match; the
  slice barrier is the only shared structure).

## Model caveats

* The DDR4 model is single-command-per-cycle with realistic latencies
  but no bank-group/tCCD modeling; at 12.8 GB/s AXI vs 19.2 GB/s DRAM the
  bus is the slower side, so this is faithful for this core's traffic.
* p=1 lanes don't interact; the 4-lane number is 4× per-lane. The p=4
  slice barrier is exercised functionally by `tb_cl_argon2` / the RFC
  bench but not yet timed against the DDR4 model.
* Verilator 5.4x (pip wheel) is the reference simulator for these
  numbers; the bench also builds under Icarus (`make -C sim perf`).
