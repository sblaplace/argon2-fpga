# argon2-fpga

Accelerating argon2i/argon2id passphrase cracking on FPGAs by exploiting
**partitioned memory bandwidth** — the one axis argon2's memory-hardness can't
defend against.

## Motivation

argon2 is memory-hard by design: each guess requires a large (~1 GB) working
set hammered with random access, so the cost of cracking is

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

- **Core:** Blake2b round function (argon2's compression primitive) fully
  pipelined in fabric, plus the argon2 fill/index addressing logic.
- **Memory:** one independent channel per core (HBM pseudo-channel, or a
  dedicated DDR4 port). Each core owns a private ~1 GB region.
- **Scale:** replicate core+channel pairs until logic or channels run out.

## Hardware roadmap

1. **AWS F1 (`f1.2xlarge`, VU9P, 4×DDR4 channels)** — rent by the hour to
   develop + benchmark the core against 4 real independent ports. Cheapest
   way to prove scaling before spending capital.
2. **Used Alveo U50 (HBM2, ~$1.5–3k)** — the entry point for a real owned
   cracker (32 pseudo-channels).
3. Later: U55C / Bittware 520N if the design proves out and more ports are
   wanted.

## Status / next steps

- [ ] Survey existing open-source argon2 / Blake2b HDL cores (bcrypt cores are
      mature; argon2 is thin — likely porting/writing the core).
- [ ] Stand up an AWS F1 spot instance; get a hello-world DDR4 multi-channel
      benchmark running.
- [ ] Implement + verify Blake2b round in HDL against test vectors.
- [ ] Integrate argon2i fill/index logic; single-channel correctness.
- [ ] Scale to N channels; measure cand/s vs. theoretical bandwidth ceiling.

## References

- argon2 spec (RFC 9106) — https://www.rfc-editor.org/rfc/rfc9106
- Blake2b (RFC 7693) — https://www.rfc-editor.org/rfc/rfc7693
- bcrypt FPGA cluster (Malvoni & Designer) — the canonical "many memory ports"
  cracking architecture this project generalizes to argon2.
