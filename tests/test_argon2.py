"""RFC 9106 §5 test vectors for Argon2d / Argon2i / Argon2id v1.3."""

from __future__ import annotations

import unittest

from ref.argon2 import Type, argon2, _le32
from ref.blake2b import blake2b as blake2b_hash


PASSWORD = bytes([0x01] * 32)
SALT = bytes([0x02] * 16)
SECRET = bytes([0x03] * 8)
AD = bytes([0x04] * 12)
PARAMS = dict(
    time_cost=3,
    memory_cost=32,
    parallelism=4,
    hash_len=32,
    secret=SECRET,
    associated_data=AD,
)

# RFC 9106 §5 — pre-hashing digest H0 and final tags.
H0_D = bytes.fromhex(
    "b8819791a0359660bb7709c85fa48f04d5d82c05c5f215ccdb885491717cf757"
    "082c28b951be381410b5fc2eb7274033b9fdc7ae672bcaac5d179097a4af3109"
)
H0_I = bytes.fromhex(
    "c46065815276a0b3e731731c902f1fd80cf776907fbb7b6a5ca72e7b56011fee"
    "ca446c86dd75b9469a5e6879dec4b72d0863fb939b982e5f397cc7d164fddaa9"
)
H0_ID = bytes.fromhex(
    "2889de487eb42ae500c0007ed9252f1069eadec40d5765b485de6dc2437a67b8"
    "546a2f0acc1a0882db8fcf74714b472e94df421a5da1112ffa11434370a1e997"
)

TAG_D = bytes.fromhex(
    "512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb"
)
TAG_I = bytes.fromhex(
    "c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8"
)
TAG_ID = bytes.fromhex(
    "0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659"
)


def _h0(type_: Type) -> bytes:
    body = b"".join(
        (
            _le32(4),
            _le32(32),
            _le32(32),
            _le32(3),
            _le32(0x13),
            _le32(int(type_)),
            _le32(len(PASSWORD)),
            PASSWORD,
            _le32(len(SALT)),
            SALT,
            _le32(len(SECRET)),
            SECRET,
            _le32(len(AD)),
            AD,
        )
    )
    return blake2b_hash(body, digest_size=64)


class H0Tests(unittest.TestCase):
    def test_h0_d(self) -> None:
        self.assertEqual(_h0(Type.D), H0_D)

    def test_h0_i(self) -> None:
        self.assertEqual(_h0(Type.I), H0_I)

    def test_h0_id(self) -> None:
        self.assertEqual(_h0(Type.ID), H0_ID)


class Rfc9106Tags(unittest.TestCase):
    def test_argon2d(self) -> None:
        self.assertEqual(argon2(PASSWORD, SALT, type_=Type.D, **PARAMS), TAG_D)

    def test_argon2i(self) -> None:
        self.assertEqual(argon2(PASSWORD, SALT, type_=Type.I, **PARAMS), TAG_I)

    def test_argon2id(self) -> None:
        self.assertEqual(argon2(PASSWORD, SALT, type_=Type.ID, **PARAMS), TAG_ID)


class BlaMkaSanity(unittest.TestCase):
    def test_fbla_differs_from_add(self) -> None:
        # If we forgot the multiply, G would collapse to a BLAKE2b round.
        from ref.argon2 import _fbla

        self.assertNotEqual(_fbla(3, 5), (3 + 5) & ((1 << 64) - 1))
        self.assertEqual(_fbla(3, 5), (3 + 5 + 2 * 3 * 5) & ((1 << 64) - 1))


if __name__ == "__main__":
    unittest.main()
