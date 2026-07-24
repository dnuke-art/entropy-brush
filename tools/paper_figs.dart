// Reproducible figure data for the paper. Drives the REAL headless sim
// (Flutter-free lib/sim) deterministically and dumps height + albedo fields and
// an STL, so paper/figures/gen_figures.py can render them. No GPU/app needed.
//
//   dart run tools/paper_figs.dart          # writes paper/figures/data/*
//
// Provenance: this script + gen_figures.py fully regenerate every figure.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:entropy_brush/sim/brush.dart';
import 'package:entropy_brush/sim/paint_grid.dart';
import 'package:entropy_brush/export/stl_export.dart';

const int N = 512;
const double dt = 1.0 / 120.0;
const String outDir = 'paper/figures/data';

/// height field actually rendered/exported = substrate + paint.
Float32List heightField(PaintGrid g) {
  final out = Float32List(g.width * g.height);
  for (int i = 0; i < out.length; i++) {
    out[i] = g.canvasHeight[i] + g.thickness[i];
  }
  return out;
}

void _writeHeader(RandomAccessFile f, int w, int h) {
  final hdr = ByteData(8)
    ..setInt32(0, w, Endian.little)
    ..setInt32(4, h, Endian.little);
  f.writeFromSync(hdr.buffer.asUint8List());
}

void dumpField(String path, int w, int h, Float32List data) {
  final f = File(path).openSync(mode: FileMode.write);
  _writeHeader(f, w, h);
  f.writeFromSync(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes));
  f.closeSync();
}

/// Surface pigment colour (linear RGB), interleaved r,g,b per cell.
void dumpAlbedo(String path, PaintGrid g) {
  final n = g.width * g.height;
  final data = Float32List(n * 3);
  for (int i = 0; i < n; i++) {
    data[i * 3] = g.r[i];
    data[i * 3 + 1] = g.g[i];
    data[i * 3 + 2] = g.b[i];
  }
  final f = File(path).openSync(mode: FileMode.write);
  _writeHeader(f, g.width, g.height);
  f.writeFromSync(data.buffer.asUint8List());
  f.closeSync();
}

/// Paint one straight stroke, substepping like the app does.
void stroke(Brush b, PaintGrid g, double x0, double y0, double x1, double y1,
    double pr) {
  b.begin(StrokeSample(x0, y0, pressure: pr));
  final double dx = x1 - x0, dy = y1 - y0;
  final int steps = (math.sqrt(dx * dx + dy * dy) / 1.5).ceil().clamp(1, 4096);
  for (int k = 1; k <= steps; k++) {
    final double t = k / steps;
    b.step(StrokeSample(x0 + dx * t, y0 + dy * t, pressure: pr), dt, g);
  }
  b.end();
}

/// A fixed little composition — deterministic (fixed brush seed + scripted ops).
/// Buttery paint (higher body) over a subtle tooth so strokes read clearly.
void paintScene(PaintGrid g) {
  g.generateCanvasTexture(amplitude: 0.04); // softer weave for legibility
  g.profile = g.profile..body = 1.7;
  final b = Brush(BrushConfig(loadCapacity: 2.4, mileage: 0.8, depositRate: 3.2),
      seed: 7);
  b.setPigment(0.12, 0.20, 0.62); // ultramarine
  b.reload();
  stroke(b, g, 90, 150, 300, 130, 0.95);
  stroke(b, g, 300, 130, 420, 210, 0.9);
  b.setPigment(0.78, 0.12, 0.10); // cadmium red
  b.reload();
  stroke(b, g, 120, 300, 260, 250, 0.95);
  stroke(b, g, 260, 250, 400, 320, 0.85);
  b.setPigment(0.92, 0.78, 0.12); // cadmium yellow
  b.reload();
  stroke(b, g, 150, 380, 360, 400, 1.0);
  for (int i = 0; i < 30; i++) {
    g.flowStep(dt, flow: 0.4, dryTime: 3.0);
  }
}

void main() {
  Directory(outDir).createSync(recursive: true);

  // 1) Main painted scene (impasto + dual-geometry figures).
  final scene = PaintGrid(N, N);
  paintScene(scene);
  dumpField('$outDir/scene_height.bin', N, N, heightField(scene));
  dumpAlbedo('$outDir/scene_albedo.bin', scene);
  File('$outDir/scene.stl').writeAsBytesSync(
      buildStl(scene, resolution: 256, sizeMm: 100, reliefMm: 6, baseMm: 2));

  // 2) Determinism: same scripted performance twice; fixed timestep => the
  //    fields are bit-identical (supports determinism + the fixed-timestep
  //    "bit-exact replay" future-work point).
  final a = PaintGrid(N, N);
  final bb = PaintGrid(N, N);
  paintScene(a);
  paintScene(bb);
  final ha = heightField(a), hb = heightField(bb);
  double maxDiff = 0;
  for (int i = 0; i < ha.length; i++) {
    final d = (ha[i] - hb[i]).abs();
    if (d > maxDiff) maxDiff = d;
  }
  dumpField('$outDir/det_a.bin', N, N, ha);
  dumpField('$outDir/det_b.bin', N, N, hb);
  dumpAlbedo('$outDir/det_a_albedo.bin', a);
  dumpAlbedo('$outDir/det_b_albedo.bin', bb);
  stderr.writeln('determinism max|A-B| = $maxDiff  (expect 0.0)');

  // 3) Spin art: thick off-centre wet blobs flung by centrifugal + Coriolis
  //    forces. Thick paint + many substeps => visible spiral streaks.
  final spin = PaintGrid(N, N);
  spin.generateCanvasTexture(amplitude: 0.03);
  final cx = N / 2.0, cy = N / 2.0;
  spin.pile(cx + 55, cy - 25, 24, 260.0, 0.12, 0.20, 0.62); // blue
  spin.pile(cx - 50, cy + 35, 22, 230.0, 0.78, 0.12, 0.10); // red
  spin.pile(cx + 5, cy + 65, 20, 200.0, 0.92, 0.78, 0.12); // yellow
  for (int i = 0; i < 420; i++) {
    spin.flowStep(dt,
        flow: 0.03,
        dryTime: 100000,
        spinCf: 0.024,
        spinCor: 0.015,
        spinCx: cx,
        spinCy: cy);
  }
  dumpField('$outDir/spin_height.bin', N, N, heightField(spin));
  dumpAlbedo('$outDir/spin_albedo.bin', spin);

  stderr.writeln('wrote fields + albedo + STL to $outDir/');
}
