import 'dart:math' as math;

import 'package:entropy_brush/sim/paint_grid.dart';

// Diagnostic: after a pure-centrifugal spin from a centred blob, is the flung
// paint spread isotropically, or biased toward the diagonals (i.e. the
// corners)? Compares paint mass in the four axis-aligned 45° sectors against
// the four diagonal 45° sectors (equal total angle, so isotropic ≈ 1.0; a
// per-axis force cap biases this above 1). Run: dart run test/spin_isotropy_probe.dart
void main() {
  const n = 256;
  final g = PaintGrid(n, n);
  g.resetDirty();
  final cx = n / 2.0, cy = n / 2.0;
  g.pile(cx, cy, n * 0.06, n * n * 0.01, 0.5, 0.3, 0.2);
  // The app's mobile spin: spinCf = 0.06·w²/iters with w=1.5, iters=3 → 0.045.
  // No Coriolis, so the only "correct" answer is a perfectly radial spread.
  for (int i = 0; i < 180; i++) {
    g.flowStep(1 / 60 / 3,
        flow: 0.03,
        dryTime: 1e9,
        spinCf: 0.045,
        spinCor: 0.0,
        spinCx: cx,
        spinCy: cy);
  }
  double axis = 0, diag = 0;
  for (int y = 0; y < n; y++) {
    for (int x = 0; x < n; x++) {
      final t = g.thicknessAt(x, y);
      if (t <= 0) continue;
      final dx = x - cx, dy = y - cy;
      if (math.sqrt(dx * dx + dy * dy) < n * 0.12) continue; // central remnant
      // Fold the angle into [0°, 45°]: <22.5° is near an axis, else a diagonal.
      double a = (math.atan2(dy, dx).abs() * 180 / math.pi) % 90;
      if (a > 45) a = 90 - a;
      if (a < 22.5) {
        axis += t;
      } else {
        diag += t;
      }
    }
  }
  final ratio = diag / math.max(axis, 1e-9);
  print('flung paint  axis-sectors=${axis.toStringAsFixed(2)}  '
      'diag-sectors=${diag.toStringAsFixed(2)}  '
      'diag/axis=${ratio.toStringAsFixed(3)}  (isotropic ≈ 1.0; >1 = corner bias)');
}
