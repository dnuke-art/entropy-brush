import 'dart:math' as math;
import 'dart:typed_data';

import 'noise.dart';
import 'paint_profile.dart';

/// The canvas as a height field of paint.
///
/// Every cell stores the paint *thickness* (relief) and the colour of the
/// top surface. Bristles deposit into and lift from these cells; the relief
/// shader later turns [heightAt] into normals for lighting and the mesh
/// exporter turns it into geometry.
class PaintGrid {
  PaintGrid(this.width, this.height, {this.maxHeight = 8.0})
      : thickness = Float32List(width * height),
        canvasHeight = Float32List(width * height),
        wet = Float32List(width * height),
        r = Float32List(width * height),
        g = Float32List(width * height),
        b = Float32List(width * height) {
    clear();
    generateCanvasTexture();
    dripPhase = math.Random().nextDouble() * 997.0;
  }

  /// Random phase for the drip-wander noise field, so drips don't form the exact
  /// same shape every time. Re-roll with [shuffleDrips].
  double dripPhase = 0;
  void shuffleDrips() => dripPhase = math.Random().nextDouble() * 997.0;

  final int width;
  final int height;

  /// Thickness used to normalise the packed height texture. Paint taller than
  /// this clamps in the relief render (but is preserved for mesh export).
  final double maxHeight;

  /// Paint thickness per cell, in arbitrary units (~mm).
  final Float32List thickness;

  /// Base canvas substrate relief (linen tooth / weave) in the same units. The
  /// relief render and mesh export use thickness + canvasHeight, so even bare
  /// canvas is 3D. Survives [clear] — wiping paint doesn't sand the canvas.
  final Float32List canvasHeight;

  /// Wetness per cell (0..1). Fresh paint is wet and flows/levels; it dries over
  /// time and sets, locking in the impasto. Only wet paint participates in flow.
  final Float32List wet;

  // Bounding box of currently-wet paint, so flow only touches the live region.
  int _wetMinX = 0, _wetMinY = 0, _wetMaxX = 0, _wetMaxY = 0;
  bool _hasWet = false;

  /// Whether any paint is still wet (and therefore still being simulated). The
  /// flow sim only runs while this is true; once paint dries it drops out.
  bool get hasWet => _hasWet;

  /// Area (in cells) of the wet bounding box currently being simulated — a proxy
  /// for the per-frame flow cost. Zero when everything has dried.
  int get wetArea => _hasWet
      ? (_wetMaxX - _wetMinX + 1) * (_wetMaxY - _wetMinY + 1)
      : 0;

  // Scratch buffers for the flow step (allocated lazily, reused each frame).
  Float32List? _dH, _inA, _inR, _inG, _inB, _inW;

  // Reused RGBA encode buffers so the per-frame texture upload doesn't allocate
  // ~2.4 MB twice every frame (which pins the GC, worst on web/VR).
  Uint8List? _heightBuf, _albedoBuf;

  void _wetTouch(int x, int y) {
    wet[y * width + x] = 1.0;
    if (!_hasWet) {
      _wetMinX = x;
      _wetMinY = y;
      _wetMaxX = x;
      _wetMaxY = y;
      _hasWet = true;
      return;
    }
    if (x < _wetMinX) _wetMinX = x;
    if (y < _wetMinY) _wetMinY = y;
    if (x > _wetMaxX) _wetMaxX = x;
    if (y > _wetMaxY) _wetMaxY = y;
  }

  /// Combined surface height (substrate + paint) used for lighting and export.
  double heightAt(int i) => canvasHeight[i] + thickness[i];

  /// (Re)build the canvas substrate as fractal (Perlin-style) noise. [amplitude]
  /// is the tooth depth in thickness units, [scale] the spatial frequency.
  /// Amplitude of the current canvas tooth, used to normalise it for the
  /// drybrush/scumble gating in [deposit]. 0 means a smooth (e.g. palette) grid.
  double canvasToothAmplitude = 0.08;

