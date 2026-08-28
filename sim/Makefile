# Self-checking benches. Two back ends:
#
#   make            # Icarus Verilog (iverilog + vvp)
#   make SIM=verilator
#
# Both run the same .sv sources and the same vectors dumped from ref/.

SIM      ?= iverilog

# Parallel P units for the compression G (1, 2, 4, 8). Every bench top
# carries an N_P parameter, so one override re-builds the whole suite at
# the chosen area/performance point:  make SIM=verilator NP=8 all cl
NP       ?= 1

IVERILOG ?= iverilog
VVP      ?= vvp
VERILATOR ?= verilator

INCDIR   := ../rtl/include
RTL      := ../rtl
GEN      := gen
OBJ      := obj

ARGON2_G := \
	$(RTL)/argon2/blamka_g.sv \
	$(RTL)/argon2/argon2_p.sv \
	$(RTL)/argon2/argon2_compress.sv

FILL_RTL := \
	$(ARGON2_G) \
	$(RTL)/argon2/argon2_index.sv \
	$(RTL)/argon2/argon2_addr_gen.sv \
	$(RTL)/argon2/argon2_fill_ctrl.sv

SRC_tb_blake2b_g        := $(RTL)/blake2b/blake2b_g.sv
SRC_tb_blamka_g         := $(RTL)/argon2/blamka_g.sv
SRC_tb_argon2_index     := $(RTL)/argon2/argon2_index.sv
SRC_tb_argon2_compress  := $(ARGON2_G)
SRC_tb_argon2_addr_gen  := $(RTL)/argon2/argon2_addr_gen.sv $(ARGON2_G)
SRC_tb_argon2_fill      := $(FILL_RTL)
SRC_tb_argon2_fill_discipline := $(FILL_RTL)
SRC_tb_argon2_fill_rfc  := $(FILL_RTL) $(RTL)/argon2/argon2_fill_job.sv
SRC_tb_argon2_axi       := $(FILL_RTL) \
	$(RTL)/argon2/argon2_axi_mm.sv \
	$(RTL)/argon2/argon2_fill_axi.sv \
	tb_axi_ram.sv

# Large-m' (128 KiB, t=3) AXI KAT — exercises scale-only scheduling paths
# (write-FIFO hazard skips, cross-segment early dest, multi-window addr).
SRC_tb_argon2_axi_big   := $(SRC_tb_argon2_axi)

# Geometry sweep (m' 16/32/64/128 x t 1/2/3 x i/d/id): locks the dependent
# early-ref reference area and write-FIFO RAW distances that m'=8 cannot see.
SRC_tb_argon2_axi_sweep := $(SRC_tb_argon2_axi)

# Partitioned-memory p=4: four fill controllers + the read crossbar + four
# separate local-addressed memories (RFC 9106 5 vector + p4 geometry sweep).
SRC_tb_argon2_p4 := \
	$(FILL_RTL) \
	$(RTL)/argon2/argon2_fill_job.sv \
	$(RTL)/argon2/argon2_mem_xbar.sv

# Tagged multi-partition block fabric baseline (HBM-scale architecture).
SRC_tb_argon2_block_fabric := $(RTL)/argon2/argon2_block_fabric.sv
SRC_tb_hbm_fabric_perf := $(RTL)/argon2/argon2_block_fabric.sv

# Many-context engine: LANES fill controllers scheduled over independent p=1
# contexts through one shared block fabric (HBM4 plan step 3).
SRC_tb_argon2_multi_ctx := $(FILL_RTL) \
	$(RTL)/argon2/argon2_ctx_lane.sv \
	$(RTL)/argon2/argon2_multi_ctx.sv \
	$(RTL)/argon2/argon2_block_fabric.sv

# Multi-context concentrator KAT: NCTX independent p=1 contexts sharing ONE
# memory port through argon2_lane_conc (tagged multi-in-flight reads +
# burst-locked writes) — the lever-2 topology measured by tb_conc_perf.
SRC_tb_argon2_conc := $(FILL_RTL) \
	$(RTL)/argon2/argon2_lane_conc.sv


