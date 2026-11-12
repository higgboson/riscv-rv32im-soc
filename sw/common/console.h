// console.h - tiny I/O library for the CPU (there is no C standard library)

#ifndef CONSOLE_H
#define CONSOLE_H

#include <stdint.h>

#define IO_UART_TX     (*(volatile uint32_t *)0x10000000)
#define IO_TOHOST      (*(volatile uint32_t *)0x10000004)
#define IO_LEDS        (*(volatile uint32_t *)0x10000008)
#define IO_UART_STATUS (*(volatile uint32_t *)0x1000000C)
#define IO_HEX         (*(volatile uint32_t *)0x10000024)
#define IO_SWITCHES    (*(volatile uint32_t *)0x10000028)
#define IO_BUTTONS     (*(volatile uint32_t *)0x1000002C)
#define IO_UART_RX     (*(volatile uint32_t *)0x10000030)

#define UART_TX_FULL   0x1
#define UART_TX_BUSY   0x2
#define UART_RX_READY  0x4

void putchar_(char c);
void print_str(const char *s);
void print_dec(int32_t v);
void print_hex(uint32_t v);
int  getchar_nb(void);        // next received character, or -1 if none
void uart_flush(void);        // wait until everything has been sent

#endif