  void generateCanvasTexture(
      {double amplitude = 0.08, double scale = 0.16, int seed = 1}) {
    canvasToothAmplitude = amplitude;
    final double off = seed * 53.13;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final double n =
            fbm(x * scale + off, y * scale + off, octaves: 3);
        canvasHeight[y * width + x] = n * amplitude;
      }
    }
    _dirtyAll();
  }

  /// Top-surface pigment colour, linear 0..1.
  final Float32List r, g, b;

  /// Active paint medium — controls how thick and lumpy deposits are.
  PaintProfile profile = PaintProfile();

  // Bare canvas colour shown where no paint has been laid.
  static const double canvasR = 0.92;
  static const double canvasG = 0.89;
  static const double canvasB = 0.82;

  // Dirty rectangle so the renderer only re-encodes what changed.
  int _dirtyMinX = 0, _dirtyMinY = 0, _dirtyMaxX = 0, _dirtyMaxY = 0;
  bool _dirty = false;

  bool get isDirty => _dirty;

  void clear() {
    for (int i = 0; i < thickness.length; i++) {
      thickness[i] = 0;
      wet[i] = 0;
      r[i] = canvasR;
      g[i] = canvasG;
      b[i] = canvasB;
    }
    _hasWet = false;
    _dirtyAll();
  }

  void _dirtyAll() {
    _dirty = true;
    _dirtyMinX = 0;
    _dirtyMinY = 0;
    _dirtyMaxX = width;
    _dirtyMaxY = height;
  }

  void resetDirty() => _dirty = false;

  void _touch(int x, int y) {
    if (!_dirty) {
      _dirtyMinX = x;
      _dirtyMinY = y;
      _dirtyMaxX = x + 1;
      _dirtyMaxY = y + 1;
      _dirty = true;
      return;
    }
    if (x < _dirtyMinX) _dirtyMinX = x;
    if (y < _dirtyMinY) _dirtyMinY = y;
    if (x + 1 > _dirtyMaxX) _dirtyMaxX = x + 1;
    if (y + 1 > _dirtyMaxY) _dirtyMaxY = y + 1;
  }

  double thicknessAt(int x, int y) => thickness[y * width + x];

  /// Deposit [volume] of pigment ([pr],[pg],[pb]) as a soft round dab centred
  /// at ([cx],[cy]) with radius [radius] (cells). Returns the volume actually
  /// laid down (always == volume here; gating happens in the brush).
  ///
  /// Colour mixes wet-on-wet: a dab tints the existing surface in proportion
  /// to how much it covers, so overlapping strokes blend instead of replace.
  ///
  /// [coverage] (0..1) is how deeply the brush reaches into the canvas tooth: 1
  /// floods the valleys (smooth, loaded paint); lower values let only the raised
  /// tooth peaks catch paint, producing drybrush / scumble that reveals the
  /// canvas weave.
  void deposit(double cx, double cy, double radius, double volume, double pr,
      double pg, double pb, {double coverage = 1.0}) {
    if (volume <= 0) return;
    final bool gateTooth = coverage < 0.999 && canvasToothAmplitude > 1e-6;
    final double toothThresh = 1.0 - coverage;
    final double invToothAmp =
        canvasToothAmplitude > 0 ? 1.0 / canvasToothAmplitude : 0.0;
    final int x0 = math.max(0, (cx - radius).floor());
    final int x1 = math.min(width - 1, (cx + radius).ceil());
    final int y0 = math.max(0, (cy - radius).floor());
    final int y1 = math.min(height - 1, (cy + radius).ceil());
    if (x0 > x1 || y0 > y1) return;

    final double invR2 = 1.0 / (radius * radius);
    // Normalise the gaussian-ish weights so total deposited ~= volume.
    double wsum = 0;
    for (int y = y0; y <= y1; y++) {
      final double dy = y - cy;
      for (int x = x0; x <= x1; x++) {
        final double dx = x - cx;
        final double t = (dx * dx + dy * dy) * invR2;
        if (t <= 1.0) wsum += (1.0 - t) * (1.0 - t);
      }
    }
    if (wsum <= 0) return;
    final double k = volume / wsum;

    for (int y = y0; y <= y1; y++) {
      final double dy = y - cy;
      for (int x = x0; x <= x1; x++) {
        final double dx = x - cx;
        final double t = (dx * dx + dy * dy) * invR2;
        if (t > 1.0) continue;
        final double w = (1.0 - t) * (1.0 - t);
        final int i = y * width + x;

        // Body sets how much the paint piles; lumpiness modulates it with a
        // canvas-locked noise field so the relief breaks into ridges/clumps.
        double lumpMul = 1.0;
        if (profile.lumpiness > 0) {
          final double n = profile.grainAt(x.toDouble(), y.toDouble());
          lumpMul = 1.0 + profile.lumpiness * (n - 0.5) * 1.8;
          if (lumpMul < 0) lumpMul = 0;
        }

        // Drybrush gate: high tooth (peaks) catch paint first; valleys only as
        // coverage approaches 1.
        double toothGate = 1.0;
        if (gateTooth) {
          final double toothN = (canvasHeight[i] * invToothAmp).clamp(0.0, 1.0);
          toothGate =
              _smoothstep(toothThresh - 0.18, toothThresh + 0.06, toothN);
          if (toothGate <= 0) continue;
        }

        final double add = w * k * profile.body * lumpMul * toothGate;
        thickness[i] += add;
        _wetTouch(x, y);

        // Coverage drives how strongly the new pigment tints the surface.
        // Mixing is subtractive (Kubelka-Munk per channel) so pigments blend
        // like paint — blue + yellow makes green, not muddy grey.
        final double cover = (add * 6.0 * profile.opacity).clamp(0.0, 1.0);
        r[i] = _kmMix(r[i], pr, cover);
        g[i] = _kmMix(g[i], pg, cover);
        b[i] = _kmMix(b[i], pb, cover);
        _touch(x, y);
      }
    }
  }

  /// Read-only sample of the wet paint under ([cx],[cy]): the thickness-weighted
  /// average surface colour goes into [outRgb], and the total thickness present
  /// is returned. Used for wet-on-wet colour pickup — it does NOT remove paint,
  /// so strokes blend without destroying material and the brush load only ever
  /// drains.
  double sampleColor(double cx, double cy, double radius, List<double> outRgb) {
    final int x0 = math.max(0, (cx - radius).floor());
    final int x1 = math.min(width - 1, (cx + radius).ceil());
    final int y0 = math.max(0, (cy - radius).floor());
    final int y1 = math.min(height - 1, (cy + radius).ceil());
    if (x0 > x1 || y0 > y1) return 0;

    double wr = 0, wg = 0, wb = 0, wsum = 0, total = 0;
    final double invR2 = 1.0 / (radius * radius);
    for (int y = y0; y <= y1; y++) {
      final double dy = y - cy;
      for (int x = x0; x <= x1; x++) {
        final double dx = x - cx;
        final double t = (dx * dx + dy * dy) * invR2;
        if (t > 1.0) continue;
        final int i = y * width + x;
        final double th = thickness[i];
        if (th <= 0) continue;
        final double w = (1.0 - t) * th; // weight by how much paint is there
        wr += r[i] * w;
        wg += g[i] * w;
        wb += b[i] * w;
        wsum += w;
        total += th;
      }
    }
    if (wsum > 0) {
      outRgb[0] = wr / wsum;
      outRgb[1] = wg / wsum;
      outRgb[2] = wb / wsum;
    }
    return total;
  }

  /// Remove [fraction] of the paint thickness in a dab at ([cx],[cy]) and return
  /// the total amount removed, with its thickness-weighted colour in [outRgb].
  /// Pair with [pile] to push paint around (a bristle plowing wet paint).
  double scrape(double cx, double cy, double radius, double fraction,
      List<double> outRgb) {
    final int x0 = math.max(0, (cx - radius).floor());
    final int x1 = math.min(width - 1, (cx + radius).ceil());
    final int y0 = math.max(0, (cy - radius).floor());
    final int y1 = math.min(height - 1, (cy + radius).ceil());
    if (x0 > x1 || y0 > y1) return 0;

    double wr = 0, wg = 0, wb = 0, removed = 0;
    final double invR2 = 1.0 / (radius * radius);
    for (int y = y0; y <= y1; y++) {
      final double dy = y - cy;
      for (int x = x0; x <= x1; x++) {
        final double dx = x - cx;
        final double t = (dx * dx + dy * dy) * invR2;
        if (t > 1.0) continue;
        final int i = y * width + x;
        final double th = thickness[i];
        if (th <= 0) continue;
        final double take = th * fraction * (1.0 - t);
        thickness[i] = th - take;
        wr += r[i] * take;
        wg += g[i] * take;
        wb += b[i] * take;
        removed += take;
        _touch(x, y);
      }
    }
    if (removed > 0) {
      outRgb[0] = wr / removed;
      outRgb[1] = wg / removed;
      outRgb[2] = wb / removed;
    }
    return removed;
  }

  /// Conservatively add [amount] of thickness (and colour) as a soft dab —
  /// like [deposit] but with no body/lumpiness/tooth modulation, so paint moved
  /// by [scrape] is preserved exactly. Used for paint displacement / ridging.
  void pile(double cx, double cy, double radius, double amount, double pr,
      double pg, double pb) {
    if (amount <= 0) return;
    final int x0 = math.max(0, (cx - radius).floor());
    final int x1 = math.min(width - 1, (cx + radius).ceil());
    final int y0 = math.max(0, (cy - radius).floor());
    final int y1 = math.min(height - 1, (cy + radius).ceil());
    if (x0 > x1 || y0 > y1) return;

    final double invR2 = 1.0 / (radius * radius);
    double wsum = 0;
    for (int y = y0; y <= y1; y++) {
      final double dy = y - cy;
      for (int x = x0; x <= x1; x++) {
        final double dx = x - cx;
        final double t = (dx * dx + dy * dy) * invR2;
        if (t <= 1.0) wsum += (1.0 - t) * (1.0 - t);
      }
    }
    if (wsum <= 0) return;
    final double k = amount / wsum;
    for (int y = y0; y <= y1; y++) {
      final double dy = y - cy;
      for (int x = x0; x <= x1; x++) {
        final double dx = x - cx;
        final double t = (dx * dx + dy * dy) * invR2;
        if (t > 1.0) continue;
        final int i = y * width + x;
        final double add = (1.0 - t) * (1.0 - t) * k;
        thickness[i] += add;
        _wetTouch(x, y);
        final double cover = (add * 6.0).clamp(0.0, 1.0);
        r[i] = _kmMix(r[i], pr, cover);
        g[i] = _kmMix(g[i], pg, cover);
        b[i] = _kmMix(b[i], pb, cover);
        _touch(x, y);
      }
    }
  }

  /// One step of wet-paint flow: wet paint levels downhill (surface tension /
  /// gravity), oozing into neighbours and bleeding colour wet-on-wet, then dries
  /// a little so impasto eventually sets. Conservative — paint is moved, not
  /// created. [flow] is the leveling rate, [dryTime] seconds to mostly dry.
  /// [gravX]/[gravY] are the in-plane gravity vector (cells of drift per step);
  /// non-zero makes wet paint run downhill (drips), on top of the leveling.
  /// [dripYield] is the yield-stress threshold: paint is a yield-stress fluid,
  /// so only thickness ABOVE [dripYield] flows — thinner paint holds, and a drip
  /// leaves a ~[dripYield] film behind, which depletes it and ends the run.
  void flowStep(double dt,
      {double flow = 0.2,
      double dryTime = 3.0,
      double gravX = 0,
      double gravY = 0,
      double dripYield = 0.0,
      double dripWander = 0.0,
      double spinCf = 0.0,
      double spinCor = 0.0,
      double spinCx = 0.0,
      double spinCy = 0.0}) {
    // Spin adds a position-dependent body force: centrifugal (spinCf, outward
    // ∝ radius) flings paint to the rim, Coriolis (spinCor, tangential, signed)
    // curls the outward streaks into spirals like real spin art.
    final bool spin = spinCf != 0 || spinCor != 0;
    final bool grav = gravX != 0 || gravY != 0 || spin;
    if (!_hasWet || (flow <= 0 && !grav)) return;
    // Lateral wander magnitude (cells) — a smooth noise field nudges drips
    // left/right as they fall so they meander and aren't identical.
    final double gMag = math.sqrt(gravX * gravX + gravY * gravY);
    final double wander = grav ? dripWander * gMag : 0.0;
    // Viscosity resists all motion: slower leveling, higher drip yield, slower
    // drips. (Yield-stress / Bingham behaviour of the medium.)
    final double visc = profile.viscosity.clamp(0.1, 10.0);
    final double yld = dripYield * visc;
    final int x0 = math.max(1, _wetMinX);
    final int y0 = math.max(1, _wetMinY);
    final int x1 = math.min(width - 2, _wetMaxX);
    final int y1 = math.min(height - 2, _wetMaxY);
    if (x0 > x1 || y0 > y1) {
      _hasWet = false;
      return;
    }

    final dH = _dH ??= Float32List(width * height);
    final inA = _inA ??= Float32List(width * height);
    final inR = _inR ??= Float32List(width * height);
    final inG = _inG ??= Float32List(width * height);
    final inB = _inB ??= Float32List(width * height);
    final inW = _inW ??= Float32List(width * height); // incoming wetness × mass

    // Zero scratch over the bbox plus a 1-cell margin (flow writes to neighbours).
    for (int y = y0 - 1; y <= y1 + 1; y++) {
      final int base = y * width;
      for (int x = x0 - 1; x <= x1 + 1; x++) {
        final int i = base + x;
        dH[i] = 0;
        inA[i] = 0;
        inR[i] = 0;
        inG[i] = 0;
        inB[i] = 0;
        inW[i] = 0;
      }
    }

    final double k = (flow / visc).clamp(0.0, 0.2);
    // Every outflow a cell wants is collected first, then the whole set is
    // scaled to fit a single budget (what the cell actually holds), so leveling
    // and gravity can never *together* draw more paint than is present. Without
    // this joint cap, each term stays individually bounded but their sum can
    // exceed the cell's thickness; the clamp-at-zero on apply then turns that
    // over-draw into created paint, which feeds back and blows the field up to
    // Infinity (the "Infinity or NaN toInt" crash). Push-only (each cell pushes
    // downhill to its 4 neighbours) keeps all of a cell's outflow in one place
    // so it can be budgeted; it is equivalent to the old pairwise leveling.
    for (int y = y0; y <= y1; y++) {
      final int base = y * width;
      for (int x = x0; x <= x1; x++) {
        final int i = base + x;
        if (wet[i] <= 0.002) continue;
        final double hi = thickness[i];
        final double weti = wet[i];

        // Leveling: push to any lower 4-neighbour, gated by this cell's wetness.
        double oL = 0, oR = 0, oU = 0, oD = 0;
        if (k > 0 && weti > 0.002) {
          final double kw = k * weti;
          final double hl = thickness[i - 1];
          final double hr = thickness[i + 1];
          final double hu = thickness[i - width];
          final double hd = thickness[i + width];
          if (hi > hl) oL = kw * (hi - hl);
          if (hi > hr) oR = kw * (hi - hr);
          if (hi > hu) oU = kw * (hi - hu);
          if (hi > hd) oD = kw * (hi - hd);
        }

        // Body force (yield-stress): only paint ABOVE the holding film
        // (thickness − yld) is mobile; it slides into the downstream
        // neighbour(s), leaving the film behind. Thin paint holds. The drift
        // vector is uniform gravity plus — when the canvas is spinning — a
        // position-dependent centrifugal (outward from the pivot) and Coriolis
        // (tangential) term.
        double gX = 0, gY = 0;
        int gXj = i, gYj = i;
        if (grav) {
          final double mobile = hi - yld;
          if (mobile > 0) {
            final double wi = weti / visc; // viscous paint runs slower
            double dgx = gravX;
            double dgy = gravY;
            if (spin) {
              final double rx = x - spinCx;
              final double ry = y - spinCy;
              // Centrifugal ∝ ω²·r pushes straight out; Coriolis ∝ ω is
              // perpendicular, so the outward run curls into a spiral (its sign
              // is the spin direction).
              dgx += spinCf * rx + spinCor * ry;
              dgy += spinCf * ry - spinCor * rx;
            }
            // Smooth low-frequency wander so drips meander instead of running
            // dead-straight.
            if (wander > 0) {
              final double nz = valueNoise(x * 0.03 + dripPhase, y * 0.06);
              dgx += (nz - 0.5) * 2.0 * wander;
            }
            final double gcap = mobile * 0.7; // body force alone keeps the film
            if (dgx != 0) {
              gXj = dgx > 0 ? i + 1 : i - 1;
              gX = dgx.abs() * mobile * wi;
              if (gX > gcap) gX = gcap;
            }
            if (dgy != 0) {
              gYj = dgy > 0 ? i + width : i - width;
              gY = dgy.abs() * mobile * wi;
              if (gY > gcap) gY = gcap;
            }
          }
        }

        // Joint budget: total outflow can't exceed what the cell holds. Leave a
        // sliver behind so a cell never fully empties in one step (stability).
        double out = oL + oR + oU + oD + gX + gY;
        if (out <= 0) continue;
        final double budget = hi * 0.85;
        if (out > budget) {
          final double s = budget / out;
          oL *= s;
          oR *= s;
          oU *= s;
          oD *= s;
          gX *= s;
          gY *= s;
          out = budget;
        }

        dH[i] -= out;
        // All outflow carries this cell's colour and wetness to where it lands.
        final double ri = r[i], gi = g[i], bi = b[i];
        if (oL > 0) {
          final int j = i - 1;
          dH[j] += oL;
          inA[j] += oL;
          inR[j] += oL * ri;
          inG[j] += oL * gi;
          inB[j] += oL * bi;
          inW[j] += oL * weti;
        }
        if (oR > 0) {
          final int j = i + 1;
          dH[j] += oR;
          inA[j] += oR;
          inR[j] += oR * ri;
          inG[j] += oR * gi;
          inB[j] += oR * bi;
          inW[j] += oR * weti;
        }
        if (oU > 0) {
          final int j = i - width;
          dH[j] += oU;
          inA[j] += oU;
          inR[j] += oU * ri;
          inG[j] += oU * gi;
          inB[j] += oU * bi;
          inW[j] += oU * weti;
        }
        if (oD > 0) {
          final int j = i + width;
          dH[j] += oD;
          inA[j] += oD;
          inR[j] += oD * ri;
          inG[j] += oD * gi;
          inB[j] += oD * bi;
          inW[j] += oD * weti;
        }
        if (gX > 0) {
          dH[gXj] += gX;
          inA[gXj] += gX;
          inR[gXj] += gX * ri;
          inG[gXj] += gX * gi;
          inB[gXj] += gX * bi;
          inW[gXj] += gX * weti;
        }
        if (gY > 0) {
          dH[gYj] += gY;
          inA[gYj] += gY;
          inR[gYj] += gY * ri;
          inG[gYj] += gY * gi;
          inB[gYj] += gY * bi;
          inW[gYj] += gY * weti;
        }
      }
    }

    // Apply height/colour/wetness deltas and dry, tracking the wet region.
    final double dryBase = math.max(0.05, dryTime);
    double maxWet = 0;
    int nMinX = width, nMinY = height, nMaxX = 0, nMaxY = 0;
    for (int y = y0 - 1; y <= y1 + 1; y++) {
      final int base = y * width;
      for (int x = x0 - 1; x <= x1 + 1; x++) {
        final int i = base + x;
        final double d = dH[i];
        final double ia = inA[i];
        if (d != 0) {
          double nt = thickness[i] + d;
          if (nt < 0) nt = 0;
          thickness[i] = nt;
        }
        if (ia > 0) {
          // Mass-weighted: colour AND wetness follow the moving paint, so the
          // pigment travels with the drip (no detached outline).
          final double nt = thickness[i];
          final double frac = (ia / (nt + 1e-6)).clamp(0.0, 1.0);
          r[i] = _kmMix(r[i], inR[i] / ia, frac);
          g[i] = _kmMix(g[i], inG[i] / ia, frac);
          b[i] = _kmMix(b[i], inB[i] / ia, frac);
          wet[i] += (inW[i] / ia - wet[i]) * frac;
        }
        if (d != 0 || ia > 0) _touch(x, y);

        double w = wet[i];
        if (w > 0) {
          // Thicker paint dries slower (more volume → longer to set), so big
          // pools stay wet (and keep dripping) while thin trails dry and stop.
          // Thicker paint dries slower (bigger pools stay wet), but cap the
          // slowdown so even heavy impasto dries in bounded time instead of
          // staying wet — and simulated — for minutes.
          final double localDry = math.exp(
              -dt / (dryBase * (1.0 + math.min(thickness[i] * 8.0, 3.0))));
          w *= localDry;
          // Drop near-dry paint from the wet set decisively: below this it
          // barely flows (the flow gate is 0.002), so keeping it wet only
          // bloats the simulated region and its bounding box.
          if (w < 0.02) w = 0;
          wet[i] = w;
          if (w > 0) {
            if (x < nMinX) nMinX = x;
            if (y < nMinY) nMinY = y;
            if (x > nMaxX) nMaxX = x;
            if (y > nMaxY) nMaxY = y;
            if (w > maxWet) maxWet = w;
          }
        }
      }
    }
    if (maxWet <= 0) {
      _hasWet = false;
    } else {
      _wetMinX = nMinX;
      _wetMinY = nMinY;
      _wetMaxX = nMaxX;
      _wetMaxY = nMaxY;
    }
  }

  /// Resample the paint from [src] into this grid (bilinear), so a resolution
  /// change preserves the current painting instead of clearing it. Only the
  /// paint layers move here (thickness / colour / wetness); the canvas substrate
  /// is regenerated separately by the caller. Recomputes the wet bounding box so
  /// the flow sim keeps working after the swap.
  void resampleFrom(PaintGrid src) {
    final double fx = src.width / width;
    final double fy = src.height / height;
    bool anyWet = false;
    int minX = width, minY = height, maxX = 0, maxY = 0;
    for (int y = 0; y < height; y++) {
      double syf = (y + 0.5) * fy - 0.5;
      if (syf < 0) syf = 0;
      if (syf > src.height - 1) syf = src.height - 1.0;
      final int sy0 = syf.floor();
      final int sy1 = math.min(sy0 + 1, src.height - 1);
      final double wy = syf - sy0;
      for (int x = 0; x < width; x++) {
        double sxf = (x + 0.5) * fx - 0.5;
        if (sxf < 0) sxf = 0;
        if (sxf > src.width - 1) sxf = src.width - 1.0;
        final int sx0 = sxf.floor();
        final int sx1 = math.min(sx0 + 1, src.width - 1);
        final double wx = sxf - sx0;

        final int i00 = sy0 * src.width + sx0;
        final int i01 = sy0 * src.width + sx1;
        final int i10 = sy1 * src.width + sx0;
        final int i11 = sy1 * src.width + sx1;
        final double w00 = (1 - wx) * (1 - wy);
        final double w01 = wx * (1 - wy);
        final double w10 = (1 - wx) * wy;
        final double w11 = wx * wy;

        final int di = y * width + x;
        thickness[di] = src.thickness[i00] * w00 +
            src.thickness[i01] * w01 +
            src.thickness[i10] * w10 +
            src.thickness[i11] * w11;
        r[di] = src.r[i00] * w00 +
            src.r[i01] * w01 +
            src.r[i10] * w10 +
            src.r[i11] * w11;
        g[di] = src.g[i00] * w00 +
            src.g[i01] * w01 +
            src.g[i10] * w10 +
            src.g[i11] * w11;
        b[di] = src.b[i00] * w00 +
            src.b[i01] * w01 +
            src.b[i10] * w10 +
            src.b[i11] * w11;
        final double wv = src.wet[i00] * w00 +
            src.wet[i01] * w01 +
            src.wet[i10] * w10 +
            src.wet[i11] * w11;
        wet[di] = wv;
        if (wv > 0.004) {
          anyWet = true;
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
    }
    _hasWet = anyWet;
    if (anyWet) {
      _wetMinX = minX;
      _wetMinY = minY;
      _wetMaxX = maxX;
      _wetMaxY = maxY;
    }
    _dirtyAll();
  }

  // --- texture encoding for the relief shader ---

  /// RGBA8 buffer with thickness packed 16-bit into R (high) + G (low).
  // Encode window: the reused packed buffer stays fully valid frame-to-frame, so
  // only the dirty rect needs re-packing (a brush dab touches a tiny fraction of
  // the grid). Full-pack when the buffer was just allocated or the whole grid
  // was invalidated (clear/resample/canvas rebuild). Returns null when nothing
  // changed and the buffer is already current.
  ({int x0, int y0, int x1, int y1})? _encodeWindow(bool fresh) {
    if (!fresh && !_dirty) return null; // buffer already current
    final bool full = fresh ||
        (_dirtyMinX <= 0 &&
            _dirtyMinY <= 0 &&
            _dirtyMaxX >= width &&
            _dirtyMaxY >= height);
    if (full) return (x0: 0, y0: 0, x1: width, y1: height);
    return (
      x0: _dirtyMinX.clamp(0, width),
      y0: _dirtyMinY.clamp(0, height),
      x1: _dirtyMaxX.clamp(0, width),
      y1: _dirtyMaxY.clamp(0, height),
    );
  }

  Uint8List encodeHeightRGBA() {
    final bool fresh = _heightBuf == null;
    final out = _heightBuf ??= Uint8List(width * height * 4);
    final w = _encodeWindow(fresh);
    if (w == null) return out;
    final double inv = 1.0 / maxHeight;
    for (int y = w.y0; y < w.y1; y++) {
      int i = y * width + w.x0;
      int p = i * 4;
      for (int x = w.x0; x < w.x1; x++, i++, p += 4) {
        double h = (canvasHeight[i] + thickness[i]) * inv;
        // `!(h > 0)` is deliberately written so it also catches NaN (every
        // comparison with NaN is false), which a plain `h < 0` clamp would let
        // slip through to `.round()` and crash the renderer every frame.
        if (!(h > 0)) {
          h = 0;
        } else if (h > 1) {
          h = 1;
        }
        final int q = (h * 65535.0).round();
        out[p] = (q >> 8) & 0xFF;
        out[p + 1] = q & 0xFF;
        out[p + 2] = 0;
        out[p + 3] = 255;
      }
    }
    return out;
  }

  /// RGBA8 buffer of the surface pigment colour.
  Uint8List encodeAlbedoRGBA() {
    final bool fresh = _albedoBuf == null;
    final out = _albedoBuf ??= Uint8List(width * height * 4);
    final w = _encodeWindow(fresh);
    if (w == null) return out;
    for (int y = w.y0; y < w.y1; y++) {
      int i = y * width + w.x0;
      int p = i * 4;
      for (int x = w.x0; x < w.x1; x++, i++, p += 4) {
        // _u8 clamps and rejects non-finite values, so a stray NaN can't crash
        // `.round()` here either.
        out[p] = _u8(r[i]);
        out[p + 1] = _u8(g[i]);
        out[p + 2] = _u8(b[i]);
        out[p + 3] = 255;
      }
    }
    return out;
  }
}

// --- Kubelka-Munk subtractive colour mixing ---
//
// Treat each RGB channel as a reflectance and mix in K/S (absorption over
// scattering) space, which is how real pigments combine. Mixing [base] with
// pigment [pig] at concentration [t] (0..1).

/// Channel value (0..1) → 0..255, rejecting non-finite values so a stray
/// NaN/Infinity can never reach `.round()` and crash the renderer.
int _u8(double v) {
  if (!(v > 0)) return 0; // NaN or ≤0
  if (v >= 1) return 255;
  return (v * 255.0).round();
}

double _smoothstep(double edge0, double edge1, double x) {
  if (edge1 <= edge0) return x >= edge1 ? 1.0 : 0.0;
  final double t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

double _ks(double reflectance) {
  final double r = reflectance.clamp(0.004, 1.0);
  return (1.0 - r) * (1.0 - r) / (2.0 * r);
}

double _unKs(double ks) => 1.0 + ks - math.sqrt(ks * ks + 2.0 * ks);

double _kmMix(double base, double pig, double t) {
  if (t <= 0) return base;
  final double ks = _ks(base) * (1.0 - t) + _ks(pig) * t;
  return _unKs(ks).clamp(0.0, 1.0);
}
