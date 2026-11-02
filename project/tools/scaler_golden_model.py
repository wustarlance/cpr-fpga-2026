#!/usr/bin/env python3
"""Fixed-point model of the proposed RTL scaler.

Algorithm (unified, exact, division-free)
-----------------------------------------
Map source pixel boundaries into output-cell units with a per-image constant

    inv_r_q = (n_dst << 16) // n_src

so source pixel sx spans u = [sx*inv_r_q, (sx+1)*inv_r_q), while output cell x
occupies [x<<16, (x+1)<<16). The weight of pixel sx for cell x is the overlap
of those two intervals; the weights of a cell always sum to exactly 1<<16, so

    out[x] = ( sum_sx  w(sx,x) * src[sx] ) >> 16

needs no division. When inv_r_q < 1<<16 (downscale) a pixel touches at most two
cells and several pixels share one cell -> area average. When inv_r_q > 1<<16
(upscale) a cell sits inside one pixel, except at pixel boundaries where it is
split between two -> linear interpolation. One code path covers both.
"""
import sys
import numpy as np
from PIL import Image

Q = 16
ONE = 1 << Q


def scale_axis(arr, n_dst, axis):
    """Resample one axis of `arr` to n_dst samples.

    Downscale: box overlap in u-space (exact area average).
    Upscale:   centre-aligned linear interpolation. A box kernel degenerates to
               nearest neighbour when magnifying, so the kernel must change.
    """
    n_src = arr.shape[axis]
    moved = np.moveaxis(arr, axis, 0).astype(np.float64)

    if n_dst > n_src:
        # upscale: centre-aligned bilinear, exactly what the Q16 RTL accumulator
        # produces from phase = ((x+0.5)*n_src/n_dst - 0.5) << 16
        step = (n_src << Q) // n_dst
        ph = np.arange(n_dst, dtype=np.int64) * step + (step >> 1) - (1 << (Q - 1))
        sx = np.clip(ph >> Q, 0, n_src - 1)
        f = np.where(ph < 0, 0, ph & (ONE - 1)).astype(np.float64) / ONE
        s1 = np.clip(sx + 1, 0, n_src - 1)
        shape = (-1,) + (1,) * (moved.ndim - 1)
        out = moved[sx] * (1.0 - f).reshape(shape) + moved[s1] * f.reshape(shape)
        return np.moveaxis(out, 0, axis)

    inv = (n_dst << Q) // n_src

    u0 = np.arange(n_src, dtype=np.int64) * inv
    u1 = u0 + inv
    c0 = u0 >> Q
    c1 = (u1 - 1) >> Q

    acc = np.zeros((n_dst,) + moved.shape[1:], dtype=np.float64)

    span = int((c1 - c0).max()) + 1
    for k in range(span):
        c = c0 + k
        valid = (c <= c1) & (c < n_dst)
        if not valid.any():
            continue
        cv = c[valid]
        lo = np.maximum(u0[valid], cv << Q)
        hi = np.minimum(u1[valid], (cv + 1) << Q)
        w = np.maximum(hi - lo, 0).astype(np.float64)
        contrib = moved[valid] * w.reshape((-1,) + (1,) * (moved.ndim - 1))
        np.add.at(acc, cv, contrib)

    out = acc / ONE
    return np.moveaxis(out, 0, axis)


def rtl_scale(src, fit_w, fit_h):
    a = np.asarray(src).astype(np.float64)
    a = scale_axis(a, fit_h, axis=0)
    a = scale_axis(a, fit_w, axis=1)
    return a


def ref_downscale(src, fit_w, fit_h):
    return np.asarray(Image.fromarray(np.asarray(src).astype(np.uint8))
                      .resize((fit_w, fit_h), Image.BOX)).astype(np.float64)


def ref_upscale(src, fit_w, fit_h):
    return np.asarray(Image.fromarray(np.asarray(src).astype(np.uint8))
                      .resize((fit_w, fit_h), Image.LANCZOS)).astype(np.float64)


def psnr(x, ref):
    mse = float(np.mean((x - ref) ** 2))
    return 99.0 if mse <= 0 else 10 * np.log10(255.0 * 255.0 / mse)


def fit_size(w, h, dw=640, dh=480):
    s = min(dw / w, dh / h)
    return max(1, round(w * s)), max(1, round(h * s))


def main():
    src_path = sys.argv[1] if len(sys.argv) > 1 else \
        "05_lab_ex/lab_ex5_i2s/doc/convert/1.png"
    src = Image.open(src_path).convert("RGB")

    print("  源图 1536×1024 → 等比 640×427（缩小，与精确面积平均比）")
    fw, fh = fit_size(*src.size)
    ref = ref_downscale(src, fw, fh)
    cands = [
        ("最近邻（当前实现）", Image.NEAREST),
        ("双线性 2 点（BILINEAR）", Image.BILINEAR),
    ]
    for name, mode in cands:
        a = np.asarray(src.resize((fw, fh), mode)).astype(np.float64)
        print(f"    {name:<26} {psnr(a, ref):>6.2f} dB")
    print(f"    {'本方案 u 空间定点':<26} {psnr(rtl_scale(src, fw, fh), ref):>6.2f} dB")

    print("\n  极端比例抽查")
    print(f"    {'源图 → 目标':<24} {'方向':<6} {'最近邻':>8} {'双线性':>8} {'本方案':>8} {'参考':>10}")
    for (w, h) in ((2048, 1536), (1920, 1080), (1024, 768), (1536, 1024),
                   (320, 240), (426, 240), (480, 640)):
        s = Image.fromarray(np.asarray(src)).resize((w, h), Image.LANCZOS)
        fw2, fh2 = fit_size(w, h)
        down = w > fw2
        r = ref_downscale(s, fw2, fh2) if down else ref_upscale(s, fw2, fh2)
        nn = np.asarray(s.resize((fw2, fh2), Image.NEAREST)).astype(np.float64)
        bl = np.asarray(s.resize((fw2, fh2), Image.BILINEAR)).astype(np.float64)
        ours = rtl_scale(s, fw2, fh2)
        kind = "缩小" if down else ("放大" if w < fw2 else "直通")
        base = "面积平均" if down else "Lanczos"
        print(f"    {w:>4}×{h:<4} → {fw2:>3}×{fh2:<3}      {kind:<6} "
              f"{psnr(nn, r):>7.2f} {psnr(bl, r):>7.2f} {psnr(ours, r):>7.2f}  ({base})")

    Image.fromarray(rtl_scale(src, fw, fh).clip(0, 255).astype(np.uint8)).save(
        ".scratch/scale/rtl_model_out.png")
    print("\n  预览：.scratch/scale/rtl_model_out.png")


if __name__ == "__main__":
    main()
