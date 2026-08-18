"""RFC 7693 + hashlib cross-checks for the BLAKE2b golden model."""

from __future__ import annotations

import hashlib
import unittest

from ref.blake2b import blake2b


# RFC 7693 Appendix A / commonly published BLAKE2b-512 vectors.
BLAKE2B_512_EMPTY = bytes.fromhex(
    "786a02f742015903c6c6fd852552d272912f4740e15847618a86e217f71f5419"
    "d25e1031afee585313896444934eb04b903a685b1448b755d56f701afe9be2ce"
)
BLAKE2B_512_ABC = bytes.fromhex(
    "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
    "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923"
)


class Blake2bTests(unittest.TestCase):
    def test_rfc_empty(self) -> None:
        self.assertEqual(blake2b(b""), BLAKE2B_512_EMPTY)

    def test_rfc_abc(self) -> None:
        self.assertEqual(blake2b(b"abc"), BLAKE2B_512_ABC)

    def test_matches_hashlib_unkeyed(self) -> None:
        messages = [
            b"",
            b"abc",
            b"a" * 127,
            b"a" * 128,
            b"a" * 129,
            b"The quick brown fox jumps over the lazy dog",
            bytes(range(256)),
        ]
        for msg in messages:
            for nn in (16, 32, 64):
                with self.subTest(n=len(msg), nn=nn):
                    self.assertEqual(
                        blake2b(msg, digest_size=nn),
                        hashlib.blake2b(msg, digest_size=nn).digest(),
                    )

    def test_matches_hashlib_keyed(self) -> None:
        key = b"secret-key-32-bytes-long!!!!!!!"
        msg = b"argon2-fpga keyed blake2b"
        self.assertEqual(
            blake2b(msg, digest_size=64, key=key),
            hashlib.blake2b(msg, digest_size=64, key=key).digest(),
        )


if __name__ == "__main__":
    unittest.main()
