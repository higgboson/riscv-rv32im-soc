// ascon.h - driver for the Ascon peripheral (rtl/ascon_mmio.v, base 0x3000_0000)
//
//   ascon_hw_encrypt   Ascon-AEAD128: ciphertext + 16-byte tag
//   ascon_hw_decrypt   Ascon-AEAD128: plaintext, or -1 if the message was tampered with
//   ascon_hw_hash256   Ascon-Hash256: 32-byte hash
//   ascon_hw_xof128    Ascon-XOF128:  as many hash bytes as asked for
//
// Buffers can have any address. Word-aligned ones are faster: their data moves as whole
// 32-bit words instead of byte by byte (the CPU has no unaligned loads).
//
// AEAD rule, the same for every implementation: never use the same nonce twice with the
// same key. Two messages encrypted with one (key, nonce) pair reveal the XOR of their
// plaintexts, and the tags stop protecting anything.

#ifndef ASCON_H
#define ASCON_H

#include <stdint.h>

#define ASCON_BASE       0x30000000u
#define ASCON_CTRL       (*(volatile uint32_t *)(ASCON_BASE + 0x00))   // write
#define ASCON_STATUS     (*(volatile uint32_t *)(ASCON_BASE + 0x00))   // read
#define ASCON_OUT_LEN    (*(volatile uint32_t *)(ASCON_BASE + 0x04))
#define ASCON_KEY        ((volatile uint32_t *)(ASCON_BASE + 0x10))
#define ASCON_NONCE      ((volatile uint32_t *)(ASCON_BASE + 0x20))
#define ASCON_DIN        ((volatile uint32_t *)(ASCON_BASE + 0x30))
#define ASCON_DIN_CTRL   (*(volatile uint32_t *)(ASCON_BASE + 0x40))
#define ASCON_DOUT       ((volatile uint32_t *)(ASCON_BASE + 0x50))
#define ASCON_DOUT_ACK   (*(volatile uint32_t *)(ASCON_BASE + 0x60))
#define ASCON_TAG        ((volatile uint32_t *)(ASCON_BASE + 0x70))

// CTRL
#define ASCON_MODE_ENC   0u
#define ASCON_MODE_DEC   1u
#define ASCON_MODE_HASH  2u
#define ASCON_MODE_XOF   3u
#define ASCON_START      (1u << 8)
#define ASCON_RESET      (1u << 31)

// STATUS
#define ASCON_BUSY       (1u << 0)
#define ASCON_DIN_FULL   (1u << 1)
#define ASCON_DOUT_VALID (1u << 2)
#define ASCON_DONE       (1u << 3)
#define ASCON_TAG_OK     (1u << 4)

// DIN_CTRL
#define ASCON_LAST       (1u << 8)

// One 32-bit load when the pointer is known to be aligned. memcpy (not a pointer cast)
// keeps this legal C for a byte buffer; the compiler turns it into a single lw / sw.
static inline uint32_t ascon_ldw(const uint8_t *p)
{
    uint32_t x;
    __builtin_memcpy(&x, __builtin_assume_aligned(p, 4), 4);
    return x;
}

static inline void ascon_stw(uint8_t *p, uint32_t x)
{
    __builtin_memcpy(__builtin_assume_aligned(p, 4), &x, 4);
}

// n bytes (0..16) from memory into registers reg[0..], byte 0 in the low byte of reg[0]
static inline void ascon_put(volatile uint32_t *reg, const uint8_t *p, uint32_t n)
{
    if ((((uintptr_t)p | n) & 3) == 0) {
        for (uint32_t i = 0; i < n; i += 4)
            reg[i >> 2] = ascon_ldw(p + i);
    } else {
        for (uint32_t i = 0; i < n; i += 4) {
            uint32_t w = 0;
            for (uint32_t j = 0; j < 4 && i + j < n; j++)
                w |= (uint32_t)p[i + j] << (8 * j);
            reg[i >> 2] = w;
        }
    }
}

// n bytes (0..16) from registers reg[0..] into memory
static inline void ascon_get(uint8_t *p, const volatile uint32_t *reg, uint32_t n)
{
    if ((((uintptr_t)p | n) & 3) == 0) {
        for (uint32_t i = 0; i < n; i += 4)
            ascon_stw(p + i, reg[i >> 2]);
    } else {
        for (uint32_t i = 0; i < n; i += 4) {
            uint32_t w = reg[i >> 2];
            for (uint32_t j = 0; j < 4 && i + j < n; j++)
                p[i + j] = (uint8_t)(w >> (8 * j));
        }
    }
}

// Send one input beat. The previous beat may still be waiting for the core (it takes a
// beat only between permutations), and DIN must not change under it.
static inline void ascon_beat(const uint8_t *p, uint32_t n, uint32_t last)
{
    while (ASCON_STATUS & ASCON_DIN_FULL)
        ;
    ascon_put(ASCON_DIN, p, n);
    ASCON_DIN_CTRL = n | (last ? ASCON_LAST : 0);
}

static inline void ascon_start(uint32_t mode, const uint8_t *key, const uint8_t *nonce)
{
    while (ASCON_STATUS & ASCON_BUSY)
        ;
    if (key) {
        ascon_put(ASCON_KEY, key, 16);
        ascon_put(ASCON_NONCE, nonce, 16);
    }
    ASCON_CTRL = ASCON_START | mode;
}