# ---- F1 CL top-level bench ------------------------------------------------
F1DES := ../fpga/f1/design

SRC_tb_cl_argon2 := \
	$(RTL)/blake2b/blake2b_g.sv $(RTL)/blake2b/blake2b_round.sv \
	$(RTL)/blake2b/blake2b_compress.sv $(RTL)/blake2b/blake2b_core.sv \
	$(RTL)/argon2/blamka_g.sv $(RTL)/argon2/argon2_p.sv $(RTL)/argon2/argon2_compress.sv \
	$(RTL)/argon2/argon2_index.sv \
	$(RTL)/argon2/argon2_addr_gen.sv $(RTL)/argon2/argon2_fill_ctrl.sv \
	$(RTL)/argon2/argon2_fill_job.sv $(RTL)/argon2/argon2_axi_mm.sv $(RTL)/argon2/argon2_fill_axi.sv \
	$(F1DES)/cl_argon2_ocl.sv \
	$(F1DES)/cl_argon2_core.sv $(F1DES)/cl_argon2.sv \
	tb_axi_ram.sv

# ---- perf bench -----------------------------------------------------------
# Cycle-accurate throughput measurement: one argon2i lane vs ideal memory
# and vs a DDR4-2400 channel timing model (tb_ddr4_ram). PERF_BLKS sets the
# working set (m', in 1 KiB blocks); the printed cand/s is projected to the
# 1 GiB / t=3 reference job.
#
# NOTE: `all` (not `perf`) is the default goal — run_tb.py and humans
# running bare `make` get the functional suite.

.DEFAULT_GOAL := all

PERF_BLKS ?= 4096
PERF_NP   ?= 1
PERF_IWR  ?= 0
PERF_TYPE ?= 1
PERF_MHZ  ?= 200    # core clock; 250 re-derives the DDR4 cycle counts (see tb_perf)

SRC_tb_perf := $(FILL_RTL) \
	$(RTL)/argon2/argon2_axi_mm.sv \
	$(RTL)/argon2/argon2_fill_axi.sv \
	tb_ddr4_ram.sv

# Channel-capacity ceiling bench: the DDR4 model plus its own AXI master.
SRC_tb_ddr4_ceiling := tb_ddr4_ram.sv

# Per-channel capacity ceiling: a saturating AXI master on tb_ddr4_ram issuing
# the argon2 traffic mix (NRD reads per NWR writes; 5:3 is t=3). Answers "how
# many lanes can share one DDR4 channel" — an upper bound, not an achieved rate.
CEIL_BLKS  ?= 4096
CEIL_NRD   ?= 5
CEIL_NWR   ?= 3
CEIL_OUT   ?= 4
CEIL_NCOMP ?= 24576
CEIL_MHZ   ?= 200
CEIL_LANE  ?= 1.044   # tb_perf argon2id N_P=8 cand/s at CEIL_MHZ (report only)

# Multi-context concentrator perf bench: NCTX p=1 contexts sharing ONE
# DDR4-2400 channel through argon2_lane_conc (lever 2; see tb_conc_perf
# header). CONC_CTXS sweeps the contexts-per-channel point.
CONC_NP   ?= 8
CONC_CTXS ?= 2
CONC_BLKS ?= 4096
CONC_TYPE ?= 2
CONC_MHZ  ?= 200

SRC_tb_conc_perf := $(FILL_RTL) \
	$(RTL)/argon2/argon2_lane_conc.sv \
	$(RTL)/argon2/argon2_axi_mm.sv \
	tb_ddr4_ram.sv

# Partitioned-memory p=4 perf bench: one candidate over 4 independent
# DDR4-2400 channels through argon2_mem_xbar (see tb_p4_perf header).
P4_BLKS ?= 16384
P4_NP   ?= 1
P4_TYPE ?= 1
P4_MHZ  ?= 200

