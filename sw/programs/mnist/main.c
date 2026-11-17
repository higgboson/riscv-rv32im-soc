// mnist - handwritten digit recognition with an INT8 CNN, on the CPU alone and with the
// systolic-array accelerator. For every built-in test image, both versions must give
// exactly the scores of the golden model (ml/mnist/quantize.py). The hardware counters
// time each layer; the speedup is shown on the 7-segment display ("12.3" = 12.3x).

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

// runs one version, returns the cycles of each layer in t[0..3] and the number of scores
// that differ from the golden model
static int infer(int img, int accel, uint32_t t[4])
{
    uint32_t c0, c1, c2, c3, c4;
    c0 = now();  cnn_input(&test_images[img * 784], x);
    c1 = now();  if (accel) conv1_accel(x, p1);  else conv1_cpu(x, p1);
    c2 = now();  if (accel) conv2_accel(p1, p2); else conv2_cpu(p1, p2);
    c3 = now();  if (accel) fc_accel(p2, scores); else fc_cpu(p2, scores);
    c4 = now();
    t[0] = c1 - c0;  t[1] = c2 - c1;  t[2] = c3 - c2;  t[3] = c4 - c3;
    int wrong = 0;
    for (int i = 0; i < 10; i++) wrong += scores[i] != test_golden[img * 10 + i];
    return wrong;
}

static const char *layer[4] = { "  input  ", "  conv1  ", "  conv2  ", "  fc     " };

int main(void)
{
    uint32_t tc[4], ta[4], sum_c = 0, sum_a = 0;
    int errors = 0;

    print_str("MNIST INT8 CNN: 28x28 -> conv 8 -> pool -> conv 16 -> pool -> fc 10\n");
    print_str("(about 168,000 multiply-adds per image)\n\n");

    for (int img = 0; img < n_test_images; img++) {
        errors += infer(img, 0, tc);
        int digit_cpu = cnn_argmax(scores);
        errors += infer(img, 1, ta);
        int digit_acc = cnn_argmax(scores);
        errors += digit_cpu != digit_acc;

        print_str("image "); print_dec(img);
        print_str(": label "); print_dec(test_labels[img]);
        print_str(", recognised "); print_dec(digit_acc);
        print_str(digit_acc == test_labels[img] ? "  ok\n" : "  WRONG\n");

        uint32_t c = 0, a = 0;
        for (int l = 0; l < 4; l++) {
            print_str(layer[l]); print_dec(tc[l]); print_str(" -> "); print_dec(ta[l]);
            print_str(" cycles  ("); print_x10(tc[l], ta[l]); print_str("x)\n");
            c += tc[l];  a += ta[l];
        }
        print_str("  total  "); print_dec(c); print_str(" -> "); print_dec(a);
        print_str(" cycles  ("); print_x10(c, a); print_str("x)\n");
        sum_c += c;  sum_a += a;
        IO_HEX = 0x10000u | (uint32_t)digit_acc;     // show the digit while the next one runs
    }

    print_str("\nper image at 50 MHz: CPU only ");
    print_dec(sum_c / n_test_images / 50); print_str(" us, with accelerator ");
    print_dec(sum_a / n_test_images / 50); print_str(" us, speedup ");
    print_x10(sum_c, sum_a); print_str("x\n");
    print_str(errors ? "SCORES DIFFER FROM THE GOLDEN MODEL\n"
                     : "all scores match the golden model exactly\n");

    uint32_t x10 = (sum_c * 10u + sum_a / 2) / sum_a;
    IO_HEX = (0x2u << 16) | to_bcd(x10);
    uart_flush();
    return errors;
}
