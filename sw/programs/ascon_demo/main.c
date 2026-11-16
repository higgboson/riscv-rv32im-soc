// ascon_demo - lock, unlock and tamper with a message on the Ascon hardware, live on the Basys 3
//
// Over the USB serial link (PuTTY / Tera Term at 115200, or sw/ascon_demo.py):
//   e <text>   lock (encrypt) the text: Ascon-AEAD128 on the FPGA
//   d          unlock (decrypt) the last locked message
//   t          change one bit of the locked message on the way, then try to unlock it
//   h <text>   fingerprint (Ascon-Hash256) of the text
//
// Without a PC, the buttons do the same with a built-in message:
//   btnL lock   btnU unlock   btnD tamper and unlock   btnR fingerprint
//
// 7-segment: first 4 hex digits of the seal or fingerprint, 600d = unlocked (good),
// 0bAd = refused. LEDs: all on = unlocked, blinking = refused.
//
// The key is fixed and printed, because this is a demonstration of the hardware.
// A real device would keep its key secret and never send it anywhere.

#include "console.h"
#include "perf.h"
#include "ascon.h"

#define BTN_UP    0x1
#define BTN_LEFT  0x2
#define BTN_RIGHT 0x4
#define BTN_DOWN  0x8

#define MAX_MSG   200
#ifndef CLK_MHZ
#define CLK_MHZ   50        // CPU clock, must match fpga/basys3 (simulation builds use 1 to skip the waits)
#endif

static const uint8_t key[16] = {
    0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
    0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
};

static const char preset[] = "HELLO FROM THE BASYS 3";

// word-aligned buffers move through the peripheral as whole words, which is faster
static uint8_t msg[MAX_MSG + 1] __attribute__((aligned(4)));
static uint8_t ct[MAX_MSG] __attribute__((aligned(4)));
static uint8_t out[MAX_MSG + 1] __attribute__((aligned(4)));
static uint8_t tag[16] __attribute__((aligned(4)));
static uint8_t nonce[16] __attribute__((aligned(4)));
static uint32_t msg_len, have_locked, n_locked;

// LED blinking after a refusal runs from the main loop, so the keyboard is never ignored
static uint32_t blink_left, blink_t;

static int elapsed_ms(uint32_t since, uint32_t ms)
{
    return PERF_CYCLES - since >= ms * (CLK_MHZ * 1000u);
}

static void put_hex8(uint32_t b)
{
    putchar_("0123456789abcdef"[(b >> 4) & 0xF]);
    putchar_("0123456789abcdef"[b & 0xF]);
}

static void print_bytes(const uint8_t *p, uint32_t n)
{
    for (uint32_t i = 0; i < n; i++) {
        if (i)
            putchar_(' ');
        put_hex8(p[i]);
    }
    putchar_('\n');
}

// what someone listening on the wire would see: unprintable bytes become '.'
static void print_as_text(const uint8_t *p, uint32_t n)
{
    putchar_('"');
    for (uint32_t i = 0; i < n; i++)
        putchar_(p[i] >= 32 && p[i] < 127 ? (char)p[i] : '.');
    print_str("\"\n");
}

static void print_time(uint32_t cycles)
{
    print_dec(cycles);
    print_str(" cycles (");
    print_dec(cycles / CLK_MHZ);
    print_str(" us at 50 MHz)\n");
}

static uint32_t show_digits(const uint8_t *p)
{
    return ((uint32_t)p[0] << 8) | p[1];
}

// A nonce must never repeat under the same key. The counter changes it for every message
// and the cycle count at the moment of locking changes it again after a reset.
static void new_nonce(void)
{
    uint32_t c = PERF_CYCLES;
    n_locked++;
    for (int i = 0; i < 4; i++) {
        nonce[i]     = (uint8_t)(n_locked >> (8 * i));
        nonce[4 + i] = (uint8_t)(c >> (8 * i));
    }
    for (int i = 8; i < 16; i++)
        nonce[i] = (uint8_t)("BASYS3-A"[i - 8]);
}

static void do_lock(const uint8_t *text, uint32_t len)
{
    for (uint32_t i = 0; i < len; i++)
        msg[i] = text[i];
    msg_len = len;
    new_nonce();

    uint32_t t0 = PERF_CYCLES;
    ascon_hw_encrypt(ct, tag, msg, len, 0, 0, nonce, key);
    uint32_t t1 = PERF_CYCLES;
    have_locked = 1;

    print_str("\nLOCKED on the FPGA (Ascon-AEAD128)\n");
    print_str("  message    : ");
    print_as_text(msg, len);
    print_str("  key        : ");
    print_bytes(key, 16);
    print_str("  nonce      : ");
    print_bytes(nonce, 16);
    print_str("  ciphertext : ");
    print_bytes(ct, len);
    print_str("  as text    : ");
    print_as_text(ct, len);
    print_str("  seal (tag) : ");
    print_bytes(tag, 16);
    print_str("  hardware   : ");
    print_time(t1 - t0);

    IO_HEX = show_digits(tag);
    IO_LEDS = 0x00FF;
}

