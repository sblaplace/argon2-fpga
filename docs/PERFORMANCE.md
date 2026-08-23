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
| **N_P=8 + 32-deep write FIFO**      | 67.9    | 0.937          | 3.75        | 48%           |
| **+ compress double-buffer + overlapped next-block send**        | 61.8 | 1.029 | 4.12 | 55%  |
| **+ dependent fast path / RAW fixes (now, argon2i)**             | **63.4** | **1.003** | **4.01** | **52%** |
| **+ dependent fast path / RAW fixes (now, argon2d)**             | **63.1** | **1.007** | **4.03** | **49%** |
| **+ dependent fast path / RAW fixes (now, argon2id)**            | **60.9** | **1.044** | **4.18** | **51%** |

Per-lane IDEAL floor at N_P=8 is now **56.3 cyc/blk (1.13 cand/s)** —
down from 62.3 — because the double-buffered compressor lets LOAD of the
next block overlap DRAIN of the current one, so overlapped blocks cost no
COMPRESS cycles at all. The DDR4 number (61.8 cyc/blk, 1.029 cand/s) is
within ~4% of the 200 MHz AXI bus ceiling (~1.07 cand/s/lane): **the lane
is now essentially AXI-bandwidth-bound for argon2i**, and the DDR port is
55% busy.

