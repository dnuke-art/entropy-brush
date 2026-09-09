// Two-constant Kubelka-Munk colour checks (the reason for the per-cell S
// channel). Run: dart run test/km2_color_test.dart
//
// The single-constant mix (average K/S) failed both of these: white barely
// lightened anything and complements collapsed to near-black — the "everything
// ends up brown" complaint.
import 'package:entropy_brush/sim/paint_grid.dart';

// Pigments as in the control panel: (r, g, b, S).
const red = [0.78, 0.12, 0.10, 0.6];
const blue = [0.12, 0.20, 0.62, 0.5];
const yellow = [0.92, 0.78, 0.12, 0.6];
const white = [0.95, 0.94, 0.90, 4.0];

List<double> mixOnCanvas(List<double> a, List<double> b, double coverB) {
  final g = PaintGrid(9, 9);
  // Radius 1 at an integer centre puts all the volume in one cell, so the
  // per-cell "add" equals volume·body and cover = add·6·opacity. Fully cover
  // the centre with A, then lay B on top at exactly [coverB].
  g.deposit(4, 4, 1.0, 5.0, a[0], a[1], a[2], coverage: 1.0, ps: a[3]);
  final double vol = coverB / (6.0 * g.profile.body * g.profile.opacity);
  g.deposit(4, 4, 1.0, vol, b[0], b[1], b[2], coverage: 1.0, ps: b[3]);
  final int i = 4 * 9 + 4;
  return [g.r[i], g.g[i], g.b[i]];
}

double lum(List<double> c) => 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
String fmt(List<double> c) =>
    '(${c[0].toStringAsFixed(2)}, ${c[1].toStringAsFixed(2)}, ${c[2].toStringAsFixed(2)})';

void main() {
  final rw = mixOnCanvas(red, white, 0.5);
  final rb = mixOnCanvas(red, blue, 0.5);
  final by = mixOnCanvas(blue, yellow, 0.5);
  final redAlone = mixOnCanvas(red, red, 0.5);

  final bool tints = lum(rw) > lum(redAlone) * 1.8; // white makes a real pink
  final bool pinkNotGrey = rw[0] > rw[1] + 0.15; // ...and it's still reddish
  // Cadmium red + ultramarine are mutual absorbers, so the real mix is a dark
  // maroon (painters reach for alizarin/quinacridone for violets). We only
  // require it not to be black, and not to have browned (green ≤ blue).
  final bool purpleNotBlack = rb.reduce((a, b) => a > b ? a : b) > 0.12;
  final bool notBrown = rb[2] >= rb[1] - 0.01;
  final bool greenish = by[1] > by[0] && by[1] > by[2];

  print('red alone          ${fmt(redAlone)}  L=${lum(redAlone).toStringAsFixed(3)}');
  print('red + white        ${fmt(rw)}  L=${lum(rw).toStringAsFixed(3)}');
  print('red + ultramarine  ${fmt(rb)}');
  print('ultramarine + yel  ${fmt(by)}');
  print('white tints red (lum x1.8+):    $tints');
  print('tint stays pink, not grey:      $pinkNotGrey');
  print('red+blue is maroon, not black:  $purpleNotBlack');
  print('red+blue has not browned:       $notBrown');
  print('blue+yellow leans green:        $greenish');
  final ok = tints && pinkNotGrey && purpleNotBlack && notBrown && greenish;
  print(ok ? 'PASS' : 'FAIL');
}
