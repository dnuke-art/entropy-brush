#!/usr/bin/env python3
"""Render the paper's figures from the fields dumped by tools/paper_figs.dart.
Reproducible: run the Dart generator first, then this.

    dart run tools/paper_figs.dart
    python3 paper/figures/gen_figures.py

Each figure combines the SIMULATED height field (relief shading) with the
SIMULATED surface pigment (albedo colour) --- not a scan, not the GPU shader.
Outputs (paper/figures/): spinart.png, impasto_relief.png, dualgeometry.png,
determinism.png.
"""
import os
import struct
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LightSource

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "data")
LS = LightSource(azdeg=315, altdeg=45)


def load_height(name):
    with open(os.path.join(DATA, name), "rb") as f:
        w, h = struct.unpack("<ii", f.read(8))
        z = np.frombuffer(f.read(), dtype="<f4").astype(np.float64).reshape(h, w)
    return z


def load_albedo(name):
    with open(os.path.join(DATA, name), "rb") as f:
        w, h = struct.unpack("<ii", f.read(8))
        rgb = np.frombuffer(f.read(), dtype="<f4").astype(np.float64)
    return rgb.reshape(h, w, 3)


def relief_rgb(z, rgb, vert=6.0, ambient=0.42):
    """Pigment albedo modulated by height-based relief shading, sRGB-encoded."""
    inten = LS.hillshade(z, vert_exag=vert)          # 0..1
    inten = ambient + (1.0 - ambient) * inten
    out = np.clip(rgb * inten[..., None], 0, 1) ** (1 / 2.2)
    return out


def show(ax, img, title):
    ax.imshow(img, origin="upper")
    ax.set_title(title, fontsize=10)
    ax.set_xticks([]); ax.set_yticks([])


def fig_spinart():
    z = load_height("spin_height.bin"); rgb = load_albedo("spin_albedo.bin")
    fig, ax = plt.subplots(figsize=(4.2, 4.2))
    show(ax, relief_rgb(z, rgb, vert=7.0),
         "Spin art: wet paint flung by\ncentrifugal + Coriolis forces")
    fig.tight_layout()
    fig.savefig(os.path.join(HERE, "spinart.png"), dpi=150, bbox_inches="tight")
    plt.close(fig)


def fig_impasto():
    z = load_height("scene_height.bin"); rgb = load_albedo("scene_albedo.bin")
    fig, ax = plt.subplots(figsize=(4.2, 4.2))
    show(ax, relief_rgb(z, rgb), "Simulated impasto: pigment + relief")
    fig.tight_layout()
    fig.savefig(os.path.join(HERE, "impasto_relief.png"), dpi=150,
                bbox_inches="tight")
    plt.close(fig)


def fig_dualgeometry():
    z = load_height("scene_height.bin"); rgb = load_albedo("scene_albedo.bin")
    fig = plt.figure(figsize=(8.6, 4.3))
    ax1 = fig.add_subplot(1, 2, 1)
    show(ax1, relief_rgb(z, rgb), "(a) the painting, rendered as relief")
    # (b) the SAME field as a 3D surface = the form the watertight STL encodes,
    #     coloured by the same pigment.
    ax2 = fig.add_subplot(1, 2, 2, projection="3d")
    s = 4
    zs = z[::s, ::s]
    cols = np.clip(rgb[::s, ::s], 0, 1) ** (1 / 2.2)
    ys, xs = np.mgrid[0:zs.shape[0], 0:zs.shape[1]]
    ax2.plot_surface(xs, ys, zs, facecolors=cols, linewidth=0,
                     antialiased=False, shade=False,
                     rcount=zs.shape[0], ccount=zs.shape[1])
    ax2.set_title("(b) the same field as fabrication geometry\n(the form the "
                  "watertight STL encodes)", fontsize=10)
    ax2.set_box_aspect((1, 1, 0.30))
    ax2.set_xticks([]); ax2.set_yticks([]); ax2.set_zticks([])
    ax2.view_init(elev=58, azim=-58)
    fig.tight_layout()
    fig.savefig(os.path.join(HERE, "dualgeometry.png"), dpi=150,
                bbox_inches="tight")
    plt.close(fig)


def fig_determinism():
    za = load_height("det_a.bin"); zb = load_height("det_b.bin")
    ra = load_albedo("det_a_albedo.bin"); rb = load_albedo("det_b_albedo.bin")
    diff = np.abs(za - zb)
    fig, ax = plt.subplots(1, 3, figsize=(9.8, 3.5))
    show(ax[0], relief_rgb(za, ra), "replay 1")
    show(ax[1], relief_rgb(zb, rb), "replay 2")
    im = ax[2].imshow(diff, origin="upper", cmap="inferno",
                      vmin=0, vmax=max(1e-9, diff.max()))
    ax[2].set_title(f"|replay 1 - replay 2|\nmax = {diff.max():.1e}", fontsize=10)
    ax[2].set_xticks([]); ax[2].set_yticks([])
    fig.colorbar(im, ax=ax[2], fraction=0.046, pad=0.04)
    fig.suptitle("Same recorded performance, fixed timestep -> bit-identical "
                 "replay", fontsize=10)
    fig.tight_layout()
    fig.savefig(os.path.join(HERE, "determinism.png"), dpi=150,
                bbox_inches="tight")
    plt.close(fig)


if __name__ == "__main__":
    fig_spinart()
    fig_impasto()
    fig_dualgeometry()
    fig_determinism()
    print("wrote spinart.png, impasto_relief.png, dualgeometry.png, "
          "determinism.png to", HERE)
