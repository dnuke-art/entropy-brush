import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'export/exporter.dart';
import 'render/relief_renderer.dart';
import 'sim/brush.dart';
import 'sim/paint_grid.dart';
import 'sim/paint_profile.dart';
import 'twin/camera_input.dart';
import 'twin/spacemouse_input.dart';
import 'twin/twin_performance.dart';

/// Ties the input, the bristle brush, the height-field grid and the relief
/// renderer together. The widget feeds it pointer samples in *grid* coordinates
/// and pumps [frame] once per vsync; everything else lives here.
class PaintController extends ChangeNotifier {
  /// Sim grid resolution presets. Higher = crisper relief but heavier per
  /// frame: both the flow sim and the relief-texture rebuild cost O(size²).
  static const int qualityLow = 384;
  static const int qualityMed = 512;
  static const int qualityHigh = 768;

  PaintController({int gridSize = qualityHigh, int paletteSize = 240})
      : grid = PaintGrid(gridSize, gridSize),
        palette = PaintGrid(paletteSize, paletteSize, maxHeight: 4.0)
          ..profile = PaintProfile(body: 1.0, lumpiness: 0.0, opacity: 1.4)
          ..generateCanvasTexture(amplitude: 0.0), // palette stays smooth
        brush = Brush(BrushConfig()) {
    // Brush geometry is authored in grid px at the High reference resolution;
    // scale it so a stroke covers the same fraction of the canvas at any
    // starting quality (e.g. the lighter web default).
    if (gridSize != qualityHigh) {
      final double ratio = gridSize / qualityHigh;
      brush.config.headRadius *= ratio;
      brush.config.bristleLength *= ratio;
      brush.rebuildBristles();
    }
  }

  PaintGrid grid;
  final Brush brush;
  final LightSettings light = LightSettings();

  /// The mixing palette: a second canvas where pigments blend so you can load
  /// the brush with a custom colour.
  final PaintGrid palette;

  /// Lightly raked lighting for the palette so squeezed blobs of paint read as
  /// dimensional mounds (but flatter than the main canvas).
  final LightSettings paletteLight = LightSettings(
      ambient: 0.78, heightScale: 320, specular: 0.18, elevation: 1.0);

  ReliefRenderer? renderer;
  ReliefRenderer? paletteRenderer;
  bool get rendererReady => renderer?.ready ?? false;

  /// The painting rendered flat to an image; the slab view textures this onto
  /// its top face. Re-rendered when the canvas or light changes.
  ui.Image? reliefImage;
  bool _renderingImage = false;

  /// Canvas slab thickness, as a fraction of the canvas width.
  double canvasThicknessFrac = 0.06;

  void _requestReliefImage() {
    final r = renderer;
    if (r == null || !r.ready || _renderingImage) return;
    _renderingImage = true;
    r.renderToImage(grid, light).then((img) {
      reliefImage?.dispose();
      reliefImage = img;
      _renderingImage = false;
      notifyListeners();
    });
  }

  // --- render quality (sim grid resolution) ---------------------------------
  int get gridQuality => grid.width;

  /// Switch the sim grid to [size]×[size], preserving the current painting by
  /// bilinear-resampling it into the new grid. Both the relief-texture rebuild
  /// and the flow sim cost O(size²), so this is the main performance lever:
  /// lower it for smooth spin/drips on web/VR, raise it for crisper relief.
  void setQuality(int size) {
    if (size == grid.width) return;
    // Don't carry a live stroke/pour across the coordinate-space change.
    if (_stroking) _doEnd();
    _pouring = false;
    final old = grid;
    final double ratio = size / old.width;
    final ng = PaintGrid(size, size, maxHeight: old.maxHeight);
    ng.profile = old.profile; // keep the user's paint (body/viscosity/…) settings
    ng.dripPhase = old.dripPhase;
    ng.generateCanvasTexture(
        amplitude: canvasAmplitude, scale: canvasScale, seed: _canvasSeed);
    ng.resampleFrom(old);
    grid = ng;
    // Keep brush marks the same fraction of the canvas at the new resolution.
    brush.config.headRadius *= ratio;
    brush.config.bristleLength *= ratio;
    brush.rebuildBristles();
    reliefImage?.dispose();
    reliefImage = null;
    _renderingImage = false;
    _reliefAccum = 0;
    _requestReliefImage();
    notifyListeners();
  }

