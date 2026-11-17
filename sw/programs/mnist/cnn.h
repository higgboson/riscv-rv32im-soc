// cnn.h - the INT8 MNIST network, layer by layer, on the CPU alone or with the accelerator
//
//   28x28 image -> conv 3x3 (8) + ReLU -> pool -> 13x13x8
//               -> conv 3x3 (16) + ReLU -> pool -> 5x5x16
//               -> fully connected 400 -> 10 scores; the largest score is the digit
//
// Activations are stored height x width x channels, int8 values 0..127. Both versions must
// give exactly the same scores as the golden model in ml/mnist/quantize.py.

#ifndef CNN_H
#define CNN_H

#include <stdint.h>

void cnn_input(const uint8_t *pixels, int8_t *x);            // 28x28 pixels -> x = pixel >> 1

void conv1_cpu(const int8_t *x,  int8_t *p1);                 // 28x28x1  -> 13x13x8
void conv2_cpu(const int8_t *p1, int8_t *p2);                 // 13x13x8  -> 5x5x16
void fc_cpu   (const int8_t *p2, int32_t *scores);            // 400      -> 10

void conv1_accel(const int8_t *x,  int8_t *p1);
void conv2_accel(const int8_t *p1, int8_t *p2);
void fc_accel   (const int8_t *p2, int32_t *scores);

int  cnn_argmax(const int32_t *scores);

#endif
