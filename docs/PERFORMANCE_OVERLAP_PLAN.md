# Overlapped compression across all passes — intent + incremental plan

## Status

**Partially landed (2026-08-22).** The dependent path is now optimized end
to end and the plan's key mechanisms are in, in a different form than
sketched:

* Step 2 (dest double-buffer) — **not needed as designed**: the early dest
  read goes out from a COMPRESS-state hook (deterministic address, port
  idle in dependent mode) and a single buffer suffices because the data is
  consumed one block later than it is collected.
* Step 3 (early dest prefetch) — **landed** for dependent pass>0 blocks.
* Step 4 (multi-outstanding reads) — **correctly skipped** (see the
  "Rejected" note in `docs/PERFORMANCE.md`; a second ARID cannot overlap
  R beats on one channel).
* Mechanism 1 for *dependent* blocks — **landed differently**: instead of
  chaining the background send (which needs the ref address before the
  drain, impossible for data-dependent blocks), the returning dep read
  **streams into the compressor load** (DSM_REF + `dep_cnt` watermark).
  argon2d 97.2 → 63.1 cyc/blk (0.654 → 1.007 cand/s), argon2id
  93.1 → 60.9 (0.683 → 1.044). The dep read now also runs in every pass,
  gated by raw write-FIFO / self hazards.
* **Mechanism 1 for independent pass>0 blocks (the original step 5)
  remains open** — that is the chained overlapped send with a
  watermark-gated or double-buffered dest, worth the remaining ~4–6% for
  argon2i.

Landing the sweep also exposed and fixed two latent correctness bugs (the
`u_area_dep` `same_lane` input was never connected; the write-FIFO RAW
guard was masked by a cache hit that nothing forwarded from) — see
`docs/PERFORMANCE.md`. The discipline gate from step 1 still passes:
pass>0 blocks keep using the COMPRESS state (the stream runs *inside* the
load, it does not chain), so `p0 COMPRESS < p1 COMPRESS` still holds.

The original plan text follows for the record.

## Objective

Saturate the 512-bit AXI bandwidth (~**1.07 cand/s/lane** at 200 MHz, per
`docs/PERFORMANCE.md`) across **all** Argon2i passes, not just pass 0.

