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

.PHONY: all blake2b blamka index compress addr fill vectors clean
.SECONDARY:   # keep the built .out / model dirs between targets

all: blake2b blamka index compress addr fill

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

clean:
	rm -f *.out *.vcd
	rm -rf $(GEN) $(OBJ)
