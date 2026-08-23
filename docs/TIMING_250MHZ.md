# 250 MHz timing closure — target, measured payoff, and critical-path map

The single highest-value lever left is raising the core clock from 200 MHz
to **250 MHz** (the F1 `sh_ddr` reference-design frequency). Unlike the
overlap work it helps **all three types**, and unlike memory-bandwidth
tricks it is a pure clock-rate gain. This page is the closure-prep kit:
the realistic target (measured, not assumed), the critical paths, and what
to do about each.

## The realistic target (measured)

`tb_perf` is now clock-parameterized (`make -C sim PERF_MHZ=250 perf`,
or `make perf250`). Raising the clock re-derives the DDR4-2400 model's
cycle counts for the shorter period (tCL/tRCD/tRP 3→4, tRTW 2→3,
tRFC 70→88, tREFI 1560→1950), so the projection is honest rather than a
naive 1.25× scale.

N_P=8, m'=4096, t=3, p=1, Verilator:

| Type      | 200 MHz cand/s/lane (F1×4) | 250 MHz cand/s/lane (F1×4) | Δ/lane |
|-----------|----------------------------|----------------------------|--------|
| argon2i   | 1.002 (4.01)               | 1.135 (4.54)               | +13%   |
| argon2d   | 1.007 (4.03)               | 1.210 (4.84)               | +20%   |
| argon2id  | 1.044 (4.18)               | **1.240 (4.96)**           | +19%   |

The gain is below the 25% clock ratio because DRAM latency is fixed in
nanoseconds: cyc/block *rises* (argon2i 63.5→70.0, argon2id 60.9→64.1) as
the same tRCD/tCL cost more cycles, and the read port's *latency* occupancy
climbs from ~52% to ~64-67%. **argon2id, the RFC-recommended type, reaches
1.24 cand/s/lane — 4.96 on a 4-channel f1.2xlarge — if the fabric closes
at 250 MHz.** That is the number to design toward.

This is bounded by the 250 MHz AXI ceiling (~1.33 cand/s/lane): the lane
is ~93% of ceiling for argon2id, ~85% for argon2i (which is more
DRAM-latency-sensitive). Closing the rest needs the dest double-buffer
(see `docs/PERFORMANCE_OVERLAP_PLAN.md` — argon2i-only, low priority).

## What actually has to close

### 1. argon2_index modulo — DONE (this branch)

`ref_index = (start_position + rel) % lane_length` was a **full 32-bit
divider**: `lane_length` is a runtime input, so the synthesizer cannot
reduce it, and it was instantiated three times (`u_idx`, `u_idx_n`,
`u_idx_dep`) on the read-address path. A 32-bit divider is ~6-8 ns of
fabric — comfortably the worst path at 200 MHz and a hard block at 250 MHz.

It is now a **single conditional subtract**. `start_position <
lane_length` (it is a segment boundary: `0` or `(slice+1)*segment_length`
≤ ¾·lane_length) and `rel < lane_length` for every legal input
(`ref_area < lane_length` for every output of `argon2_ref_area` — the lone
`0xFFFF_FFFF` sentinel is the pass-0/slice-0/!same-lane/index-0 branch,
which the fill controller never produces since pass-0 slice-0 is always
same-lane). So the sum is in `[0, 2·lane_length)` and `%` collapses to

```systemverilog
sum = {1'b0,start_position} + {1'b0,rel};
ref_index = (sum >= {1'b0,lane_length}) ? sum - {1'b0,lane_length} : sum[31:0];
```

Bit- and cycle-identical across the full KAT suite (fill, rfc, axi, the
m'∈{16,32,64,128} geometry sweep, the 4-lane F1 `cl` top; i/d/id; N_P=1
and 8). **A divider→subtract on three read-address paths is very likely
the dominant 250 MHz closure win.**

### 2. BlaMka `fbla` (the multiply-add) — DSP register packing

`fbla(x,y) = x + y + 2·(x[31:0]·y[31:0])`. The 32×32 multiply infers DSP48
(`argon2/blamka_g.sv`). The RTL already pipelines one mix-quarter per
stage (Q0-Q3, registers between them), so the per-stage path is
register → DSP multiply → fabric add (x+y+2·prod) → register. That is
~3 ns (DSP) + ~1.5 ns (adds+routing) — tight but closeable at 250 MHz
**provided the synthesizer packs the DSP's internal pipeline registers**.

