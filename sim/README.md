# HDL simulation

Golden-model tests (`python3 -m unittest`) do not need a simulator.

Two back ends run the same sources and the same vectors:

```
make -C sim                     # Icarus Verilog (default)
make -C sim SIM=verilator       # Verilator
```

Individual benches:

```
make -C sim blake2b    # blake2b G
make -C sim blamka     # BlaMka GB
make -C sim index      # index_alpha
make -C sim compress   # compression G (incl. dest-xor)
make -C sim addr       # argon2i address window
make -C sim fill       # 8 KiB p=1 fill KAT (i / d / id)
make -C sim rfc        # RFC 9106 §5 32 KiB / p=4 fill (i / d / id)
make -C sim axi        # 8 KiB fill through the AXI4-MM adapter
```

`make -C sim fill` first dumps hex from `ref/` into `sim/gen/`. Dump by
hand with:

```
python3 -m tests.dump_vectors
```

The fill bench uses a 12-cycle read latency so the argon2i prefetch
(random ref issued at the start of G) is actually in flight.

Current status — all eight pass on both back ends:

| Bench | Checks |
|-------|--------|
| `tb_blake2b_g` | G against RFC 7693 |
| `tb_blamka_g` | GB (4-stage pipe, latency asserted) |
| `tb_argon2_index` | `index_alpha` corner cases |
| `tb_argon2_compress` | G(IV×16, 0) and the pass>0 dest-XOR path |
| `tb_argon2_addr_gen` | 128-address argon2i window in counter mode |
| `tb_argon2_fill` | t=2 / m=8 KiB / p=1 fill, argon2i + d + id |
| `tb_argon2_fill_rfc` | RFC 9106 §5: t=3 / m=32 KiB / p=4, slice barrier |
| `tb_argon2_axi` | 8 KiB fill through `argon2_fill_axi` + AXI slave |

`tb_argon2_fill` compares the whole 8 KiB working set against `ref/`
after the last pass, so it covers addressing, the prefetch path, the
empty first segment (q/4 == 2), and dest-XOR on pass 1.

## Note on the Verilator flow

Verilator's `--binary` mode drives its own make. Some packaged builds
(notably the PyPI wheel) ship a precompiled-header configuration that
does not match a stock `g++`, which fails with

```
c++: error: V<top>__pch.h.fast: linker input file not found
```

The `SIM=verilator` rules here sidestep that by generating with
`--cc --main --exe` and compiling the model with the PCH passed as a
plain `-include`. A distro Verilator (`apt install verilator`) works
with the same rules.
