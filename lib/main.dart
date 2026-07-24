import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'paint_controller.dart';
import 'sim/paint_grid.dart';
import 'ui/control_panel.dart';
import 'ui/paint_canvas.dart';

void main() {
  runApp(const EntropyBrushApp());
}

class EntropyBrushApp extends StatelessWidget {
  const EntropyBrushApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'entropybrush',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true).copyWith(
        scaffoldBackgroundColor: const Color(0xFF1A1A1D),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
    with SingleTickerProviderStateMixin {
  late final PaintController controller;
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    // Default to a lighter grid on web (incl. VR browsers like Quest), where the
    // CPU sim + CanvasKit image round-trips run ~2–4× costlier than desktop.
    controller = PaintController(
        gridSize:
            kIsWeb ? PaintController.qualityMed : PaintController.qualityHigh);
    _ticker = createTicker((_) => controller.frame());
    _ticker.start();
    _init();
  }

  Future<void> _init() async {
    await controller.attachRenderer();
    // Start with pigment A loaded so the first stroke paints.
    controller.setPigment(0.12, 0.20, 0.62);
    // Default to infinite paint on — never run dry unless the user turns it off.
    controller.brush.config.infiniteLoad = true;
    controller.reloadBrush();
    if (mounted) setState(() {});
    // Dev-only sim micro-benchmark: load with ?bench to time the spin flow step
    // under whatever compiler this bundle is (dart2js vs dart2wasm). Results go
    // to the browser console. Never runs in normal use.
    if (Uri.base.queryParameters.containsKey('bench')) _benchmark();
  }

  /// Time [PaintGrid.flowStep] on a fully-wet grid running the spin body-force
  /// path (the real spin-art hot loop). Reports best-of-N so JIT warmup and
  /// browser clock-clamp noise don't dominate.
  void _benchmark() {
    for (final n in const [512]) {
      final g = PaintGrid(n, n);
      final double cx = n / 2.0, cy = n / 2.0;
      // Cover a big chunk of the grid with thick wet paint so the wet bbox is
      // large (a canvas mid-spin-art, paint flung across most of the surface).
      g.pile(cx, cy, n * 0.38, n * n * 0.02, 0.2, 0.4, 0.8);
      void step() => g.flowStep(1 / 60,
          flow: 0.03,
          dryTime: 1e9, // never dry, so the grid stays fully active across steps
          spinCf: 0.02,
          spinCor: 0.01,
          spinCx: cx,
          spinCy: cy);
      for (int i = 0; i < 15; i++) {
        step(); // warmup
      }
      const int trials = 4, steps = 30;
      double best = double.infinity;
      for (int t = 0; t < trials; t++) {
        final sw = Stopwatch()..start();
        for (int i = 0; i < steps; i++) {
          step();
        }
        sw.stop();
        final double ms = sw.elapsedMicroseconds / 1000.0;
        if (ms < best) best = ms;
      }
      final double perStep = best / steps;
      // ignore: avoid_print
      print('BENCH grid=$n²  ${perStep.toStringAsFixed(3)} ms/step  '
          '(${(1000 / perStep).toStringAsFixed(0)} steps/s, '
          'best ${best.toStringAsFixed(1)} ms / $steps steps)');
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Wide screens (desktop / web / tablet-landscape) show the controls as a
        // fixed sidebar. Narrow screens (phones) tuck them into a slide-out
        // drawer so the canvas gets the whole screen.
        final bool wide = constraints.maxWidth >= 720;
        if (wide) {
          return Scaffold(
            body: SafeArea(
              child: Row(
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: PaintCanvas(controller: controller),
                    ),
                  ),
                  SizedBox(
                    width: 320,
                    child: ControlPanel(controller: controller),
                  ),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          endDrawer: Drawer(
            width: math.min(340, constraints.maxWidth * 0.86),
            backgroundColor: const Color(0xFF1A1A1D),
            child: SafeArea(child: ControlPanel(controller: controller)),
          ),
          body: SafeArea(
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.all(8),
                  child: PaintCanvas(controller: controller),
                ),
                // A pull-tab on the right edge signals the controls drawer and
                // opens it on tap (edge-swipe still works too).
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: Builder(
                      builder: (context) => GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => Scaffold.of(context).openEndDrawer(),
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
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
