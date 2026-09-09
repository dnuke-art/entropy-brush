#!/usr/bin/env python3
"""Colour-mixing harness: the app's exact pigments through the CURRENT mixer
(single-constant Kubelka-Munk: K/S ratio averaged per RGB channel) vs the
proposed two-constant KM (K and S mixed separately by concentration, then K/S).
Prints RGB + saturation for key pairs and renders test/km_mix_swatches.png.
Run: python3 test/km_mix_swatches.py   (needs Pillow)

Findings (2026-09-09): single-constant KM can't tint — Titanium White barely
lightens anything (R+W stays a saturated red) — and complements go near-black,
so any multi-colour mix collapses to brown. Gamma-correcting the inputs and
raising the K/S floor were measured and do NOT help. Two-constant KM with a
per-pigment scattering S (white a strong scatterer) restores tints and makes
complements dark-but-chromatic. S values below are a starting point to tune.
"""
import math, sys
from PIL import Image, ImageDraw

def ksr(r, floor=0.004):
    r = min(max(r, floor), 1.0); return (1 - r) * (1 - r) / (2 * r)
def unks(k): return 1 + k - math.sqrt(k * k + 2 * k)

P = {'R': (0.78, 0.12, 0.10), 'B': (0.12, 0.20, 0.62),
     'Y': (0.92, 0.78, 0.12), 'W': (0.95, 0.94, 0.90)}
# Two-constant KM: per-pigment scattering S (opacity / tinting strength).
S = {'W': 4.0, 'R': 0.6, 'Y': 0.6, 'B': 0.35}

def mix_single(keys):
    out = []
    for ch in range(3):
        vals = [P[k][ch] for k in keys]; acc = vals[0]
        for i, v in enumerate(vals[1:], start=2):
            acc = min(max(unks(ksr(acc) * (1 - 1 / i) + ksr(v) / i), 0), 1)
        out.append(acc)
    return tuple(out)

def mix_two(keys):
    n = len(keys); out = []
    for ch in range(3):
        K = sum(S[k] * ksr(P[k][ch]) for k in keys) / n
        Ssum = sum(S[k] for k in keys) / n
        out.append(min(max(unks(K / Ssum), 0), 1))
    return tuple(out)

combos = [('R+B', 'RB'), ('B+Y', 'BY'), ('R+Y', 'RY'), ('R+W', 'RW'), ('B+W', 'BW'),
          ('Y+W', 'YW'), ('R+B+Y', 'RBY'), ('R+B+Y+W', 'RBYW')]
to255 = lambda c: tuple(int(round(x * 255)) for x in c)
sat = lambda c: 0 if max(c) == 0 else (max(c) - min(c)) / max(c)
print(f"{'mix':<9}{'A current':<28}{'D two-constant KM'}")
for name, keys in combos:
    a, d = mix_single(keys), mix_two(keys)
    print(f"{name:<9}{str(to255(a)):<16}s={sat(a):.2f}      {str(to255(d)):<16}s={sat(d):.2f}")

models = [('A', 'current: single-constant KM (K/S ratio averaged)', mix_single),
          ('D', 'proposed: two-constant KM (K and S mixed separately)', mix_two)]
W, H, pad, labw = 140, 110, 8, 330
img = Image.new('RGB', (labw + len(combos) * (W + pad) + pad, len(models) * (H + pad) + pad + 40), (30, 30, 34))
dr = ImageDraw.Draw(img)
for j, (name, _) in enumerate(combos): dr.text((labw + pad + j * (W + pad) + 4, 10), name, fill=(220, 220, 220))
for i, (m, desc, fn) in enumerate(models):
    y = 40 + pad + i * (H + pad); dr.text((10, y + H // 2 - 6), f"{m}: {desc}", fill=(220, 220, 220))
    for j, (_, keys) in enumerate(combos):
        x = labw + pad + j * (W + pad); dr.rectangle([x, y, x + W, y + H], fill=to255(fn(keys)))
        cw = W // len(keys)
        for k_i, k in enumerate(keys): dr.rectangle([x + k_i * cw, y, x + (k_i + 1) * cw - 1, y + 14], fill=to255(P[k]))
out = sys.argv[1] if len(sys.argv) > 1 else 'test/km_mix_swatches.png'
img.save(out); print('swatches ->', out)