The per-block structure at N_P=8 (DDR4, from the FSM histogram,
m'=4096, t=3, argon2i):

```
DISPATCH     1.6  copy prefetch→ref (skipped for overlapped blocks)
COMPRESS    10.9  pass-0 blocks overlap away their LOAD (chained send)
WRITE       41.2  2×P waves (~18) + 16-beat push to FIFO + first-beat wait
ADVANCE      3.3  fast path for overlapped blocks (no prefetch wait)
DEST_WAIT    4.0  pass>0 residual waits for the early dest read
ADDR_WAIT    1.5  one G-window per 128 blocks
COLLECT_REF  0.4  etc.
────────────
~61.8 cyc/block
```

How the overlap works (`argon2_compress` double-buffer +
`argon2_fill_ctrl` overlapped send): while the compressor drains block N
it accepts block N+1's data into its idle buffer. The fill controller
streams it in lockstep with the drain beats — prev is the current output
beat forwarded combinatorially, ref is the already-prefetched block — and
the next prefetch (block N+2) is issued during the same drain via a
redirected second address port, so every independent block chains (no
COMPRESS state at all). Passes 1–2 keep the serial COMPRESS→WRITE path
(the dest-xor read would not be ready before the drain starts with a
single memory port); that is why the average lands between "all pass 0
blocks free" and the old number.

### Type sweep (N_P=8, m'=4 MiB, t=3, DDR4)

| Type      | cyc/blk (DDR4) | cand/s/lane | F1×4 | Bottleneck |
|-----------|----------------|-------------|------|------------|
| argon2i   | 63.4           | 1.003       | 4.01 | AXI bus ceiling (~1.07); ~0.7 cyc/blk of prefetch-safety fallbacks |
| argon2d   | 63.1           | 1.007       | 4.03 | P latency + dep-read tail (see "Dependent fast path" below) |
| argon2id  | 60.9           | 1.044       | 4.18 | mixed |

All three types now run within ~6% of each other and ~6% of the 200 MHz
AXI ceiling (~1.07 cand/s/lane). History: before the dependent fast path
the d/id rows were 97.2 / 0.654 / 2.62 and 93.1 / 0.683 / 2.73; argon2i
was 61.8 / 1.029 / 4.12 and gives back ~2.5% to the prefetch-safety fix
(see "Write-FIFO RAW" below) — correctness over a single-type cost.

### Dependent fast path (argon2d / argon2id, all passes)

Two mechanisms, landed one at a time on green KATs:

1. **Early deterministic dest read + dep read in every pass.** The pass>0
   dest-xor word lives at the *next block's own position* — a fully
   deterministic address with no data dependence. A COMPRESS-state hook
   issues it while the read port is idle in dependent mode; the dependent
   ref read (issued at drain beat 0 as before, now allowed in pass>0 too)
   queues behind it on the single outstanding read — exactly the schedule
   the port wants. Measured: argon2d 97.2 → 73.7 cyc/blk (0.654 → 0.863
   cand/s), argon2id 93.1 → 69.0 (0.683 → 0.922), argon2i bit-identical.
2. **Stream the returning dep read into the load (DSM_REF).** Instead of
   waiting for all 16 dep beats and then re-loading them from registers,
   DISPATCH enters COMPRESS while the dep burst is still in flight: beats
   already collected replay from dep_q (a `dep_cnt` watermark), the beat
   currently on the port flows straight into the compressor input, and the
   load ends with the read instead of after it. Measured on top of (1):
   argon2d 73.7 → 63.1 (0.863 → 1.007), argon2id 69.0 → 60.9
   (0.922 → 1.044). The ADVANCE dep_ready wait is relaxed only when the
   fast path will consume the read live (prev in the write-through cache,
   dest ready / no xor).

Per-block structure at N_P=8 (DDR4, argon2d): WRITE 43.0 (two P waves +
16-beat drain, the hard floor), COMPRESS 18.3 (dep-beat-paced load),
~2 cycles of everything else.

### Write-FIFO RAW + reference-area bugs found by the geometry sweep

Extending KAT coverage past m'=8 (`sim/tb_argon2_axi_sweep.sv`,
m' ∈ {16,32,64,128} × t ∈ {1,2,3} × i/d/id) exposed two latent bugs in
previously-landed optimizations — invisible at m'=8 because
segment_length=2 makes both reference-area mappings coincide and short
reference distances always clear the 32-beat write FIFO, and the perf
bench does not check data:

* **Early dependent ref: `same_lane` was never connected** on the
  `u_area_dep` reference-area instance, so every early dep read used the
  !same_lane area formula — wrong for essentially every p=1 dependent
  block at segment_length > 2 (i.e. wrong candidate data at 1 GiB scale).
* **A prefetched/serial reference to a recently written block could read
  memory before its write committed.** The wb-hit guard was masked by a
  cache hit (`wb_hit && !cache_hit`) that nothing ever forwarded from —
  the documented "if it hits the cache (last block), use cache" behavior
  did not exist. Fixes: a cache-hit reference is now *forwarded* from the
  write-through cache at DISPATCH/DREF_SETTLE (no read at all); the wb
  wait uses the raw hit; prefetches additionally skip when the target is
  the block being compressed (or being streamed, for the chained K+2
  prefetch) since those writes have not happened yet. The early-dep issue
  gained the same raw-FIFO/self gating.

Cost: ~0.7 cyc/blk on argon2i (an occasional serial block instead of a
chained one when the prefetch was skipped for safety). Both bugs were
present on main; every KAT now passes at every swept geometry, N_P=1 and
N_P=8.

### Early dependent ref (argon2d / argon2id second half)

The dependent reference address comes from word 0 of the just-written
block K, so it is only known once K starts draining. There is no
128-block prefetch as for argon2i. But after the first drain beat, the
read port is otherwise idle for the rest of K's drain (writes use the
independent write channel), so K+1's 16-beat ref read is issued then on
the **same** read port and collected behind K's remaining drain + K+1's
compression. At K+1's DISPATCH the buffer is usually already full; prev
comes from the write-through cache, so K+1 goes straight to COMPRESS
with no COLLECT_REF wait. This is the same "issue another read on the
idle port" pattern as the existing early dest read, not a second AXI
stream (a second stream on one shared R channel does not help — see
"Rejected" below).

