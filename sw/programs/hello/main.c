// hello - first C program on the CPU
// Prints a message, then checks a few results that need the M extension
// (multiply, divide, remainder) against values worked out by hand.
// Returning 0 from main means pass (crt0.S reports it through TOHOST).

#include "console.h"

static int32_t factorial(int32_t n)
{
    int32_t r = 1;
    while (n > 1)
        r *= n--;
    return r;
}

static uint32_t gcd(uint32_t a, uint32_t b)
{
    while (b) {
        uint32_t t = a % b;
        a = b;
        b = t;
    }
    return a;
}

// volatile stops the compiler from working the answers out at compile time,
// so the CPU really executes mul / div / rem
static volatile int32_t  vn = 10;
static volatile uint32_t va = 1071, vb = 462;
static volatile int32_t  vx = -7, vy = 2;

int main(void)
{
    int errors = 0;

    print_str("Hello from the RV32IM pipeline!\n");

    int32_t f = factorial(vn);
    print_str("10! = ");  print_dec(f);  print_str("\n");
    if (f != 3628800) errors++;

    uint32_t g = gcd(va, vb);
    print_str("gcd(1071, 462) = ");  print_dec(g);  print_str("\n");
    if (g != 21) errors++;

    // C rounds signed division toward zero, same as the RISC-V div / rem instructions
    int32_t q = vx / vy, r = vx % vy;
    print_str("-7 / 2 = ");  print_dec(q);  print_str(", -7 % 2 = ");  print_dec(r);  print_str("\n");
    if (q != -3 || r != -1) errors++;

    IO_LEDS = errors ? 0x0F : 0xA5;   // pattern on the board LEDs: A5 = all good

    print_str(errors ? "FAILED\n" : "All checks passed\n");
    return errors;
}
