import 'dart:convert';
import 'dart:js_interop';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:web/web.dart' as web;

import '../render/relief_renderer.dart';
import '../sim/paint_grid.dart';
import '../twin/twin_performance.dart';
import 'glb_export.dart';
import 'stl_export.dart';

/// Web exporter: instead of writing to a folder, each "save" streams the bytes
/// straight to a browser download. Returns the download filename so the UI can
/// report it (same call shape as the desktop exporter).
///
/// Uses `package:web` + `dart:js_interop` (not `dart:html`) so the app compiles
/// under dart2wasm as well as dart2js.
class Exporter {
  static String _stamp() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${p(n.month)}${p(n.day)}-${p(n.hour)}${p(n.minute)}${p(n.second)}';
  }

  static void _download(String filename, List<int> bytes, String mime) {
    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final blob = web.Blob(
      <JSAny>[data.toJS].toJS,
      web.BlobPropertyBag(type: mime),
    );
    final url = web.URL.createObjectURL(blob);
    (web.document.createElement('a') as web.HTMLAnchorElement)
      ..href = url
      ..download = filename
      ..click();
    web.URL.revokeObjectURL(url);
  }

  static Future<String> savePng(PaintGrid grid, ReliefRenderer renderer,
      LightSettings light) async {
    final ui.Image img = await renderer.renderToImage(grid, light);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (data == null) throw StateError('PNG encode failed');
    final name = 'paint-${_stamp()}.png';
    _download(name, data.buffer.asUint8List(), 'image/png');
    return name;
  }

  static Future<String> saveGlb(PaintGrid grid,
      {int resolution = 256,
      double sizeMm = 100,
      double reliefMm = 6}) async {
    final bytes = buildGlb(grid,
        resolution: resolution, sizeMm: sizeMm, reliefMm: reliefMm);
    final name = 'relief-${_stamp()}.glb';
    _download(name, bytes, 'model/gltf-binary');
    return name;
  }

  static Future<String> saveStl(PaintGrid grid,
      {int resolution = 256,
      double sizeMm = 100,
      double reliefMm = 6,
      double baseMm = 2}) async {
    final bytes = buildStl(grid,
        resolution: resolution,
        sizeMm: sizeMm,
        reliefMm: reliefMm,
        baseMm: baseMm);
    final name = 'relief-${_stamp()}.stl';
    _download(name, bytes, 'model/stl');
    return name;
  }

  static Future<String> savePerformance(TwinPerformance perf) async {
    final name = 'print-${_stamp()}.json';
    _download(name, utf8.encode(perf.encode()), 'application/json');
    return name;
  }
}
