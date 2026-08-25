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


# RFC 9106 §5 — the 32 KiB / p=4 / t=3 published vector.
RFC_PASSWORD = bytes([0x01] * 32)
RFC_SALT = bytes([0x02] * 16)
RFC_KW = dict(
    time_cost=3,
    memory_cost=32,
    parallelism=4,
    hash_len=32,
    secret=bytes([0x03] * 8),
    associated_data=bytes([0x04] * 12),
)


def dump_rfc(type_: Type, stem: str) -> None:
    kw = dict(RFC_KW, type_=type_)
    init = argon2_init_memory(RFC_PASSWORD, RFC_SALT, **kw)
    tag, final = argon2_fill(RFC_PASSWORD, RFC_SALT, **kw)
    write_mem_hex(GEN / f"{stem}_init.hex", init)
    write_mem_hex(GEN / f"{stem}_exp.hex", final)
    print(f"{stem} tag {tag.hex()}")


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


def dump_sweep(m: int, t: int, type_: Type, stem: str) -> None:
    """p=1 KAT at an arbitrary geometry: m' >= 16 / t >= 1 exposes the
    early-dep reference-area and write-FIFO RAW paths that m'=8 KATs cannot
    (segment_length 2 makes both mappings coincide and short reference
    distances always clear the FIFO)."""
    kw = dict(
        time_cost=t,
        memory_cost=m,
        parallelism=1,
        hash_len=32,
        type_=type_,
    )
    init = argon2_init_memory(b"password", b"somesalt", **kw)
    tag, final = argon2_fill(b"password", b"somesalt", **kw)
    write_mem_hex(GEN / f"{stem}_init.hex", init)
    write_mem_hex(GEN / f"{stem}_exp.hex", final)
    print(f"{stem} tag {tag.hex()}")


def dump_multi(type_: Type, nctx: int, stem: str) -> None:
    """One init/exp pair per independent p=1 context for tb_argon2_multi_ctx.
    Each context uses a distinct password/salt so that a block misrouted by
    the shared fabric (cross-context contamination) shows up as a mismatch
    rather than passing because all contexts hold identical data."""
    for c in range(nctx):
        kw = dict(
            time_cost=2,
            memory_cost=8,
            parallelism=1,
            hash_len=32,
            type_=type_,
        )
        pwd = f"password-{c}".encode()
        salt = f"somesalt-{c}".encode()
        init = argon2_init_memory(pwd, salt, **kw)
        tag, final = argon2_fill(pwd, salt, **kw)
        write_mem_hex(GEN / f"{stem}_c{c}_init.hex", init)
        write_mem_hex(GEN / f"{stem}_c{c}_exp.hex", final)


def dump_p4(m: int, t: int, type_: Type, stem: str) -> None:
    """p=4 KAT at an arbitrary geometry for the partitioned-memory bench
    (tb_argon2_p4): four controllers + the read crossbar + four LOCAL
    memories. m' must be a multiple of 8*p (RFC 9106 s2.4); lane_length
    m'/4 need NOT be a power of two (m'=48 exercises a non-pow2 segment
    length, which the crossbar's subtract-based addressing allows)."""
    kw = dict(
        time_cost=t,
        memory_cost=m,
        parallelism=4,
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
    for tn, tt in (("i", Type.I), ("d", Type.D), ("id", Type.ID)):  # tb_argon2_multi_ctx
        dump_multi(tt, 32, f"multi_{tn}")
    dump_sweep(128, 3, Type.I, "bigfill_i")   # tb_argon2_axi_big
    dump_sweep(128, 3, Type.D, "bigfill_d")
    dump_sweep(128, 3, Type.ID, "bigfill_id")
    for m in (16, 32, 64, 128):               # tb_argon2_axi_sweep
        for tn, tt in (("i", Type.I), ("d", Type.D), ("id", Type.ID)):
            for t in (1, 2, 3):
                if t == 3 or m in (16,) or (m, tn) in ((128, "id"),):
                    dump_sweep(m, t, tt, f"sweep_{tn}_m{m}t{t}")
    # tb_argon2_p4: partitioned-memory p=4 (RFC official vector + geometries;
    # m'=48 keeps a non-power-of-two lane_length in coverage)
    for m in (64, 128):
        for tn, tt_ in (("i", Type.I), ("d", Type.D), ("id", Type.ID)):
            for t in (1, 3):
                dump_p4(m, t, tt_, f"p4sweep_{tn}_m{m}t{t}")
    dump_p4(48, 2, Type.ID, "p4sweep_id_m48t2")
    dump_rfc(Type.I, "rfc_i")
    dump_rfc(Type.D, "rfc_d")
    dump_rfc(Type.ID, "rfc_id")
    print(f"wrote hex under {GEN}", file=sys.stderr)


if __name__ == "__main__":
    main()
