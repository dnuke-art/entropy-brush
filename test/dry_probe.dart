import 'package:entropy_brush/sim/paint_grid.dart';

// Diagnostic: how long does paint stay wet (and simulated) by thickness?
// Run: dart run test/dry_probe.dart
void main() {
  print('dryTime=3s, dt=1/60, flow=0.2 — steps until paint fully dries:');
  for (final amount in [40.0, 200.0, 800.0, 3000.0]) {
    final g = PaintGrid(256, 256);
    g.resetDirty();
    g.pile(128, 128, 22, amount, 0.5, 0.3, 0.2);
    final peak = g.thicknessAt(128, 128);
    int steps = 0;
    const maxSteps = 60 * 240; // cap at 4 min of sim time
    while (g.hasWet && steps < maxSteps) {
      g.flowStep(1 / 60, flow: 0.2, dryTime: 3.0);
      steps++;
    }
    final tag = g.hasWet
        ? '>${(maxSteps / 60).toStringAsFixed(0)}s (never dried)'
        : '${(steps / 60.0).toStringAsFixed(1)}s';
    print('  amount=${amount.toStringAsFixed(0).padLeft(4)}  '
        'peakThickness=${peak.toStringAsFixed(2).padLeft(5)}  dry-out=$tag');
  }
}
