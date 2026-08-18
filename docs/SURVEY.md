# Survey: existing BLAKE2b / Argon2 HDL

The first item on the roadmap. Short version: **there is no production
open-source Argon2 fabric core**. BLAKE2b cores exist and are useful for
H / H', but they do **not** implement the memory-fill compression function.

## Why stock BLAKE2b cores are the wrong primitive

Argon2 (RFC 9106) uses BLAKE2b in two different ways:

| Call site | Function | What we need |
|-----------|----------|----------------|
| H, H'     | BLAKE2b-b (RFC 7693) | Any correct hasher. Used once per guess (H0) plus a handful of times for the two seed blocks and the tag. **Not** bandwidth-critical. |
| Fill loop | Compression **G**     | 16 applications of permutation **P** per 1 KiB block. P is a BLAKE2b *round* whose G-function is replaced by **BlaMka**: each add becomes `a + b + 2·trunc32(a)·trunc32(b)`. ~4 M calls/guess at 1 GiB / t=4. **This is the core.** |

A BLAKE2b miner pipeline (12 rounds, message schedule, IV, counters) cannot
be retargeted at G without throwing most of it away. The 32×32 multiply is
the entire point of BlaMka — it was added specifically to deepen an ASIC /
FPGA critical path.

## Open-source BLAKE2b cores

| Project | Lang | Notes | Reuse? |
|---------|------|-------|--------|
| [secworks/blake2](https://github.com/secworks/blake2) | Verilog | Clean RFC 7693 BLAKE2b, BSD-2. Incremental hasher + reference C. | Yes, as a drop-in H / H' — we wrote our own equivalently-sized core instead, to keep the tree self-contained and MIT. |
| [christian-krieg/blake2](https://github.com/christian-krieg/blake2) | VHDL | TU Wien class project, BLAKE2b + BLAKE2s, BSD-3, GHDL tests. | Same role as secworks. VHDL would force a mixed-language flow on Vivado. |
| [pedrorivera/SiaFpgaMiner](https://github.com/pedrorivera/SiaFpgaMiner) | VHDL | Fully unrolled / pipelined MixG for Siacoin. 200 MHz on mid Kintex, ~18 % per core. | Architecture reference for a deep MixG pipeline. Wrong G (no multiply, 12-round hash, nonce counter). |
| [mikalv/blake2-1](https://github.com/mikalv/blake2-1) | Verilog | Another BLAKE2b hasher. | Same as secworks. |

No Argon2 fill-loop HDL turned up. CPU/GPU libraries (PHC reference,
yandex/argon2, hashcat) are software only.

## Architectural precedent: many memory ports

The design thesis is borrowed from the bcrypt FPGA clusters (Malvoni &
Designer): **give each guess its own memory port**. bcrypt is ~4 KiB;
Argon2 is ~1 GiB. The compute/area trade is inverted — bcrypt is
logic-bound, Argon2 is *channel*-bound — but the floorplan is the same:

```
  [ core 0 ]──port 0──[ DDR/HBM ch 0 ]
  [ core 1 ]──port 1──[ DDR/HBM ch 1 ]
  [  ...   ]          [     ...      ]
```

Shared-memory GPU/CPU implementations lose because the working set of one
guess evicts the next. Partitioned ports do not.

## Decision

Write the core. Specifically:

1. **BlaMka GB**, 4-stage DSP pipeline — `rtl/argon2/blamka_g.sv`
2. **P** (8 GB) and **G** (16 P) — `rtl/argon2/argon2_p.sv`, `argon2_compress.sv`
3. **index_alpha** — `rtl/argon2/argon2_index.sv`
4. **BLAKE2b F** for H / H' — `rtl/blake2b/`
5. A Python golden model locked to RFC 9106 §5 vectors — `ref/`

Existing BLAKE2b HDL is treated as a second source, not a dependency.
