# HBM4 / custom-package architecture

## Purpose

This document defines the next scale point beyond the current DDR4/F1 design:
a many-context Argon2 accelerator attached to one or more HBM4-class memory
stacks. It is an architecture target, not a claim that the current RTL has
an HBM PHY or an HBM4 implementation.

The current design proves the important local result: one isolated memory
channel can sustain approximately one 1 GiB, `t=3`, `p=1` candidate per
second when the lane uses `N_P=8`. HBM4 changes the scale of the memory system,
not the Argon2 algorithm. The proposed implementation therefore preserves the
verified fill controller and replaces the one-lane memory attachment with a
bank-aware pool of contexts.

## External reference point

JEDEC JESD270-4 HBM4 specifies a 2,048-bit interface, 32 channels per stack,
and up to 2 TB/s aggregate bandwidth per stack at up to 8 Gb/s per pin:

<https://www.jedec.org/news/pressreleases/jedec%C2%AE-and-industry-leaders-collaborate-release-jesd270-4-hbm4-standard-advancing>

The bandwidth number is a package-level peak. It must not be used as the
expected Argon2 rate without measuring request efficiency, bank conflicts,
refresh, and read/write scheduling.

## First-order rate model

The existing `tb_perf` reference point is close to a 512-bit, 200 MHz AXI
channel: 12.8 GB/s and approximately 1.0 candidate/s. This implies an
initial planning estimate of about 12 GB of DRAM traffic per candidate for
the repository's 1 GiB / `t=3` projection.

```text
ideal_candidates_per_second = usable_memory_bytes_per_second / traffic_per_candidate
```

Planning numbers, not acceptance criteria:

| HBM4 stacks | Peak bandwidth | 12 GB/candidate bound | 70% usable-bandwidth estimate |
|-------------:|----------------:|----------------------:|------------------------------:|
| 1            | 2 TB/s          | 167 cand/s            | 117 cand/s                    |
| 4            | 8 TB/s          | 667 cand/s            | 467 cand/s                    |
| 8            | 16 TB/s         | 1,333 cand/s          | 933 cand/s                    |
| 16           | 32 TB/s         | 2,667 cand/s          | 1,867 cand/s                  |

The 70% column is deliberately conservative. The eventual benchmark must
report useful bandwidth and candidates/s separately. Argon2d/id should be
measured with many contexts in flight; a single context has an unavoidable
data-dependent reference dependency.

## Proposed top-level organization

```text
                 host / PCIe / control plane
                            |
                    context queue + scheduler
                            |
              +-------------+-------------+
              |                           |
       Argon2 lane pool             HBM address mapper
       (many contexts)              + bank/channel queues
              |                           |
              +-------------+-------------+
                            |
                 HBM controller / PHYs
                            |
                    HBM4 stacks
```

A context is one Argon2 password attempt, including its H0 state, parameters,
current block position, pass/slice/segment state, and memory base. Contexts are
independent for `p=1`. The scheduler may suspend a context while its dependent
read is outstanding and issue work from another context.

### Logical versus physical lanes

The current `argon2_fill_ctrl` lane is both a compute lane and a memory owner.
That coupling is appropriate for a single DDR channel but should not be
preserved at HBM scale.

The new design should distinguish:

* **Context**: one candidate and its logical 1 GiB address space.
* **Compute lane**: a BlaMka/P pipeline that executes a ready block.
* **Memory partition**: a schedulable HBM channel/bank-group destination.
* **Physical HBM channel**: a controller/PHY-visible endpoint.

A block address is hashed/interleaved across physical channels. A context may
therefore use the whole HBM stack, rather than being pinned to one 1 GiB
channel. This is important: pinning one candidate to one HBM channel throws
away most of HBM's aggregate bandwidth.

## Memory mapping

The first implementation should use a fixed, reversible mapping:

```text
byte_address = context_base
             + block_index * 1024
             + beat_index * 64

physical_channel = hash(context_id, block_index[...]) % CHANNELS
bank/group       = hash(context_id, block_index[...])
row/column       = controller mapping
```

The mapping must preserve the 1 KiB block abstraction at the fill-controller
boundary. It must also expose the physical destination before a request enters
the scheduler, so arbitration does not require a runtime divider.

The first mapping should be intentionally simple and deterministic. Candidate
placement and channel hashing can be optimized after a traffic trace exists.
Do not start with a cache-coherent or virtual-memory interface.

## Request interface to standardize now

The HBM-independent fabric should use a decoupled block interface. It is
narrower than the physical HBM datapath and can later be adapted to 512-bit,
1024-bit, or native HBM widths.

### Read request

```systemverilog
valid, ready
context_id       // identifies the candidate
request_id       // identifies the 1 KiB burst
block_addr       // logical block index within the candidate
channel_hint     // optional mapper result
priority         // normal / dependent / writeback-recovery
```

### Read response

```systemverilog
valid, ready
context_id
request_id
beat_index       // 0..15 for the current 1 KiB block
last
error
512-bit data     // first portable implementation width
```

### Write stream

```systemverilog
valid, ready
context_id
block_addr
beat_index
last
512-bit data
```