// A whole stream that produces no output (associated data, or a message to hash), cut into
// blocks of `rate` bytes (16 or 8). The stream ends with the first beat marked last: the
// final full block if the length is a multiple of the rate, otherwise the short (maybe
// empty) rest.
static inline __attribute__((always_inline))
void ascon_absorb(const uint8_t *p, uint32_t len, uint32_t rate)
{
    if (((uintptr_t)p & 3) == 0) {
        // fast path: full blocks from a word-aligned buffer, as whole words
        while (len > rate) {
            while (ASCON_STATUS & ASCON_DIN_FULL)
                ;
            ASCON_DIN[0] = ascon_ldw(p);
            ASCON_DIN[1] = ascon_ldw(p + 4);
            if (rate == 16) {
                ASCON_DIN[2] = ascon_ldw(p + 8);
                ASCON_DIN[3] = ascon_ldw(p + 12);
            }
            ASCON_DIN_CTRL = rate;
            p   += rate;
            len -= rate;
        }
    }
    while (len > rate) {
        ascon_beat(p, rate, 0);
        p   += rate;
        len -= rate;
    }
    ascon_beat(p, len, 1);
}

// The message stream of an encryption or decryption: every beat in gives one beat out
static inline void ascon_crypt(uint8_t *out, const uint8_t *in, uint32_t len)
{
    if ((((uintptr_t)in | (uintptr_t)out) & 3) == 0 && len > 16) {
        // fast path: full blocks between word-aligned buffers, as whole words.
        // Seeing the output of a beat means the core has taken that beat, so DIN is free
        // again without asking; only the first beat has to wait for the stream before it.
        while (ASCON_STATUS & ASCON_DIN_FULL)
            ;
        do {
            ASCON_DIN[0] = ascon_ldw(in);
            ASCON_DIN[1] = ascon_ldw(in + 4);
            ASCON_DIN[2] = ascon_ldw(in + 8);
            ASCON_DIN[3] = ascon_ldw(in + 12);
            ASCON_DIN_CTRL = 16;
            while (!(ASCON_STATUS & ASCON_DOUT_VALID))
                ;
            ascon_stw(out,      ASCON_DOUT[0]);
            ascon_stw(out + 4,  ASCON_DOUT[1]);
            ascon_stw(out + 8,  ASCON_DOUT[2]);
            ascon_stw(out + 12, ASCON_DOUT[3]);
            ASCON_DOUT_ACK = 0;
            in  += 16;
            out += 16;
            len -= 16;
        } while (len > 16);
    }
    // the rest: any alignment, and the last beat (1..16 bytes, or 0 for an empty message)
    for (;;) {
        uint32_t n = len > 16 ? 16 : len;
        len -= n;
        ascon_beat(in, n, len == 0);
        while (!(ASCON_STATUS & ASCON_DOUT_VALID))
            ;
        ascon_get(out, ASCON_DOUT, n);
        ASCON_DOUT_ACK = 0;
        if (len == 0)
            break;
        in  += n;
        out += n;
    }
}

// c gets mlen bytes of ciphertext, tag gets 16 bytes. c may be the same buffer as m.
static inline void ascon_hw_encrypt(uint8_t *c, uint8_t *tag,
                                    const uint8_t *m, uint32_t mlen,
                                    const uint8_t *ad, uint32_t adlen,
                                    const uint8_t *nonce, const uint8_t *key)
{
    ascon_start(ASCON_MODE_ENC, key, nonce);
    ascon_absorb(ad, adlen, 16);
    ascon_crypt(c, m, mlen);
    while (!(ASCON_STATUS & ASCON_DONE))
        ;
    ascon_get(tag, ASCON_TAG, 16);
}

// m gets clen bytes of plaintext. Returns 0 if the tag is right. If it is not, returns -1
// and m is wiped: plaintext of a message that failed the check must never be used.
static inline int ascon_hw_decrypt(uint8_t *m,
                                   const uint8_t *c, uint32_t clen, const uint8_t *tag,
                                   const uint8_t *ad, uint32_t adlen,
                                   const uint8_t *nonce, const uint8_t *key)
{
    ascon_put(ASCON_TAG, tag, 16);
    ascon_start(ASCON_MODE_DEC, key, nonce);
    ascon_absorb(ad, adlen, 16);
    ascon_crypt(m, c, clen);
    while (!(ASCON_STATUS & ASCON_DONE))
        ;
    if (ASCON_STATUS & ASCON_TAG_OK)
        return 0;
    for (uint32_t i = 0; i < clen; i++)
        m[i] = 0;
    return -1;
}

// the output of a hash, 8 bytes per beat
static inline void ascon_squeeze(uint8_t *out, uint32_t outlen)
{
    while (outlen) {
        uint32_t n = outlen > 8 ? 8 : outlen;
        while (!(ASCON_STATUS & ASCON_DOUT_VALID))
            ;
        ascon_get(out, ASCON_DOUT, n);
        ASCON_DOUT_ACK = 0;
        out    += n;
        outlen -= n;
    }
}

static inline void ascon_hw_hash256(uint8_t *out, const uint8_t *m, uint32_t mlen)
{
    ascon_start(ASCON_MODE_HASH, 0, 0);
    ascon_absorb(m, mlen, 8);
    ascon_squeeze(out, 32);
}

static inline void ascon_hw_xof128(uint8_t *out, uint32_t outlen, const uint8_t *m, uint32_t mlen)
{
    while (ASCON_STATUS & ASCON_BUSY)
        ;
    ASCON_OUT_LEN = outlen;
    ascon_start(ASCON_MODE_XOF, 0, 0);
    ascon_absorb(m, mlen, 8);
    ascon_squeeze(out, outlen);
}

#endif