# HBM-like fabric model knobs.
FABRIC_RQ  ?= 32
FABRIC_PP  ?= 32
FABRIC_LAT ?= 20
FABRIC_BANKS ?= 16
FABRIC_TURN ?= 4

SRC_tb_p4_perf := $(FILL_RTL) \
	$(RTL)/argon2/argon2_fill_job.sv \
	$(RTL)/argon2/argon2_mem_xbar.sv \
	$(RTL)/argon2/argon2_axi_mm.sv \
	tb_ddr4_ram.sv

concperf: run-tb_conc_perf

concperf250: CONC_MHZ = 250
concperf250: concperf

p4perf: run-tb_p4_perf

perf: run-tb_perf

ddrceil: run-tb_ddr4_ceiling

# 250 MHz timing-closure target (F1 sh_ddr geometry): same RTL cycle counts,
# but the DDR4-2400 model is re-tuned for the 4 ns period so the projected
# cand/s is realistic. perf-all sweeps all three types at PERF_MHZ.
perf250: PERF_MHZ = 250
perf250: perf

perf-all: perf
	$(MAKE) PERF_TYPE=0 perf
	$(MAKE) PERF_TYPE=2 perf

ifeq ($(SIM),verilator)

run-tb_p4_perf: tb_p4_perf.sv tb_ddr4_ram.sv
	@rm -rf $(OBJ)/tb_p4_perf
	@mkdir -p $(OBJ)/tb_p4_perf
	$(VERILATOR) $(VFLAGS) -GNBLK=$(P4_BLKS) -GN_P=$(P4_NP) -GTYPE_I=$(P4_TYPE) -GPERF_MHZ=$(P4_MHZ) --Mdir $(OBJ)/tb_p4_perf --main --exe --cc -o tb_p4_perf tb_p4_perf.sv $(SRC_tb_p4_perf) --top-module tb_p4_perf
	@ln -sf Vtb_p4_perf__pch.h $(OBJ)/tb_p4_perf/Vtb_p4_perf__pch.h.fast
	@ln -sf Vtb_p4_perf__pch.h $(OBJ)/tb_p4_perf/Vtb_p4_perf__pch.h.slow
	@$(MAKE) -s -C $(OBJ)/tb_p4_perf -f Vtb_p4_perf.mk CFG_CXXFLAGS_PCH_I=-include CXXFLAGS="$(VCXXFLAGS)"
	./$(OBJ)/tb_p4_perf/tb_p4_perf

run-tb_conc_perf: tb_conc_perf.sv tb_ddr4_ram.sv
	@rm -rf $(OBJ)/tb_conc_perf
	@mkdir -p $(OBJ)/tb_conc_perf
	$(VERILATOR) $(VFLAGS) -GNBLK=$(CONC_BLKS) -GN_P=$(CONC_NP) -GTYPE_I=$(CONC_TYPE) -GNCTX=$(CONC_CTXS) -GPERF_MHZ=$(CONC_MHZ) --Mdir $(OBJ)/tb_conc_perf --main --exe --cc -o tb_conc_perf tb_conc_perf.sv $(SRC_tb_conc_perf) --top-module tb_conc_perf
	@ln -sf Vtb_conc_perf__pch.h $(OBJ)/tb_conc_perf/Vtb_conc_perf__pch.h.fast
	@ln -sf Vtb_conc_perf__pch.h $(OBJ)/tb_conc_perf/Vtb_conc_perf__pch.h.slow
	@$(MAKE) -s -C $(OBJ)/tb_conc_perf -f Vtb_conc_perf.mk CFG_CXXFLAGS_PCH_I=-include CXXFLAGS="$(VCXXFLAGS)"
	./$(OBJ)/tb_conc_perf/tb_conc_perf

