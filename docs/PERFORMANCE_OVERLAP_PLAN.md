# Overlapped compression across all passes — intent + incremental plan

## Status

**Not implemented (pending).** This note captures the *intent* of the
throughput optimization so it can be re-attempted carefully on top of
green `main`, and records the failure mode of the first attempt to avoid
repeating it.

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

1. **Baseline gate.** Without touching RTL, write a benchtop test that
   locks pass-0 overlap and pass>0 serial behavior (golden-bit vs
   reference). This is the harness that makes a correctness regression
   attributable.

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