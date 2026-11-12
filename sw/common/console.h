// console.h - tiny I/O library for the CPU (there is no C standard library)

#ifndef CONSOLE_H
#define CONSOLE_H

#include <stdint.h>

#define IO_CONSOLE (*(volatile uint32_t *)0x10000000)
#define IO_TOHOST  (*(volatile uint32_t *)0x10000004)
#define IO_LEDS    (*(volatile uint32_t *)0x10000008)

void putchar_(char c);
void print_str(const char *s);
void print_dec(int32_t v);
void print_hex(uint32_t v);

#endif
