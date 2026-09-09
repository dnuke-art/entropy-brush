// Visual probe: what do wet strokes look like after they flow — with gravity
// drips on and off? Renders thickness (grey) and colour frames as PPM so the
// drip morphology (rivulets, striping, spreading) can be eyeballed.
// Run: dart run test/drip_shape_probe.dart <outdir>
//      then: mogrify -format png <outdir>/*.ppm
// Mirrors PaintController.frame()'s flow dispatch (iters, flowK, gy, yield,
// wander) so the shapes match the app, not a synthetic setup.
import 'dart:io';
import 'dart:math' as math;

import 'package:entropy_brush/sim/brush.dart';
import 'package:entropy_brush/sim/paint_grid.dart';

const int n = 512;
const double frameDt = 1 / 60;

void paintStrokes(PaintGrid grid, Brush brush) {
  // Three horizontal strokes of different pigments, like a quick test scribble.
  final pigs = [
    [0.12, 0.20, 0.62, 0.5],
    [0.78, 0.12, 0.10, 0.6],
    [0.95, 0.94, 0.90, 4.0],
  ];
  for (int k = 0; k < 3; k++) {
    final p = pigs[k];
    brush.setPigment(p[0], p[1], p[2], p[3]);
    brush.reload();
    final double y = n * (0.25 + 0.12 * k);
    brush.begin(StrokeSample(n * 0.2, y, pressure: 0.8));
    const int steps = 240;
    for (int i = 1; i <= steps; i++) {
      final double t = i / steps;
      brush.step(
          StrokeSample(n * 0.2 + n * 0.6 * t, y + math.sin(t * 6) * 6,
              pressure: 0.8),
          1 / 120,
          grid);
    }
    brush.end();
  }
}

void pourBlobs(PaintGrid grid) {
  // Thick pour-mode style blobs (well above the drip yield) so they run.
  grid.pile(n * 0.3, n * 0.25, 14, 60, 0.12, 0.20, 0.62, ps: 0.5);
  grid.pile(n * 0.55, n * 0.22, 18, 120, 0.78, 0.12, 0.10, ps: 0.6);
  grid.pile(n * 0.75, n * 0.28, 12, 40, 0.95, 0.94, 0.90, ps: 4.0);
}

void flow(PaintGrid grid,
    {required bool gravity,
    required double seconds,
    double dripWander = 0.4}) {
  const double flowRate = 0.4, gravityStrength = 1.0, dripYield = 0.07;
  const double dryTime = 3.0;
  final int iters = math.max(1, (flowRate * 6).round());
  final double flowK = gravity ? 0.03 : 0.2;
  final double gy = gravity ? 1.3 * gravityStrength / iters : 0.0;
  final int frames = (seconds / frameDt).round();
  for (int f = 0; f < frames; f++) {
    for (int it = 0; it < iters; it++) {
      grid.flowStep(frameDt / iters,
          flow: flowK,
          dryTime: dryTime,
          gravY: gy,
          dripYield: dripYield,
          dripWander: dripWander);
    }
  }
}

void dump(PaintGrid g, String path) {
  final sb = BytesBuilder();
  sb.add('P6\n${g.width} ${g.height}\n255\n'.codeUnits);
  double maxT = 0;
  for (final t in g.thickness) {
    if (t > maxT) maxT = t;
  }
  for (int i = 0; i < g.width * g.height; i++) {
    // Colour, darkened by relief so ridges/rivulets read.
    final double shade = 0.55 + 0.45 * (g.thickness[i] / (maxT + 1e-9));
    sb.addByte((g.r[i] * shade * 255).round().clamp(0, 255));
    sb.addByte((g.g[i] * shade * 255).round().clamp(0, 255));
    sb.addByte((g.b[i] * shade * 255).round().clamp(0, 255));
  }
  File(path).writeAsBytesSync(sb.takeBytes());
  final tb = BytesBuilder();
  tb.add('P5\n${g.width} ${g.height}\n255\n'.codeUnits);
  for (final t in g.thickness) {
    tb.addByte((math.sqrt(t / (maxT + 1e-9)) * 255).round().clamp(0, 255));
  }
  File(path.replaceFirst('.ppm', '_h.pgm')).writeAsBytesSync(tb.takeBytes());
}

void main(List<String> args) {
  final out = args.isNotEmpty ? args[0] : '/tmp/drip_probe';
  Directory(out).createSync(recursive: true);
  // (tag, gravity on?, pour blobs instead of strokes?, drip wander)
  final scenarios = [
    ('level', false, false, 0.4),
    ('grav', true, false, 0.4),
    ('pour', true, true, 0.4),
    ('pour_nowander', true, true, 0.0),
  ];
  for (final (tag, gravity, pour, wander) in scenarios) {
    final grid = PaintGrid(n, n);
    if (pour) {
      pourBlobs(grid);
    } else {
      final brush = Brush(BrushConfig());
      brush.config.infiniteLoad = true;
      paintStrokes(grid, brush);
    }
    dump(grid, '$out/${tag}_t0.ppm');
    double t = 0;
    for (final stop in [0.5, 1.5, 4.0]) {
      flow(grid, gravity: gravity, seconds: stop - t, dripWander: wander);
      t = stop;
      dump(grid, '$out/${tag}_t${stop.toStringAsFixed(1)}.ppm');
    }
    double peak = 0;
    for (final th in grid.thickness) {
      if (th > peak) peak = th;
    }
    print('$tag: wetArea=${grid.wetArea} hasWet=${grid.hasWet} '
        'peak=${peak.toStringAsFixed(3)}');
  }
}
