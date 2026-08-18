# argon2-fpga

Accelerating argon2i/argon2id passphrase hashing on FPGAs by exploiting
**partitioned memory bandwidth** — the one axis argon2's memory-hardness can't
defend against.

## Motivation

argon2 is memory-hard by design: each guess requires a large (~1 GB) working
set hammered with random access, so the cost of an evaluation is

    cost = memory_per_instance × bandwidth_per_instance × parallelism

- **CPUs** lose: few memory channels, bandwidth shared across all cores.
- **GPUs** lose: huge bandwidth, but shared across thousands of lanes — the
  ~1 GB working set per guess fits almost no lanes, and they thrash.
- **An FPGA wins only if it breaks the bandwidth sharing** — by giving each
  argon2 core its own independent memory port. Logic is cheap (even a mid
  Kintex hosts dozens of cores); the *memory system* is the entire design.

The thesis: **N independent memory ports = N full-rate argon2 instances.**
Everything else is plumbing.

## The memory wall (measured / derived)

Per argon2i guess (time cost 4, 1 GB memory): ~4 GB of random memory traffic.

| Platform            | Memory BW  | argon2i cand/s | Note                        |
|---------------------|-----------|----------------|-----------------------------|
| i5-8400 desktop     | ~40 GB/s   | ~0.8–1         | already BW-saturated        |
| XC7K420T + 1 SODIMM | ~5 GB/s    | ~1.2           | DDR3 SODIMM = the whole cap |
| AWS f1.2xlarge VU9P | 4×DDR4 ch  | ~4             | 4 independent ports         |
| Alveo U50 (HBM2)    | ~460 GB/s  | ~tens          | 32 pseudo-channels          |

The takeaway: bandwidth per *isolated channel* × channel count is the only
number that matters. A single shared SODIMM caps a huge fabric at ~1 cand/s.

## Target architecture

- **Core:** BlaMka GB (not stock BLAKE2b — see below) fully pipelined onto
  DSP48, plus the argon2 fill / `index_alpha` addressing logic.
- **Memory:** one independent channel per core (HBM pseudo-channel, or a
  dedicated DDR4 port). Each core owns a private ~1 GB region.
- **Scale:** replicate core+channel pairs until logic or channels run out.

Argon2 uses BLAKE2b only for H / H' (once per guess). The fill loop is
compression **G**: 16 applications of permutation **P**, whose G-function is
**BlaMka** (`a + b + 2·trunc32(a)·trunc32(b)`). Stock BLAKE2b miner cores
cannot be reused for G. Details: [docs/SURVEY.md](docs/SURVEY.md),
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Hardware roadmap

1. **AWS F1 (`f1.2xlarge`, VU9P, 4×DDR4 channels)** — rent by the hour to
   develop + benchmark the core against 4 real independent ports. Cheapest
   way to prove scaling before spending capital.
2. **Used Alveo U50 (HBM2, ~$1.5–3k)** — the entry point for a real owned
   box (32 pseudo-channels).
3. Later: U55C / Bittware 520N if the design proves out and more ports are
   wanted.

## Status / next steps

- [x] Survey existing open-source argon2 / BLAKE2b HDL ([docs/SURVEY.md](docs/SURVEY.md)).
      No usable Argon2 fill core; BLAKE2b hashers exist but are the wrong primitive.
- [x] Python golden model of BLAKE2b + Argon2i/d/id, locked to RFC 7693 and
      RFC 9106 §5 (`make test`).
- [x] Synthesizable SystemVerilog: BlaMka GB, P, G, `index_alpha`, BLAKE2b F,
      and a single-lane fill-controller skeleton (`rtl/`).
- [x] Wire argon2i address generation (`G` in counter mode) into the fill FSM
      and prefetch the random read. Dest-xor (v1.3, pass > 0) is fetched too.
- [x] Icarus self-checking benches in `sim/` (G, index, addr-gen, 8 KiB fill
      KAT). Workflow YAML is in [`docs/github-ci.yml`](docs/github-ci.yml)
      (copy to `.github/workflows/ci.yml` to enable Actions).
- [ ] AWS F1 hello-world: `cl_dram_dma` multi-channel bandwidth, then one
      known-answer fill (the 32 KiB RFC vector) on a single DDR4 port.
- [ ] Slice barrier so one job can use p > 1 across cores; v1 is p = 1.
- [ ] Scale to N channels; measure cand/s vs. the bandwidth ceiling.

## Tree

```
ref/                  RFC-faithful Python (the spec the RTL is written to)
rtl/blake2b/          BLAKE2b G / round / F / incremental hasher  (H, H')
rtl/argon2/           BlaMka, P, G, index, addr-gen, fill ctrl     (the job)
sim/                  Icarus benches, vectors from ref/
docs/                 survey + architecture
tests/                unittest against RFC 9106 §5
```

## Verify

```
make test                 # RFC 7693 + RFC 9106 §5, no simulator needed
make -C sim               # Icarus self-checks (needs iverilog)
```

## References

- argon2 spec (RFC 9106) — https://www.rfc-editor.org/rfc/rfc9106
- Blake2b (RFC 7693) — https://www.rfc-editor.org/rfc/rfc7693
- bcrypt FPGA cluster (Malvoni & Designer) — the canonical "many memory ports"
  architecture this project generalizes to argon2.
