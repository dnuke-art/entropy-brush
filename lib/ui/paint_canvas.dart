import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../paint_controller.dart';
import '../render/relief_renderer.dart';
import 'orbit_gizmo.dart';
import 'slab_painter.dart';
import 'slab_view.dart';

/// The painting surface — a 3D canvas slab. One finger (or the mouse/Pencil)
/// paints; two fingers pan + pinch-zoom the slab. Tilt stays on the orbit
/// gizmo. Pointer input is inverse-projected onto the top face so painting
/// lands where you touch.
class PaintCanvas extends StatefulWidget {
  const PaintCanvas({super.key, required this.controller});

  final PaintController controller;

  @override
  State<PaintCanvas> createState() => _PaintCanvasState();
}

class _PaintCanvasState extends State<PaintCanvas> {
  PaintController get controller => widget.controller;

  // Active pointers on the canvas. One → painting; two → view gesture. This is
  // what lets a single finger draw while two fingers frame the shot, the same
  // split every drawing app uses.
  final Map<int, Offset> _pointers = {};
  int? _paintPointer; // the pointer currently laying a stroke
  int? _pendingPointer; // a first finger down that hasn't become a stroke yet
  Offset _pendingPos = Offset.zero;

  // Two-finger baseline, captured when the second finger lands.
  bool _twoActive = false;
  double _baseDist = 1, _baseZoom = 1, _basePanX = 0, _basePanY = 0;
  Offset _baseMid = Offset.zero;
  double _anchorX = 0, _anchorY = 0; // canvas-space point held under the fingers

  SlabView _slab(Size size) => _slabWith(
      size, controller.zoom, controller.panX, controller.panY);

  SlabView _slabWith(Size size, double zoom, double panX, double panY) =>
      SlabView(
        viewW: size.width,
        viewH: size.height,
        tiltX: controller.tiltX,
        tiltY: controller.tiltY,
        roll: controller.displayRoll,
        zoom: zoom,
        panX: panX,
        panY: panY,
        thickness: controller.canvasThicknessFrac,
      );

  void _send(Offset local, Size size, void Function(double, double) fn) {
    final c = _slab(size).screenToCanvas(local.dx, local.dy);
    if (c.x < 0 || c.x > 1 || c.y < 0 || c.y > 1) return; // missed the canvas
    final gx =
        (c.x * controller.grid.width).clamp(0.0, controller.grid.width - 1.0);
    final gy =
        (c.y * controller.grid.height).clamp(0.0, controller.grid.height - 1.0);
    fn(gx, gy);
  }

  /// Scroll-wheel / trackpad zoom, anchored on the cursor (desktop).
  void _zoomAt(Offset local, Size size, double scrollDy) {
    final before = _slab(size).screenToCanvas(local.dx, local.dy);
    controller.zoom =
        (controller.zoom * math.exp(-scrollDy * 0.0015)).clamp(0.5, 12.0);
    final after = _slab(size).project(before.x, before.y, 0);
    final double s = 0.42 * (size.width < size.height ? size.width : size.height);
    controller.panX += (local.dx - after.x) / s;
    controller.panY += (local.dy - after.y) / s;
    controller.viewChanged();
  }

  List<Offset> _twoPoints() {
    final v = _pointers.values.toList();
    return [v[0], v[1]];
  }

  void _beginTwoFinger(Size size) {
    final p = _twoPoints();
    _baseDist = math.max(1.0, (p[0] - p[1]).distance);
    _baseMid = (p[0] + p[1]) / 2;
    _baseZoom = controller.zoom;
    _basePanX = controller.panX;
    _basePanY = controller.panY;
    final a = _slab(size).screenToCanvas(_baseMid.dx, _baseMid.dy);
    _anchorX = a.x;
    _anchorY = a.y;
    _twoActive = true;
  }

  void _updateTwoFinger(Size size) {
    final p = _twoPoints();
    final newDist = math.max(1.0, (p[0] - p[1]).distance);
    final newMid = (p[0] + p[1]) / 2;
    final newZoom = (_baseZoom * (newDist / _baseDist)).clamp(0.5, 12.0);
    controller.zoom = newZoom;
    // Keep the canvas point that was under the fingers pinned to the moving
    // midpoint (combined pan + zoom), recomputed from the baseline each frame
    // so it never drifts. Same anchoring trick as the scroll-zoom.
    final proj = _slabWith(size, newZoom, _basePanX, _basePanY)
        .project(_anchorX, _anchorY, 0);
    final double s =
        0.42 * (size.width < size.height ? size.width : size.height);
    controller.panX = _basePanX + (newMid.dx - proj.x) / s;
    controller.panY = _basePanY + (newMid.dy - proj.y) / s;
    controller.viewChanged();
  }

