"""Argon2i / Argon2d / Argon2id (RFC 9106 / version 1.3).

Compression G uses BlaMka, *not* stock BLAKE2b. H / H' use BLAKE2b.
Indexing matches the PHC reference (phc-winner-argon2), which is the
unambiguous reading of RFC 9106 §3.4.

This module now has two layers:
- Pure-Python reference (slow, always correct)
- Optional fast path via hashlib (for BLAKE2b) and numba+numpy (for G and fill)

The fast path is used automatically when those packages are available;
otherwise the pure implementation is used. Tests compare both.
"""

from __future__ import annotations

from enum import IntEnum

from .blake2b import blake2b, rotr64, MASK64

SYNC_POINTS = 4
BLOCK_BYTES = 1024
BLOCK_WORDS = 128
ADDRESSES_PER_BLOCK = 128
VERSION_13 = 0x13


class Type(IntEnum):
    D = 0
    I = 1
    ID = 2


# ---------------------------------------------------------------------------
# Pure-Python reference (slow)
# ---------------------------------------------------------------------------

def _fbla(a: int, b: int) -> int:
    """a + b + 2 * trunc32(a) * trunc32(b)  (mod 2^64)."""
    return (a + b + (((a & 0xFFFFFFFF) * (b & 0xFFFFFFFF)) << 1)) & MASK64


def blamka_g(v: list[int], a: int, b: int, c: int, d: int) -> None:
    """GB — the only difference from BLAKE2b G is the 32x32 multiply."""
    v[a] = _fbla(v[a], v[b])
    v[d] = rotr64(v[d] ^ v[a], 32)
    v[c] = _fbla(v[c], v[d])
    v[b] = rotr64(v[b] ^ v[c], 24)
    v[a] = _fbla(v[a], v[b])
    v[d] = rotr64(v[d] ^ v[a], 16)
    v[c] = _fbla(v[c], v[d])
    v[b] = rotr64(v[b] ^ v[c], 63)


def argon2_p(v: list[int]) -> None:
    """Permutation P: one BLAKE2b-style round of eight BlaMka GBs."""
    blamka_g(v, 0, 4, 8, 12)
    blamka_g(v, 1, 5, 9, 13)
    blamka_g(v, 2, 6, 10, 14)
    blamka_g(v, 3, 7, 11, 15)
    blamka_g(v, 0, 5, 10, 15)
    blamka_g(v, 1, 6, 11, 12)
    blamka_g(v, 2, 7, 8, 13)
    blamka_g(v, 3, 4, 9, 14)


def _compress_g_pure(x: list[int], y: list[int], with_xor: list[int] | None = None) -> list[int]:
    """G(X, Y) = P_cols(P_rows(X ⊕ Y)) ⊕ (X ⊕ Y)  [⊕ dest if with_xor]. Pure."""
    r = [(x[i] ^ y[i]) & MASK64 for i in range(BLOCK_WORDS)]
    tmp = r[:]

    for i in range(8):
        row = r[16 * i : 16 * i + 16]
        argon2_p(row)
        r[16 * i : 16 * i + 16] = row

    for i in range(8):
        col = [
            r[2 * i],
            r[2 * i + 1],
            r[2 * i + 16],
            r[2 * i + 17],
            r[2 * i + 32],
            r[2 * i + 33],
            r[2 * i + 48],
            r[2 * i + 49],
            r[2 * i + 64],
            r[2 * i + 65],
            r[2 * i + 80],
            r[2 * i + 81],
            r[2 * i + 96],
            r[2 * i + 97],
            r[2 * i + 112],
            r[2 * i + 113],
        ]
        argon2_p(col)
        (
            r[2 * i],
            r[2 * i + 1],
            r[2 * i + 16],
            r[2 * i + 17],
            r[2 * i + 32],
            r[2 * i + 33],
            r[2 * i + 48],
            r[2 * i + 49],
            r[2 * i + 64],
            r[2 * i + 65],
            r[2 * i + 80],
            r[2 * i + 81],
            r[2 * i + 96],
            r[2 * i + 97],
            r[2 * i + 112],
            r[2 * i + 113],
        ) = col

    if with_xor is not None:
        return [(r[i] ^ tmp[i] ^ with_xor[i]) & MASK64 for i in range(BLOCK_WORDS)]
    return [(r[i] ^ tmp[i]) & MASK64 for i in range(BLOCK_WORDS)]