Implementation in `argon2_fill_ctrl`: a second `ref_area`/`index`
instance evaluates K+1's index from the captured `J1||J2`; the read is
gated to pass-0 dependent blocks (pass>0 also needs a dest-xor read which
would contend), with hazard skips when the target is K+1 itself
(uncomputed) or uncommitted in the write FIFO. The response is collected
in any FSM state once accepted (a transition mid-burst cannot drop its
tail), and a stale/ late result is discarded at DISPATCH / DREF_SETTLE
so the normal dependent path always remains correct. Measured effect
(N_P=8, m'=4096, t=3, p=1, 200 MHz, cycle-accurate DDR4):

| Type | before cyc/blk (cand/s, F1×4) | after cyc/blk (cand/s, F1×4) | Δ cand/s |
|------|-------------------------------|------------------------------|----------|
| argon2d  | 106.7 (0.596, 2.38) | 97.2 (0.654, 2.62) | +9.8% |
| argon2id | 97.2 (0.654, 2.62) | 93.1 (0.683, 2.73) | +4.5% |
| argon2i  | 61.8 (1.029, 4.12) | 61.8 (1.029, 4.12) | unchanged (gated off) |

COLLECT_REF fell from ~399k to ~265k cycles (argon2d) and ~358k to
~238k (argon2id) over the run. Bit-identical against the full KAT suite
(`fill`, `fill_rfc`, `axi`, i/d/id, N_P=1 and N_P=8). The optimization
is pass-0 only; extending it to pass>0 would need to arbitrate against
the dest-xor read (the two could be tagged/prioritized, but pass>0 is a
smaller fraction of the t=3 workload).

### Dest-xor chain gate-relaxation (argon2i, IDEAL only)

Mechanism 5 step 1 of the overlap plan: let the chained overlapped send
fire for independent **dest-xor** (pass>0) blocks, not just pass-0. The
chain already streams block K+1's `prev` (from the write-through cache)
and `ref` (from the prefetch) into the compressor's idle buffer during
K's drain; for pass>0 it additionally needs K+1's `dest`. The compressor
applies it during the background load (`c_in_dest` already gated on
`with_xor`), so the datapath needed no change — only the FSM gate:

`nxt_ok` was `... && !with_xor`; it is now `... && (dest_done || !with_xor)`.
`dest_done` is correct for the *next* block because it is cleared on
COMPRESS entry and re-armed only by the dest read issued after that
block's ref prefetch completes. At the chain latch the dest handshake
flags are cleared (the next block's dest is consumed by the drain, and
clearing prevents the block after that from chaining on a stale dest),
and the K+2 early-prefetch (`can_prefetch_n2`) is kept **pass-0 only**:
for a dest pass its address would be wrong (`dest_next_addr` is
`curr_idx+1` while `index_r` is still K), so the next block's ref is
issued from its own DISPATCH[nxt_skip] where `index_r` has advanced and
the dest address is correct. dest_q is untouched during the drain (no
dest/prefetch is in flight), so no double-buffer is needed for this step.

Measured (N_P=8, m'=4096, t=3, p=1, 200 MHz):

| Type      | IDEAL cyc/blk before → after | DDR4 cyc/blk before → after |
|-----------|------------------------------|-----------------------------|
| argon2i   | 57.4 → 51.6 (1.109 → 1.233 cand/s) | 63.4 → 63.5 (unchanged) |
| argon2d   | 61.0 → 61.0                  | 63.1 → 63.1 (bit-identical) |
| argon2id  | 58.6 → 58.6                  | 60.9 → 60.9 (bit-identical) |

Bit-identical against the full KAT suite (fill, fill_rfc, axi, the
m'∈{16,32,64,128} geometry sweep, the F1 `cl` top, i/d/id, N_P=1 and
N_P=8). The discipline bench still holds (argon2i pass0 COMPRESS=96 <
pass1 COMPRESS=145). **The DDR4 number is unchanged** because the dest
read's DRAM latency exceeds the single-port window before the drain, so
the chain almost never fires on real memory — only on the IDEAL
(zero-latency) model. The DDR4 gain is gated on the dest double-buffer
(prefetch the dest one block earlier, during the previous drain where the
read port is idle), which is the remaining mechanism-5 step.

The AXI bus ceiling at 200 MHz is 12.8 GB/s ÷ ~11.5 GB traffic per
1 GiB candidate ≈ **1.07 cand/s/lane** (the shell's 512-bit @ 250 MHz
raises it to ~1.33). At 1.029 cand/s the argon2i lane is within ~4% of
that ceiling; the residual gap is the pass>0 serial path and the AXI
write handshakes.

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
   * **Compress double-buffering + chained overlapped send**: the
     compressor keeps two 1 KiB block buffers; during DRAIN it also
     accepts the next block's input (background load), and the fill
     controller streams block N+1 into it in lockstep with N's drain
     beats — prev forwarded from the output, ref from the prefetch — then
     issues block N+2's prefetch in the same drain window via a
     redirected second address port. Pass-0 blocks skip COMPRESS entirely
     and chain; saves ~6 cyc/blk on the 1 GiB t=3 argon2i reference.

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

## Partitioned-memory p=4: the read crossbar (`argon2_mem_xbar`)

The last piece the partitioned floorplan was missing (previously: "the RFC
p=4 bench uses shared memory and does not model cross-channel routing").
`argon2_mem_xbar` sits between `argon2_fill_job` (4 fill controllers, one
per lane) and four single-outstanding memory ports (`argon2_axi_mm` + one
DDR4 channel each):

* **Reads** carry the controller's `mem_rd_owner` hint (the reference LANE,
  known at issue time) and are routed to the owning channel with a
  global→local index translation (`addr − owner*lane_length`, a per-channel
  shift-add — no runtime division, no power-of-two assumption on
  `lane_length`, per the 250 MHz closure rule). Responses are tag-routed
  back to the requesting lane; per-channel round-robin, so no lane starves
  behind the others' remote references.
* **Writes** pass through 1:1: a lane only ever writes its own region.
* **No producer-side hazard logic is needed**: cross-lane references only
  target the reference lane's *completed* slices (`argon2_ref_area`:
  pass>0/!same_lane → `lane_length − segment_length`, i.e. everything but
  the current slice; pass 0 → completed slices only), and each lane drains
  its write FIFO before the slice barrier. Own-lane recency hazards stay
  in the fill controller.

**Lane-port contract** (what the fill controller was designed against, and
what the crossbar must reproduce): a request is accepted the cycle the lane
is drained (the single-RAM "free" semantics), a lane never sees two
responses interleaved (a queued request waits until the lane's previous
burst — including a deliberately *abandoned* dependent read — fully
drains), and beats only start ≥1 cycle after command acceptance.

### Two latent `argon2_fill_ctrl` hazards found and fixed

Wiring the router in exposed that several fill-controller states (DISPATCH,
DREF_SETTLE, COLLECT_REF/PREV) *pre-placed* read requests on the port at
the moment of jumping into an `ISSUE_*` state, without checking
`mem_rd_valid` — so they could **overwrite a still-pending hook-issued
request** (early dest / dependent ref / K+2 prefetch) and leave its
collector armed to eat the replacement request's response (observed as
`dest == ref` inputs). With a direct RAM the pending window was ~1 cycle,
so main was green *by pacing luck* (fragile at N_P=8 even without the
router). Fix: request placement moved **into** the `ISSUE_REF/PREV/DEST`
states, gated on the port being free; hooks keep their `!mem_rd_valid`
gating. The whole KAT suite (fill, rfc, p4, axi, axibig, sweep, cl,
discipline — at N_P=1 and N_P=8) stayed green through the change.

