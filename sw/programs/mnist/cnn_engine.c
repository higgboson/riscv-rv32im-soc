// cnn_engine.c - the convolution layers on the accelerator's layer engine: one command per
// layer. The engine walks over all tiles itself, loads the bias and scale of each filter
// group, gathers patches and weights, runs the array, and writes the 2x2 max-pooled INT8
// results straight back to data memory. The CPU only describes the layer and waits.
// The small fully connected layer stays on the gather path (cnn_gather.c).

#include "cnn.h"
#include "weights.h"
#include "accel.h"

void conv1_engine(const int8_t *x,  int8_t *p1) { accel_conv_layer(x,  28, 1,  8, 13, 13, w1t, b1, m1, p1); }
void conv2_engine(const int8_t *p1, int8_t *p2) { accel_conv_layer(p1, 13, 8, 16,  5,  5, w2t, b2, m2, p2); }
