import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'paint_controller.dart';
import 'ui/control_panel.dart';
import 'ui/paint_canvas.dart';

/// App Store screenshot scenes. Each seeds a fresh [PaintController] with a
/// showcase painting, sets a flattering 3D tilt + light, and rebuilds the REAL
/// app layout (iPad: canvas + control panel; iPhone: canvas + drawer) so the capture is the actual app — not
/// a mockup. Driven by integration_test/screenshots_test.dart on an iPad Pro or
/// iPhone Pro Max simulator. Tune the seeds here; re-run `ios-screenshots.yml` to re-capture.
typedef Seed = void Function(PaintController c);

class ScreenshotScene {
  const ScreenshotScene(this.seed,
      {this.tiltX,
      this.tiltY,
      this.azimuth,
      this.elevation,
      this.showControls = false});
  final Seed seed;
  final double? tiltX, tiltY, azimuth, elevation;

  /// On the narrow (phone) layout the controls live in a drawer; set this to
  /// capture the scene with that drawer open so one shot shows the panel.
  final bool showControls;
  Widget build() => _ShotHost(scene: this);
}

final Map<String, ScreenshotScene> screenshotScenes = {
  '01-hero': ScreenshotScene(_seedHero,
      tiltX: 0.42, tiltY: 0.30, azimuth: 2.2, elevation: 0.85),
  '02-spin': ScreenshotScene(_seedSpin,
      tiltX: 0.30, tiltY: 0.10, azimuth: 2.6, elevation: 0.9),
  '03-impasto': ScreenshotScene(_seedImpasto,
      tiltX: 0.66, tiltY: 0.34, azimuth: 3.7, elevation: 0.42),
  '04-mixing': ScreenshotScene(_seedMixing,
      tiltX: 0.40,
      tiltY: 0.26,
      azimuth: 2.0,
      elevation: 0.9,
      showControls: true),
};

// --- scene host: real UI, seeded controller, frozen sim -----------------------

class _ShotHost extends StatefulWidget {
  const _ShotHost({required this.scene});
  final ScreenshotScene scene;
  @override
  State<_ShotHost> createState() => _ShotHostState();
}

class _ShotHostState extends State<_ShotHost> {
  late final PaintController c;
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();
  bool _drawerOpened = false;

  @override
  void initState() {
    super.initState();
    c = PaintController(gridSize: PaintController.qualityHigh);
    _boot();
  }

