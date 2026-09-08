import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../paint_controller.dart';

/// An orbit gizmo (top-right of the canvas): drag it to tilt the canvas in
/// 3D (pitch + yaw). Double-tap to reset. Mirrors the tilt sliders. Sized as a
/// comfortable thumb target so you can orbit with one hand while painting with
/// the other (the finger on the gizmo is captured here, so it never trips the
/// canvas's two-finger pan/zoom).
class OrbitGizmo extends StatelessWidget {
  const OrbitGizmo({super.key, required this.controller});

  final PaintController controller;

  static const double range = 1.309; // max tilt (~75°) at the rim
  static const double diameter = 112;

  void _set(Offset local) {
    final double c = diameter / 2;
    final double dx = ((local.dx - c) / c).clamp(-1.0, 1.0);
    final double dy = ((local.dy - c) / c).clamp(-1.0, 1.0);
    controller.tiltY = dx * range; // horizontal drag → yaw
    controller.tiltX = -dy * range; // vertical drag → pitch (up = tilt toward you)
    controller.viewChanged();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (d) => _set(d.localPosition),
      onPanUpdate: (d) => _set(d.localPosition),
      onDoubleTap: () {
        controller.tiltX = PaintController.defaultTiltX;
        controller.tiltY = PaintController.defaultTiltY;
        controller.viewChanged();
      },
      child: SizedBox(
        width: diameter,
        height: diameter,
        child: CustomPaint(painter: _OrbitPainter(controller)),
      ),
    );
  }
}

/// Vertical zoom slider that sits under the orbit gizmo (up = zoom in). Mirrors
/// scroll-wheel zoom (controller.zoom, 0.5–12×) so it stays in sync.
class ZoomControl extends StatelessWidget {
  const ZoomControl({super.key, required this.controller});

  final PaintController controller;

  static const double minZoom = 0.5, maxZoom = 12.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 168,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xCC1C1C20),
        borderRadius: BorderRadius.circular(17),
        border: Border.all(color: const Color(0xFF55555C), width: 1),
      ),
      child: Column(
        children: [
          const Icon(Icons.zoom_in, size: 15, color: Color(0xFF99AACC)),
          Expanded(
            child: RotatedBox(
              quarterTurns: 3, // horizontal slider → vertical, min at bottom
              child: AnimatedBuilder(
                animation: controller,
                builder: (context, _) => SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    thumbShape:
                        const RoundSliderThumbShape(enabledThumbRadius: 7),
                    overlayShape:
                        const RoundSliderOverlayShape(overlayRadius: 14),
                    activeTrackColor: const Color(0xFF3A86FF),
                    inactiveTrackColor: const Color(0xFF44444C),
                    thumbColor: Colors.white,
                  ),
                  child: Slider(
                    min: minZoom,
                    max: maxZoom,
                    value: controller.zoom.clamp(minZoom, maxZoom),
                    onChanged: (v) {
                      controller.zoom = v;
                      controller.viewChanged();
                    },
                  ),
                ),
              ),
            ),
          ),
          const Icon(Icons.zoom_out, size: 15, color: Color(0xFF99AACC)),
        ],
      ),
    );
  }
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter(this.c) : super(repaint: c);
  final PaintController c;

  @override
  void paint(Canvas canvas, Size size) {
    final double r = size.width / 2;
    final Offset ctr = Offset(r, r);
    final double pitch = c.tiltX;
    final double yaw = c.tiltY;

    // Disc background + rim.
    canvas.drawCircle(ctr, r, Paint()..color = const Color(0xCC1C1C20));
    canvas.drawCircle(
        ctr,
        r - 1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = const Color(0xFF55555C));

    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = const Color(0x99AAD4FF);

    // Equator squashed by pitch, meridian squashed by yaw — a little gyroscope.
    final double eqH = r * 0.78 * math.cos(pitch).abs().clamp(0.12, 1.0);
    canvas.drawOval(
        Rect.fromCenter(center: ctr, width: r * 1.56, height: eqH * 2), ring);
    final double merW = r * 0.78 * math.cos(yaw).abs().clamp(0.12, 1.0);
    canvas.drawOval(
        Rect.fromCenter(center: ctr, width: merW * 2, height: r * 1.56), ring);

    // Knob showing current orientation.
    final Offset knob = Offset(
      ctr.dx + (yaw / OrbitGizmo.range).clamp(-1.0, 1.0) * r * 0.78,
      // Pitch is inverted (drag up = tilt toward you), so mirror the knob's
      // vertical so it still sits under the finger.
      ctr.dy - (pitch / OrbitGizmo.range).clamp(-1.0, 1.0) * r * 0.78,
    );
    final double kr = r * 0.11; // knob scales with the disc
    canvas.drawCircle(knob, kr, Paint()..color = Colors.white);
    canvas.drawCircle(
        knob,
        kr,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = kr * 0.36
          ..color = const Color(0xFF3A86FF));
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter oldDelegate) => true;
}
