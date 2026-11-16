// ascon - Ascon-AEAD128 and Ascon-Hash256 on the CPU alone vs. with the Ascon peripheral
//
// 1. Known-answer tests: one official NIST SP 800-232 vector for the cipher and one for
//    the hash, through the hardware.
// 2. A 1024-byte message is encrypted and hashed twice, in software and by the hardware.
//    The results must match exactly; the hardware counters measure each run.
// 3. The hardware decrypts its own output (must give the message back), then the same
//    ciphertext with one bit flipped (must be rejected).
// On the board the encryption speedup is also shown on the 7-segment display.

#include "console.h"
#include "perf.h"
#include "ascon.h"
#include "ascon-c/aead/crypto_aead.h"
#include "ascon-c/hash/crypto_hash.h"

#define MLEN  1024
#define ADLEN 32

// uint32_t arrays so the buffers are word-aligned (the driver's fast path)
static uint32_t msg_w[MLEN / 4], ct_hw_w[MLEN / 4], back_w[MLEN / 4];
static uint8_t  ct_sw[MLEN + 16];           // software output: ciphertext then tag
static uint8_t  ad[ADLEN], key[16], nonce[16];
static uint8_t  tag_hw[16], hash_sw[32], hash_hw[32];

#define msg   ((uint8_t *)msg_w)
#define ct_hw ((uint8_t *)ct_hw_w)
#define back  ((uint8_t *)back_w)

// official test vectors: kat/aead128.txt Count = 678, kat/hash256.txt Count = 21
static const uint8_t kat_ct[36] = {
    0xBF, 0x77, 0xC7, 0x1B, 0x3D, 0xE9, 0xF1, 0xC5, 0xB3, 0x72, 0xEF, 0x27, 0x3A, 0x08, 0xE8, 0x9B,
    0xE9, 0x67, 0x5A, 0xDC, 0x83, 0xB8, 0x8C, 0x00, 0xA0, 0x56, 0x5A, 0xB4, 0x3E, 0xA1, 0xC8, 0x35,
    0x8C, 0x56, 0xB8, 0xA9 };
static const uint8_t kat_md[32] = {
    0x98, 0x94, 0x1E, 0x48, 0x4F, 0xBA, 0xE8, 0x74, 0x52, 0xDD, 0xAF, 0x60, 0x30, 0x08, 0x8B, 0x79,
    0x8A, 0x56, 0xC3, 0x6E, 0xB6, 0xD4, 0xD3, 0xE9, 0x4B, 0x5C, 0xFF, 0x78, 0xB2, 0x0E, 0x04, 0x81 };

static int differ(const uint8_t *a, const uint8_t *b, uint32_t n)
{
    uint8_t d = 0;
    for (uint32_t i = 0; i < n; i++)
        d |= a[i] ^ b[i];
    return d != 0;
}

static int check(const char *what, int failed)
{
    print_str(what);
    print_str(failed ? "FAIL\n" : "ok\n");
    return failed;
}

// 0..9999 -> 4 BCD digits, so the hex display shows a decimal number
static uint32_t to_bcd(uint32_t v)
{
    uint32_t bcd = 0;
    for (int shift = 0; shift < 16; shift += 4) {
        bcd |= (v % 10) << shift;
        v /= 10;
    }
    return bcd;
}

// prints the two cycle counts and returns the speedup x10
static uint32_t report(const char *what, uint32_t sw, uint32_t hw)
{
    uint32_t x10 = (sw * 10 + hw / 2) / hw;
    print_str(what);
    print_str("software ");
    print_dec(sw);
    print_str(" cycles, hardware ");
    print_dec(hw);
    print_str(" cycles: ");
    print_dec(x10 / 10);
    putchar_('.');
    putchar_('0' + x10 % 10);
    print_str("x\n");
    return x10;
}

int main(void)
{
    unsigned long long len;
    uint32_t t0, sw, hw, x10;
    int errors = 0;

    for (int i = 0; i < 16; i++) {
        key[i]   = i;
        nonce[i] = 0x10 + i;
    }

    // 1. known answers (the vectors use counting bytes as data)
    for (int i = 0; i < 20; i++) msg[i] = 0x20 + i;
    for (int i = 0; i < 17; i++) ad[i]  = 0x30 + i;
    ascon_hw_encrypt(ct_hw, tag_hw, msg, 20, ad, 17, nonce, key);
    errors += check("NIST vector, AEAD128 : ",
                    differ(ct_hw, kat_ct, 20) | differ(tag_hw, kat_ct + 20, 16));
    for (int i = 0; i < 20; i++) msg[i] = i;
    ascon_hw_hash256(hash_hw, msg, 20);
    errors += check("NIST vector, Hash256 : ", differ(hash_hw, kat_md, 32));

    // 2. software against hardware
    uint32_t lcg = 12345;
    for (int i = 0; i < MLEN; i++) {
        lcg = lcg * 1103515245u + 12345u;
        msg[i] = lcg >> 16;
    }
    for (int i = 0; i < ADLEN; i++) ad[i] = 0xA0 + i;

    t0 = PERF_CYCLES;
    crypto_aead_encrypt(ct_sw, &len, msg, MLEN, ad, ADLEN, 0, nonce, key);
    sw = PERF_CYCLES - t0;
    t0 = PERF_CYCLES;
    ascon_hw_encrypt(ct_hw, tag_hw, msg, MLEN, ad, ADLEN, nonce, key);
    hw = PERF_CYCLES - t0;
    x10 = report("encrypt 1024 bytes   : ", sw, hw);
    errors += check("same ciphertext, tag : ",
                    differ(ct_sw, ct_hw, MLEN) | differ(ct_sw + MLEN, tag_hw, 16));

    t0 = PERF_CYCLES;
    crypto_hash(hash_sw, msg, MLEN);
    sw = PERF_CYCLES - t0;
    t0 = PERF_CYCLES;
    ascon_hw_hash256(hash_hw, msg, MLEN);
    hw = PERF_CYCLES - t0;
    report("hash 1024 bytes      : ", sw, hw);
    errors += check("same hash            : ", differ(hash_sw, hash_hw, 32));

    // 3. decrypt, then a forged message
    int r = ascon_hw_decrypt(back, ct_hw, MLEN, tag_hw, ad, ADLEN, nonce, key);
    errors += check("decrypt              : ", r != 0 || differ(back, msg, MLEN));

    ct_hw[500] ^= 0x04;
    r = ascon_hw_decrypt(back, ct_hw, MLEN, tag_hw, ad, ADLEN, nonce, key);
    uint8_t leaked = 0;
    for (int i = 0; i < MLEN; i++) leaked |= back[i];
    errors += check("1 flipped bit refused: ", r != -1 || leaked != 0);

    // display: speedup x10 as decimal with a dot before the last digit, e.g. "42.5"
    IO_HEX = (0x2u << 16) | to_bcd(x10);
    uart_flush();
    return errors;
}