  // --- view: tilt, zoom, pan ---
  // Slight isometric default so the canvas reads as 3D from first load (and on
  // Reset view). tiltX > 0 makes the top edge recede, like it's on a table.
  static const double defaultTiltX = 0.5;
  static const double defaultTiltY = 0.38;
  double tiltX = defaultTiltX; // pitch, radians
  double tiltY = defaultTiltY; // yaw, radians
  double perspective = 0.0012;
  double zoom = 1.0;
  double panX = 0.0;
  double panY = 0.0;
  double canvasRoll = 0.0; // in-plane spin of the canvas (radians)
  double _spinAngle = 0.0; // live rotation accumulated while spinning

  /// The canvas orientation actually shown: the user's set roll plus whatever
  /// the live spin has wound up. Used for both projection and pointer mapping
  /// so clicks still land correctly on the spinning canvas.
  double get displayRoll => canvasRoll + _spinAngle;

  /// Clear the accumulated live spin (canvas returns to its set roll).
  void resetSpin() {
    _spinAngle = 0.0;
    notifyListeners();
  }

  void viewChanged() => notifyListeners();

  // --- canvas substrate texture (Perlin relief) ---
  double canvasAmplitude = 0.08;
  double canvasScale = 0.16;
  int _canvasSeed = 1;

  void applyCanvasTexture() {
    grid.generateCanvasTexture(
        amplitude: canvasAmplitude, scale: canvasScale, seed: _canvasSeed);
    _requestReliefImage();
    notifyListeners();
  }

  void newCanvasTexture() {
    _canvasSeed++;
    applyCanvasTexture();
  }

  /// Direction to the camera expressed in the canvas's own frame, given the
  /// current tilt. Feeds the shader so specular highlights shift with tilt.
  List<double> get viewDir {
    final double cx = math.cos(tiltX);
    return [
      -cx * math.sin(tiltY),
      math.sin(tiltX),
      cx * math.cos(tiltY),
    ];
  }

  void tiltChanged() => notifyListeners();

  // Current pigment, shared by the swatch picker and palette mixing.
  double _curR = 0.12, _curG = 0.20, _curB = 0.62;

  // Fixed simulation step keeps the bristle springs stable regardless of how
  // fast pointer events arrive. Fast strokes simply take more substeps.
  static const double _simDt = 1.0 / 120.0;
  static const double _substepPx = 1.5;
  static const int _maxSubsteps = 64;

  double _pressure = 1.0;
  double get pressure => _pressure;
  set pressure(double v) {
    _pressure = v.clamp(0.05, 1.0);
  }

  bool _hasLast = false;
  double _lastX = 0, _lastY = 0;

  // Stroke-velocity tracking for dwell (slow strokes pool paint → drips).
  final Stopwatch _strokeClock = Stopwatch();
  double _lastMoveT = 0;
  // Replay reconstructs dwell from the recorded op timestamps.
  double _rpLastT = 0, _rpLastX = 0, _rpLastY = 0;

  /// Dwell 0..1 from stroke speed (grid px / s): slow → 1, fast → 0.
  static double _dwell(double dist, double dt) {
    if (dt <= 1e-4) return 0.0;
    final double speed = dist / dt;
    const double kRef = 700.0; // speed at which dwell = 0.5
    return (kRef / (speed + kRef)).clamp(0.0, 1.0);
  }
  bool _stroking = false;

  // --- twin recorder & replay state ---
  final List<TwinOp> _recOps = [];
  final Stopwatch _recClock = Stopwatch();
  bool _recording = false;

  TwinPerformance? _lastPerformance;
  TwinPerformance? get lastPerformance => _lastPerformance;

  TwinPerformance? _replayPerf;
  int _replayIdx = 0;
  final Stopwatch _replayClock = Stopwatch();
  bool _replaying = false;

  bool get recording => _recording;
  bool get replaying => _replaying;

  double get _now => _recording ? _recClock.elapsedMicroseconds / 1e6 : 0.0;
  void _rec(TwinOp op) {
    if (_recording) _recOps.add(op);
  }

  /// Non-null if the relief shader failed to load (e.g. stale asset bundle —
  /// do a full restart, not hot reload). The UI shows this instead of crashing.
  String? rendererError;

