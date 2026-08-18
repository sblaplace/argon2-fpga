"""Argon2i / Argon2d / Argon2id (RFC 9106 / version 1.3).

Compression G uses BlaMka, *not* stock BLAKE2b. H / H' use BLAKE2b.
Indexing matches the PHC reference (phc-winner-argon2), which is the
unambiguous reading of RFC 9106 §3.4.
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


def compress_g(x: list[int], y: list[int], with_xor: list[int] | None = None) -> list[int]:
    """G(X, Y) = P_cols(P_rows(X ⊕ Y)) ⊕ (X ⊕ Y)  [⊕ dest if with_xor]."""
    r = [(x[i] ^ y[i]) & MASK64 for i in range(BLOCK_WORDS)]
    tmp = r[:]  # saved R, optionally XORed with destination (v1.3 later passes)

    # Rows: 8 groups of 16 consecutive 64-bit words.
    for i in range(8):
        row = r[16 * i : 16 * i + 16]
        argon2_p(row)
        r[16 * i : 16 * i + 16] = row

    # Columns: 8 groups taking the i-th 16-byte register of each row.
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
    """Variable-length hash H' (RFC 9106 §3.3)."""
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


def _words_from_bytes(buf: bytes) -> list[int]:
    return [int.from_bytes(buf[i : i + 8], "little") for i in range(0, len(buf), 8)]


def _bytes_from_words(words: list[int]) -> bytes:
    return b"".join(w.to_bytes(8, "little") for w in words)


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
    """Build the argon2i address-generator input block Z (RFC 9106 §3.4.1).

    Words: pass, lane, slice, m', t, y, counter=0, then zeros.
    """
    block = [0] * BLOCK_WORDS
    block[0] = int(pass_)
    block[1] = int(lane)
    block[2] = int(slice_)
    block[3] = int(memory_blocks)
    block[4] = int(time_cost)
    block[5] = int(type_)
    return block


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
                _fill_segment(
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
    independent = _data_independent(type_, pass_, slice_)
    input_block = make_address_input(
        pass_, lane, slice_, memory_blocks, time_cost, type_
    )
    address_block: list[int] = []

    starting = 2 if pass_ == 0 and slice_ == 0 else 0
    # PHC reference: pre-generate the first address block only for the
    # already-initialized first two blocks of pass 0 / slice 0. Every
    # subsequent refresh is `if i % 128 == 0` inside the loop (which
    # fires at i=0 of later segments, and at i=128, 256, … everywhere).
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
            memory[curr] = compress_g(memory[prev], ref)
        else:
            memory[curr] = compress_g(memory[prev], ref, with_xor=dest)

        curr += 1
        prev += 1


def argon2d(password: bytes, salt: bytes, **kw) -> bytes:
    return argon2(password, salt, type_=Type.D, **kw)


def argon2i(password: bytes, salt: bytes, **kw) -> bytes:
    return argon2(password, salt, type_=Type.I, **kw)


def argon2id(password: bytes, salt: bytes, **kw) -> bytes:
    return argon2(password, salt, type_=Type.ID, **kw)
