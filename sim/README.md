# HDL simulation

Golden-model tests (`python3 -m unittest`) do not need a simulator.

When Icarus Verilog or Verilator is installed:

```
make -C sim blake2b
make -C sim blamka
```

`tb_blake2b_g.sv` and `tb_blamka_g.sv` are self-checking against constants
taken from `ref/`. Dump more vectors with:

```
python3 -m tests.dump_vectors
```