  void _onDown(PointerDownEvent e, Size size) {
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length == 1) {
      // Defer the stroke: lay no paint until this finger actually moves (a
      // drag) or lifts (a tap). If a second finger lands first it's a
      // pan/zoom and nothing was painted — no stray dab.
      _pendingPointer = e.pointer;
      _pendingPos = e.localPosition;
    } else if (_pointers.length == 2) {
      if (_paintPointer != null) {
        controller.strokeEnd();
        _paintPointer = null;
      }
      _pendingPointer = null; // the deferred stroke never happened
      _beginTwoFinger(size);
    }
  }

  void _onMove(PointerMoveEvent e, Size size) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length >= 2 && _twoActive) {
      _updateTwoFinger(size);
      return;
    }
    if (_pointers.length != 1 || e.buttons == 0) return;
    if (e.pointer == _pendingPointer &&
        (e.localPosition - _pendingPos).distance > 1.0) {
      // First real movement promotes the deferred touch into a stroke,
      // starting back at the down point so no lead-in paint is lost.
      _send(_pendingPos, size, controller.strokeStart);
      _send(e.localPosition, size, controller.strokeMove);
      _paintPointer = e.pointer;
      _pendingPointer = null;
    } else if (e.pointer == _paintPointer) {
      _send(e.localPosition, size, controller.strokeMove);
    }
  }

  void _onUp(int pointer, Size size) {
    if (pointer == _pendingPointer) {
      // A tap that never moved and never got a second finger → a single dab.
      _send(_pendingPos, size, controller.strokeStart);
      controller.strokeEnd();
      _pendingPointer = null;
    }
    if (pointer == _paintPointer) {
      controller.strokeEnd();
      _paintPointer = null;
    }
    _pointers.remove(pointer);
    // Below two fingers ends the view gesture. Don't paint with a leftover
    // finger — wait for a fresh touch so lifting out of a pinch never draws.
    if (_pointers.length < 2) _twoActive = false;
  }

  void _onCancel(int pointer) {
    // System-interrupted (not a deliberate tap) — drop it without dabbing.
    if (pointer == _pendingPointer) _pendingPointer = null;
    if (pointer == _paintPointer) {
      controller.strokeEnd();
      _paintPointer = null;
    }
    _pointers.remove(pointer);
    if (_pointers.length < 2) _twoActive = false;
  }

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return ListenableBuilder(
            listenable: controller,
            builder: (context, _) {
              if (controller.rendererError != null) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      controller.rendererError!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Colors.orangeAccent, fontSize: 13),
                    ),
                  ),
                );
              }
              return Stack(
                children: [
                  Positioned.fill(
                    child: Listener(
                      onPointerDown: (e) => _onDown(e, size),
                      onPointerMove: (e) => _onMove(e, size),
                      onPointerUp: (e) => _onUp(e.pointer, size),
                      onPointerCancel: (e) => _onCancel(e.pointer),
                      onPointerSignal: (e) {
                        if (e is PointerScrollEvent) {
                          _zoomAt(e.localPosition, size, e.scrollDelta.dy);
                        }
                      },
                      child: CustomPaint(
                        painter: SlabPainter(
                            repaintOn: controller, controller: controller),
                        size: size,
                        isComplex: true,
                        willChange: true,
                      ),
                    ),
                  ),
                  Positioned(
                    top: 10,
                    right: 10,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        OrbitGizmo(controller: controller),
                        const SizedBox(height: 8),
                        ZoomControl(controller: controller),
                      ],
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// Draws a shaded relief surface via the GPU shader. Reused for both the main
/// canvas and the (flat-lit) palette by passing different renderers/lights.
class ReliefPainter extends CustomPainter {
  ReliefPainter({
    required Listenable repaintOn,
    required this.renderer,
    required this.light,
    this.viewDir = const [0.0, 0.0, 1.0],
    this.zoom = 1.0,
    this.panX = 0.0,
    this.panY = 0.0,
  }) : super(repaint: repaintOn);

  final ReliefRenderer? renderer;
  final LightSettings light;
  final List<double> viewDir;
  final double zoom, panX, panY;

  @override
  void paint(Canvas canvas, Size size) {
    final r = renderer;
    if (r == null || !r.ready) {
      canvas.drawRect(
          Offset.zero & size, Paint()..color = const Color(0xFF2A2A2E));
      return;
    }
    r.paint(canvas, size, light,
        viewDir: viewDir, zoom: zoom, panX: panX, panY: panY);
  }

  @override
  bool shouldRepaint(covariant ReliefPainter oldDelegate) => true;
}