run-tb_perf: tb_perf.sv tb_ddr4_ram.sv
	@rm -rf $(OBJ)/tb_perf
	@mkdir -p $(OBJ)/tb_perf
	$(VERILATOR) $(VFLAGS) -GNBLK=$(PERF_BLKS) -GN_P=$(PERF_NP) -GIDEAL_WR=$(PERF_IWR) -GTYPE_I=$(PERF_TYPE) -GPERF_MHZ=$(PERF_MHZ) --Mdir $(OBJ)/tb_perf --main --exe --cc -o tb_perf tb_perf.sv $(SRC_tb_perf) --top-module tb_perf
	@ln -sf Vtb_perf__pch.h $(OBJ)/tb_perf/Vtb_perf__pch.h.fast
	@ln -sf Vtb_perf__pch.h $(OBJ)/tb_perf/Vtb_perf__pch.h.slow
	@$(MAKE) -s -C $(OBJ)/tb_perf -f Vtb_perf.mk CFG_CXXFLAGS_PCH_I=-include CXXFLAGS="$(VCXXFLAGS)"
	./$(OBJ)/tb_perf/tb_perf

run-tb_ddr4_ceiling: tb_ddr4_ceiling.sv tb_ddr4_ram.sv
	@rm -rf $(OBJ)/tb_ddr4_ceiling
	@mkdir -p $(OBJ)/tb_ddr4_ceiling
	$(VERILATOR) $(VFLAGS) -GNBLK=$(CEIL_BLKS) -GNRD=$(CEIL_NRD) -GNWR=$(CEIL_NWR) -GOUTSTANDING=$(CEIL_OUT) -GNCOMP=$(CEIL_NCOMP) -GPERF_MHZ=$(CEIL_MHZ) -GLANE_CAND=$(CEIL_LANE) --Mdir $(OBJ)/tb_ddr4_ceiling --main --exe --cc -o tb_ddr4_ceiling tb_ddr4_ceiling.sv $(SRC_tb_ddr4_ceiling) --top-module tb_ddr4_ceiling
	@ln -sf Vtb_ddr4_ceiling__pch.h $(OBJ)/tb_ddr4_ceiling/Vtb_ddr4_ceiling__pch.h.fast
	@ln -sf Vtb_ddr4_ceiling__pch.h $(OBJ)/tb_ddr4_ceiling/Vtb_ddr4_ceiling__pch.h.slow
	@$(MAKE) -s -C $(OBJ)/tb_ddr4_ceiling -f Vtb_ddr4_ceiling.mk CFG_CXXFLAGS_PCH_I=-include CXXFLAGS="$(VCXXFLAGS)"
	./$(OBJ)/tb_ddr4_ceiling/tb_ddr4_ceiling
else
tb_perf.out: tb_perf.sv tb_ddr4_ram.sv
	$(IVERILOG) -g2012 -PNBLK=$(PERF_BLKS) -PN_P=$(PERF_NP) -PIDEAL_WR=$(PERF_IWR) -PTYPE_I=$(PERF_TYPE) -PPERF_MHZ=$(PERF_MHZ) -I$(INCDIR) -o $@ $< $(SRC_tb_perf)

run-tb_perf: tb_perf.out
	$(VVP) $<

tb_ddr4_ceiling.out: tb_ddr4_ceiling.sv tb_ddr4_ram.sv
	@# LANE_CAND is report-only and a `real` parameter; iverilog -P overrides
	@# are integer-only, so the Icarus build uses the module default (1.044).
	$(IVERILOG) -g2012 -PNBLK=$(CEIL_BLKS) -PNRD=$(CEIL_NRD) -PNWR=$(CEIL_NWR) -POUTSTANDING=$(CEIL_OUT) -PNCOMP=$(CEIL_NCOMP) -PPERF_MHZ=$(CEIL_MHZ) -I$(INCDIR) -o $@ $< $(SRC_tb_ddr4_ceiling)

run-tb_ddr4_ceiling: tb_ddr4_ceiling.out
	$(VVP) $<
