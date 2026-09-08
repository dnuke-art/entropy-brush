import 'dart:io';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../render/relief_renderer.dart';
import '../sim/paint_grid.dart';
import '../twin/twin_performance.dart';
import 'glb_export.dart';
import 'stl_export.dart';

/// Writes PNG (shaded colour) and GLB/STL (relief mesh) assets and returns the
/// paths so the UI can report them. On desktop, files land in a visible
/// `~/entropybrush-exports` folder. On mobile (iOS/iPadOS/Android) there is no
/// such folder — the sandbox forbids it — so exports are written into the app's
/// temporary directory and handed to the system share sheet ([share]), which is
/// how the user saves them to Files, Photos, AirDrop, etc.
class Exporter {
  static bool get isMobile => Platform.isIOS || Platform.isAndroid;

  /// Resolve (and create) the export directory: the app's temp dir on mobile,
  /// `~/entropybrush-exports` on desktop.
  static Future<Directory> exportDir() async {
    final Directory dir;
    if (isMobile) {
      final base = await getTemporaryDirectory();
      dir = Directory('${base.path}/entropybrush-exports');
    } else {
      final home = Platform.environment['HOME'] ??
          Platform.environment['USERPROFILE'] ??
          Directory.current.path;
      dir = Directory('$home/entropybrush-exports');
    }
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static String _stamp() {
    final n = DateTime.now();
    String p(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${p(n.month)}${p(n.day)}-${p(n.hour)}${p(n.minute)}${p(n.second)}';
  }

  /// Render the shaded canvas and save it as PNG. Returns the file path.
  static Future<String> savePng(PaintGrid grid, ReliefRenderer renderer,
      LightSettings light) async {
    final ui.Image img = await renderer.renderToImage(grid, light);
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    img.dispose();
    if (data == null) throw StateError('PNG encode failed');
    final path = '${(await exportDir()).path}/paint-${_stamp()}.png';
    await File(path).writeAsBytes(data.buffer.asUint8List());
    return path;
  }

  /// Build and save the relief mesh as GLB. Returns the file path.
  static Future<String> saveGlb(PaintGrid grid,
      {int resolution = 256,
      double sizeMm = 100,
      double reliefMm = 6}) async {
    final bytes = buildGlb(grid,
        resolution: resolution, sizeMm: sizeMm, reliefMm: reliefMm);
    final path = '${(await exportDir()).path}/relief-${_stamp()}.glb';
    await File(path).writeAsBytes(bytes);
    return path;
  }

  /// Build and save the relief as a watertight binary STL. Returns the path.
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
    final path = '${(await exportDir()).path}/relief-${_stamp()}.stl';
    await File(path).writeAsBytes(bytes);
    return path;
  }

  /// Save a recorded performance ("print") as JSON for later replay or G-code.
  static Future<String> savePerformance(TwinPerformance perf) async {
    final path = '${(await exportDir()).path}/print-${_stamp()}.json';
    await File(path).writeAsString(perf.encode());
    return path;
  }

  /// On mobile, present the system share sheet for [paths] so the user can save
  /// them (Files, Photos, AirDrop…) — returns true. On desktop this is a no-op
  /// (files are already in a visible folder) and returns false so the caller can
  /// tell the user where they landed. [origin] anchors the iPad share popover.
  static Future<bool> share(List<String> paths, {ui.Rect? origin}) async {
    if (!isMobile || paths.isEmpty) return false;
    await Share.shareXFiles(
      paths.map((p) => XFile(p)).toList(),
      sharePositionOrigin: origin,
    );
    return true;
  }
}
