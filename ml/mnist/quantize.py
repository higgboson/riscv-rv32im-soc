# quantize.py - turns the float CNN into the INT8 network the SoC runs, and holds the
# golden model: the exact integer arithmetic that the C code and the hardware must match
# bit for bit.
#
# Every layer: acc = sum(w_q * x_q) + b_q (int32), then for the conv layers
#   y = clamp((acc * M[f] + 2^(S-1)) >> S, 0, 127)
# which is "scale back to 8 bits" and ReLU in one step. M[f] / 2^S approximates
# s_w[f] * s_in / s_out. The last layer keeps the int32 sums; the answer is the largest one.

import numpy as np
from train import load, im2col

S = 24                                   # shift of the fixed-point multipliers

def float_acts(p, x):
    c1 = im2col(x); a1 = np.maximum(c1 @ p['w1'].T + p['b1'], 0)
    B, H, W, C = a1.shape; p1 = a1[:, :2*(H//2), :2*(W//2)].reshape(B, H//2, 2, W//2, 2, C).max((2, 4))
    c2 = im2col(p1); a2 = np.maximum(c2 @ p['w2'].T + p['b2'], 0)
    return a1, a2

def quant_w(w):                          # symmetric, one scale per output channel
    s = np.abs(w).max(1) / 127.0
    return np.clip(np.round(w / s[:, None]), -127, 127).astype(np.int64), s

def build(p, xcal):
    a1, a2 = float_acts(p, xcal)
    s0 = 1 / 127.0                                       # input: q = pixel >> 1, real = q / 127
    s1 = np.percentile(a1, 99.99) / 127.0                # conv1 output scale
    s2 = np.percentile(a2, 99.99) / 127.0                # conv2 output scale
    q = {}
    for name, w, b, s_in, s_out in (('1', p['w1'], p['b1'], s0, s1),
                                    ('2', p['w2'], p['b2'], s1, s2),
                                    ('3', p['w3'], p['b3'], s2, None)):
        wq, sw = quant_w(w)
        q['w' + name] = wq
        q['b' + name] = np.round(b / (sw * s_in)).astype(np.int64)
        if s_out is not None:
            q['m' + name] = np.round(sw * s_in / s_out * 2 ** S).astype(np.int64)
    return q

# ---------------- the golden model: integers only ----------------
def requant(acc, m):
    return np.clip((acc * m + (1 << (S - 1))) >> S, 0, 127)

def pool_int(a):
    B, H, W, C = a.shape
    return a[:, :2*(H//2), :2*(W//2)].reshape(B, H//2, 2, W//2, 2, C).max((2, 4))

def golden(q, pixels):
    """pixels: (B,28,28,1) uint8 -> logits (B,10) int64, plus the intermediate layers"""
    x  = (pixels >> 1).astype(np.int64)
    a1 = requant(im2col(x) @ q['w1'].T + q['b1'], q['m1']);  p1 = pool_int(a1)
    a2 = requant(im2col(p1) @ q['w2'].T + q['b2'], q['m2']); p2 = pool_int(a2)
    logits = p2.reshape(len(x), -1) @ q['w3'].T + q['b3']
    return logits, (x, p1, p2)

if __name__ == '__main__':
    p = dict(np.load('weights_float.npz'))
    xtr, _ = load('train-images-idx3-ubyte.gz', 'train-labels-idx1-ubyte.gz')
    xte, yte = load('t10k-images-idx3-ubyte.gz', 't10k-labels-idx1-ubyte.gz')
    q = build(p, (xtr[:5000] >> 1).astype(np.float32) / 127.0)
    pred = np.concatenate([golden(q, xte[i:i+1000])[0].argmax(1) for i in range(0, 10000, 1000)])
    print(f'INT8 golden model: test accuracy {np.mean(pred == yte)*100:.2f}%')
    for k in ('m1', 'm2'): print(k, 'range', q[k].min(), q[k].max())
    for k in ('b1', 'b2', 'b3'): print(k, 'range', q[k].min(), q[k].max())
    np.savez('weights_int8.npz', **q)