### Correctness coverage: `tb_argon2_p4`

Four controllers + crossbar + **four separate local-addressed memories**;
per-job full-matrix compare against `ref/`. 16 jobs, all passing at both
N_P=1 and N_P=8 (Verilator; iverilog via CI):

* RFC 9106 §5 official vector (m=32 KiB, p=4, t=3) — argon2i/d/id;
* geometry sweep m' ∈ {64, 128} × t ∈ {1, 3} × i/d/id (lane_length 16/32,
  segment_length 4/8 — scales the shared-RAM RFC bench never covered);
* m'=48, t=2, argon2id — lane_length 12, **not a power of two**.

### Measured: `tb_p4_perf` (1×p=4 across four independent DDR4-2400 channels)

N_P=8, 200 MHz, m'=16 MiB (4 MiB/channel), t=3, preload with
pseudo-random data (zeroed memory collapses argon2d's data-dependent
reference lane onto lane 0 — pass 0's J2 comes from the initial blocks;
from pass 1 it is computed output, i.e. avalanche-random):

| Type     | 1×p=4 cand/s (4 ch) | cyc/blk (candidate-wide) | 4×p=1 aggregate\* | Efficiency | 250 MHz p=4 |
|----------|--------------------:|-------------------------:|------------------:|-----------:|------------:|
| argon2i  | 3.018               | 21.1                     | 4.05              | 75%       | —           |
| argon2d  | 2.925               | 21.7                     | 4.03              | 73%       | —           |
| argon2id | 3.005               | 21.2                     | 4.19              | 72%       | 3.399       |

\* per-lane `tb_perf` at m'=16 MiB × 4 (i 1.013 / d 1.007 / id 1.049).