Current measured state (N_P=8, m'=4 MiB, t=3, p=1, 200 MHz, DDR4 model):

| Type   | cyc/blk (DDR4) | cand/s/lane | F1 ×4 |
|--------|----------------|-------------|-------|
| argon2i| 61.8           | 1.029       | 4.12  |
| argon2d| 97.2           | 0.654       | 2.62  |
| argon2id| 93.1          | 0.683       | 2.73  |

Argon2i is already within ~4% of the AXI ceiling. The residual gap is the
**pass>0 serial COMPRESS→WRITE path**: for a dest-xor block, the dest read
for block N+1 cannot complete before N's drain starts with a single memory
port, so pass>0 blocks do not overlap-compress and fall back to the serial
path.

## The four mechanisms (from the rejected big-bang attempt)

PR #12 ("Optimize throughput: extend overlapped compression to all passes")
attempted all four at once in one `argon2_fill_ctrl` rewrite:

1. **Overlapped compression extended to dest-xor passes** — let pass>0
   blocks chain (skip the serial COMPRESS state) the way pass-0 blocks
   already do.
2. **Multi-outstanding AXI reads** — the AXI-MM adapter permits up to two
   in-flight read transactions.
3. **Early destination prefetch** — issue the dest-xor read immediately
   after the reference block read, before the compressor needs it.
4. **Destination double-buffering** — a dedicated `dest_work_q` so a
   background dest prefetch cannot race the block being compressed.

**The intent is sound; the packaging was not.** See "Why the attempt failed"
below. Each mechanism is worth pursuing individually, gated by the existing
self-checking benches.

## Why the attempt failed (anti-pattern to avoid)

The failed attempt was branch `arena/01a0236b-argon2-fpga` (PR #12). Facts
from the record:

- A single 27-commit rewrite of `argon2_fill_ctrl` (a 731-line diff), 23
  of 27 commits are "fix / syntax / robust FSM" churn, and the final 16
  commits are consecutive fix-attempts with **no test ever passing**.
- The `fill`, `fill_rfc`, `axi`, and F1 `cl` benches never went green. The
  failure is behavioral, not syntactic: `fill` and `axi` report
  `FAIL argon2id 113 beat(s) differ` (similarly argon2d / argon2id across
  the fill, axi, and F1 `cl` benches), `rfc` stalls,
  and F1 `cl` wedges all four lanes at `state=12`.
- `docs/PERFORMANCE.md` had already **rejected** the "second outstanding
  read for the data-dependent ref" variant, because a single AXI R data
  channel cannot overlap a 16-beat burst with itself (issue-order
  reordering, but not data overlap). That rejection is on record, and the
  fresh attempt did not rest on it.

**Never bag all four at once.** The dependent path, the dest-xor path, the
double-buffer, and the multi-outstanding-read all touch interleaving and
hazard arbitration that this FSM gets wrong in aggregate (totally plausible
given the wrong-cycle counts). They must be landed one at a time so the
generic verification can attribute any regression to a specific mechanism.

## Incremental plan (each step green on `main` before the next)

The repo already carries the acceptance harness:
`scripts/run_tb.py` → `sim/blake2b, blamka, index, compress, addr, fill,
rfc, axi, cl`. Every COMPLETE step must keep all of them green plus the
`perf` bench bit-identical to main's numbers.

1. **Baseline gate (DONE — `sim/tb_argon2_fill_discipline.sv`, this PR).**
   A state-discipline bench that re-asserts bit-identical KAT output *and*
   locks the overlap structure: pass-0 COMPRESS cycles strictly less than
   pass>0 (overlap is pass-0-only because `nxt_ok` requires `!with_xor`).
   Measured on green main (N_P=1, m'=8, t=2, these vectors):
   argon2i p0=64 p1=180, argon2d p0=96 p1=232, argon2id p0=96 p1=232.
   This is the harness that makes a correctness *or* throughput regression in
   the overlapped path attributable. RTL untouched; main stays golden.

2. **Dest double-buffering.** add `dest_q`/`dest_work_q` in the serialize
   -in-one-register form first (no multi-read), verify vs the KAT suite.

3. **Early dest prefetch** — issue the dest-xor read earlier (right after
   the ref read, per mechanism 3) but *only* when the write port is truly
   idle, gated exactly.

4. **Multi-outstanding reads (mechanism 2)** — model says the second ARID
   gives issue-order only, so this is expected to be ~neutral; do it
   LAST and measure, don't assume.

5. **Overlap pass>0 (mechanism 1)** — only once 2–4 are separate;
   extend the chained send into the dest-xor path and measure against
   `perf` (target: argon2i cand/s/lane → ~1.07, F1 ×4 → ~4.2+).

Step 4 should be treated as a maybe-not. If a single R channel cannot
overlap read beats, the real lever for pass>0 is the `docs/PERFORMANCE.md`
"Remaining headroom" bullet — raising the CL clock to 250 MHz (up to
~1.33 cand/s/lane) — NOT a second outstanding transaction on the same
port.

## Acceptance / definition of done

- All sim benches green: `scripts/run_tb.py` (0 failures), which re-drives
  every self-checking bench including the F1 `cl` top.
- `perf` numbers unchanged or improved for argon2i, argon2d, argon2id vs
  main.
- Bit-identical candidate output against the RFC reference for the full
  KAT suite (fill / fill_rfc / axi space, type i/d/id, N_P=1 and N_P=8).

## History

- 2026-08-21: PR #12 big-bang attempt closed as dead (broken FSM, 27
  commits, never green). This note captures the intent in `docs/` only so a
  future attempt starts from the research record, not from the failed diff.
- 2026-08-21: PR #13 adds the step-1 baseline gate and this intent/plan note.
  Verified with Verilator (reference sim, per PERFORMANCE.md): discipline
  bench passes for argon2i / argon2d / argon2id; RTL unchanged (bit-KAT
  identical to green main).