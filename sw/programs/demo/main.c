// demo - the program built into the Basys 3 bitstream
//
// 1. prints a banner and runs the benchmark table on the real hardware (over USB-UART)
// 2. shows the measured CPI on the 7-segment display, e.g. "1.20"
// 3. then stays interactive:
//      switches 0-12 -> LEDs 0-12
//      btnU          -> run the benchmarks again
//      btnL          -> show the total cycle count (low 4 hex digits) instead of CPI
// A new program can be sent at any time with sw/load.py.

#include "console.h"
#include "report.h"

#define BTN_UP   0x1
#define BTN_LEFT 0x2

// 0..9999 -> 4 BCD digits, so the hex display shows it as a decimal number
static uint32_t to_bcd(uint32_t v)
{
    uint32_t bcd = 0;
    for (int shift = 0; shift < 16; shift += 4) {
        bcd |= (v % 10) << shift;
        v /= 10;
    }
    return bcd;
}

static perf_t total;

static void show_cpi(void)
{
    // CPI x 100 as decimal digits, dot after the first digit: 120 -> "1.20"
    IO_HEX = (0x4u << 16) | to_bcd(ratio_x100(total.cycles, total.instret));
}

static void run_all(void)
{
    IO_HEX = 0;
    print_str("\nRunning benchmarks...\n");
    int errors = run_benchmarks(&total);
    print_str(errors ? "SOME RESULTS WRONG\n" : "all results correct\n");
    show_cpi();
}

int main(void)
{
    print_str("\n================================================\n");
    print_str(" RV32IM 5-stage pipelined RISC-V CPU on Basys 3\n");
    print_str(" branch prediction, hardware performance counters\n");
    print_str("================================================\n");
    print_str("btnU: run benchmarks again   btnL: show cycles / CPI\n");
    print_str("switches 0-12 drive the LEDs\n");

    run_all();

    uint32_t last_buttons = 0;
    int show_cycles = 0;

    for (;;) {
        IO_LEDS = IO_SWITCHES & 0x1FFF;

        // act on a button when it goes down, not while it is held
        uint32_t b = IO_BUTTONS;
        uint32_t pressed = b & ~last_buttons;
        last_buttons = b;

        if (pressed & BTN_UP)
            run_all();
        if (pressed & BTN_LEFT) {
            show_cycles = !show_cycles;
            if (show_cycles)
                IO_HEX = total.cycles & 0xFFFF;
            else
                show_cpi();
        }
    }
}