  Future<void> _boot() async {
    await c.attachRenderer();
    if (c.renderer == null) {
      if (mounted) setState(() {}); // shows the shader-load error, if any
      return;
    }
    c.brush.config.infiniteLoad = true;
    c.flowRate = 0.0;
    c.spinning = false;
    c.gravityDrips = false;
    widget.scene.seed(c);
    final s = widget.scene;
    if (s.tiltX != null) c.tiltX = s.tiltX!;
    if (s.tiltY != null) c.tiltY = s.tiltY!;
    if (s.azimuth != null) c.light.azimuth = s.azimuth!;
    if (s.elevation != null) c.light.elevation = s.elevation!;
    // Render the relief ONCE, awaited. No ticker: a continuously-animating
    // scene deadlocks the integration-test capture surface. renderToImage
    // re-uploads the grid and renders offscreen, so the seeded paint shows.
    final img = await c.renderer!.renderToImage(c.grid, c.light);
    c.reliefImage?.dispose();
    c.reliefImage = img;
    c.viewChanged(); // repaint the static canvas with the finished relief
    if (mounted) setState(() {});
    // Phone layout only: pop the controls drawer for scenes that ask for it.
    if (mounted && widget.scene.showControls && !_drawerOpened) {
      final st = _scaffold.currentState;
      if (st != null && st.hasEndDrawer) {
        _drawerOpened = true;
        st.openEndDrawer();
      }
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Mirror main.dart: wide screens (iPad) get the canvas + fixed control
    // sidebar; narrow screens (iPhone) get a full-bleed canvas with the
    // controls in an end drawer behind a pull tab on the right edge.
    return LayoutBuilder(builder: (context, constraints) {
      final bool wide = constraints.maxWidth >= 720;
      if (wide) {
        return Scaffold(
          backgroundColor: const Color(0xFF1A1A1D),
          body: SafeArea(
            child: Row(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: PaintCanvas(controller: c),
                  ),
                ),
                SizedBox(width: 320, child: ControlPanel(controller: c)),
              ],
            ),
          ),
        );
      }
      return Scaffold(
        key: _scaffold,
        backgroundColor: const Color(0xFF1A1A1D),
        endDrawer: Drawer(
          width: math.min(340, constraints.maxWidth * 0.86),
          backgroundColor: const Color(0xFF1A1A1D),
          child: SafeArea(child: ControlPanel(controller: c)),
        ),
        body: SafeArea(
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: PaintCanvas(controller: c),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                child: Center(
                  child: Container(
                    width: 22,
                    height: 80,
                    alignment: Alignment.center,
                    decoration: const BoxDecoration(
                      color: Color(0xE61C1C20),
                      borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(11),
                        bottomLeft: Radius.circular(11),
                      ),
                      border: Border(
                        top: BorderSide(color: Color(0xFF55555C)),
                        left: BorderSide(color: Color(0xFF55555C)),
                        bottom: BorderSide(color: Color(0xFF55555C)),
                      ),
                    ),
                    child: const Icon(Icons.chevron_left,
                        size: 20, color: Color(0xFFBBBBC4)),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

// --- painting helpers ---------------------------------------------------------

void _stroke(PaintController c, List<Offset> pts, double r, double g, double b,
    {double pressure = 0.9}) {
  c.setPigment(r, g, b);
  c.reloadBrush();
  c.strokeStart(pts.first.dx, pts.first.dy, pressure: pressure);
  for (int i = 1; i < pts.length; i++) {
    c.strokeMove(pts[i].dx, pts[i].dy, pressure: pressure);
  }
  c.strokeEnd();
}

/// Sample a quadratic bezier a→ctrl→b into [n]+1 points.
List<Offset> _curve(Offset a, Offset ctrl, Offset b, {int n = 44}) {
  final pts = <Offset>[];
  for (int i = 0; i <= n; i++) {
    final t = i / n, u = 1 - t;
    pts.add(Offset(
      u * u * a.dx + 2 * u * t * ctrl.dx + t * t * b.dx,
      u * u * a.dy + 2 * u * t * ctrl.dy + t * t * b.dy,
    ));
  }
  return pts;
}

// --- scenes -------------------------------------------------------------------

void _seedHero(PaintController c) {
  final g = c.grid.width.toDouble();
  _stroke(c, _curve(Offset(g * .12, g * .78), Offset(g * .35, g * .30),
      Offset(g * .62, g * .55)), .72, .12, .16); // crimson
  _stroke(c, _curve(Offset(g * .20, g * .32), Offset(g * .55, g * .62),
      Offset(g * .86, g * .28)), .10, .28, .70); // cobalt
  _stroke(c, _curve(Offset(g * .30, g * .70), Offset(g * .55, g * .46),
      Offset(g * .82, g * .72)), .96, .64, .10); // gold
  _stroke(c, _curve(Offset(g * .46, g * .18), Offset(g * .52, g * .50),
      Offset(g * .40, g * .86)), .06, .46, .36); // teal
}

void _seedSpin(PaintController c) {
  final g = c.grid.width.toDouble();
  final cx = g / 2, cy = g / 2;
  const cols = [
    [.78, .12, .20],
    [.12, .30, .72],
    [.97, .66, .12],
    [.10, .52, .40],
  ];
  final rnd = math.Random(3);
  for (int i = 0; i < 12; i++) {
    final ang = i / 12 * 2 * math.pi;
    final rr = g * 0.05 * (1 + rnd.nextDouble());
    final col = cols[i % cols.length];
    c.grid.pile(cx + math.cos(ang) * rr, cy + math.sin(ang) * rr, g * 0.05,
        g * g * 0.004, col[0], col[1], col[2]);
  }
  // Develop the centrifugal spiral deterministically (no wall-clock).
  for (int i = 0; i < 240; i++) {
    c.grid.flowStep(1 / 60,
        flow: 0.03,
        dryTime: 1e9,
        spinCf: 0.05,
        spinCor: 0.02,
        spinCx: cx,
        spinCy: cy);
  }
}

void _seedImpasto(PaintController c) {
  final g = c.grid.width.toDouble();
  const cols = [
    [.72, .16, .20],
    [.94, .56, .10],
    [.14, .30, .62],
    [.10, .50, .36],
    [.58, .20, .52],
  ];
  for (int i = 0; i < cols.length; i++) {
    final y = g * (0.27 + 0.115 * i);
    _stroke(
        c,
        _curve(Offset(g * .20, y), Offset(g * .50, y - g * .05),
            Offset(g * .80, y)),
        cols[i][0],
        cols[i][1],
        cols[i][2],
        pressure: 1.0);
  }
}

void _seedMixing(PaintController c) {
  final g = c.grid.width.toDouble();
  _stroke(c, _curve(Offset(g * .20, g * .42), Offset(g * .50, g * .30),
      Offset(g * .80, g * .44)), .10, .28, .74); // blue
  _stroke(c, _curve(Offset(g * .24, g * .60), Offset(g * .50, g * .50),
      Offset(g * .78, g * .60)), .96, .82, .12); // yellow
  // A vertical yellow stroke crossing the blue makes green where they overlap.
  _stroke(c, _curve(Offset(g * .50, g * .24), Offset(g * .50, g * .50),
      Offset(g * .50, g * .76)), .96, .82, .12);
}