endif

ifeq ($(SIM),verilator)
p4perf250: P4_MHZ = 250
p4perf250: p4perf
else
tb_p4_perf.out: tb_p4_perf.sv tb_ddr4_ram.sv
	$(IVERILOG) -g2012 -PNBLK=$(P4_BLKS) -GN_P=$(P4_NP) -PTYPE_I=$(P4_TYPE) -PPERF_MHZ=$(P4_MHZ) -I$(INCDIR) -o $@ $< $(SRC_tb_p4_perf)

p4perf250: P4_MHZ = 250
p4perf250: tb_p4_perf.out
	$(VVP) $<
endif

.PHONY: all blake2b blamka index compress addr fill discipline rfc p4 fabric hbmperf hbmperf-sweep multi axi axibig sweep cl perf p4perf perf250 perf-all ddrceil vectors clean
.SECONDARY:   # keep the built .out / model dirs between targets

all: blake2b blamka index compress addr fill discipline rfc p4 fabric multi conc axi axibig sweep

vectors: $(GEN)/fill_i_init.hex

$(GEN)/fill_i_init.hex: ../tests/dump_vectors.py ../ref/argon2.py
	mkdir -p $(GEN)
	cd .. && python3 -m tests.dump_vectors

blake2b: run-tb_blake2b_g
blamka:  run-tb_blamka_g
index:   run-tb_argon2_index
compress: run-tb_argon2_compress
addr:    run-tb_argon2_addr_gen
fill:    vectors run-tb_argon2_fill
discipline: vectors run-tb_argon2_fill_discipline
rfc:     vectors run-tb_argon2_fill_rfc
p4:      vectors run-tb_argon2_p4
fabric:  run-tb_argon2_block_fabric
hbmperf: run-tb_hbm_fabric_perf
multi:   vectors run-tb_argon2_multi_ctx
conc:    vectors run-tb_argon2_conc
axi:     vectors run-tb_argon2_axi
axibig:  vectors run-tb_argon2_axi_big
sweep:   vectors run-tb_argon2_axi_sweep

ifeq ($(SIM),verilator)

# Verilator's --binary drives its own make; the wheel-packaged builds ship a
# precompiled-header config that does not match a stock g++, so compile the
# generated model here with PCH used as a plain -include.
VFLAGS := --timing -Wno-WIDTH -Wno-fatal -I$(INCDIR) -GN_P=$(NP)
VCXXFLAGS := -O1 --std=c++20 -fcoroutines -DVL_TIME_CONTEXT

run-%: %.sv
	@rm -rf $(OBJ)/$*
	@mkdir -p $(OBJ)/$*
	$(VERILATOR) $(VFLAGS) --Mdir $(OBJ)/$* --main --exe --cc -o $* $*.sv $(SRC_$*) --top-module $*
	@ln -sf V$*__pch.h $(OBJ)/$*/V$*__pch.h.fast
	@ln -sf V$*__pch.h $(OBJ)/$*/V$*__pch.h.slow
	@$(MAKE) -s -C $(OBJ)/$* -f V$*.mk CFG_CXXFLAGS_PCH_I=-include CXXFLAGS="$(VCXXFLAGS)"
	./$(OBJ)/$*/$*

else

run-%: %.out
	$(VVP) $<

%.out: %.sv
	$(IVERILOG) -g2012 -PN_P=$(NP) -I$(INCDIR) -o $@ $< $(SRC_$*)

endif

# HBM-like fabric sweep target. The compile is parameterized separately from
# the generic run-% rule so changing FABRIC_PP really rebuilds the top.
hbmperf-sweep:
	@for p in 8 16 32; do \
		echo "== fabric partitions=$$p requesters=$$p =="; \
		$(MAKE) --no-print-directory -B hbmperf FABRIC_PP=$$p FABRIC_RQ=$$p; \
	done

