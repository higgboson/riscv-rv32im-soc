// host_check.c - runs all four versions of the network on the PC for every MNIST test image and
// writes their scores, so check.py can compare them with the golden model.
//   cc -O2 -I. -I.. host_check.c accel_model.c ../cnn_*.c ../weights.c -o host_check
#include <stdio.h>
#include <stdlib.h>
#include "../cnn.h"

int main(void)
{
    FILE *in = fopen("test_images.raw", "rb"), *out = fopen("scores.raw", "wb");
    if (!in || !out) { fprintf(stderr, "needs test_images.raw (ml/mnist/gen_c.py)\n"); return 1; }
    static uint8_t img[784];
    static int8_t x[784], p1[13 * 13 * 8] __attribute__((aligned(4))), p2[400] __attribute__((aligned(4)));    // static: near accel_anchor (see host/accel.h)
    int32_t s_cpu[10], s_acc[10], s_gat[10], s_eng[10];
    int n = 0, differ = 0;
    while (fread(img, 1, 784, in) == 784) {
        cnn_input(img, x);
        conv1_cpu(x, p1);   conv2_cpu(p1, p2);   fc_cpu(p2, s_cpu);
        conv1_accel(x, p1); conv2_accel(p1, p2); fc_accel(p2, s_acc);
        conv1_gather(x, p1); conv2_gather(p1, p2); fc_gather(p2, s_gat);
        conv1_engine(x, p1); conv2_engine(p1, p2); fc_gather(p2, s_eng);
        for (int i = 0; i < 10; i++)
            differ += (s_cpu[i] != s_acc[i]) + (s_cpu[i] != s_gat[i]) + (s_cpu[i] != s_eng[i]);
        fwrite(s_cpu, 4, 10, out);
        n++;
    }
    printf("%d images, the four versions differ in %d scores\n", n, differ);
    fclose(out);
    return differ != 0;
}