Per-channel load matches the model (~2 reads + 1 write per own-lane block,
~20.5k read bursts/channel, ~4 GB/s read + 2.4 GB/s write each), and the
slice-barrier skew is small (≤3.4%, worst lane). The gap to 4×p=1 is
**crossbar contention**: each channel serializes up to 4 lanes' remote
reads behind its own (single outstanding read per channel, matching
`argon2_axi_mm`), and lanes spend ~42% of their cycles waiting for a grant
— hidden behind compute for throughput, but the reason p=4 lands at
~73% of the p=1 aggregate rather than ~100%. Closing it needs multiple
outstanding reads per channel (an `argon2_axi_mm` with 2 ARIDs + RID
routing in the crossbar), which the single-R-channel experiment below says
is only worth it if the *data* beats can interleave — i.e. per-lane
outstanding tags on one channel, not just multiple ARIDs.

Bottom line: a defender-specified p=4 parameter now runs at ~3.0 cand/s on
an f1.2xlarge-class 4-channel box (vs ~4.1 for 4×p=1) — and a single
p=4 candidate gets 4× the per-candidate latency advantage, since all four
channels work on it at once. Build/run: `make -C sim p4perf` (`P4_TYPE`,
`P4_BLKS`, `P4_NP`, `P4_MHZ`; `p4` for the KAT bench).



* **250 MHz CL clock** (the F1 shell runs sh_ddr at 250 MHz in the
  reference designs): **measured** with the new clock-parameterized perf
  model (`make -C sim perf250`) — argon2i 1.135, argon2d 1.210, argon2id
  **1.240 cand/s/lane** (F1×4 = 4.54 / 4.84 / 4.96). +13-20% per type
  (below the 25% clock ratio: DRAM latency is fixed in ns, so cyc/block
  rises at the higher clock). The dominant 200→250 MHz closure blocker —
  a 32-bit divider in `argon2_index` (3 instances) — is already removed
  (replaced by a conditional subtract, bit-/cycle-identical). Remaining
  closure is the BlaMka mult-add via DSP48 register-packing (a synth
  `-retiming` setting, not an RTL change). Full map + checklist:
  `docs/TIMING_250MHZ.md`.
* **Overlap passes 1–2 (dest-xor) for argon2i**: the chained overlapped
  send now also fires for independent dest-xor blocks when the next
  block's dest is already collected (`nxt_ok` relaxed from `!with_xor` to
  `dest_done || !with_xor`). This lifts the **IDEAL** (compute) floor for
  argon2i from 57.4 → 51.6 cyc/blk (1.109 → 1.233 cand/s/lane, +11%) —
  the binding constraint on HBM-class memory and at a higher CL clock.
  On the **DDR4** model argon2i is unchanged (~63.5 cyc/blk): the dest
  read is issued only after the ref prefetch completes, so at real DRAM
  latency it rarely finishes before the drain starts and the chain falls
  back to the serial path. Closing the DDR4 gap needs the dest prefetched
  *one block earlier* (during the previous drain, where the read port is
  idle), which requires a **dest double-buffer** to avoid clobbering the
  dest being streamed — see "Dest-xor chain gate-relaxation" below. That
  is mechanism 5 of `docs/PERFORMANCE_OVERLAP_PLAN.md` and the only big
  RTL lever left.
* **Deeper P retiming** (the 2-wave × ~9-cycle P chain is the hard
  floor; 16 P units instead of 8 does not help — the column wave reads
  the row wave's output).
* **Partitioned-memory p=4 routing: DONE (simulation)** — `argon2_mem_xbar`
  routes cross-lane reference reads to the owning channel and tag-returns
  the beats; RFC §5 + geometry KATs at N_P=1/8 and a four-DDR4-channel perf
  bench all land (see "Partitioned-memory p=4" above). Remaining: wire it
  into the F1 CL + host API (the CL currently runs four independent p=1
  jobs), and consider multi-outstanding reads per channel to cut the ~27%
  contention gap to 4×p=1.


## Rejected: second outstanding read for the argon2d dependent ref

An obvious idea for closing the argon2d/argon2id COLLECT_REF gap is to
mirror what the independent path does for prefetch: issue block K+1's
dependent reference read early, while block K is still draining, and
collect it in the background so its DRAM latency overlaps K's drain and
K+1's compression. Unlike the 128-block G prefetch (whose addresses are
known far ahead), the dependent ref's address is only known once K's
first output beat produces J1||J2 — i.e. ~16 beats (plus P latency)
before K finishes — so the window is tight, but it exists while the read
port is otherwise idle (writes use the independent write channel).

