"""Print / write hex vectors for the Icarus / Verilator self-checks."""

from __future__ import annotations

import pathlib
import sys

from ref.argon2 import (
    Type,
    argon2_fill,
    argon2_init_memory,
    blamka_g,
    compress_g,
    make_address_input,
    next_addresses,
)
from ref.blake2b import IV, MASK64, blake2b_g

GEN = pathlib.Path(__file__).resolve().parents[1] / "sim" / "gen"


def _beat_hex(words: list[int]) -> str:
    """512-bit beat, word 0 in [63:0] — matches the RTL streaming ports."""
    val = 0
    for i, w in enumerate(words):
        val |= (w & MASK64) << (64 * i)
    return f"{val:0128x}"


def write_mem_hex(path: pathlib.Path, memory: list[list[int]]) -> None:
    lines: list[str] = []
    for blk in memory:
        for beat in range(16):
            lines.append(_beat_hex(blk[beat * 8 : beat * 8 + 8]))
    path.write_text("\n".join(lines) + "\n")


def dump_fill(type_: Type, stem: str) -> None:
    kw = dict(
        time_cost=2,
        memory_cost=8,
        parallelism=1,
        hash_len=32,
        type_=type_,
    )
    init = argon2_init_memory(b"password", b"somesalt", **kw)
    tag, final = argon2_fill(b"password", b"somesalt", **kw)
    write_mem_hex(GEN / f"{stem}_init.hex", init)
    write_mem_hex(GEN / f"{stem}_exp.hex", final)
    print(f"{stem} tag {tag.hex()}")


def main() -> None:
    v = [IV[0], IV[1], IV[2], IV[3]] + [0] * 12
    blake2b_g(v, 0, 1, 2, 3, 1, 2)
    print("blake2b_g(IV[0..3], x=1, y=2)")
    print(f"  a={v[0]:016x}  b={v[1]:016x}")
    print(f"  c={v[2]:016x}  d={v[3]:016x}")

    v = [IV[0], IV[1], IV[2], IV[3]] + [0] * 12
    blamka_g(v, 0, 1, 2, 3)
    print("blamka_g(IV[0..3])")
    print(f"  a={v[0]:016x}  b={v[1]:016x}")
    print(f"  c={v[2]:016x}  d={v[3]:016x}")

    x = list(IV) * 16
    out = compress_g(x, [0] * 128)
    print("G(IV*16, 0)")
    print(f"  [0]={out[0]:016x}  [7]={out[7]:016x}  [127]={out[127]:016x}")

    z = make_address_input(0, 0, 0, 32, 3, Type.I)
    addr = next_addresses(z)
    print("next_addresses(p0 l0 s0 m32 t3 i)")
    print(f"  [0]={addr[0]:016x}  [2]={addr[2]:016x}  [127]={addr[127]:016x}")

    GEN.mkdir(parents=True, exist_ok=True)
    dump_fill(Type.I, "fill_i")
    dump_fill(Type.D, "fill_d")
    dump_fill(Type.ID, "fill_id")
    print(f"wrote hex under {GEN}", file=sys.stderr)


if __name__ == "__main__":
    main()
