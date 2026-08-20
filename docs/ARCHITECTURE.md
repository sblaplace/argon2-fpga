# Architecture

The only number that matters is **isolated bandwidth × channel count**.
This document is how the fabric is supposed to spend that bandwidth.

## Split of work

| Path | Rate | Where it runs (v1) |
|------|------|--------------------|
| H0 = BLAKE2b(params \|\| pwd \|\| salt \|\| …) | once / guess | Host or `blake2b_core` |
| B[i][0], B[i][1] = H'(H0 \|\| …) | 2p × 1 KiB | Host or `blake2b_core` |
| Fill: G + index, t · m' blocks | **the job** | One `argon2_fill_ctrl` per memory channel |
| Tag = H'(XOR last column) | once / guess | Host or `blake2b_core` |

H / H' are a rounding error next to 4 M compresses. Do not spend DSPs on
them until the fill loop is saturated.

## Compression G

```
X, Y  --xor-->  R  --P×8 rows-->  Q  --P×8 cols-->  Z  --xor R-->  out
```

P is one BLAKE2b-style round of eight BlaMka GBs (4 column + 4 diagonal).
GB is four serial mix-quarters, each `fbla(a,b) = a + b + 2·a[31:0]·b[31:0]`.

Current RTL (`argon2_compress`):

- 512-bit streaming ports (16 beats / block) — matches HBM AXI and is a
  clean multiple of a 64-bit DDR beat.
- `N_P` parallel `argon2_p` units, restricted to 1, 2, 4, or 8. Each P is
  4-stage GB × 2 phases ≈ 9 cycles. Rows run first, then columns; the two
  phases cannot share a wave because every column consumes the row result.
- 4 parallel GB units inside each P (the column/diagonal groups have no
  internal dependence).
- The measured performance point is **N_P=8**: two P waves, about 18 P
  cycles and 61.8 total cycles per block against the DDR model (argon2i
  t=3). N_P=1 is the small-area default and takes about 160 P cycles.
- The block store is **double-buffered**: while the compressor drains
  block N it also accepts block N+1's input into the idle buffer, and the
  fill controller streams it in lockstep with the drain beats (prev
  forwarded from the output, ref from the prefetch). Pass-0 independent
  blocks therefore skip the LOAD/COMPRESS phase entirely and chain via an
  early K+2 prefetch; passes 1–2 keep the serial path because the
  dest-xor read would not be ready in time on the single memory port.

### Why not fully unroll

A fully parallel G is 16 P × 8 GB × 4 × (32×32) ≈ 512 multiplies.
UltraScale+ wants ~4 DSP48E2 per 32×32 unsigned, so ~2k DSP / core.
VU9P has 6840 — it may fit one such core, but not four channel-local cores,
and rows must still complete before columns. `N_P=8` exposes all useful
parallelism within each phase while remaining replicable across four DDR
ports.

Rough pre-synthesis budget (timing and utilization still need confirmation
from the F1 build):

| Resource | N_P=1 / core | N_P=8 / core |
|----------|--------------|--------------|
| DSP48    | ~16–32 | ~128–256 |
| LUT      | add/xor/rotate + block state | roughly 8× P logic + block state |
| BRAM     | 0 if the 128-word file is registers; more if mapped to RAM | same storage order |
| P cycles/G | ~160 | ~18 |
| Measured total cycles/block | ~249 DDR4 | ~61.8 DDR4 |

At 200 MHz, N_P=8 measures 1.029 candidate/s per lane for the 1 GiB,
t=3 Argon2i projection — within ~4% of the 200 MHz AXI bus ceiling
(~1.07 cand/s/lane); the IDEAL-memory floor is 56.3 cyc/blk (1.13
cand/s). See [`PERFORMANCE.md`](PERFORMANCE.md) for the complete sweep
and model caveats. Real F1 timing closure and DDR measurements should
come next; the remaining compute-side idea is overlapping the dest-xor
passes.

## Indexing

`index_alpha` is two 32×32 multiplies and a modulo:

```
x  = J1² >> 32
y  = |W| · x >> 32
z  = (start + (|W| − 1 − y)) mod lane_length
```

- **Argon2d / second half of Argon2id:** J1∥J2 = first 8 bytes of the
  previous block. Reference address is data-dependent — the ref read
  cannot launch until prev has returned.
- **Argon2i / first half of Argon2id:** J1∥J2 come from G in counter
  mode (`argon2_addr_gen`, wired into the fill FSM). Addresses for a
  whole 128-block window are known ahead of time. The fill controller
  issues the random ref read *first* (no wait on prev) and launches the
  next window entry's ref read at the start of G — a full compute
  latency early, which is also a full memory latency on a well-behaved
  DDR/HBM port. This is the variant the README targets, and the one
  where an FPGA actually wins.