This was implemented end-to-end and verified bit-identical against the
full KAT suite, then measured. It was **rejected**: a second outstanding
read on a single AXI channel does not overlap a read's 16 R beats with
anything else on the same R channel, so it mainly reorders/contends.

### What was built

* `argon2_axi_mm` / `argon2_fill_axi`: a second tagged read stream
  (stream 0 = working read on ARID 0, stream 1 = early next-ref on
  ARID 1), with RID-routed responses and RREADY interlock. Supports up
  to two in-flight reads; a controller that ties stream 1 off gets the
  original one-read behavior.
* `argon2_fill_ctrl`: on the first drain beat of block K, capture word 0
  (= J1||J2 for data-dependent blocks), compute K+1's reference index
  through a second ref_area/index instance, issue it on stream 1, and
  collect into a buffer. At K+1's DISPATCH, if the buffer is ready use
  it with prev from the write-through cache; otherwise discard it (and
  any late response) and take the normal dependent ref path. Hazard
  gating skips the issue when the target is K/K+1 (not yet committed) or
  is still uncommitted in the write FIFO.
* Testbench models (`tb_axi_ram`, `tb_ddr4_ram`, and a zero-latency
  ideal memory for the perf bench) were extended to accept two
  outstanding ARIDs, hold each R beat until RREADY, and tag responses.

### Result (N_P=8, m'=4096, t=3, p=1, 200 MHz, DDR4 model)

| Type | baseline cyc/blk (cand/s/lane) | + 2nd early-ref stream |
|------|--------------------------------|------------------------|
| argon2d  | 106.7 (0.596) | 111.2 (0.572) |
| argon2id |  97.2 (0.654) | 101.2 (0.628) |
| argon2i  |  61.8 (1.029) |  60.7 (1.047, within noise) |

F1 x4 (4 independent p=1 lanes) moved argon2d 2.38 -> 2.29 cand/s and
argon2id 2.62 -> 2.51. The functional KATs (fill, fill_rfc, axi for
argon2i/d/id at N_P=1 and N_P=8) all passed, so the regression is a
throughput effect, not a correctness one.

### Why it didn't help

* **One shared read-data channel.** The dependent ref is a full 16-beat
  burst. With only one AXI R channel, that burst cannot overlap any other
  read's data beats — the second ARID gives out-of-order *issue* but not
  out-of-order *data*. The "hidden" ref still consumes 16 R beats on the
  critical resource; the 16-beat drain of K and the ref's 16 R beats
  serialize rather than overlap.
* **The window is too short.** By the time J1||J2 is visible (first beat
  of K's drain), the port is free for only the remainder of the drain;
  the ref's latency either does not fully fit before K+1 needs it, or
  (when it does) it displaces another read the port would have done. The
  COLLECT_REF drop was small and was eaten by AR arbitration, the second
  ref-area/index datapath, and the fallback path.
* **argon2i was unaffected** because it never takes the dependent path
  (its refs come from the 128-block prefetcher), confirming the change
  was correctly gated to data-dependent blocks.

The takeaway: hiding the dependent ref needs either (a) genuinely
independent read *data* bandwidth (a second memory port / channel, not
just a second outstanding transaction), or (b) a way to know the
dependent address earlier than K's first output beat, which Argon2's
data-dependent ordering does not permit. A second outstanding read on the
same AXI port is not that mechanism. Code was reverted; this note is kept
so the experiment isn't repeated.

## Model caveats

* The DDR4 model is single-command-per-cycle with realistic latencies
  but no bank-group/tCCD modeling; at 12.8 GB/s AXI vs 19.2 GB/s DRAM the
  bus is the slower side, so this is faithful for this core's traffic.
* p=1 lanes don't interact; the 4-lane number is 4× per-lane. The p=4 RFC
  bench uses shared memory and verifies fill/index/barrier behavior, not the
  cross-channel routing required by four physically separate DDRs.
* Verilator 5.4x (pip wheel) is the reference simulator for these
  numbers; the bench also builds under Icarus (`make -C sim perf`).
* Write FIFO RAW handling stalls on hit; hit rate is ~1/lane_length, so
  performance impact is negligible, but it is required for correctness
  (ref could equal a recently written block).
