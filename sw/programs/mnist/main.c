// mnist - handwritten digit recognition with an INT8 CNN, three ways:
//   cpu    the CPU alone
//   feed   the systolic array, fed word by word by the CPU (cnn_accel.c)
//   gather the systolic array with its gather engine fetching the data itself (cnn_gather.c)
// For every built-in test image all three must give exactly the scores of the golden model
// (ml/mnist/quantize.py). The hardware counters time each layer; the final speedup of
// "gather" over "cpu" is shown on the 7-segment display ("12.3" = 12.3x).

#include "console.h"
#include "perf.h"
#include "cnn.h"

extern const int     n_test_images;
extern const uint8_t test_images[], test_labels[];
extern const int32_t test_golden[];

static int8_t  x[28 * 28], p1[13 * 13 * 8], p2[400];
static int32_t scores[10];

static uint32_t now(void) { return PERF_CYCLES; }

static void print_x10(uint32_t a, uint32_t b)        // a / b with one decimal
{
    uint32_t r = (a * 10u + b / 2) / b;
    print_dec(r / 10); putchar_('.'); putchar_('0' + r % 10);
}

static uint32_t to_bcd(uint32_t v)
{
    uint32_t bcd = 0;
    for (int shift = 0; shift < 16; shift += 4) { bcd |= (v % 10) << shift; v /= 10; }
    return bcd;
}

// runs one version (0 cpu, 1 feed, 2 gather), returns the cycles of each layer in t[0..3]
// and the number of scores that differ from the golden model
static int infer(int img, int version, uint32_t t[4])
{
    uint32_t c0, c1, c2, c3, c4;
    c0 = now();  cnn_input(&test_images[img * 784], x);
    c1 = now();
    if (version == 0)      conv1_cpu(x, p1);
    else if (version == 1) conv1_accel(x, p1);
    else                   conv1_gather(x, p1);
    c2 = now();
    if (version == 0)      conv2_cpu(p1, p2);
    else if (version == 1) conv2_accel(p1, p2);
    else                   conv2_gather(p1, p2);
    c3 = now();
    if (version == 0)      fc_cpu(p2, scores);
    else if (version == 1) fc_accel(p2, scores);
    else                   fc_gather(p2, scores);
    c4 = now();
    t[0] = c1 - c0;  t[1] = c2 - c1;  t[2] = c3 - c2;  t[3] = c4 - c3;
    int wrong = 0;
    for (int i = 0; i < 10; i++) wrong += scores[i] != test_golden[img * 10 + i];
    return wrong;
}

static const char *layer[4] = { "  input  ", "  conv1  ", "  conv2  ", "  fc     " };

static void print_col(uint32_t v)                      // right-aligned in 9 characters
{
    uint32_t w = 1, n = v;
    while (n >= 10) { n /= 10; w++; }
    for (; w < 9; w++) putchar_(' ');
    print_dec(v);
}

int main(void)
{
    uint32_t t[3][4], sum[3] = {0, 0, 0};
    int errors = 0;

    print_str("MNIST INT8 CNN: 28x28 -> conv 8 -> pool -> conv 16 -> pool -> fc 10\n");
    print_str("(about 168,000 multiply-adds per image)\n\n");

    for (int img = 0; img < n_test_images; img++) {
        int digit[3];
        for (int v = 0; v < 3; v++) {
            errors += infer(img, v, t[v]);
            digit[v] = cnn_argmax(scores);
        }
        errors += (digit[0] != digit[1]) + (digit[0] != digit[2]);

        print_str("image "); print_dec(img);
        print_str(": label "); print_dec(test_labels[img]);
        print_str(", recognised "); print_dec(digit[2]);
        print_str(digit[2] == test_labels[img] ? "  ok\n" : "  WRONG\n");
        print_str("  cycles        cpu     feed   gather   speedup (gather vs cpu)\n");

        uint32_t tot[3] = {0, 0, 0};
        for (int l = 0; l < 4; l++) {
            print_str(layer[l]);
            for (int v = 0; v < 3; v++) { print_col(t[v][l]); tot[v] += t[v][l]; }
            print_str("   "); print_x10(t[0][l], t[2][l]); print_str("x\n");
        }
        print_str("  total  ");
        for (int v = 0; v < 3; v++) { print_col(tot[v]); sum[v] += tot[v]; }
        print_str("   "); print_x10(tot[0], tot[2]); print_str("x\n");
        IO_HEX = 0x10000u | (uint32_t)digit[2];       // show the digit while the next one runs
    }

    print_str("\nper image at 50 MHz:  cpu ");
    print_dec(sum[0] / n_test_images / 50);  print_str(" us,  feed ");
    print_dec(sum[1] / n_test_images / 50);  print_str(" us,  gather ");
    print_dec(sum[2] / n_test_images / 50);  print_str(" us\n");
    print_str("speedup over the CPU:  feed "); print_x10(sum[0], sum[1]);
    print_str("x,  gather "); print_x10(sum[0], sum[2]); print_str("x\n");
    print_str(errors ? "SCORES DIFFER FROM THE GOLDEN MODEL\n"
                     : "all scores match the golden model exactly\n");

    uint32_t x10 = (sum[0] * 10u + sum[2] / 2) / sum[2];
    IO_HEX = (0x2u << 16) | to_bcd(x10);
    uart_flush();
    return errors;
}
