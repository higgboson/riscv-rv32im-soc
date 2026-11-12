// console.c - printing through the CONSOLE I/O register, plus memset / memcpy
// (gcc may call memset / memcpy on its own, e.g. to zero a local array, even with no libc)

#include "console.h"

void putchar_(char c)
{
    IO_CONSOLE = (uint32_t)c;
}

void print_str(const char *s)
{
    while (*s)
        putchar_(*s++);
}

void print_dec(int32_t v)
{
    char buf[12];
    int i = 0;
    // work with unsigned so -2147483648 does not overflow when negated
    uint32_t u = (v < 0) ? -(uint32_t)v : (uint32_t)v;

    if (v < 0)
        putchar_('-');
    do {
        buf[i++] = '0' + (u % 10);   // compiles to the hardware remu / divu
        u /= 10;
    } while (u);
    while (i)
        putchar_(buf[--i]);
}

void print_hex(uint32_t v)
{
    print_str("0x");
    for (int s = 28; s >= 0; s -= 4)
        putchar_("0123456789abcdef"[(v >> s) & 0xF]);
}

void *memset(void *dst, int c, unsigned n)
{
    unsigned char *d = dst;
    while (n--)
        *d++ = (unsigned char)c;
    return dst;
}

void *memcpy(void *dst, const void *src, unsigned n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--)
        *d++ = *s++;
    return dst;
}
