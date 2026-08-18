IVERILOG ?= iverilog
VVP      ?= vvp
INCDIR   := ../rtl/include

.PHONY: all blake2b blamka clean

all: blake2b blamka

blake2b: tb_blake2b_g.out
	$(VVP) $<

blamka: tb_blamka_g.out
	$(VVP) $<

tb_blake2b_g.out: tb_blake2b_g.sv ../rtl/blake2b/blake2b_g.sv
	$(IVERILOG) -g2012 -I$(INCDIR) -o $@ $^

tb_blamka_g.out: tb_blamka_g.sv ../rtl/argon2/blamka_g.sv
	$(IVERILOG) -g2012 -I$(INCDIR) -o $@ $^

clean:
	rm -f *.out *.vcd
