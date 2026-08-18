IVERILOG ?= iverilog
VVP      ?= vvp
INCDIR   := ../rtl/include
RTL      := ../rtl
GEN      := gen

ARGON2_G := \
	$(RTL)/argon2/blamka_g.sv \
	$(RTL)/argon2/argon2_p.sv \
	$(RTL)/argon2/argon2_compress.sv

FILL_RTL := \
	$(ARGON2_G) \
	$(RTL)/argon2/argon2_index.sv \
	$(RTL)/argon2/argon2_addr_gen.sv \
	$(RTL)/argon2/argon2_fill_ctrl.sv

.PHONY: all blake2b blamka index compress addr fill vectors clean

all: blake2b blamka index compress addr fill

vectors: $(GEN)/fill_i_init.hex

$(GEN)/fill_i_init.hex: ../tests/dump_vectors.py ../ref/argon2.py
	mkdir -p $(GEN)
	cd .. && python3 -m tests.dump_vectors

blake2b: tb_blake2b_g.out
	$(VVP) $<

blamka: tb_blamka_g.out
	$(VVP) $<

index: tb_argon2_index.out
	$(VVP) $<

compress: tb_argon2_compress.out
	$(VVP) $<

addr: tb_argon2_addr_gen.out
	$(VVP) $<

fill: tb_argon2_fill.out vectors
	$(VVP) $<

tb_blake2b_g.out: tb_blake2b_g.sv $(RTL)/blake2b/blake2b_g.sv
	$(IVERILOG) -g2012 -I$(INCDIR) -o $@ $^

tb_blamka_g.out: tb_blamka_g.sv $(RTL)/argon2/blamka_g.sv
	$(IVERILOG) -g2012 -I$(INCDIR) -o $@ $^

tb_argon2_index.out: tb_argon2_index.sv $(RTL)/argon2/argon2_index.sv
	$(IVERILOG) -g2012 -I$(INCDIR) -o $@ $^

tb_argon2_compress.out: tb_argon2_compress.sv $(ARGON2_G)
	$(IVERILOG) -g2012 -I$(INCDIR) -o $@ $^

tb_argon2_addr_gen.out: tb_argon2_addr_gen.sv $(RTL)/argon2/argon2_addr_gen.sv $(ARGON2_G)
	$(IVERILOG) -g2012 -I$(INCDIR) -o $@ $^

tb_argon2_fill.out: tb_argon2_fill.sv $(FILL_RTL)
	$(IVERILOG) -g2012 -I$(INCDIR) -o $@ $^

clean:
	rm -f *.out *.vcd
	rm -rf $(GEN)