  Future<void> attachRenderer() async {
    try {
      renderer = await ReliefRenderer.load();
      await renderer!.uploadTextures(grid);
      paletteRenderer = await ReliefRenderer.load();
      await paletteRenderer!.uploadTextures(palette);
      _requestReliefImage();
    } catch (e) {
      rendererError = 'Could not load relief shader: $e\n'
          'Fully restart the app (stop and re-run; hot reload does not '
          're-bundle assets).';
      debugPrint(rendererError);
    }
    notifyListeners();
  }

  void setPigment(double r, double g, double b) {
    _curR = r;
    _curG = g;
    _curB = b;
    brush.setPigment(r, g, b);
  }

  void reloadBrush() {
    final c = brush.loadColor;
    _rec(TwinOp(_now, TwinOpKind.reload, r: c[0], g: c[1], b: c[2]));
    brush.reload();
  }

  void rebuildBristles() => brush.rebuildBristles();

  // --- input seam -----------------------------------------------------------
  // The public stroke methods are the single point every input source (mouse,
  // stylus, depth-camera arm tracking) feeds into. [pressure] is first-class so
  // a tracker can supply contact force; the mouse falls back to the slider.
  // Each public call records a TwinOp, then drives the sim via a private _do
  // method that replay also calls (without recording).

  void strokeStart(double gx, double gy, {double? pressure}) {
    final pr = pressure ?? _pressure;
    _rec(TwinOp(_now, TwinOpKind.down, x: gx, y: gy, pressure: pr));
    if (pourMode) {
      _pourStart(gx, gy);
      return;
    }
    _doStart(gx, gy, pr);
  }

  void strokeMove(double gx, double gy, {double? pressure}) {
    final pr = pressure ?? _pressure;
    // Real-time dwell: how slowly the brush is moving right now.
    final double now = _strokeClock.elapsedMicroseconds / 1e6;
    final double dt = now - _lastMoveT;
    _lastMoveT = now;
    final double dist =
        math.sqrt((gx - _lastX) * (gx - _lastX) + (gy - _lastY) * (gy - _lastY));
    _rec(TwinOp(_now, TwinOpKind.move, x: gx, y: gy, pressure: pr));
    if (_pouring) {
      _pourMove(gx, gy);
      return;
    }
    _doMove(gx, gy, pr, _dwell(dist, dt));
  }

  void strokeEnd() {
    _rec(TwinOp(_now, TwinOpKind.up));
    if (_pouring) {
      _pourEnd();
      return;
    }
    _doEnd();
  }

  void _doStart(double gx, double gy, double pr) {
    brush.begin(StrokeSample(gx, gy, pressure: pr));
    _lastX = gx;
    _lastY = gy;
    _hasLast = true;
    _stroking = true;
    _strokeClock
      ..reset()
      ..start();
    _lastMoveT = 0;
    brush.dwell = 0;
  }

  void _doMove(double gx, double gy, double pr, [double dwell = 0]) {
    if (!_hasLast) {
      _doStart(gx, gy, pr);
      return;
    }
    brush.dwell = dwell;
    final double dx = gx - _lastX;
    final double dy = gy - _lastY;
    final double dist = math.sqrt(dx * dx + dy * dy);
    final int steps =
        math.max(1, math.min(_maxSubsteps, (dist / _substepPx).ceil()));
    for (int i = 1; i <= steps; i++) {
      final double t = i / steps;
      brush.step(
        StrokeSample(_lastX + dx * t, _lastY + dy * t, pressure: pr),
        _simDt,
        grid,
      );
    }
    _lastX = gx;
    _lastY = gy;
  }

  void _doEnd() {
    // Releasing the brush leaves a pool where it dwelled — drips start here.
    brush.layPool(grid);
    brush.end();
    _stroking = false;
    _hasLast = false;
  }

  // --- pour / squirt mode: flowing liquid paint straight onto the canvas ---
  // No brush, no bristles, no drybrush gating: while the pen is down we keep
  // laying a fully-wet bead at the pen tip that spreads, pools, and (with
  // gravity/spin on) runs. The pen path is still a stroke, so it draws a
  // continuous poured trail — like squeezing paint from a bottle.

  bool pourMode = false; // user toggle: pen pours liquid instead of brushing
  bool _pouring = false;
  double _pourX = 0, _pourY = 0;
  double _pourAccum = 0;
  static const double _pourVolPerFrame = 0.9;
  static const double _pourMaxRadius = 11.0;

