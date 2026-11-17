# train.py - trains the tiny MNIST CNN in plain NumPy and saves the float weights.
#
#   input 28x28x1 -> conv 3x3, 8 ch, ReLU -> maxpool 2 -> 13x13x8
#                 -> conv 3x3, 16 ch, ReLU -> maxpool 2 -> 5x5x16 = 400
#                 -> fully connected 400 -> 10
#
# Activations are kept as (batch, height, width, channels). A 3x3 patch is flattened in the
# order (ky, kx, channel), the same order the C code uses when it builds im2col matrices.

import gzip, numpy as np, time

def load(images, labels):
    with gzip.open(images) as f: x = np.frombuffer(f.read(), np.uint8, offset=16).reshape(-1, 28, 28, 1)
    with gzip.open(labels) as f: y = np.frombuffer(f.read(), np.uint8, offset=8)
    return x, y

def im2col(x):                       # (B,H,W,C) -> (B,OH,OW,9*C), valid 3x3
    B, H, W, C = x.shape
    oh, ow = H - 2, W - 2
    cols = np.stack([x[:, ky:ky+oh, kx:kx+ow, :] for ky in range(3) for kx in range(3)], axis=3)
    return cols.reshape(B, oh, ow, 9 * C)

def col2im(dcols, shape):            # adds the patch gradients back onto the input
    B, H, W, C = shape
    oh, ow = H - 2, W - 2
    d = dcols.reshape(B, oh, ow, 9, C)
    dx = np.zeros(shape, np.float32)
    for i, (ky, kx) in enumerate((ky, kx) for ky in range(3) for kx in range(3)):
        dx[:, ky:ky+oh, kx:kx+ow, :] += d[:, :, :, i, :]
    return dx

def pool(x):                         # 2x2 max pool, odd sizes drop the last row/column
    B, H, W, C = x.shape
    h, w = H // 2, W // 2
    v = x[:, :2*h, :2*w, :].reshape(B, h, 2, w, 2, C)
    out = v.max(axis=(2, 4))
    mask = (v == out[:, :, None, :, None, :])
    return out, mask

def unpool(dout, mask, shape):
    B, H, W, C = shape
    h, w = H // 2, W // 2
    d = mask * dout[:, :, None, :, None, :]
    d = d / np.maximum(mask.sum(axis=(2, 4), keepdims=True), 1)      # ties share the gradient
    dx = np.zeros(shape, np.float32)
    dx[:, :2*h, :2*w, :] = d.reshape(B, 2*h, 2*w, C)
    return dx

def forward(p, x, keep=False):
    c1 = im2col(x);                    z1 = c1 @ p['w1'].T + p['b1'];   a1 = np.maximum(z1, 0)
    p1, m1 = pool(a1)
    c2 = im2col(p1);                   z2 = c2 @ p['w2'].T + p['b2'];   a2 = np.maximum(z2, 0)
    p2, m2 = pool(a2)
    f = p2.reshape(len(x), -1);        z3 = f @ p['w3'].T + p['b3']
    if keep: return z3, (x, c1, z1, a1, p1, m1, c2, z2, a2, p2, m2, f)
    return z3

def backward(p, cache, z3, y):
    x, c1, z1, a1, p1, m1, c2, z2, a2, p2, m2, f = cache
    B = len(x)
    e = np.exp(z3 - z3.max(1, keepdims=True)); prob = e / e.sum(1, keepdims=True)
    loss = -np.log(prob[np.arange(B), y] + 1e-12).mean()
    d3 = prob; d3[np.arange(B), y] -= 1; d3 /= B
    g = {'w3': d3.T @ f, 'b3': d3.sum(0)}
    dp2 = (d3 @ p['w3']).reshape(p2.shape)
    da2 = unpool(dp2, m2, a2.shape) * (z2 > 0)
    g['w2'] = da2.reshape(-1, da2.shape[-1]).T @ c2.reshape(-1, c2.shape[-1]); g['b2'] = da2.sum((0, 1, 2))
    dp1 = col2im(da2 @ p['w2'], p1.shape)
    da1 = unpool(dp1, m1, a1.shape) * (z1 > 0)
    g['w1'] = da1.reshape(-1, da1.shape[-1]).T @ c1.reshape(-1, c1.shape[-1]); g['b1'] = da1.sum((0, 1, 2))
    return loss, g

if __name__ == '__main__':
    rng = np.random.default_rng(1)
    xtr, ytr = load('train-images-idx3-ubyte.gz', 'train-labels-idx1-ubyte.gz')
    xte, yte = load('t10k-images-idx3-ubyte.gz', 't10k-labels-idx1-ubyte.gz')
    # train on the same values the hardware sees: pixel >> 1 (0..127), scaled to 0..1
    to_f = lambda a: (a >> 1).astype(np.float32) / 127.0
    Xtr, Xte = to_f(xtr), to_f(xte)

    he = lambda fan_in, shape: (rng.standard_normal(shape) * np.sqrt(2 / fan_in)).astype(np.float32)
    p = {'w1': he(9, (8, 9)),      'b1': np.zeros(8, np.float32),
         'w2': he(72, (16, 72)),   'b2': np.zeros(16, np.float32),
         'w3': he(400, (10, 400)), 'b3': np.zeros(10, np.float32)}
    m = {k: np.zeros_like(v) for k, v in p.items()}; v = {k: np.zeros_like(v) for k, v in p.items()}

    step, lr, bs = 0, 2e-3, 64
    for epoch in range(8):
        t0 = time.time(); idx = rng.permutation(len(Xtr)); tot = 0
        if epoch == 5: lr = 5e-4
        for i in range(0, len(idx), bs):
            b = idx[i:i+bs]
            z3, cache = forward(p, Xtr[b], keep=True)
            loss, g = backward(p, cache, z3, ytr[b]); tot += loss * len(b)
            step += 1
            for k in p:                                   # Adam
                m[k] = 0.9 * m[k] + 0.1 * g[k]
                v[k] = 0.999 * v[k] + 0.001 * g[k] ** 2
                p[k] -= lr * (m[k] / (1 - 0.9 ** step)) / (np.sqrt(v[k] / (1 - 0.999 ** step)) + 1e-8)
        acc = np.mean(np.concatenate([forward(p, Xte[i:i+1000]).argmax(1) for i in range(0, 10000, 1000)]) == yte)
        print(f'epoch {epoch+1}: loss {tot/len(idx):.4f}  test accuracy {acc*100:.2f}%  ({time.time()-t0:.0f} s)', flush=True)

    np.savez('weights_float.npz', **p)
