"""BLAKE2b as specified in RFC 7693.

This is the hash used by Argon2 for H / H' (initial digest and tag).
The Argon2 *compression* function G is *not* BLAKE2b — it is BlaMka,
implemented in argon2.py.
"""

from __future__ import annotations

MASK64 = (1 << 64) - 1

IV = (
    0x6A09E667F3BCC908,
    0xBB67AE8584CAA73B,
    0x3C6EF372FE94F82B,
    0xA54FF53A5F1D36F1,
    0x510E527FADE682D1,
    0x9B05688C2B3E6C1F,
    0x1F83D9ABFB41BD6B,
    0x5BE0CD19137E2179,
)

# RFC 7693 SIGMA[0..9]; rounds 10 and 11 reuse 0 and 1.
SIGMA = (
    (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15),
    (14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3),
    (11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4),
    (7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8),
    (9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13),
    (2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9),
    (12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11),
    (13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10),
    (6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5),
    (10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0),
)

# Column then diagonal mixing schedule (same as Argon2 P).
G_IDX = (
    (0, 4, 8, 12),
    (1, 5, 9, 13),
    (2, 6, 10, 14),
    (3, 7, 11, 15),
    (0, 5, 10, 15),
    (1, 6, 11, 12),
    (2, 7, 8, 13),
    (3, 4, 9, 14),
)


def rotr64(x: int, n: int) -> int:
    x &= MASK64
    return ((x >> n) | (x << (64 - n))) & MASK64


def blake2b_g(v: list[int], a: int, b: int, c: int, d: int, x: int, y: int) -> None:
    """One BLAKE2b G mix (no multiply — contrast with BlaMka GB)."""
    v[a] = (v[a] + v[b] + x) & MASK64
    v[d] = rotr64(v[d] ^ v[a], 32)
    v[c] = (v[c] + v[d]) & MASK64
    v[b] = rotr64(v[b] ^ v[c], 24)
    v[a] = (v[a] + v[b] + y) & MASK64
    v[d] = rotr64(v[d] ^ v[a], 16)
    v[c] = (v[c] + v[d]) & MASK64
    v[b] = rotr64(v[b] ^ v[c], 63)


def blake2b_round(v: list[int], m: list[int], r: int) -> None:
    s = SIGMA[r % 10]
    pairs = (
        (0, 1),
        (2, 3),
        (4, 5),
        (6, 7),
        (8, 9),
        (10, 11),
        (12, 13),
        (14, 15),
    )
    for (a, b, c, d), (sx, sy) in zip(G_IDX, pairs):
        blake2b_g(v, a, b, c, d, m[s[sx]], m[s[sy]])


def blake2b_compress(h: list[int], block: bytes, t0: int, t1: int, last: bool) -> None:
    """F(h, m, t, f) — RFC 7693 §3.2. Mutates h in place."""
    assert len(block) == 128
    m = [int.from_bytes(block[i : i + 8], "little") for i in range(0, 128, 8)]
    v = h[:8] + list(IV)
    v[12] ^= t0 & MASK64
    v[13] ^= t1 & MASK64
    if last:
        v[14] ^= MASK64
    for r in range(12):
        blake2b_round(v, m, r)
    for i in range(8):
        h[i] ^= v[i] ^ v[i + 8]


def _blake2b_pure(data: bytes, digest_size: int = 64, key: bytes = b"") -> bytes:
    """Pure-Python reference (slow) — kept for verification."""
    h = list(IV)
    h[0] ^= 0x01010000 ^ (len(key) << 8) ^ digest_size
    t0 = 0
    t1 = 0
    buf = (key + bytes(128 - len(key))) if key else b""
    offset = 0

    def absorb(chunk: bytes, last: bool) -> None:
        nonlocal t0, t1
        t0 = (t0 + len(chunk)) & MASK64
        if t0 < len(chunk):
            t1 = (t1 + 1) & MASK64
        blake2b_compress(h, chunk + bytes(128 - len(chunk)), t0, t1, last)

    while offset < len(data):
        take = 128 - len(buf)
        buf += data[offset : offset + take]
        offset += take
        if offset < len(data) and len(buf) == 128:
            absorb(buf, last=False)
            buf = b""

    absorb(buf, last=True)
    out = b"".join(word.to_bytes(8, "little") for word in h)
    return out[:digest_size]


def blake2b(data: bytes, digest_size: int = 64, key: bytes = b"") -> bytes:
    """Keyed or unkeyed BLAKE2b. Fast path via hashlib, fallback to pure."""
    if not 1 <= digest_size <= 64:
        raise ValueError("digest_size must be in 1..64")
    if len(key) > 64:
        raise ValueError("key longer than 64 bytes")
    try:
        import hashlib

        if key:
            return hashlib.blake2b(data, digest_size=digest_size, key=key).digest()
        return hashlib.blake2b(data, digest_size=digest_size).digest()
    except Exception:
        return _blake2b_pure(data, digest_size=digest_size, key=key)