def _le32(n: int) -> bytes:
    return int(n).to_bytes(4, "little")


def h_prime(data: bytes, out_len: int) -> bytes:
    """Variable-length hash H' (RFC 9106 §3.3). Uses fast blake2b via hashlib."""
    if out_len <= 64:
        return blake2b(_le32(out_len) + data, digest_size=out_len)
    r = ((out_len + 31) // 32) - 2
    v = blake2b(_le32(out_len) + data, digest_size=64)
    out = bytearray(v[:32])
    for _ in range(r - 1):
        v = blake2b(v, digest_size=64)
        out.extend(v[:32])
    last_len = out_len - 32 * r
    out.extend(blake2b(v, digest_size=last_len))
    return bytes(out)


def _words_from_bytes_pure(buf: bytes) -> list[int]:
    return [int.from_bytes(buf[i : i + 8], "little") for i in range(0, len(buf), 8)]


def _bytes_from_words_pure(words: list[int]) -> bytes:
    return b"".join(w.to_bytes(8, "little") for w in words)


# Fast helpers using numpy when available
try:
    import numpy as _np

    _HAS_NUMPY = True
except Exception:
    _np = None  # type: ignore
    _HAS_NUMPY = False


def _words_from_bytes(buf: bytes) -> list[int]:
    if _HAS_NUMPY:
        try:
            return _np.frombuffer(buf, dtype=_np.dtype("<u8")).tolist()
        except Exception:
            pass
    return _words_from_bytes_pure(buf)


def _bytes_from_words(words: list[int]) -> bytes:
    if _HAS_NUMPY:
        try:
            # words may be list or numpy array
            if isinstance(words, _np.ndarray):
                # ensure little endian
                return words.astype(_np.dtype("<u8"), copy=False).tobytes()
            return _np.array(words, dtype=_np.dtype("<u8")).tobytes()
        except Exception:
            pass
    return _bytes_from_words_pure(words)


def index_alpha(
    pass_: int,
    slice_: int,
    index: int,
    lane_length: int,
    segment_length: int,
    pseudo_rand_lo: int,
    same_lane: bool,
) -> int:
    """Map J1 onto a reference column. PHC reference `index_alpha`."""
    if pass_ == 0:
        if slice_ == 0:
            ref_area = index - 1
        elif same_lane:
            ref_area = slice_ * segment_length + index - 1
        else:
            ref_area = slice_ * segment_length + (-1 if index == 0 else 0)
    elif same_lane:
        ref_area = lane_length - segment_length + index - 1
    else:
        ref_area = lane_length - segment_length + (-1 if index == 0 else 0)

    rel = (pseudo_rand_lo * pseudo_rand_lo) >> 32
    rel = ref_area - 1 - ((ref_area * rel) >> 32)

    if pass_ == 0:
        start = 0
    else:
        start = 0 if slice_ == SYNC_POINTS - 1 else (slice_ + 1) * segment_length

    return (start + rel) % lane_length


def data_independent(type_: Type, pass_: int, slice_: int) -> bool:
    """True when J1∥J2 come from G in counter mode, not from the previous block."""
    if type_ == Type.I:
        return True
    if type_ == Type.ID and pass_ == 0 and slice_ < SYNC_POINTS // 2:
        return True
    return False


def _data_independent(type_: Type, pass_: int, slice_: int) -> bool:
    return data_independent(type_, pass_, slice_)


def make_address_input(
    pass_: int,
    lane: int,
    slice_: int,
    memory_blocks: int,
    time_cost: int,
    type_: Type,
) -> list[int]:
    """Build the argon2i address-generator input block Z (RFC 9106 §3.4.1)."""
    block = [0] * BLOCK_WORDS
    block[0] = int(pass_)
    block[1] = int(lane)
    block[2] = int(slice_)
    block[3] = int(memory_blocks)
    block[4] = int(time_cost)
    block[5] = int(type_)
    return block


# ---------------------------------------------------------------------------
# Optional numba-accelerated path
# ---------------------------------------------------------------------------
try:
    import numba  # type: ignore
    import numpy as np  # type: ignore

    _HAS_NUMBA = True
except Exception:
    numba = None  # type: ignore
    np = _np  # type: ignore
    _HAS_NUMBA = False

if _HAS_NUMBA:
    @numba.njit  # type: ignore
    def _rotr64_numba(x, n):
        return (x >> np.uint64(n)) | (x << np.uint64(64 - n))

    @numba.njit  # type: ignore
    def _fbla_numba(a, b):
        return a + b + np.uint64(2) * ((a & np.uint64(0xFFFFFFFF)) * (b & np.uint64(0xFFFFFFFF)))

    @numba.njit  # type: ignore
    def _blamka_g_numba(v, a, b, c, d):
        v[a] = _fbla_numba(v[a], v[b])
        v[d] = _rotr64_numba(v[d] ^ v[a], 32)
        v[c] = _fbla_numba(v[c], v[d])
        v[b] = _rotr64_numba(v[b] ^ v[c], 24)
        v[a] = _fbla_numba(v[a], v[b])
        v[d] = _rotr64_numba(v[d] ^ v[a], 16)
        v[c] = _fbla_numba(v[c], v[d])
        v[b] = _rotr64_numba(v[b] ^ v[c], 63)

    @numba.njit  # type: ignore
    def _argon2_p_numba(v):
        _blamka_g_numba(v, 0, 4, 8, 12)
        _blamka_g_numba(v, 1, 5, 9, 13)
        _blamka_g_numba(v, 2, 6, 10, 14)
        _blamka_g_numba(v, 3, 7, 11, 15)
        _blamka_g_numba(v, 0, 5, 10, 15)
        _blamka_g_numba(v, 1, 6, 11, 12)
        _blamka_g_numba(v, 2, 7, 8, 13)
        _blamka_g_numba(v, 3, 4, 9, 14)

    @numba.njit  # type: ignore
    def _compress_g_numba_impl(x, y, dest, out, with_xor):
        tmp = np.empty(128, dtype=np.uint64)
        for i in range(128):
            r = x[i] ^ y[i]
            out[i] = r
            tmp[i] = r
        for row in range(8):
            base = row * 16
            v = np.empty(16, dtype=np.uint64)
            for kk in range(16):
                v[kk] = out[base + kk]
            _argon2_p_numba(v)
            for kk in range(16):
                out[base + kk] = v[kk]
        for col in range(8):
            v = np.empty(16, dtype=np.uint64)
            v[0] = out[2 * col]
            v[1] = out[2 * col + 1]
            v[2] = out[2 * col + 16]
            v[3] = out[2 * col + 17]
            v[4] = out[2 * col + 32]
            v[5] = out[2 * col + 33]
            v[6] = out[2 * col + 48]
            v[7] = out[2 * col + 49]
            v[8] = out[2 * col + 64]
            v[9] = out[2 * col + 65]
            v[10] = out[2 * col + 80]
            v[11] = out[2 * col + 81]
            v[12] = out[2 * col + 96]
            v[13] = out[2 * col + 97]
            v[14] = out[2 * col + 112]
            v[15] = out[2 * col + 113]
            _argon2_p_numba(v)
            out[2 * col] = v[0]
            out[2 * col + 1] = v[1]
            out[2 * col + 16] = v[2]
            out[2 * col + 17] = v[3]
            out[2 * col + 32] = v[4]
            out[2 * col + 33] = v[5]
            out[2 * col + 48] = v[6]
            out[2 * col + 49] = v[7]
            out[2 * col + 64] = v[8]
            out[2 * col + 65] = v[9]
            out[2 * col + 80] = v[10]
            out[2 * col + 81] = v[11]
            out[2 * col + 96] = v[12]
            out[2 * col + 97] = v[13]
            out[2 * col + 112] = v[14]
            out[2 * col + 113] = v[15]
        for i in range(128):
            if with_xor:
                out[i] = out[i] ^ tmp[i] ^ dest[i]
            else:
                out[i] = out[i] ^ tmp[i]

    @numba.njit  # type: ignore
    def _index_alpha_numba(pass_, slice_, index, lane_length, segment_length, pseudo_rand_lo, same_lane):
        if pass_ == 0:
            if slice_ == 0:
                ref_area = index - 1
            elif same_lane:
                ref_area = slice_ * segment_length + index - 1
            else:
                if index == 0:
                    ref_area = slice_ * segment_length - 1
                else:
                    ref_area = slice_ * segment_length
        else:
            if same_lane:
                ref_area = lane_length - segment_length + index - 1
            else:
                if index == 0:
                    ref_area = lane_length - segment_length - 1
                else:
                    ref_area = lane_length - segment_length
        rel = (pseudo_rand_lo * pseudo_rand_lo) >> np.uint64(32)
        rel = np.uint64(ref_area) - np.uint64(1) - ((np.uint64(ref_area) * rel) >> np.uint64(32))
        if pass_ == 0:
            start = np.uint64(0)
        else:
            if slice_ == 3:
                start = np.uint64(0)
            else:
                start = np.uint64((slice_ + 1) * segment_length)
        return (start + rel) % np.uint64(lane_length)

    @numba.njit  # type: ignore
    def _fill_segment_independent_numba(memory, pass_, slice_, lane, lanes, lane_length, segment_length, starting, pseudo_rands, with_xor):
        curr_base = lane * lane_length + slice_ * segment_length
        out_buf = np.empty(128, dtype=np.uint64)
        dest_buf = np.empty(128, dtype=np.uint64)
        tmp_local = np.empty(128, dtype=np.uint64)
        for i in range(starting, segment_length):
            curr = curr_base + i
            if curr % lane_length == 0:
                prev = curr + lane_length - 1
            else:
                prev = curr - 1
            pseudo_rand = pseudo_rands[i]
            if pass_ == 0 and slice_ == 0:
                ref_lane = np.uint64(lane)
            else:
                ref_lane = (pseudo_rand >> np.uint64(32)) % np.uint64(lanes)
            same_lane = ref_lane == np.uint64(lane)
            pseudo_lo = pseudo_rand & np.uint64(0xFFFFFFFF)
            ref_index = _index_alpha_numba(pass_, slice_, i, lane_length, segment_length, pseudo_lo, same_lane)
            ref = ref_lane * np.uint64(lane_length) + ref_index
            if with_xor:
                for k in range(128):
                    dest_buf[k] = memory[curr, k]
            for k in range(128):
                r = memory[prev, k] ^ memory[ref, k]
                out_buf[k] = r
                tmp_local[k] = r
            for row in range(8):
                base = row * 16
                v = np.empty(16, dtype=np.uint64)
                for kk in range(16):
                    v[kk] = out_buf[base + kk]
                _argon2_p_numba(v)
                for kk in range(16):
                    out_buf[base + kk] = v[kk]
            for col in range(8):
                v = np.empty(16, dtype=np.uint64)
                v[0] = out_buf[2 * col]
                v[1] = out_buf[2 * col + 1]
                v[2] = out_buf[2 * col + 16]
                v[3] = out_buf[2 * col + 17]
                v[4] = out_buf[2 * col + 32]
                v[5] = out_buf[2 * col + 33]
                v[6] = out_buf[2 * col + 48]
                v[7] = out_buf[2 * col + 49]
                v[8] = out_buf[2 * col + 64]
                v[9] = out_buf[2 * col + 65]
                v[10] = out_buf[2 * col + 80]
                v[11] = out_buf[2 * col + 81]
                v[12] = out_buf[2 * col + 96]
                v[13] = out_buf[2 * col + 97]
                v[14] = out_buf[2 * col + 112]
                v[15] = out_buf[2 * col + 113]
                _argon2_p_numba(v)
                out_buf[2 * col] = v[0]
                out_buf[2 * col + 1] = v[1]
                out_buf[2 * col + 16] = v[2]
                out_buf[2 * col + 17] = v[3]
                out_buf[2 * col + 32] = v[4]
                out_buf[2 * col + 33] = v[5]
                out_buf[2 * col + 48] = v[6]
                out_buf[2 * col + 49] = v[7]
                out_buf[2 * col + 64] = v[8]
                out_buf[2 * col + 65] = v[9]
                out_buf[2 * col + 80] = v[10]
                out_buf[2 * col + 81] = v[11]
                out_buf[2 * col + 96] = v[12]
                out_buf[2 * col + 97] = v[13]
                out_buf[2 * col + 112] = v[14]
                out_buf[2 * col + 113] = v[15]
            for k in range(128):
                if with_xor:
                    out_buf[k] = out_buf[k] ^ tmp_local[k] ^ dest_buf[k]
                else:
                    out_buf[k] = out_buf[k] ^ tmp_local[k]
            for k in range(128):
                memory[curr, k] = out_buf[k]

    @numba.njit  # type: ignore
    def _fill_segment_dependent_numba(memory, pass_, slice_, lane, lanes, lane_length, segment_length, starting, with_xor):
        curr_base = lane * lane_length + slice_ * segment_length
        out_buf = np.empty(128, dtype=np.uint64)
        dest_buf = np.empty(128, dtype=np.uint64)
        tmp_local = np.empty(128, dtype=np.uint64)
        for i in range(starting, segment_length):
            curr = curr_base + i
            if curr % lane_length == 0:
                prev = curr + lane_length - 1
            else:
                prev = curr - 1
            pseudo_rand = memory[prev, 0]
            if pass_ == 0 and slice_ == 0:
                ref_lane = np.uint64(lane)
            else:
                ref_lane = (pseudo_rand >> np.uint64(32)) % np.uint64(lanes)
            same_lane = ref_lane == np.uint64(lane)
            pseudo_lo = pseudo_rand & np.uint64(0xFFFFFFFF)
            ref_index = _index_alpha_numba(pass_, slice_, i, lane_length, segment_length, pseudo_lo, same_lane)
            ref = ref_lane * np.uint64(lane_length) + ref_index
            if with_xor:
                for k in range(128):
                    dest_buf[k] = memory[curr, k]
            for k in range(128):
                r = memory[prev, k] ^ memory[ref, k]
                out_buf[k] = r
                tmp_local[k] = r
            for row in range(8):
                base = row * 16
                v = np.empty(16, dtype=np.uint64)
                for kk in range(16):
                    v[kk] = out_buf[base + kk]
                _argon2_p_numba(v)
                for kk in range(16):
                    out_buf[base + kk] = v[kk]
            for col in range(8):
                v = np.empty(16, dtype=np.uint64)
                v[0] = out_buf[2 * col]
                v[1] = out_buf[2 * col + 1]
                v[2] = out_buf[2 * col + 16]
                v[3] = out_buf[2 * col + 17]
                v[4] = out_buf[2 * col + 32]
                v[5] = out_buf[2 * col + 33]
                v[6] = out_buf[2 * col + 48]
                v[7] = out_buf[2 * col + 49]
                v[8] = out_buf[2 * col + 64]
                v[9] = out_buf[2 * col + 65]
                v[10] = out_buf[2 * col + 80]
                v[11] = out_buf[2 * col + 81]
                v[12] = out_buf[2 * col + 96]
                v[13] = out_buf[2 * col + 97]
                v[14] = out_buf[2 * col + 112]
                v[15] = out_buf[2 * col + 113]
                _argon2_p_numba(v)
                out_buf[2 * col] = v[0]
                out_buf[2 * col + 1] = v[1]
                out_buf[2 * col + 16] = v[2]
                out_buf[2 * col + 17] = v[3]
                out_buf[2 * col + 32] = v[4]
                out_buf[2 * col + 33] = v[5]
                out_buf[2 * col + 48] = v[6]
                out_buf[2 * col + 49] = v[7]
                out_buf[2 * col + 64] = v[8]
                out_buf[2 * col + 65] = v[9]
                out_buf[2 * col + 80] = v[10]
                out_buf[2 * col + 81] = v[11]
                out_buf[2 * col + 96] = v[12]
                out_buf[2 * col + 97] = v[13]
                out_buf[2 * col + 112] = v[14]
                out_buf[2 * col + 113] = v[15]
            for k in range(128):
                if with_xor:
                    out_buf[k] = out_buf[k] ^ tmp_local[k] ^ dest_buf[k]
                else:
                    out_buf[k] = out_buf[k] ^ tmp_local[k]
            for k in range(128):
                memory[curr, k] = out_buf[k]

    def _compress_g_numba(x, y, with_xor=None):
        x_np = np.array(x, dtype=np.uint64)
        y_np = np.array(y, dtype=np.uint64)
        if with_xor is not None:
            dest_np = np.array(with_xor, dtype=np.uint64)
            with_flag = True
        else:
            dest_np = np.empty(128, dtype=np.uint64)
            with_flag = False
        out_np = np.empty(128, dtype=np.uint64)
        _compress_g_numba_impl(x_np, y_np, dest_np, out_np, with_flag)
        return out_np.tolist()

else:
    # no numba — placeholders
    def _compress_g_numba(x, y, with_xor=None):  # type: ignore
        raise RuntimeError("numba not available")


# Public compress_g — fast path if numba present, else pure
def compress_g(x: list[int], y: list[int], with_xor: list[int] | None = None) -> list[int]:
    if _HAS_NUMBA:
        try:
            return _compress_g_numba(x, y, with_xor)
        except Exception:
            pass
    return _compress_g_pure(x, y, with_xor)


# Keep original name for compatibility with tests that import compress_g
# and also expose pure version
compress_g_pure = _compress_g_pure


def next_addresses(input_block: list[int]) -> list[int]:
    """Increment word 6 and return G(0, G(0, input_block)) — 128× J1∥J2."""
    zero = [0] * BLOCK_WORDS
    input_block[6] = (input_block[6] + 1) & MASK64
    addr = compress_g(zero, input_block)
    return compress_g(zero, addr)


def _next_addresses(input_block: list[int]) -> list[int]:
    return next_addresses(input_block)


def _derive(
    *,
    time_cost: int,
    memory_cost: int,
    parallelism: int,
    hash_len: int,
) -> tuple[int, int, int]:
    if parallelism < 1:
        raise ValueError("parallelism must be >= 1")
    if time_cost < 1:
        raise ValueError("time_cost must be >= 1")
    if memory_cost < 8 * parallelism:
        raise ValueError("memory_cost must be >= 8 * parallelism")
    if not 4 <= hash_len <= (1 << 32) - 1:
        raise ValueError("hash_len out of range")
    lanes = parallelism
    memory_blocks = 4 * lanes * (memory_cost // (4 * lanes))
    lane_length = memory_blocks // lanes
    return memory_blocks, lane_length, lane_length // SYNC_POINTS


def argon2_h0(
    password: bytes,
    salt: bytes,
    *,
    time_cost: int,
    memory_cost: int,
    parallelism: int,
    hash_len: int,
    secret: bytes = b"",
    associated_data: bytes = b"",
    type_: Type = Type.ID,
    version: int = VERSION_13,
) -> bytes:
    """Pre-hashing digest H0 (RFC 9106 §3.2)."""
    return blake2b(
        b"".join(
            (
                _le32(parallelism),
                _le32(hash_len),
                _le32(memory_cost),
                _le32(time_cost),
                _le32(version),
                _le32(int(type_)),
                _le32(len(password)),
                password,
                _le32(len(salt)),
                salt,
                _le32(len(secret)),
                secret,
                _le32(len(associated_data)),
                associated_data,
            )
        ),
        digest_size=64,
    )


def argon2_init_memory(
    password: bytes,
    salt: bytes,
    *,
    time_cost: int = 3,
    memory_cost: int = 32,
    parallelism: int = 4,
    hash_len: int = 32,
    secret: bytes = b"",
    associated_data: bytes = b"",
    type_: Type = Type.ID,
    version: int = VERSION_13,
) -> list[list[int]]:
    """Allocate m' blocks and write B[i][0], B[i][1] = H'(H0 ∥ …)."""
    memory_blocks, lane_length, _ = _derive(
        time_cost=time_cost,
        memory_cost=memory_cost,
        parallelism=parallelism,
        hash_len=hash_len,
    )
    h0 = argon2_h0(
        password,
        salt,
        time_cost=time_cost,
        memory_cost=memory_cost,
        parallelism=parallelism,
        hash_len=hash_len,
        secret=secret,
        associated_data=associated_data,
        type_=type_,
        version=version,
    )
    memory: list[list[int]] = [[0] * BLOCK_WORDS for _ in range(memory_blocks)]
    for lane in range(parallelism):
        memory[lane * lane_length + 0] = _words_from_bytes(
            h_prime(h0 + _le32(0) + _le32(lane), BLOCK_BYTES)
        )
        memory[lane * lane_length + 1] = _words_from_bytes(
            h_prime(h0 + _le32(1) + _le32(lane), BLOCK_BYTES)
        )
    return memory


def argon2(
    password: bytes,
    salt: bytes,
    *,
    time_cost: int = 3,
    memory_cost: int = 32,
    parallelism: int = 4,
    hash_len: int = 32,
    secret: bytes = b"",
    associated_data: bytes = b"",
    type_: Type = Type.ID,
    version: int = VERSION_13,
) -> bytes:
    """Compute an Argon2 tag. memory_cost is in KiB."""
    tag, _ = argon2_fill(
        password,
        salt,
        time_cost=time_cost,
        memory_cost=memory_cost,
        parallelism=parallelism,
        hash_len=hash_len,
        secret=secret,
        associated_data=associated_data,
        type_=type_,
        version=version,
    )
    return tag


def _argon2_fill_pure(
    password: bytes,
    salt: bytes,
    *,
    time_cost: int = 3,
    memory_cost: int = 32,
    parallelism: int = 4,
    hash_len: int = 32,
    secret: bytes = b"",
    associated_data: bytes = b"",
    type_: Type = Type.ID,
    version: int = VERSION_13,
) -> tuple[bytes, list[list[int]]]:
    memory_blocks, lane_length, segment_length = _derive(
        time_cost=time_cost,
        memory_cost=memory_cost,
        parallelism=parallelism,
        hash_len=hash_len,
    )
    memory = argon2_init_memory(
        password,
        salt,
        time_cost=time_cost,
        memory_cost=memory_cost,
        parallelism=parallelism,
        hash_len=hash_len,
        secret=secret,
        associated_data=associated_data,
        type_=type_,
        version=version,
    )

    for pass_ in range(time_cost):
        for slice_ in range(SYNC_POINTS):
            for lane in range(parallelism):
                _fill_segment_pure(
                    memory,
                    pass_=pass_,
                    slice_=slice_,
                    lane=lane,
                    lanes=parallelism,
                    lane_length=lane_length,
                    segment_length=segment_length,
                    memory_blocks=memory_blocks,
                    time_cost=time_cost,
                    type_=type_,
                )

    c = [0] * BLOCK_WORDS
    for lane in range(parallelism):
        last = memory[lane * lane_length + lane_length - 1]
        for i in range(BLOCK_WORDS):
            c[i] ^= last[i]
    tag = h_prime(_bytes_from_words(c), hash_len)
    return tag, memory


def _fill_segment_pure(
    memory: list[list[int]],
    *,
    pass_: int,
    slice_: int,
    lane: int,
    lanes: int,
    lane_length: int,
    segment_length: int,
    memory_blocks: int,
    time_cost: int,
    type_: Type,
) -> None:
    independent = _data_independent(type_, pass_, slice_)
    input_block = make_address_input(
        pass_, lane, slice_, memory_blocks, time_cost, type_
    )
    address_block: list[int] = []

    starting = 2 if pass_ == 0 and slice_ == 0 else 0
    if independent and pass_ == 0 and slice_ == 0:
        address_block = _next_addresses(input_block)

    curr = lane * lane_length + slice_ * segment_length + starting
    prev = curr + lane_length - 1 if curr % lane_length == 0 else curr - 1

    for i in range(starting, segment_length):
        if curr % lane_length == 1:
            prev = curr - 1

        if independent:
            if i % ADDRESSES_PER_BLOCK == 0:
                address_block = _next_addresses(input_block)
            pseudo_rand = address_block[i % ADDRESSES_PER_BLOCK]
        else:
            pseudo_rand = memory[prev][0]

        ref_lane = (pseudo_rand >> 32) % lanes
        if pass_ == 0 and slice_ == 0:
            ref_lane = lane

        ref_index = index_alpha(
            pass_,
            slice_,
            i,
            lane_length,
            segment_length,
            pseudo_rand & 0xFFFFFFFF,
            ref_lane == lane,
        )
        ref = memory[lane_length * ref_lane + ref_index]
        dest = memory[curr]
        if pass_ == 0:
            memory[curr] = _compress_g_pure(memory[prev], ref)
        else:
            memory[curr] = _compress_g_pure(memory[prev], ref, with_xor=dest)

        curr += 1
        prev += 1


def _argon2_fill_fast(
    password: bytes,
    salt: bytes,
    *,
    time_cost: int = 3,
    memory_cost: int = 32,
    parallelism: int = 4,
    hash_len: int = 32,
    secret: bytes = b"",
    associated_data: bytes = b"",
    type_: Type = Type.ID,
    version: int = VERSION_13,
) -> tuple[bytes, list[list[int]]]:
    # Requires numpy + numba
    assert _HAS_NUMBA and _HAS_NUMPY
    memory_blocks, lane_length, segment_length = _derive(
        time_cost=time_cost,
        memory_cost=memory_cost,
        parallelism=parallelism,
        hash_len=hash_len,
    )
    # allocate numpy memory
    mem_np = np.zeros((memory_blocks, 128), dtype=np.uint64)
    h0 = argon2_h0(
        password,
        salt,
        time_cost=time_cost,
        memory_cost=memory_cost,
        parallelism=parallelism,
        hash_len=hash_len,
        secret=secret,
        associated_data=associated_data,
        type_=type_,
        version=version,
    )
    for lane in range(parallelism):
        for idx in [0, 1]:
            data = h0 + _le32(idx) + _le32(lane)
            block_bytes = h_prime(data, BLOCK_BYTES)
            words = np.frombuffer(block_bytes, dtype=np.dtype("<u8"))
            mem_np[lane * lane_length + idx] = words

    for pass_ in range(time_cost):
        for slice_ in range(SYNC_POINTS):
            for lane in range(parallelism):
                starting = 2 if pass_ == 0 and slice_ == 0 else 0
                with_xor = pass_ != 0
                independent = _data_independent(type_, pass_, slice_)
                if independent:
                    pseudo_rands = np.zeros(segment_length, dtype=np.uint64)
                    ib_list = make_address_input(pass_, lane, slice_, memory_blocks, time_cost, type_)
                    cur_block: list[int] = []
                    for i in range(segment_length):
                        if i % ADDRESSES_PER_BLOCK == 0:
                            cur_block = next_addresses(ib_list)
                        pseudo_rands[i] = cur_block[i % ADDRESSES_PER_BLOCK]
                    _fill_segment_independent_numba(
                        mem_np, pass_, slice_, lane, parallelism, lane_length, segment_length, starting, pseudo_rands, with_xor
                    )
                else:
                    _fill_segment_dependent_numba(
                        mem_np, pass_, slice_, lane, parallelism, lane_length, segment_length, starting, with_xor
                    )

    c = np.zeros(128, dtype=np.uint64)
    for lane in range(parallelism):
        last = mem_np[lane * lane_length + lane_length - 1]
        c ^= last
    tag = h_prime(c.tobytes(), hash_len)
    # convert to list of lists for API compatibility
    mem_list = [row.tolist() for row in mem_np]
    return tag, mem_list


def argon2_fill(
    password: bytes,
    salt: bytes,
    *,
    time_cost: int = 3,
    memory_cost: int = 32,
    parallelism: int = 4,
    hash_len: int = 32,
    secret: bytes = b"",
    associated_data: bytes = b"",
    type_: Type = Type.ID,
    version: int = VERSION_13,
) -> tuple[bytes, list[list[int]]]:
    """Like argon2(), but also return the m' working set after the last pass."""
    if _HAS_NUMBA and _HAS_NUMPY:
        try:
            return _argon2_fill_fast(
                password,
                salt,
                time_cost=time_cost,
                memory_cost=memory_cost,
                parallelism=parallelism,
                hash_len=hash_len,
                secret=secret,
                associated_data=associated_data,
                type_=type_,
                version=version,
            )
        except Exception:
            # fallback to pure on any error
            pass
    return _argon2_fill_pure(
        password,
        salt,
        time_cost=time_cost,
        memory_cost=memory_cost,
        parallelism=parallelism,
        hash_len=hash_len,
        secret=secret,
        associated_data=associated_data,
        type_=type_,
        version=version,
    )


def _fill_segment(
    memory: list[list[int]],
    *,
    pass_: int,
    slice_: int,
    lane: int,
    lanes: int,
    lane_length: int,
    segment_length: int,
    memory_blocks: int,
    time_cost: int,
    type_: Type,
) -> None:
    # Compatibility shim — pure version
    return _fill_segment_pure(
        memory,
        pass_=pass_,
        slice_=slice_,
        lane=lane,
        lanes=lanes,
        lane_length=lane_length,
        segment_length=segment_length,
        memory_blocks=memory_blocks,
        time_cost=time_cost,
        type_=type_,
    )


def argon2d(password: bytes, salt: bytes, **kw) -> bytes:
    return argon2(password, salt, type_=Type.D, **kw)


def argon2i(password: bytes, salt: bytes, **kw) -> bytes:
    return argon2(password, salt, type_=Type.I, **kw)


def argon2id(password: bytes, salt: bytes, **kw) -> bytes:
    return argon2(password, salt, type_=Type.ID, **kw)
