import 'package:entropy_brush/sim/paint_grid.dart';

/// Quick native profile: which synchronous per-frame CPU cost dominates —
/// the flow sim, or the full-grid relief encode? Run: dart run test/perf_probe.dart
double bestMs(int reps, void Function() f) {
  for (int i = 0; i < 5; i++) {
    f(); // warmup
  }
  double best = double.infinity;
  for (int t = 0; t < 8; t++) {
    final sw = Stopwatch()..start();
    for (int i = 0; i < reps; i++) {
      f();
    }
    sw.stop();
    final double ms = sw.elapsedMicroseconds / 1000.0 / reps;
    if (ms < best) best = ms;
  }
  return best;
}

void main() {
  for (final n in const [192, 256, 384, 512]) {
    // A small brush dab → tiny wet bbox (what "normal painting" a stroke is).
    final g = PaintGrid(n, n);
    // Steady state: buffers filled by a first full render, dirt cleared (the
    // renderer calls resetDirty each frame), then one brush dab dirties a tiny
    // rect — the real per-frame interactive cost with dirty-rect encoding.
    g.encodeHeightRGBA();
    g.encodeAlbedoRGBA();
    g.resetDirty();
    g.pile(n * 0.5, n * 0.5, 12, 40, 0.2, 0.4, 0.8);
    final double encH = bestMs(20, () => g.encodeHeightRGBA());
    final double encA = bestMs(20, () => g.encodeAlbedoRGBA());
    final double flowDab = bestMs(20, () => g.flowStep(1 / 60, flow: 0.2, dryTime: 1e9));

    // Flooded spin (worst-case wet region).
    final g2 = PaintGrid(n, n);
    final double c = n / 2.0;
    g2.pile(c, c, n * 0.38, n * n * 0.02, 0.2, 0.4, 0.8);
    final double flowSpin = bestMs(
        10,
        () => g2.flowStep(1 / 60,
            flow: 0.03,
            dryTime: 1e9,
            spinCf: 0.02,
            spinCor: 0.01,
            spinCx: c,
            spinCy: c));

    // ignore: avoid_print
    print('n=$n²  encodeHeight ${encH.toStringAsFixed(2)}ms  '
        'encodeAlbedo ${encA.toStringAsFixed(2)}ms  '
        '(encode total ${(encH + encA).toStringAsFixed(2)}ms/frame)  |  '
        'flow(one dab) ${flowDab.toStringAsFixed(3)}ms  '
        'flow(spin flooded) ${flowSpin.toStringAsFixed(2)}ms');
  }
}
