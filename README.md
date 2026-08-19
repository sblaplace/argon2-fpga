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
- [x] Self-checking benches in `sim/` (G, index, addr-gen, 8 KiB fill KAT,
      RFC 32 KiB / p=4 fill, AXI-MM adapter), running on **both Icarus and
      Verilator** (`make -C sim`, `make -C sim SIM=verilator`). Workflow YAML
      is in [`docs/github-ci.yml`](docs/github-ci.yml) (copy to
      `.github/workflows/ci.yml` to enable Actions).
- [x] Slice barrier so one job can use p > 1 across cores
      (`argon2_fill_job`); locked to the RFC 9106 §5 32 KiB vector.
- [x] AXI4-MM adapter (`argon2_axi_mm` / `argon2_fill_axi`): 512-bit,
      16-beat bursts, independent R/W so a prefetch can overlap a write.
- [x] F1 CL shell scaffold (`fpga/f1/`): `cl_argon2` top mapping the
      `cl_dram_dma` port list onto 4× `argon2_fill_axi` + an OCL register
      slave + a p=4 slice-sync barrier. See `fpga/f1/README.md`.
- [x] Performance model: the core was **measured** against a cycle-accurate
      DDR4-2400 timing model (`sim/tb_ddr4_ram.sv`, `make -C sim perf`) —
      and it turned out compute-bound, not memory-bound. Fixes (parallel-P
      compression `N_P`, write-through prev cache, early dest-xor read,
      dest streaming, **32-deep streaming write FIFO**) took it from
      **0.21 → 0.94 cand/s per lane** (t=3, 1 GiB, 200 MHz, argon2i),
      i.e. **~3.75 cand/s on a 4-channel f1.2xlarge**, with the DDR port
      48% busy (IDEAL floor 62.3 cyc/blk → 1.02 cand/s). Type sweep:
      argon2d ~0.59/lane, argon2id ~0.63/lane (ref-latency bound, no
      prefetch). Numbers, sweep tables, and remaining headroom:
      [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md). The same work flushed
      out four latent CL bugs (broken file list, missing `rready` in the
      local `axi_bus_t`, a byte-addressing bug in the OCL slave,
      unlatched `done`) — the 4-channel `tb_cl_argon2` bench now passes
      on Verilator as well as Icarus.
- [ ] AWS F1 hello-world: build the shell, run the 32 KiB RFC vector on a
      single DDR4 port (sim KAT already exists), then `cl_dram_dma`
      multi-channel bandwidth. Bring-up checklist, host driver, and
      DDR bandwidth microbench are in [`docs/F1_BRINGUP.md`](docs/F1_BRINGUP.md),
      [`fpga/f1/host/argon2_cl.c`](fpga/f1/host/argon2_cl.c), and
      [`fpga/f1/host/bw_test.c`](fpga/f1/host/bw_test.c) (`fpga/f1/build.sh`).
- [ ] Scale to N channels; measure cand/s vs. the bandwidth ceiling
      (per `docs/PERFORMANCE.md`, the ceiling per 512-bit @ 200 MHz
      channel is ~1.07 cand/s — the 0.94/lane argon2i measurement is
      already within ~12% of it; argon2d 0.59/lane is ref-latency bound).

## Tree

```
ref/                  RFC-faithful Python (the spec the RTL is written to)
rtl/blake2b/          BLAKE2b G / round / F / incremental hasher  (H, H')
rtl/argon2/           BlaMka, P, G, index, addr-gen, fill, AXI-MM  (the job)
sim/                  Icarus / Verilator benches, vectors from ref/
docs/                 survey + architecture
tests/                unittest against RFC 9106 §5
```

## Verify

```
make test                              # RFC 7693 + RFC 9106 §5, no simulator needed
make -C sim                            # Icarus self-checks (needs iverilog)
make -C sim SIM=verilator              # same benches on Verilator
make -C sim SIM=verilator NP=8 all cl  # whole suite at the parallel-P point
make -C sim SIM=verilator NP=8 perf    # cand/s vs. DDR4 timing model
```

## References

- argon2 spec (RFC 9106) — https://www.rfc-editor.org/rfc/rfc9106
- Blake2b (RFC 7693) — https://www.rfc-editor.org/rfc/rfc7693
- bcrypt FPGA cluster (Malvoni & Designer) — the canonical "many memory ports"
  architecture this project generalizes to argon2.
