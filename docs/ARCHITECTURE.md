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
integration is four copies of `argon2_fill_axi`, one per `sh_ddr`
port. Cross-channel traffic is only the 1-bit slice barrier when a
single job uses p > 1.

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
| F1 `cl_dram_dma` / `sh_ddr` shell | Not yet |
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
