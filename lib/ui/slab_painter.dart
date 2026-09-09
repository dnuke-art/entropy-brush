import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../paint_controller.dart';
import 'slab_view.dart';

/// Renders the canvas as a 3D slab: back + side faces give it thickness, and the
/// painting (the controller's flat relief image) is textured onto the top face.
class SlabPainter extends CustomPainter {
  SlabPainter({required Listenable repaintOn, required this.controller})
      : super(repaint: repaintOn);

  final PaintController controller;

  // Warm canvas-board edge colour.
  static const Color _edge = Color(0xFFCDBBA0);

  SlabView _slab(Size size) => SlabView(
        viewW: size.width,
        viewH: size.height,
        tiltX: controller.tiltX,
        tiltY: controller.tiltY,
        roll: controller.displayRoll,
        zoom: controller.zoom,
        panX: controller.panX,
        panY: controller.panY,
        thickness: controller.canvasThicknessFrac,
      );

  @override
  void paint(Canvas canvas, Size size) {
    // Match the app scaffold background exactly: a slightly different dark
    // gray here made the 16pt layout padding read as a visible frame around
    // the canvas area on iPad (two-tone border), even though the app itself is
    // full-screen. Same color = seamless.
    canvas.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF1A1A1D));
    final slab = _slab(size);

    final t = [
      slab.project(0, 0, 0),
      slab.project(1, 0, 0),
      slab.project(1, 1, 0),
      slab.project(0, 1, 0),
    ];
    final b = [
      slab.project(0, 0, 1),
      slab.project(1, 0, 1),
      slab.project(1, 1, 1),
      slab.project(0, 1, 1),
    ];

    // Back face, then the four sides (painter's order; top drawn last). Shades
    // fake a little lighting so the slab reads as solid.
    _face(canvas, [b[0], b[1], b[2], b[3]], 0.45);
    _face(canvas, [t[0], t[1], b[1], b[0]], 0.85); // top edge
    _face(canvas, [t[1], t[2], b[2], b[1]], 0.7); // right
    _face(canvas, [t[2], t[3], b[3], b[2]], 0.55); // bottom
    _face(canvas, [t[3], t[0], b[0], b[3]], 0.78); // left

    final img = controller.reliefImage;
    if (img != null) {
      _top(canvas, slab, img);
    } else {
      _face(canvas, t, 1.0); // placeholder until first render
    }
  }

  void _face(Canvas canvas, List<Pt> pts, double shade) {
    final path = Path()..moveTo(pts[0].x, pts[0].y);
    for (int i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].x, pts[i].y);
    }
    path.close();
    final col = Color.lerp(_edge, const Color(0xFF000000), 1 - shade)!;
    canvas.drawPath(path, Paint()..color = col..isAntiAlias = true);
    canvas.drawPath(
        path,
        Paint()
          ..color = const Color(0x22000000)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  void _top(Canvas canvas, SlabView slab, ui.Image img) {
    const int n = 12; // subdivision for ~perspective-correct texturing
    final double iw = img.width.toDouble();
    final double ih = img.height.toDouble();
    final positions = <Offset>[];
    final texCoords = <Offset>[];
    for (int j = 0; j <= n; j++) {
      for (int i = 0; i <= n; i++) {
        final double u = i / n, v = j / n;
        final p = slab.project(u, v, 0);
        positions.add(Offset(p.x, p.y));
        texCoords.add(Offset(u * iw, v * ih));
      }
    }
    final indices = <int>[];
    for (int j = 0; j < n; j++) {
      for (int i = 0; i < n; i++) {
        final int a = j * (n + 1) + i, bb = a + 1, c = a + (n + 1), d = c + 1;
        indices..add(a)..add(bb)..add(c)..add(bb)..add(d)..add(c);
      }
    }
    final shader = ui.ImageShader(
      img,
      TileMode.clamp,
      TileMode.clamp,
      Matrix4.identity().storage,
      filterQuality: FilterQuality.high,
    );
    final verts = ui.Vertices(
      VertexMode.triangles,
      positions,
      textureCoordinates: texCoords,
      indices: indices,
    );
    canvas.drawVertices(verts, BlendMode.srcOver, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(covariant SlabPainter oldDelegate) => true;
}