  void _pourStart(double gx, double gy) {
    _pouring = true;
    _pourAccum = 0;
    _pourX = gx;
    _pourY = gy;
  }

  void _pourMove(double gx, double gy) {
    _pourX = gx;
    _pourY = gy;
  }

  void _pourEnd() => _pouring = false;

  /// Emit one frame's worth of liquid paint at the pen tip. The bead widens as
  /// it flows (up to a cap) so a held pen mounds a puddle, and a moving pen
  /// draws a thick wet trail. Full coverage → no tooth gating (it floods).
  void _pour() {
    _pourAccum += _pourVolPerFrame;
    final double radius =
        math.min(_pourMaxRadius, 4.0 + math.sqrt(_pourAccum) * 1.2);
    grid.deposit(
        _pourX, _pourY, radius, _pourVolPerFrame, _curR, _curG, _curB);
  }

  void clearCanvas() {
    grid.clear();
    grid.shuffleDrips(); // fresh drip pattern each canvas
    _requestReliefImage();
  }

  // --- palette: mix pigments, then load the brush from the mix ---

  double _palLastX = 0, _palLastY = 0;
  bool _palHasPos = false;

  // Squeezing paint from the tube: while the pen is held on the palette we keep
  // depositing every frame, so a long press grows a blob even without moving.
  bool _squirting = false;
  double _squirtAccum = 0;

  static const double _squirtVolPerFrame = 1.2;
  static const double _squirtMaxRadius = 16.0;

  void paletteSquirtStart(double gx, double gy) {
    _squirting = true;
    _squirtAccum = 0;
    _palLastX = gx;
    _palLastY = gy;
    _palHasPos = true;
  }

  void paletteSquirtMove(double gx, double gy) {
    _palLastX = gx;
    _palLastY = gy;
    _palHasPos = true;
  }

  void paletteSquirtEnd() => _squirting = false;

  /// Emit one frame's worth of paint at the held spot. The blob spreads as more
  /// comes out, like a bead squeezed from a tube.
  void _squirt() {
    _squirtAccum += _squirtVolPerFrame;
    // Spread up to a cap, then keep depositing so the bead mounds up instead of
    // flattening into a puddle.
    final double radius =
        math.min(_squirtMaxRadius, 6.0 + math.sqrt(_squirtAccum) * 1.8);
    palette.deposit(
        _palLastX, _palLastY, radius, _squirtVolPerFrame, _curR, _curG, _curB);
  }

  /// Dip the brush into the palette at the last touched spot: the brush takes
  /// on the mixed colour there and refills to a full load.
  void loadBrushFromPalette() {
    final px = _palHasPos ? _palLastX : palette.width / 2;
    final py = _palHasPos ? _palLastY : palette.height / 2;
    final rgb = <double>[_curR, _curG, _curB];
    final amount = palette.sampleColor(px, py, 12.0, rgb);
    if (amount > 0) {
      setPigment(rgb[0], rgb[1], rgb[2]);
    }
    final c = brush.loadColor;
    _rec(TwinOp(_now, TwinOpKind.reload, r: c[0], g: c[1], b: c[2]));
    brush.reload();
    notifyListeners();
  }

  // --- twin: record a performance, then replay it (this is a "print") --------

  void startRecording() {
    if (_replaying) return;
    _recOps.clear();
    _recClock
      ..reset()
      ..start();
    _recording = true;
    notifyListeners();
  }

  TwinPerformance stopRecording() {
    _recording = false;
    _recClock.stop();
    final perf =
        TwinPerformance(grid.width, List<TwinOp>.of(_recOps), sizeMm: exportSizeMm);
    _lastPerformance = perf;
    notifyListeners();
    return perf;
  }

  /// Replay [perf] (defaults to the last recording) deterministically through
  /// the sim, in real time. Clears the canvas first so the print reproduces.
  void startReplay([TwinPerformance? perf]) {
    final p = perf ?? _lastPerformance;
    if (p == null || _recording) return;
    grid.clear();
    _doEnd();
    _replayPerf = p;
    _replayIdx = 0;
    _replaying = true;
    _replayClock
      ..reset()
      ..start();
    notifyListeners();
  }

  void stopReplay() {
    _replaying = false;
    _replayClock.stop();
    _doEnd();
    notifyListeners();
  }