Legal `lane_length` is a multiple of 4; on power-of-two memory sizes the
modulo collapses to a wire.

## Memory port

One core owns one channel and a private `m'`-block region (1 KiB blocks).

Per block of the fill:

1. Sequential read of `B[i][j-1]` (or wrap to the end of the lane).
   Trivially prefetchable / cacheable in a 1 KiB line.
2. Random read of `B[l][z]`.
3. On pass > 0, read-modify-write of `B[i][j]` (v1.3 XOR).
4. Write of the new block.

Traffic at 1 GiB / t=4 / p=1: ~4 M random reads + ~4 M writes + ~4 M
sequential prev reads. The README's "~4 GB of random memory traffic" is
the random-ref term.

AWS F1 (`f1.2xlarge`, VU9P) exposes **4 independent DDR4 channels**
through the HDK (`cl_dram_dma` / AXI-MM, typically 512-bit). The v1
integration is four copies of `argon2_fill_axi`, one per `sh_ddr` port,
and supports four independent p=1 jobs without shared data traffic.

A single p>1 job is different: Argon2 may select a reference block from
another lane. Banking lane L in channel L therefore requires a read crossbar
that routes each request to the reference lane's owner channel and returns
its tagged response. The slice barrier is necessary but not sufficient.
`argon2_fill_job` is functionally verified against a shared simulation RAM;
the current F1 CL has the barrier but not this cross-channel read router, so
its p4 mode must remain disabled on hardware.

Alveo U50 is the same picture with 32 HBM pseudo-channels.

## Handshake / clocks

All RTL is a single clock, `rst_n` async-assert / sync-deassert. Valid /
ready on every streaming port. `blamka_g` is a rigid 4-cycle pipe
(back-to-back capable). `argon2_p` is not yet fully streaming — it
accepts one P at a time — which is fine until we add a second inflight G.
`argon2_addr_gen` reuses a private `argon2_compress` (two G's per 128
addresses, ~1 % of a 128-block window). The fill controller has its own
G so address generation of the next window can later overlap a fill.

## What is implemented vs. stubbed

| Block | Status |
|-------|--------|
| `blake2b_g` / `blake2b_round` / `blake2b_compress` / `blake2b_core` | Written |
| `blamka_g` (4-stage) | Written |
| `argon2_p`, `argon2_compress` | Written |
| `argon2_index`, `argon2_ref_area` | Written |
| `argon2_fill_ctrl` | One-lane job: argon2i/d/id, dest-xor fetch, ref prefetch, slice-sync ports |
| `argon2_fill_job` | p lanes + AND barrier at each slice |
| `argon2_addr_gen` (argon2i PRNG) | Two G's in counter mode, 128 J1∥J2 / window |
| `argon2_axi_mm` / `argon2_fill_axi` | 512-bit AXI4-MM, 16-beat / 1 KiB block, independent R/W |
| F1 `cl_dram_dma` / `sh_ddr` shell | Scaffold: four independent p=1 channels; p4 barrier present, cross-channel reference router missing |
| Python golden model + RFC 9106 §5 | Passing |
| Benches + CI (Icarus **and** Verilator) | `blake2b_g`, `blamka_g`, `index`, `compress`, `addr_gen`, 8 KiB fill, RFC 32 KiB / p=4, AXI-MM — all passing |

## Verification plan

1. **Now:** `python3 -m unittest` against RFC 7693 and RFC 9106 §5.
   The golden model *is* the spec the RTL is written to.
2. **Now, in simulation:** `make sim` (Icarus) or `make -C sim SIM=verilator`
   runs the self-checking benches under `sim/` (vectors dumped from `ref/`
   via `python3 -m tests.dump_vectors`). The small fill KAT is p=1 / m=8 KiB /
   t=2. The RFC KAT is p=4 / m=32 KiB / t=3 (the published §5 vector) and
   needs the slice barrier. `tb_argon2_axi` replays the 8 KiB job through
   the AXI adapter. All three compare the entire working set against `ref/`
   after the last pass.

   Bringing a simulator up against this RTL for the first time found four
   real bugs, all now fixed: a `ROTR64` macro that part-selected a
   parenthesized expression (illegal — the RTL had never compiled), a call
   to a nonexistent `pref_collect()` task, 1024-bit `argon2_p` ports driven
   with single-bit selects in `argon2_compress`, and — the substantive one —
   a `COMPRESS`/`WRITE` handshake in `argon2_fill_ctrl` that registered the
   payload off a `beat` counter which only advanced *after* the handshake,
   so word 0 was sent twice and word 15 never. The streaming ports are now
   driven combinationally from `state` / `beat`.
3. **On F1:** one-channel known-answer (the 32 KiB RFC vector fits in
   BRAM — use it as a unit test before touching DDR) then a DDR
   bandwidth microbench (`cl_dram_dma` hello-world).