ifeq ($(SIM),verilator)
run-tb_hbm_fabric_perf: tb_hbm_fabric_perf.sv
	@rm -rf $(OBJ)/tb_hbm_fabric_perf
	@mkdir -p $(OBJ)/tb_hbm_fabric_perf
	$(VERILATOR) $(VFLAGS) -GREQUESTERS=$(FABRIC_RQ) -GPARTITIONS=$(FABRIC_PP) -GREAD_LAT=$(FABRIC_LAT) -GBANKS=$(FABRIC_BANKS) -GRW_TURNAROUND=$(FABRIC_TURN) --Mdir $(OBJ)/tb_hbm_fabric_perf --main --exe --cc -o tb_hbm_fabric_perf tb_hbm_fabric_perf.sv $(SRC_tb_hbm_fabric_perf) --top-module tb_hbm_fabric_perf
	@ln -sf Vtb_hbm_fabric_perf__pch.h $(OBJ)/tb_hbm_fabric_perf/Vtb_hbm_fabric_perf__pch.h.fast
	@ln -sf Vtb_hbm_fabric_perf__pch.h $(OBJ)/tb_hbm_fabric_perf/Vtb_hbm_fabric_perf__pch.h.slow
	@$(MAKE) -s -C $(OBJ)/tb_hbm_fabric_perf -f Vtb_hbm_fabric_perf.mk CFG_CXXFLAGS_PCH_I=-include CXXFLAGS="$(VCXXFLAGS)"
	./$(OBJ)/tb_hbm_fabric_perf/tb_hbm_fabric_perf
else
run-tb_hbm_fabric_perf: tb_hbm_fabric_perf.out
	$(VVP) $<

tb_hbm_fabric_perf.out: tb_hbm_fabric_perf.sv $(SRC_tb_hbm_fabric_perf)
	$(IVERILOG) -g2012 -Ptb_hbm_fabric_perf.REQUESTERS=$(FABRIC_RQ) -Ptb_hbm_fabric_perf.PARTITIONS=$(FABRIC_PP) -Ptb_hbm_fabric_perf.READ_LAT=$(FABRIC_LAT) -Ptb_hbm_fabric_perf.BANKS=$(FABRIC_BANKS) -Ptb_hbm_fabric_perf.RW_TURNAROUND=$(FABRIC_TURN) -I$(INCDIR) -o $@ $< $(SRC_tb_hbm_fabric_perf)
endif

# Top-level F1 CL bench: instantiate cl_argon2 with 4 behavioral DDR RAMs
# and an OCL BFM, run a known-answer argon2i job on all four channels.
cl: vectors run-tb_cl_argon2

ifeq ($(SIM),verilator)
run-tb_cl_argon2: tb_cl_argon2.sv
	$(VERILATOR) $(VFLAGS) -I$(F1DES) --Mdir $(OBJ)/tb_cl_argon2 --main --exe --cc -o tb_cl_argon2 tb_cl_argon2.sv $(SRC_tb_cl_argon2) --top-module tb_cl_argon2
	@ln -sf Vtb_cl_argon2__pch.h $(OBJ)/tb_cl_argon2/Vtb_cl_argon2__pch.h.fast
	@ln -sf Vtb_cl_argon2__pch.h $(OBJ)/tb_cl_argon2/Vtb_cl_argon2__pch.h.slow
	@$(MAKE) -s -C $(OBJ)/tb_cl_argon2 -f Vtb_cl_argon2.mk CFG_CXXFLAGS_PCH_I=-include CXXFLAGS="$(VCXXFLAGS)"
	./$(OBJ)/tb_cl_argon2/tb_cl_argon2
else
tb_cl_argon2.out: tb_cl_argon2.sv
	$(IVERILOG) -g2012 -PN_P=$(NP) -I$(INCDIR) -I$(F1DES) -o $@ $< $(SRC_tb_cl_argon2)
endif

clean:
	rm -f *.out *.vcd
	rm -rf $(GEN) $(OBJ)
