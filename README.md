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
      Verilator** (`make -C sim`, `make -C sim SIM=verilator`). The active
      smoke workflow is `.github/workflows/rtl-smoke.yml`; a larger example
      matrix is retained in [`docs/github-ci.yml`](docs/github-ci.yml).
- [x] Slice barrier for p > 1 in the shared-memory RTL harness
      (`argon2_fill_job`); locked to the RFC 9106 §5 32 KiB vector.
- [x] **Partitioned-memory p=4** (`argon2_mem_xbar`): the cross-channel
      read router the floorplan thesis needs — routes each lane's reference
      read to the owning channel (owner hint, no runtime divider), passes
      writes through 1:1, tag-returns the 16-beat responses with pipelined
      multi-outstanding read support. Verified by `tb_argon2_p4` (RFC §5
      vector + m'∈{64,128} sweep + non-pow2 m'=48, i/d/id, N_P=1/8, four
      *separate* local-addressed memories) and measured by `tb_p4_perf` on
      four cycle-accurate DDR4 channels: **1×p=4 ≈ 3.5–3.6 cand/s on 4 channels**
      (200 MHz, N_P=8) vs 4×p=1 ≈ 4.1 — **~87% aggregate efficiency** and 4×
      better per-candidate latency. Landing it also fixed two latent request-mutation
      hazards in `argon2_fill_ctrl` (see `docs/PERFORMANCE.md`).
- [x] AXI4-MM adapter (`argon2_axi_mm` / `argon2_fill_axi`): 512-bit,
      16-beat bursts, independent R/W so a prefetch can overlap a write.
- [x] F1 CL shell scaffold (`fpga/f1/`): `cl_argon2` top mapping the
      `cl_dram_dma` port list onto 4× `argon2_fill_axi` + an OCL register
      slave + a p=4 slice-sync barrier. See `fpga/f1/README.md`.
- [x] Performance model: the core was **measured** against a cycle-accurate
      DDR4-2400 timing model (`sim/tb_ddr4_ram.sv`, `make -C sim perf`) —
      and it turned out compute-bound, not memory-bound. Fixes (parallel-P
      compression `N_P`, write-through prev cache, early dest-xor read,
      dest streaming, 32-deep streaming write FIFO, **compress
      double-buffering + chained overlapped next-block send**) took it
      from **0.21 → 1.03 cand/s per lane** (t=3, 1 GiB, 200 MHz, argon2i),
      i.e. **~4.1 cand/s on a 4-channel f1.2xlarge**, within ~4% of the
      200 MHz AXI bus ceiling (1.07), with the DDR port 55% busy. The
      double-buffer lets the compressor load block N+1 while draining
      block N; pass-0 blocks skip COMPRESS entirely and chain (IDEAL
      floor 56.3 cyc/blk → 1.13 cand/s). Numbers, sweep tables, and
      remaining headroom: [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md).
      The same work flushed out four latent CL bugs (broken file list,
      missing `rready` in the local `axi_bus_t`, a byte-addressing bug in
      the OCL slave, unlatched `done`) — the 4-channel `tb_cl_argon2`
      bench now passes on Verilator as well as Icarus.