The 512-bit fabric width is intentional for compatibility with the current
AXI adapter. A future HBM adapter may combine or split beats internally. No
Argon2 controller should depend on the number of physical HBM channels.

## Compute organization

The initial ASIC target is not one enormous pipeline for one candidate. It is
a pool of `N_LANES` compute lanes, each with `N_P=8` permutation units, plus a
small context state RAM.

A lane can be in one of these classes:

1. ready to issue a memory operation;
2. waiting for a 1 KiB reference block;
3. compressing;
4. draining/writing a completed block;
5. waiting for a slice barrier;
6. idle or returning a result.

For Argon2i, address generation can run ahead and populate queues. For
Argon2d/id, the dependent reference request is issued as soon as `J1 || J2`
is available. The scheduler should switch to another ready context instead
of stalling a compute lane globally.

The existing double-buffered compressor and write-through hazard behavior are
useful starting points. The first multi-context version should retain the
current correctness-critical RAW checks and add performance optimizations only
behind counters.

## `p > 1`

`p=1` independent contexts are the first target because they demonstrate
aggregate candidates/s and have no cross-context barrier.

For `p>1`, all lanes belonging to one candidate must share a slice barrier,
and a reference read may target another logical lane. The memory mapper must
translate `(context_id, logical_lane, block_index)` to a physical partition.
The current `argon2_mem_xbar` is the correctness reference for this operation;
it should be generalized rather than bypassed.

Acceptance order:

1. many independent `p=1` contexts;
2. one `p=4` context over partitioned HBM memory;
3. many simultaneous `p=4` contexts;
4. dynamic context scheduling and channel balancing.

## Resource and capacity targets

These are planning targets, not promises:

| Target | HBM4 stacks | Memory | Compute lanes | Peak bandwidth |
|---|---:|---:|---:|---:|
| FPGA prototype | 1 | 36–64 GB | 32–64 | 2 TB/s |
| First ASIC | 4 | 144–256 GB | 128–256 | 8 TB/s |
| Large ASIC | 8 | 288–512 GB | 256–512 | 16 TB/s |

A 1 GiB working set per context means capacity supports roughly the same
number of resident contexts as gigabytes of HBM. The scheduler may keep more
candidate descriptors in host memory, but only resident contexts can make
progress without a refill mechanism.

## Verification and benchmark plan

### Phase A: fabric model

* Add a parameterized multi-partition behavioral memory model.
* Drive randomized 1 KiB reads/writes with out-of-order request completion.
* Check response tags, no beat loss, and no cross-context contamination.
* Measure channel occupancy, bank conflicts, queue depth, and read/write turn.

### Phase B: one controller, many contexts

* Keep the current `argon2_fill_ctrl` algorithm bit-identical.
* Add a context wrapper that saves/restores controller state.
* Run at least 32 `p=1` contexts through one logical HBM stack.
* Compare against the Python reference and existing AXI KATs.

### Phase C: HBM-width adapter

* Preserve the 512-bit internal interface.
* Add a parameterized width adapter and a native-channel timing model.
* Test 512/1024/2048-bit aggregate datapaths without changing the controller.

### Phase D: hardware

* Prototype the scheduler and mapper on an HBM FPGA if available.
* Collect traces before changing the address hash.
* Measure useful GB/s, cand/s, watts, and cand/s/W.
* Only then choose between more compute lanes and more memory stacks.

A performance result is accepted only when it includes the parameters (`m'`,
`t`, `p`, type, number of contexts, clock), effective bandwidth, and aggregate
cand/s. Peak HBM bandwidth alone is not a result.

## Decisions and non-goals

* **Use HBM4 as the first physical target**, because it is a standardized,
  commercially recognizable interface rather than because it is a theoretical
  optimum for Argon2.
* **Do not design a DRAM PHY in this repository.** The repository should own
  the context scheduler, block mapper, fabric, controller adaptation, and
  verification models.
* **Do not pin one candidate to one HBM channel.** That makes the design easy
  to explain but wastes aggregate bandwidth.
* **Do not introduce a general cache hierarchy initially.** Argon2's working
  set and random references make a conventional cache an uncertain use of
  area; begin with explicit queues and small correctness caches.
* **Do not claim linear scaling without a trace-backed model.** Controller
  contention and dependent references are expected to reduce scaling.

## Immediate implementation sequence

1. Extract a generic tagged block-memory interface from `argon2_fill_axi`.
   The first RTL baseline is now `rtl/argon2/argon2_block_fabric.sv`: it
   provides tagged 1 KiB reads, 16-beat response routing, rotating
   per-partition arbitration, a backpressured write stream, and a reversible
   power-of-two block mapping.
2. Build a parameterized `argon2_mem_fabric` behavioral model with 1, 4, 8,
   and 32 partitions.
3. Add a context scheduler around the existing `argon2_fill_ctrl`.
4. Reuse `argon2_mem_xbar` for the first `p=4` implementation.
5. Add a cycle-accurate HBM-like timing model and a `cand/s` sweep bench.
6. Only after those tests pass, add HBM-native width adaptation and FPGA
   vendor integration.
