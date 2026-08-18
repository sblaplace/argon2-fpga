# HDL simulation

Golden-model tests (`python3 -m unittest`) do not need a simulator.

When Icarus Verilog is installed:

```
make -C sim            # all self-checking benches
make -C sim blake2b    # blake2b G
make -C sim blamka     # BlaMka GB
make -C sim index      # index_alpha
make -C sim compress   # compression G (incl. dest-xor)
make -C sim addr       # argon2i address window
make -C sim fill       # 8 KiB p=1 fill KAT (i / d / id)
```

`make -C sim fill` first dumps hex from `ref/` into `sim/gen/`. Dump by
hand with:

```
python3 -m tests.dump_vectors
```

The fill bench uses a 12-cycle read latency so the argon2i prefetch
(random ref issued at the start of G) is actually in flight.