  void _advanceReplay() {
    final p = _replayPerf;
    if (p == null) return;
    final double t = _replayClock.elapsedMicroseconds / 1e6;
    while (_replayIdx < p.ops.length && p.ops[_replayIdx].t <= t) {
      final op = p.ops[_replayIdx++];
      switch (op.kind) {
        case TwinOpKind.down:
          _doStart(op.x, op.y, op.pressure);
          _rpLastT = op.t;
          _rpLastX = op.x;
          _rpLastY = op.y;
          break;
        case TwinOpKind.move:
          final double dist = math.sqrt((op.x - _rpLastX) * (op.x - _rpLastX) +
              (op.y - _rpLastY) * (op.y - _rpLastY));
          _doMove(op.x, op.y, op.pressure, _dwell(dist, op.t - _rpLastT));
          _rpLastT = op.t;
          _rpLastX = op.x;
          _rpLastY = op.y;
          break;
        case TwinOpKind.up:
          _doEnd();
          break;
        case TwinOpKind.reload:
          brush.setPigment(op.r, op.g, op.b);
          brush.reload();
          break;
      }
    }
    if (_replayIdx >= p.ops.length) {
      _replaying = false;
      _replayClock.stop();
      _doEnd();
      notifyListeners();
    }
  }

  void clearPalette() {
    palette.clear();
    _palHasPos = false;
    _requestPaletteUpload();
  }

  // --- SpaceMouse (6DOF view navigation) ---
  SpaceMouseInput? _spaceMouse;
  bool get spaceMouseOn => _spaceMouse != null;
  String? spaceMouseStatus;
  // Separate sensitivities (zoom was too hot, pan too sluggish).
  double smPanSpeed = 1.8;
  double smZoomSpeed = 0.6;
  double smTiltSpeed = 1.2;

  Future<void> toggleSpaceMouse() async {
    if (_spaceMouse != null) {
      await _spaceMouse!.stop();
      _spaceMouse = null;
      spaceMouseStatus = null;
    } else {
      final sm = SpaceMouseInput();
      try {
        await sm.start();
        _spaceMouse = sm;
        spaceMouseStatus = 'listening · run tools/spacemouse.py';
      } catch (e) {
        spaceMouseStatus = 'could not open UDP ${sm.port}: $e';
      }
    }
    notifyListeners();
  }

  // Integrate the latest SpaceMouse axes into the view over [dt]. Returns true
  // if the view moved (so the frame loop knows to repaint).
  bool _applySpaceMouse(double dt) {
    final sm = _spaceMouse;
    if (sm == null || !sm.active) return false;
    // SpaceMouse translation:
    //   push/pull the cap (Y, toward/away)  → zoom
    //   slide left/right (X)                → pan X
    //   lift/press the cap (Z, up/down)     → pan Y
    if (sm.ty != 0) {
      zoom = (zoom * math.exp(sm.ty * smZoomSpeed * dt)).clamp(0.5, 12.0);
    }
    panX = (panX + sm.tx * smPanSpeed * dt).clamp(-1.5, 1.5);
    panY = (panY - sm.tz * smPanSpeed * dt).clamp(-1.5, 1.5);
    // Rotation: twist (ry) spins the canvas; tilt fwd/back (rx) → tiltX;
    // tilt left/right (rz) → tiltY.
    canvasRoll += sm.ry * smTiltSpeed * dt;
    tiltX = (tiltX + sm.rx * smTiltSpeed * dt).clamp(-1.309, 1.309); // up to ~75°
    tiltY = (tiltY + sm.rz * smTiltSpeed * dt).clamp(-1.309, 1.309); // up to ~75°
    if (sm.button0) {
      tiltX = 0;
      tiltY = 0;
      zoom = 1.0;
      panX = 0;
      panY = 0;
    }
    return true;
  }

  // --- wet-paint flow ---
  double flowRate = 0.4; // 0..1 leveling/oozing strength (drives substep count)
  double dryTime = 3.0; // seconds for wet paint to mostly set
  bool gravityDrips = false; // world-down gravity → drips, per canvas tilt
  double gravityStrength = 1.0;
  double dripYield = 0.07; // yield threshold: paint thinner than this won't drip
  double dripWander = 0.4; // lateral meander so drips aren't identical
  bool spinning = false; // centrifugal: spinning the canvas flings paint outward
  double spinSpeed = 1.5; // how fast the canvas spins (0 = stopped)
  bool spinCW = false; // rotation direction (sets the spiral handedness)
  final Stopwatch _frameClock = Stopwatch()..start();