No RTL change needed; this is a synthesis/XDC setting:

* `synth_design -retiming` (or `OPT_DESIGN -retimer`), so the pipeline
  registers slide into the DSP48 M/P sites.
* `set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true` in the XSA flow.
* Keep `(* use_dsp48/use_dsp = "yes" *)` inference (Vivado does this
  automatically for 32×32; no attribute needed unless a specific DSP is
  unpicked).
* BlaMka latency stays 3 — do **not** add pipeline stages here; that would
  raise P latency and re-open the overlap tuning in
  `argon2_compress`/`argon2_fill_ctrl` (the whole N_P=8 schedule assumes
  2 waves × ~9 cycles).

If a stage still misses after retiming, the lever is the post-add: fold
`x + y` into the DSP48's C-input adder (C + M·P) rather than a fabric
chain. This is a synth hint / small `fbla` rewrite, not a latency change.

### 3. Other candidates to watch

* **`wb_hit_ref` write-FIFO RAW reduction — narrowed.** The RAW check in
  `argon2_fill_ctrl.sv` no longer scans all 32 FIFO beats. Because a 32-beat
  FIFO can contain at most three distinct block addresses (partial head,
  optional full middle, partial tail), the controller now tracks those block
  addresses explicitly and compares reads against that 3-entry queue. If this
  path still shows up after synthesis, the next lever is registering the
  compare result one cycle early.
* **`argon2_index` two 32×32 multiplies** (`j1*j1`, `ref_area*j1_sq[63:32]`),
  3 instances = 6 DSPs. Same DSP-register-packing treatment as BlaMka.
* **Lane-select `% lanes` in `argon2_fill_ctrl` — mostly removed.** The
  hot-path `J2 % lanes` selects (`ref_lane`, `ref_lane_n`, dependent-lane
  early read) now special-case the common p counts this repo actually builds
  today — 1/2/4/8/16 lanes — onto masks / bit slices, and the associated
  `lane * lane_length` offsets now use shift-adds for those same cases, so
  p=1 and p=4 no longer carry a runtime divider/full-width multiplier
  there. Odd/non-power-of-two lane counts still fall back to the generic
  modulo/multiply and remain functionally supported.
  The first-block `prev_idx` wrap was similarly rewritten from
  `curr_idx % lane_length == 0` to the direct `(slice==0 && index==0)`
  predicate.
* **`argon2_compress` gather muxes**: each P wave reads 16 of 128 64-bit
  block words per instance (N_P=8 ⇒ wide muxing). A big but shallow mux —
  expect routing, not logic, to be the cost; `PBLOCK`/floorplanning if it
  shows up.

## Closure checklist for the Vivado pass

1. Synthesize at 250 MHz with `-retiming`; confirm the `argon2_index`
   subtract (not a divider) and the BlaMka DSP register packing landed.
   For the F1 HDK flow, `fpga/f1/build/synth_timing.tcl` sets the
   `STEPS.SYNTH_DESIGN.ARGS.RETIMING` property on `synth_1` — source it
   into the HDK synthesis tcl before `launch_runs`. The core/OCL/DDR are
   all on `clk_main_a0` (shell-owned), so there are no CDC constraints to
   add.
2. Read the top negative-slack paths. Expectation: BlaMka mult-add, then
   addr/`argon2_addr_gen`, then any residual write-FIFO RAW compare logic.
3. If BlaMka misses, fold `x+y` into the DSP48 C-adder (Step 2 above).
4. Re-run the perf bench at `PERF_MHZ=250` against the post-route
   frequency (if the tool reports e.g. 240 MHz, set `PERF_MHZ=240` and
   re-derive).
5. The XDC clock is the existing `sh_clk` (250 MHz) the F1 shell already
   provides; the core currently divides to 200 MHz. Run the core on the
   raw 250 MHz `sh_clk` (or a 250 MHz BUFG) and drop the divider.

## Caveat

These numbers are from the RTL timing **model**, not post-route. The
cycle counts are real (the RTL is unchanged by the clock knob — only the
DDR4 model's cycle counts and the cand/s projection change). Whether the
fabric actually achieves 250 MHz is a synthesis question; this page
identifies the paths and removes the worst one (the divider) so the
question is answerable on the BlaMka/DSP axis, where the fix is a known
synth setting rather than a design change.
