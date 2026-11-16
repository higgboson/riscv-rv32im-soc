# ascon_ref.py - Ascon-AEAD128 and Ascon-Hash256 (NIST SP 800-232) in plain Python
#
# Used by ascon_demo.py to check, on the PC, every answer the board gives. It is written
# from the standard, separately from the hardware, so the two can only agree if both are
# right. Run it on its own to test it against the official known-answer files:
#   python sw/ascon_ref.py path/to/ascon-hw/kat

MASK = (1 << 64) - 1
ROUND_CONST = [0xF0, 0xE1, 0xD2, 0xC3, 0xB4, 0xA5, 0x96, 0x87, 0x78, 0x69, 0x5A, 0x4B]

IV_AEAD128 = 0x00001000808C0001
IV_HASH256 = 0x0000080100CC0002


def _ror(x, n):
    return ((x >> n) | (x << (64 - n))) & MASK


def _perm(s, rounds):
    # p12 uses all 12 constants, p8 the last 8
    for c in ROUND_CONST[12 - rounds:]:
        s[2] ^= c
        # substitution layer: the 5-bit S-box applied to every bit column
        s[0] ^= s[4]; s[4] ^= s[3]; s[2] ^= s[1]
        t = [(~s[i] & MASK) & s[(i + 1) % 5] for i in range(5)]
        for i in range(5):
            s[i] ^= t[(i + 1) % 5]
        s[1] ^= s[0]; s[0] ^= s[4]; s[3] ^= s[2]; s[2] = ~s[2] & MASK
        # linear diffusion layer
        s[0] ^= _ror(s[0], 19) ^ _ror(s[0], 28)
        s[1] ^= _ror(s[1], 61) ^ _ror(s[1], 39)
        s[2] ^= _ror(s[2], 1) ^ _ror(s[2], 6)
        s[3] ^= _ror(s[3], 10) ^ _ror(s[3], 17)
        s[4] ^= _ror(s[4], 7) ^ _ror(s[4], 41)


def _word(b):
    """up to 8 bytes -> 64-bit word, first byte in the lowest bits (little-endian)"""
    return int.from_bytes(b, 'little')


def _bytes(w, n=8):
    return (w & MASK).to_bytes(8, 'little')[:n]


def _pad_blocks(data, rate):
    """split into rate-byte blocks; the last one is padded with 0x01 then zeros"""
    out = [data[i:i + rate] for i in range(0, len(data) - len(data) % rate, rate)]
    tail = data[len(data) - len(data) % rate:]
    out.append(tail + b'\x01' + bytes(rate - len(tail) - 1))
    return out


def _aead_init(key, nonce):
    k0, k1 = _word(key[:8]), _word(key[8:])
    s = [IV_AEAD128, k0, k1, _word(nonce[:8]), _word(nonce[8:])]
    _perm(s, 12)
    s[3] ^= k0; s[4] ^= k1
    return s, k0, k1


def _aead_ad(s, ad):
    if ad:
        for blk in _pad_blocks(ad, 16):
            s[0] ^= _word(blk[:8]); s[1] ^= _word(blk[8:])
            _perm(s, 8)
    s[4] ^= 1 << 63          # domain separation: associated data done


def _aead_final(s, k0, k1):
    s[2] ^= k0; s[3] ^= k1
    _perm(s, 12)
    return _bytes(s[3] ^ k0) + _bytes(s[4] ^ k1)


def aead_encrypt(key, nonce, ad, msg):
    """returns (ciphertext, 16-byte tag)"""
    s, k0, k1 = _aead_init(key, nonce)
    _aead_ad(s, ad)
    ct = b''
    blocks = _pad_blocks(msg, 16)
    for i, blk in enumerate(blocks):
        s[0] ^= _word(blk[:8]); s[1] ^= _word(blk[8:])
        if i < len(blocks) - 1:
            ct += _bytes(s[0]) + _bytes(s[1])
            _perm(s, 8)
        else:
            ct += (_bytes(s[0]) + _bytes(s[1]))[:len(msg) % 16]
    return ct, _aead_final(s, k0, k1)


def aead_decrypt(key, nonce, ad, ct, tag):
    """returns the plaintext, or None if the tag does not match (message was changed)"""
    s, k0, k1 = _aead_init(key, nonce)
    _aead_ad(s, ad)
    msg = b''
    full = len(ct) - len(ct) % 16
    for i in range(0, full, 16):
        c0, c1 = _word(ct[i:i + 8]), _word(ct[i + 8:i + 16])
        msg += _bytes(s[0] ^ c0) + _bytes(s[1] ^ c1)
        s[0], s[1] = c0, c1
        _perm(s, 8)
    # last partial block: keystream XOR, then the padding goes into the state
    tail = ct[full:]
    rate = _bytes(s[0]) + _bytes(s[1])
    m = bytes(a ^ b for a, b in zip(tail, rate))
    msg += m
    blk = m + b'\x01' + bytes(15 - len(m))
    s[0] ^= _word(blk[:8]); s[1] ^= _word(blk[8:])
    if _aead_final(s, k0, k1) != tag:
        return None
    return msg


def hash256(msg):
    s = [IV_HASH256, 0, 0, 0, 0]
    _perm(s, 12)
    for blk in _pad_blocks(msg, 8):
        s[0] ^= _word(blk)
        _perm(s, 12)
    out = b''
    for i in range(4):
        out += _bytes(s[0])
        if i < 3:
            _perm(s, 12)
    return out


def _read_kat(path):
    tests, cur = [], {}
    for line in open(path):
        line = line.strip()
        if not line:
            if cur:
                tests.append(cur); cur = {}
            continue
        name, _, value = line.partition('=')
        if name.strip() != 'Count':
            cur[name.strip()] = bytes.fromhex(value.strip())
    if cur:
        tests.append(cur)
    return tests


if __name__ == '__main__':
    import os
    import sys
    kat = sys.argv[1] if len(sys.argv) > 1 else '.'
    bad = 0
    tests = _read_kat(os.path.join(kat, 'aead128.txt'))
    for t in tests:
        ct, tag = aead_encrypt(t['Key'], t['Nonce'], t['AD'], t['PT'])
        ok = ct + tag == t['CT']
        ok &= aead_decrypt(t['Key'], t['Nonce'], t['AD'], ct, tag) == t['PT']
        if t['PT'] or ct:
            bad_ct = bytearray(ct + tag); bad_ct[0] ^= 1
            ok &= aead_decrypt(t['Key'], t['Nonce'], t['AD'], bytes(bad_ct[:len(ct)]),
                               bytes(bad_ct[len(ct):])) is None
        bad += not ok
    print('AEAD128: %d tests, %d failed' % (len(tests), bad))
    hbad = 0
    htests = _read_kat(os.path.join(kat, 'hash256.txt'))
    for t in htests:
        hbad += hash256(t['Msg']) != t['MD']
    print('Hash256: %d tests, %d failed' % (len(htests), hbad))
    sys.exit(1 if bad or hbad else 0)
