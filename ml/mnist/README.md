# MNIST CNN for the SoC

A small convolutional network for handwritten digits, trained in plain NumPy, converted to
8-bit integers and run on the RISC-V SoC (`sw/programs/mnist`), on the CPU alone or with the
systolic-array accelerator.

```
28x28 image -> conv 3x3, 8 filters, ReLU -> 2x2 max pool -> 13x13x8
            -> conv 3x3, 16 filters, ReLU -> 2x2 max pool -> 5x5x16
            -> fully connected 400 -> 10 scores
5,258 weights, about 168,000 multiply-adds per image
```

| | Test accuracy (10,000 images) |
|---|---|
| float (NumPy) | 98.78 % |
| INT8 (golden model, C on the PC, C on the RTL) | 98.74 % |

## Files

- `train.py`: training (8 epochs, Adam, about 2 minutes on a laptop CPU), writes `weights_float.npz`
- `quantize.py`: INT8 conversion and the **golden model**, the exact integer arithmetic every
  other version must match: weights scaled per filter, int32 sums, then
  `y = clamp((acc * M + 2^23) >> 24, 0, 127)` (back to 8 bits and ReLU in one step)
- `gen_c.py`: writes `sw/programs/mnist/weights.c`, `weights.h` and `test_images.c`, and
  `test_images.raw` for the PC check

## Rebuilding

The MNIST files are not kept in git. Put the four `*-ubyte.gz` files from the MNIST site here, then:

```
python3 train.py          # optional: the trained weights are included
python3 quantize.py
python3 gen_c.py ../../sw/programs/mnist
```

Check both C versions against the golden model on all 10,000 images (from this folder):

```
cc -O2 -I../../sw/programs/mnist/host -I../../sw/programs/mnist ../../sw/programs/mnist/host/*.c \
   ../../sw/programs/mnist/cnn_cpu.c ../../sw/programs/mnist/cnn_accel.c ../../sw/programs/mnist/weights.c -o host_check
./host_check
```
