# Self-checking benches. Two back ends:
#
#   make            # Icarus Verilog (iverilog + vvp)
#   make SIM=verilator
#
# Both run the same .sv sources and the same vectors dumped from ref/.

SIM      ?= iverilog

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
SRC_tb_argon2_fill_rfc  := $(FILL_RTL) $(RTL)/argon2/argon2_fill_job.sv
SRC_tb_argon2_axi       := $(FILL_RTL) \
	$(RTL)/argon2/argon2_axi_mm.sv \
	$(RTL)/argon2/argon2_fill_axi.sv \
	tb_axi_ram.sv

# ---- F1 CL top-level bench ------------------------------------------------
F1DES := ../fpga/f1/design

SRC_tb_cl_argon2 := \
	$(RTL)/blake2b/blake2b_g.sv $(RTL)/blake2b/blake2b_round.sv \
	$(RTL)/blake2b/blake2b_compress.sv $(RTL)/blake2b/blake2b_core.sv \
	$(RTL)/argon2/blamka_g.sv $(RTL)/argon2/argon2_p.sv $(RTL)/argon2/argon2_compress.sv \
	$(RTL)/argon2/argon2_index.sv $(RTL)/argon2/argon2_ref_area.sv \
	$(RTL)/argon2/argon2_addr_gen.sv $(RTL)/argon2/argon2_fill_ctrl.sv \
	$(RTL)/argon2/argon2_fill_job.sv $(RTL)/argon2/argon2_axi_mm.sv $(RTL)/argon2/argon2_fill_axi.sv \
	$(F1DES)/cl_argon2_axi_if.sv $(F1DES)/cl_argon2_ocl.sv \
	$(F1DES)/cl_argon2_core.sv $(F1DES)/cl_argon2_ddr_connect.sv $(F1DES)/cl_argon2.sv \
	tb_axi_ram.sv

.PHONY: all blake2b blamka index compress addr fill rfc axi cl vectors clean
.SECONDARY:   # keep the built .out / model dirs between targets

all: blake2b blamka index compress addr fill rfc axi

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
rfc:     vectors run-tb_argon2_fill_rfc
axi:     vectors run-tb_argon2_axi

ifeq ($(SIM),verilator)

# Verilator's --binary drives its own make; the wheel-packaged builds ship a
# precompiled-header config that does not match a stock g++, so compile the
# generated model here with PCH used as a plain -include.
VFLAGS := --timing -Wno-WIDTH -Wno-fatal -I$(INCDIR)
VCXXFLAGS := -Os --std=c++20 -fcoroutines -DVL_TIME_CONTEXT

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
	$(IVERILOG) -g2012 -I$(INCDIR) -o $@ $< $(SRC_$*)

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
	$(IVERILOG) -g2012 -I$(INCDIR) -I$(F1DES) -o $@ $< $(SRC_tb_cl_argon2)
endif

clean:
	rm -f *.out *.vcd
	rm -rf $(GEN) $(OBJ)