static void do_unlock(int tamper)
{
    if (!have_locked) {
        print_str("\nNothing locked yet: type  e <message>  first, or press btnL\n");
        return;
    }

    // tampering works on a copy, so the real message can still be unlocked afterwards
    static uint8_t sent[MAX_MSG] __attribute__((aligned(4)));
    for (uint32_t i = 0; i < msg_len; i++)
        sent[i] = ct[i];
    if (tamper && msg_len)
        sent[0] ^= 0x01;

    uint32_t t0 = PERF_CYCLES;
    int bad = ascon_hw_decrypt(out, sent, msg_len, tag, 0, 0, nonce, key);
    uint32_t t1 = PERF_CYCLES;

    print_str(tamper ? "\nTAMPERED: bit 0 of byte 0 flipped on the way\n" : "\nUNLOCKING on the FPGA\n");
    print_str("  received   : ");
    print_bytes(sent, msg_len);
    print_str("  hardware   : ");
    print_time(t1 - t0);

    if (!bad) {
        print_str("  message    : ");
        print_as_text(out, msg_len);
        print_str("  result     : PASS - seal intact, message unlocked\n");
        IO_HEX = 0x600D;
        IO_LEDS = 0xFFFF;
    } else {
        print_str("  result     : FAIL - seal broken, message refused (nothing released)\n");
        IO_HEX = 0x0BAD;
        IO_LEDS = 0xAAAA;
        blink_left = 7;
        blink_t = PERF_CYCLES;
    }
}

static void do_hash(const uint8_t *text, uint32_t len)
{
    static uint8_t md[32] __attribute__((aligned(4)));
    uint32_t t0 = PERF_CYCLES;
    ascon_hw_hash256(md, text, len);
    uint32_t t1 = PERF_CYCLES;

    print_str("\nFINGERPRINT on the FPGA (Ascon-Hash256)\n");
    print_str("  message    : ");
    print_as_text(text, len);
    print_str("  hash       : ");
    print_bytes(md, 32);
    print_str("  hardware   : ");
    print_time(t1 - t0);

    IO_HEX = show_digits(md);
    IO_LEDS = 0x0F0F;
}

static void help(void)
{
    print_str("\n  e <text>   lock (encrypt) a message\n");
    print_str("  d          unlock (decrypt) the last message\n");
    print_str("  t          tamper with it on the way, then try to unlock\n");
    print_str("  h <text>   fingerprint (hash) of a message\n");
    print_str("  buttons    btnL lock   btnU unlock   btnD tamper   btnR fingerprint\n");
}

static void run_line(const uint8_t *line, uint32_t n)
{
    while (n && line[0] == ' ') {
        line++;
        n--;
    }
    if (!n)
        return;
    uint8_t cmd = line[0] | 0x20;               // accept upper or lower case
    const uint8_t *arg = line + 1;
    uint32_t alen = n - 1;
    if (alen && arg[0] == ' ') {
        arg++;
        alen--;
    }

    if (cmd == 'e' && alen)
        do_lock(arg, alen);
    else if (cmd == 'd' && !alen)
        do_unlock(0);
    else if (cmd == 't' && !alen)
        do_unlock(1);
    else if (cmd == 'h')
        do_hash(arg, alen);
    else
        help();
}

int main(void)
{
    static uint8_t line[MAX_MSG + 2];
    uint32_t n = 0, last_buttons = 0, btn_t = 0;

    print_str("\n=======================================================\n");
    print_str(" Ascon (NIST SP 800-232) hardware on the RV32IM RISC-V\n");
    print_str(" Basys 3 demo: lock, unlock, tamper, fingerprint\n");
    print_str("=======================================================\n");
    help();
    print_str("READY\n> ");
    IO_HEX = 0xA5C0;

    for (;;) {
        int c = getchar_nb();
        if (c >= 0) {
            if (c == '\r' || c == '\n') {
                blink_left = 0;
                run_line(line, n);
                n = 0;
                print_str("READY\n> ");
            } else if ((c == 8 || c == 127) && n) {      // backspace
                n--;
                print_str("\b \b");
            } else if (c >= 32 && c < 127 && n < MAX_MSG + 1) {
                line[n++] = (uint8_t)c;
                putchar_((char)c);
            }
            continue;
        }

        if (blink_left && elapsed_ms(blink_t, 150)) {
            blink_t = PERF_CYCLES;
            IO_LEDS = --blink_left ? (blink_left & 1 ? 0x5555 : 0xAAAA) : 0;
        }

        // act on a button when it goes down, not while it is held; 20 ms after a press
        // the button is ignored while its contacts stop bouncing
        if (!elapsed_ms(btn_t, 20))
            continue;
        uint32_t b = IO_BUTTONS;
        uint32_t pressed = b & ~last_buttons;
        last_buttons = b;
        if (!pressed)
            continue;
        blink_left = 0;
        if (pressed & BTN_LEFT)
            do_lock((const uint8_t *)preset, sizeof(preset) - 1);
        else if (pressed & BTN_UP)
            do_unlock(0);
        else if (pressed & BTN_DOWN)
            do_unlock(1);
        else if (pressed & BTN_RIGHT)
            do_hash((const uint8_t *)preset, sizeof(preset) - 1);
        print_str("READY\n> ");
        btn_t = PERF_CYCLES;
    }
}
