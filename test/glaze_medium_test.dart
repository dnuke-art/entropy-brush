// Glazing medium (K≈0, S≈0.05): transparent on its own, dilutes pigment when
// mixed. Run: dart run test/glaze_medium_test.dart
import 'package:entropy_brush/sim/paint_grid.dart';

const red = [0.78, 0.12, 0.10, 0.6];
const medium = [1.0, 1.0, 1.0, 0.05];

List<double> cell(PaintGrid g) {
  const int i = 4 * 9 + 4;
  return [g.r[i], g.g[i], g.b[i], g.s[i]];
}

String fmt(List<double> c) =>
    '(${c.take(3).map((v) => v.toStringAsFixed(2)).join(', ')})';

void main() {
  // 1. A heavy stroke of pure medium over red must leave it red, not white.
  final g1 = PaintGrid(9, 9);
  g1.deposit(4, 4, 1.0, 5.0, red[0], red[1], red[2], ps: red[3]);
  final before = cell(g1);
  for (int k = 0; k < 5; k++) {
    g1.deposit(4, 4, 1.0, 5.0, medium[0], medium[1], medium[2], ps: medium[3]);
  }
  final after = cell(g1);
  final bool staysRed = (after[0] - before[0]).abs() < 0.02 &&
      (after[1] - before[1]).abs() < 0.02 &&
      after[3] < 0.2; // ...but its composition is now mostly medium

  // 2. Medium over bare canvas barely changes its colour.
  final g2 = PaintGrid(9, 9);
  g2.deposit(4, 4, 1.0, 5.0, medium[0], medium[1], medium[2], ps: medium[3]);
  final canvas = cell(g2);
  final bool canvasKept = (canvas[0] - PaintGrid.canvasR).abs() < 0.05 &&
      (canvas[2] - PaintGrid.canvasB).abs() < 0.05;

  // 3. Red diluted 3:1 with medium (as on the palette) laid over canvas at
  //    partial coverage reads as a paler wash than undiluted red would.
  List<double> wash(double pigS) {
    final g = PaintGrid(9, 9);
    final double vol = 0.5 / (6.0 * g.profile.body * g.profile.opacity);
    g.deposit(4, 4, 1.0, vol, red[0], red[1], red[2], ps: pigS);
    return cell(g);
  }

  final body = wash(0.6);
  final diluted = wash(0.6 * 0.25 + 0.05 * 0.75); // S of a 1:3 red:medium mix
  final bool paler = diluted[1] > body[1] + 0.08 && diluted[0] > body[0];

  print('red, then 5 heavy coats of medium: ${fmt(before)} -> ${fmt(after)}');
  print('medium over bare canvas:            ${fmt(canvas)}');
  print('half-cover red: body ${fmt(body)}  diluted ${fmt(diluted)}');
  print('medium does not whiten red:   $staysRed');
  print('medium leaves canvas alone:   $canvasKept');
  print('diluted red is a paler wash:  $paler');
  print(staysRed && canvasKept && paler ? 'PASS' : 'FAIL');
}
