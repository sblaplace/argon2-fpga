"""Print hex vectors for the Icarus / Verilator self-checks."""

from __future__ import annotations

from ref.argon2 import blamka_g
from ref.blake2b import IV, blake2b_g


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


if __name__ == "__main__":
    main()
