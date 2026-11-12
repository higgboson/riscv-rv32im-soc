// console.c - printing over the UART, plus memset / memcpy
// (gcc may call memset / memcpy on its own, e.g. to zero a local array, even with no libc)

#include "console.h"

// the UART sends ~11,500 characters a second; wait while its FIFO is full
void putchar_(char c)
{
    if (c == '\n')
        putchar_('\r');          // terminals on Windows want CR LF
    while (IO_UART_STATUS & UART_TX_FULL)
        ;
    IO_UART_TX = (uint32_t)c;
}

int getchar_nb(void)
{
    uint32_t r = IO_UART_RX;
    if (!(r & 0x100))
        return -1;
    IO_UART_RX = 0;              // mark it as taken
    return (int)(r & 0xFF);
}

void uart_flush(void)
{
    while (IO_UART_STATUS & UART_TX_BUSY)
        ;
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
