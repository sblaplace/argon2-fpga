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
- **One** `argon2_p` reused 16 times. Each P is 4-stage GB × 2 phases ≈ 9
  cycles. Compute ≈ 160 cycles / G.
- 4 parallel GB units inside P (the column/diagonal groups have no
  internal dependence).

### Why not fully unroll

A fully parallel G is 16 P × 8 GB × 4 × (32×32) ≈ 512 multiplies.
UltraScale+ wants ~4 DSP48E2 per 32×32 unsigned, so ~2k DSP / core.
VU9P has 6840 — it *fits*, and would issue well under one G / cycle, but
a single DDR4 channel cannot feed that. The first core is sized to be
**just faster than one channel**, then replicated per port.

Rough budget for the 4-GB / 9-cycle P:

| Resource | Estimate / core |
|----------|-----------------|
| DSP48    | 4 GB × ~4 DSP × 1 (reused) ≈ 16–32 |
| LUT      | add/xor/rotate + 2 KiB of block state |
| BRAM     | 0 if the 128-word file is registers; 2×36k if moved to BRAM |
| Cycles/G | ~160 compute + mem |

At 200 MHz that is ~1.25 M G/s, i.e. enough to push ~1.2 GiB/s of
*random* 1 KiB reads — in the same ballpark as a well-behaved DDR4
channel doing 1 KiB random. The next knob is a second P (rows and
columns overlap poorly, but two inflight G's hide read latency).

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
  mode (`argon2_addr_gen`, not yet wired into the fill FSM). Addresses
  for a whole 128-block window are known ahead of time. **Prefetch the
  random read a full memory latency early.** This is the variant the
  README targets, and the one where an FPGA actually wins.

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
integration is four copies of `argon2_fill_ctrl`, one per `sh_ddr`
port, no cross-channel traffic.

Alveo U50 is the same picture with 32 HBM pseudo-channels.

## Handshake / clocks

All RTL is a single clock, `rst_n` async-assert / sync-deassert. Valid /
ready on every streaming port. `blamka_g` is a rigid 4-cycle pipe
(back-to-back capable). `argon2_p` is not yet fully streaming — it
accepts one P at a time — which is fine until we add a second inflight G.

## What is implemented vs. stubbed

| Block | Status |
|-------|--------|
| `blake2b_g` / `blake2b_round` / `blake2b_compress` / `blake2b_core` | Written |
| `blamka_g` (4-stage) | Written |
| `argon2_p`, `argon2_compress` | Written |
| `argon2_index`, `argon2_ref_area` | Written |
| `argon2_fill_ctrl` | Skeleton: argon2d-style J1/J2, dest-xor not fetched, no addr-gen |
| `argon2_addr_gen` (argon2i PRNG) | Not yet — next |
| AXI-MM / F1 shell | Not yet |
| Python golden model + RFC 9106 §5 | Passing |

## Verification plan

1. **Now:** `python3 -m unittest` against RFC 7693 and RFC 9106 §5.
   The golden model *is* the spec the RTL is written to.
2. **Next, with Icarus / Verilator:** self-checking benches under `sim/`
   drive `blake2b_g`, `blamka_g`, `argon2_compress` with vectors dumped
   from `ref/`.
3. **On F1:** one-channel known-answer (the 32 KiB RFC vector fits in
   BRAM — use it as a unit test before touching DDR) then a DDR
   bandwidth microbench (`cl_dram_dma` hello-world).