  // Spin floods the whole canvas with wet paint, so a flow step goes from
  // touching a tiny wet bbox to the entire O(grid²) field — the one mode that
  // tanks the frame rate (worst on weaker mobile GPUs). But spin is fast and
  // motion-blurred, so it doesn't need full relief resolution. While spinning we
  // drop to [spinQuality] and restore the prior resolution when it stops;
  // setQuality bilinear-resamples so the painting is preserved across the swap.
  bool autoSpinQuality = true;
  int spinQuality = qualityLow;
  bool _wasSpinning = false;
  int _qualityBeforeSpin = 0; // resolution to restore on spin stop; 0 = none

  void _syncSpinQuality() {
    if (spinning == _wasSpinning) return;
    _wasSpinning = spinning;
    if (spinning) {
      if (autoSpinQuality && grid.width > spinQuality) {
        _qualityBeforeSpin = grid.width;
        setQuality(spinQuality);
      }
    } else if (_qualityBeforeSpin != 0) {
      // Always restore if we dropped, even if auto-quality was toggled off mid-spin.
      setQuality(_qualityBeforeSpin);
      _qualityBeforeSpin = 0;
    }
  }

  // The relief texture rebuild (encode + GPU upload + offscreen render) is the
  // heaviest per-frame cost, and during continuous animation it would otherwise
  // run every frame. Cap it to ~30 fps; the on-screen canvas still rotates at
  // full frame rate via the slab transform (it just re-textures with whatever
  // relief image is current), so the throttle is invisible.
  double _reliefAccum = 0;
  static const double _reliefMinInterval = 1 / 30.0;

  /// Pump one frame: advance replay/squeeze, run wet-paint flow, then refresh
  /// GPU textures for whichever surface changed.
  void frame() {
    _syncSpinQuality();
    if (_replaying) _advanceReplay();
    if (_squirting) _squirt();
    if (_pouring) _pour();

    double dt = _frameClock.elapsedMicroseconds / 1e6;
    _frameClock
      ..reset()
      ..start();
    if (dt <= 0 || dt > 0.05) dt = 1 / 60;
    if (_applySpaceMouse(dt)) notifyListeners();
    // Strength drives how many leveling substeps run per frame (each capped for
    // stability), so high flow gives obvious oozing without going unstable.
    final bool doFlow = flowRate > 0.01;
    final bool directional = gravityDrips || spinning;
    if (doFlow || directional) {
      int iters = doFlow ? math.max(1, (flowRate * 6).round()) : 1;
      // Fast spin needs more flow substeps per frame: each substep can only
      // move a bounded fraction of a cell's paint (the conservation cap), so
      // more substeps = paint reaches the rim in fewer frames.
      if (spinning) {
        iters = math.max(iters, math.min(16, (2 + spinSpeed * 2.0).round()));
      }
      final double sdt = dt / iters;
      // With a directional body force on (gravity or spin), drop the isotropic
      // leveling way down so paint RUNS/FLINGS instead of bleeding out evenly.
      final double flowK = !doFlow ? 0.0 : (directional ? 0.03 : 0.2);
      // World-down gravity projected onto the tilted canvas plane → a drip
      // vector in grid coords. cos(tiltX) is full when face-on, zero when
      // pitched flat; displayRoll (set roll + live spin) rotates the drip
      // direction with the canvas as it turns.
      double gx = 0, gy = 0;
      if (gravityDrips) {
        final double mag = math.cos(tiltX);
        final double base = 1.3 * gravityStrength / iters;
        gx = math.sin(displayRoll) * mag * base;
        gy = math.cos(displayRoll) * mag * base;
      }
      // Centrifugal grows with ω² (outward), Coriolis with ω (tangential,
      // signed). Pivot is the canvas centre. Scaled so mid-radius paint
      // migrates at a visible-but-stable rate; the joint outflow budget in
      // flowStep keeps it conservative no matter how hard you spin.
      double spinCf = 0, spinCor = 0, spinCx = 0, spinCy = 0;
      if (spinning) {
        final double w = spinSpeed * (spinCW ? -1.0 : 1.0);
        // Stronger coefficient so paint saturates the per-step cap and flings
        // out quickly; combined with the extra substeps above this makes high
        // spin speeds dramatic while staying conservative.
        spinCf = 0.06 * w * w / iters;
        spinCor = 0.025 * w / iters;
        spinCx = grid.width / 2.0;
        spinCy = grid.height / 2.0;
        // Actually turn the canvas on screen at the same rate, so the outward
        // fling is visibly tied to a spinning canvas (not paint drifting on a
        // still one). Wrapped to stay bounded over long sessions.
        _spinAngle = (_spinAngle + w * 2.0 * dt) % (2 * math.pi);
      }
      for (int it = 0; it < iters; it++) {
        grid.flowStep(sdt,
            flow: flowK,
            dryTime: dryTime,
            gravX: gx,
            gravY: gy,
            dripYield: dripYield,
            dripWander: dripWander,
            spinCf: spinCf,
            spinCor: spinCor,
            spinCx: spinCx,
            spinCy: spinCy);
        palette.flowStep(sdt, flow: doFlow ? 0.16 : 0.0, dryTime: dryTime * 0.6);
      }
    }

    // Continuous-animation modes redraw the paint every frame; throttle the
    // costly relief rebuild to ~30 fps there. One-off edits (a brush stroke)
    // still refresh immediately so painting stays crisp and responsive.
    _reliefAccum += dt;
    final bool continuous =
        spinning || _pouring || _squirting || gravityDrips || _replaying;
    if (grid.isDirty && (!continuous || _reliefAccum >= _reliefMinInterval)) {
      _reliefAccum = 0;
      _requestReliefImage();
    }
    if (palette.isDirty) _requestPaletteUpload();
    // Keep the view turning while spinning even if no paint is moving (e.g. all
    // dried) — the canvas orientation itself is animating.
    if (spinning) notifyListeners();
  }