- [x] **Dependent fast path (argon2d / argon2id, all passes)**: the pass>0
      dest-xor read goes out early from a deterministic address (the next
      block's own position — no data dependence), the dependent ref read is
      issued at drain beat 0 in *every* pass (was pass-0 only), and the
      returning ref burst **streams straight into the compressor load**
      (watermarked replay from registers + live beats). Measured
      (N_P=8, DDR4 model, t=3): argon2d 97.2 → 63.1 cyc/blk
      (**0.654 → 1.007 cand/s/lane**), argon2id 93.1 → 60.9
      (**0.683 → 1.044**); F1×4 2.62 → 4.03 and 2.73 → 4.18 — all three
      types now within ~6% of the 200 MHz AXI ceiling. Extending the KATs
      to a geometry sweep (m' 16–128 × t 1–3 × i/d/id,
      `sim/tb_argon2_axi_sweep.sv`) also exposed and fixed **two latent
      correctness bugs** on main: the dependent early-ref reference area
      was computed with `same_lane` unconnected (wrong for every p=1
      geometry with segment_length > 2), and a reference to a recently
      written block could read memory before its write committed (the
      write-FIFO RAW guard was masked by a cache hit that nothing ever
      forwarded from; now forwarded from the write-through cache).
- [ ] AWS F1 hello-world: build the shell, run the 32 KiB RFC vector on a
      single DDR4 port (sim KAT already exists), then `cl_dram_dma`
      multi-channel bandwidth. Bring-up checklist, host driver, and
      DDR bandwidth microbench are in [`docs/F1_BRINGUP.md`](docs/F1_BRINGUP.md),
      [`fpga/f1/host/argon2_cl.c`](fpga/f1/host/argon2_cl.c), and
      [`fpga/f1/host/bw_test.c`](fpga/f1/host/bw_test.c) (`fpga/f1/build.sh`).
- [ ] Scale independent p=1 jobs to N channels; measure cand/s vs. the
      bandwidth ceiling (per `docs/PERFORMANCE.md`, the ceiling per 512-bit
      @ 200 MHz channel is ~1.07 cand/s — the 1.03/lane argon2i measurement
      is already within ~4% of it; argon2d 0.60/lane is ref-latency bound).
- [ ] Add an owner-channel read crossbar before enabling a single p>1 job
      across physically partitioned memories; Argon2 references other lanes,
      so a barrier alone is insufficient.
- [x] **HBM4/custom-package architecture:** define the many-context,
      bank-aware memory fabric and ASIC scaling target. The design proposal,
      bandwidth model, tagged block interface, and staged implementation plan
      are in [`docs/HBM4_ARCHITECTURE.md`](docs/HBM4_ARCHITECTURE.md).
- [x] **Tagged block fabric** (`argon2_block_fabric`): the correctness-first
      baseline for the many-context memory system — tagged 1 KiB reads, 16-beat
      response routing, rotating per-partition arbitration, a backpressured
      write stream, and the reversible power-of-two block mapping. Self-checked
      by `tb_argon2_block_fabric` and throughput-modeled by
      `tb_hbm_fabric_perf` (`make -C sim fabric hbmperf hbmperf-sweep`).
- [x] **Many-context scheduler** (`argon2_multi_ctx` + `argon2_ctx_lane`): a
      pool of compute lanes round-robined over independent p=1 contexts, with
      every read/write tagged by context id and striped through one shared
      block fabric. `tb_argon2_multi_ctx` runs 32 contexts (distinct
      passwords) through a data-storing HBM model and compares each context's
      final working set against the Python reference (`make -C sim multi`).

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
make sim-verilator                     # same benches on Verilator via the PyPI/system helper
make -C sim SIM=verilator NP=8 sweep   # m'16-128 x t1-3 x i/d/id AXI KAT sweep
make sim-np8                           # full sim suite at the N_P=8 performance point
make sim-verilator-np8                 # same full suite at N_P=8 on Verilator
make perf-verilator                    # DDR4 perf bench on Verilator (default PERF_NP=1)
make perf-verilator-np8                # DDR4 perf bench on Verilator at PERF_NP=8
./fpga/f1/build.sh sim --np 8          # 4-channel CL bench at the same N_P=8 point
./fpga/f1/build.sh emit-top --np 8     # generate a self-contained HDK top wrapper
```

## References

- argon2 spec (RFC 9106) — https://www.rfc-editor.org/rfc/rfc9106
- Blake2b (RFC 7693) — https://www.rfc-editor.org/rfc/rfc7693
- bcrypt FPGA cluster (Malvoni & Designer) — the canonical "many memory ports"
  architecture this project generalizes to argon2.
