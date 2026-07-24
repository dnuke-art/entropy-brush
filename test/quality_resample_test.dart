import 'package:entropy_brush/sim/paint_grid.dart';

/// Changing render quality resizes the sim grid, but it must PRESERVE the
/// painting by bilinear-resampling it into the new grid (never clear it).
/// Relief thickness is an intensive height, so peak height and the painted
/// footprint fraction carry across a resize; the normalised centroid stays put;
/// values stay finite; and the wet region is re-established so flow keeps
/// running after the swap.

double peak(PaintGrid g) {
  double m = 0;
  for (final t in g.thickness) {
    if (t > m) m = t;
  }
  return m;
}

/// Fraction of cells carrying paint (footprint ÷ total area).
double coverage(PaintGrid g) {
  int n = 0;
  for (final t in g.thickness) {
    if (t > 0.02) n++;
  }
  return n / (g.width * g.height);
}

/// Thickness-weighted centroid in normalised (0..1) canvas coords.
List<double> centroidUV(PaintGrid g) {
  double t = 0, wx = 0, wy = 0;
  for (int y = 0; y < g.height; y++) {
    for (int x = 0; x < g.width; x++) {
      final double th = g.thickness[y * g.width + x];
      if (th > 1e-6) {
        t += th;
        wx += th * x;
        wy += th * y;
      }
    }
  }
  return t > 0 ? [wx / g.width / t, wy / g.height / t] : [0.5, 0.5];
}

bool allFinite(PaintGrid g) {
  for (final t in g.thickness) {
    if (!t.isFinite) return false;
  }
  return true;
}

void main() {
  // Paint an off-centre blob at a High-ish resolution.
  final hi = PaintGrid(300, 300);
  hi.pile(180, 120, 40, 80.0, 0.2, 0.4, 0.8);
  final double p0 = peak(hi);
  final double cov0 = coverage(hi);
  final List<double> c0 = centroidUV(hi);

  // Down to a Med-ish grid — the painting must survive.
  final lo = PaintGrid(200, 200);
  lo.profile = hi.profile;
  lo.resampleFrom(hi);
  final double p1 = peak(lo);
  final double cov1 = coverage(lo);
  final List<double> c1 = centroidUV(lo);

  // Round-trip back up.
  final hi2 = PaintGrid(300, 300);
  hi2.resampleFrom(lo);
  final double p2 = peak(hi2);

  // The resampled grid must still flow without blowing up (wet bbox valid).
  for (int i = 0; i < 30; i++) {
    lo.flowStep(1 / 60, flow: 0.2, dryTime: 1000);
  }
  final bool flowsFinite = allFinite(lo);

  print('peak     $p0 -> $p1 -> $p2');
  print('coverage ${cov0.toStringAsFixed(4)} -> ${cov1.toStringAsFixed(4)}');
  print('centroid (${c0[0].toStringAsFixed(3)},${c0[1].toStringAsFixed(3)}) -> '
      '(${c1[0].toStringAsFixed(3)},${c1[1].toStringAsFixed(3)})');

  final bool survived = p1 > 0 && cov1 > 0;
  // Bilinear softens the peak a little on downsample, never inflates it.
  final bool peakKept = p1 <= p0 * 1.02 && p1 > p0 * 0.80;
  final bool covKept = (cov1 - cov0).abs() < cov0 * 0.30 + 0.005;
  final bool centroidKept =
      (c1[0] - c0[0]).abs() < 0.02 && (c1[1] - c0[1]).abs() < 0.02;
  final bool finite = allFinite(lo) && allFinite(hi2) && flowsFinite;

  print('painting survived resize: $survived');
  print('peak height preserved:    $peakKept');
  print('footprint preserved:      $covKept');
  print('centroid preserved:       $centroidKept');
  print('finite & flows after:     $finite');

  if (!survived) throw StateError('resize cleared the painting');
  if (!peakKept) throw StateError('relief peak not preserved across resize');
  if (!covKept) throw StateError('painted footprint not preserved');
  if (!centroidKept) throw StateError('painting shifted across resize');
  if (!finite) throw StateError('non-finite after resample/flow');

  print('PASS');
}