  bool _palUploading = false;
  void _requestPaletteUpload() {
    final r = paletteRenderer;
    if (r == null || _palUploading) return;
    _palUploading = true;
    r.uploadTextures(palette).then((_) {
      _palUploading = false;
      notifyListeners();
    });
  }

  void lightChanged() {
    _requestReliefImage();
    notifyListeners();
  }

  // --- exports ---

  // Real-world export scale (mm), shared by GLB + STL.
  double exportSizeMm = 100.0; // longer side
  double exportReliefMm = 6.0; // tallest impasto height
  double exportBaseMm = 2.0; // STL base plate
  int exportResolution = 256; // mesh grid resolution

  Future<String> exportPng() => Exporter.savePng(grid, renderer!, light);
  Future<String> exportGlb() => Exporter.saveGlb(grid,
      resolution: exportResolution,
      sizeMm: exportSizeMm,
      reliefMm: exportReliefMm);
  Future<String> exportStl() => Exporter.saveStl(grid,
      resolution: exportResolution,
      sizeMm: exportSizeMm,
      reliefMm: exportReliefMm,
      baseMm: exportBaseMm);

  Future<String> savePerformance() {
    final p = _lastPerformance;
    if (p == null) throw StateError('No recorded performance yet');
    return Exporter.savePerformance(p);
  }

  // --- webcam hand-tracking input -------------------------------------------

  CameraInput? _camera;
  bool get cameraOn => _camera != null;
  String? cameraStatus;

  Future<void> toggleCamera() async {
    if (_camera != null) {
      await _camera!.stop();
      _camera = null;
      cameraStatus = null;
    } else {
      final cam = CameraInput(
        gridWidth: grid.width.toDouble(),
        gridHeight: grid.height.toDouble(),
        onStart: (x, y, p) => strokeStart(x, y, pressure: p),
        onMove: (x, y, p) => strokeMove(x, y, pressure: p),
        onEnd: strokeEnd,
      );
      try {
        await cam.start();
        _camera = cam;
        cameraStatus = 'listening · run tools/hand_tracker.py · pinch to paint';
      } catch (e) {
        cameraStatus = 'could not open UDP ${cam.port}: $e';
      }
    }
    notifyListeners();
  }

  bool get stroking => _stroking;

  @override
  void dispose() {
    _camera?.stop();
    _spaceMouse?.stop();
    reliefImage?.dispose();
    renderer?.dispose();
    paletteRenderer?.dispose();
    super.dispose();
  }
}
