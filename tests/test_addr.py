"""Argon2i address generation (RFC 9106 §3.4.1 / PHC next_addresses)."""

from __future__ import annotations

import unittest

from ref.argon2 import (
    Type,
    compress_g,
    data_independent,
    make_address_input,
    next_addresses,
)


# First window for Z = (pass=0, lane=0, slice=0, m'=32, t=3, y=i).
# Locked against ref.argon2.next_addresses; the RTL bench uses the same hex.
ADDR0 = (
    0xD66F57259D654B1B,
    0x1D231F478579DCD0,
    0x61C8E2257A13CB42,
    0x3B761DCB112634DC,
)
ADDR0_LAST = 0x9E16E7ACCFC9E85D
G1_0 = 0xC4B7EEF8A26F6A57


class DataIndependent(unittest.TestCase):
    def test_variants(self) -> None:
        self.assertTrue(data_independent(Type.I, 0, 0))
        self.assertTrue(data_independent(Type.I, 9, 3))
        self.assertFalse(data_independent(Type.D, 0, 0))
        self.assertTrue(data_independent(Type.ID, 0, 0))
        self.assertTrue(data_independent(Type.ID, 0, 1))
        self.assertFalse(data_independent(Type.ID, 0, 2))
        self.assertFalse(data_independent(Type.ID, 1, 0))


class NextAddresses(unittest.TestCase):
    def _z(self, **kw) -> list[int]:
        params = dict(
            pass_=0, lane=0, slice_=0, memory_blocks=32, time_cost=3, type_=Type.I
        )
        params.update(kw)
        return make_address_input(**params)

    def test_counter_starts_at_one(self) -> None:
        z = self._z()
        self.assertEqual(z[6], 0)
        next_addresses(z)
        self.assertEqual(z[6], 1)
        next_addresses(z)
        self.assertEqual(z[6], 2)

    def test_first_window_locked(self) -> None:
        z = self._z()
        addr = next_addresses(z)
        self.assertEqual(len(addr), 128)
        self.assertEqual(tuple(addr[:4]), ADDR0)
        self.assertEqual(addr[127], ADDR0_LAST)

    def test_matches_double_g(self) -> None:
        z = self._z()
        got = next_addresses(z)
        # Reconstruct: G(0, Z||1) then G(0, that).
        inp = self._z()
        inp[6] = 1
        g1 = compress_g([0] * 128, inp)
        self.assertEqual(g1[0], G1_0)
        self.assertEqual(compress_g([0] * 128, g1), got)

    def test_slice_changes_output(self) -> None:
        a0 = next_addresses(self._z(slice_=0))
        a1 = next_addresses(self._z(slice_=1))
        self.assertNotEqual(a0, a1)

    def test_pass0_slice0_uses_index_two(self) -> None:
        # Fill starts at i=2 on the first segment; that word must be defined.
        addr = next_addresses(self._z())
        self.assertEqual(addr[2], 0x61C8E2257A13CB42)


class HexDumpRoundtrip(unittest.TestCase):
    def test_fill_hex_matches_workspace(self) -> None:
        from tests.dump_vectors import _beat_hex

        from ref.argon2 import argon2_fill

        tag, mem = argon2_fill(
            b"password",
            b"somesalt",
            time_cost=2,
            memory_cost=8,
            parallelism=1,
            hash_len=32,
            type_=Type.I,
        )
        self.assertEqual(
            tag.hex(),
            "48cc13c16c5a2d254a278e2c44420ba0fb2d0f070661e35d6486604a7a2ff1a9",
        )
        # 8 blocks × 16 beats; word 0 of each beat sits in bits [63:0].
        self.assertEqual(len(mem), 8)
        line = _beat_hex(mem[0][0:8])
        self.assertEqual(len(line), 128)
        rec = int(line, 16)
        self.assertEqual(rec & ((1 << 64) - 1), mem[0][0])


class SmallJobTags(unittest.TestCase):
    """p=1 / m=8 / t=2 — the RTL fill bench's known-answer job."""

    PARAMS = dict(
        time_cost=2,
        memory_cost=8,
        parallelism=1,
        hash_len=32,
    )

    def test_argon2i(self) -> None:
        from ref.argon2 import argon2i

        self.assertEqual(
            argon2i(b"password", b"somesalt", **self.PARAMS),
            bytes.fromhex(
                "48cc13c16c5a2d254a278e2c44420ba0"
                "fb2d0f070661e35d6486604a7a2ff1a9"
            ),
        )

    def test_argon2d(self) -> None:
        from ref.argon2 import argon2d

        self.assertEqual(
            argon2d(b"password", b"somesalt", **self.PARAMS),
            bytes.fromhex(
                "7d124315b3ba588668393b2e2d6867bd"
                "9f211a4eebd240d0023e540a783a69f0"
            ),
        )

    def test_argon2id(self) -> None:
        from ref.argon2 import argon2id

        self.assertEqual(
            argon2id(b"password", b"somesalt", **self.PARAMS),
            bytes.fromhex(
                "fdb4ddb6d5887131b66f0b2a3740c077"
                "dd05b755845861f6b5a1dde8b1071646"
            ),
        )


if __name__ == "__main__":
    unittest.main()
