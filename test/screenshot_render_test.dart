@Tags(['screenshots'])
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:entropy_brush/screenshot_seed.dart';

// Local App Store screenshot renderer (ported from cadsketch). Renders the REAL
// app UI from lib/screenshot_seed.dart at a device's native pixel size straight
// from the Dart VM — no simulator, no macOS CI minutes. Set the output dir to
// run it (without SCREENSHOT_OUT it no-ops so plain `flutter test` stays clean):
//
//   SCREENSHOT_OUT=/tmp/shots SCREENSHOT_DEVICE=iphone SCREENSHOT_SCENE=01-hero \
//   MATERIAL_ICONS=$FLUTTER/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf \
//     flutter test test/screenshot_render_test.dart --tags screenshots
//
// One scene per invocation (SCREENSHOT_SCENE): the headless rasteriser hangs
// on a second toImage in the same process. tools/render_screenshots.sh loops.

Future<void> _loadFont(String family, List<String> paths) async {
  final loader = FontLoader(family);
  for (final p in paths) {
    final f = File(p);
    if (f.existsSync()) {
      final bytes = f.readAsBytesSync();
      loader.addFont(
          Future.value(ByteData.view(Uint8List.fromList(bytes).buffer)));
    }
  }
  await loader.load();
}

void main() {
  final out = Platform.environment['SCREENSHOT_OUT'];

  testWidgets('render App Store screenshots', (tester) async {
    if (out == null) return;
    const dejavu = '/usr/share/fonts/truetype/dejavu';
    await _loadFont('AppSans', [
      '$dejavu/DejaVuSans.ttf',
      '$dejavu/DejaVuSans-Bold.ttf',
    ]);
    final mi = Platform.environment['MATERIAL_ICONS'];
    if (mi != null) await _loadFont('MaterialIcons', [mi]);

    final dir = Directory(out)..createSync(recursive: true);

    // iPad Pro 13" (2064x2752 @2x) or iPhone 6.9" (1320x2868 @3x) — accepted
    // App Store sizes. Landscape iPad keeps the shipped 2732x2048 framing.
    final device = Platform.environment['SCREENSHOT_DEVICE'] ?? 'ipad';
    final (Size physical, double dpr) = switch (device) {
      'iphone' => (const Size(1320, 2868), 3.0),
      'ipad-portrait' => (const Size(2064, 2752), 2.0),
      _ => (const Size(2732, 2048), 2.0),
    };
    tester.view.physicalSize = physical;
    tester.view.devicePixelRatio = dpr;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    final only = Platform.environment['SCREENSHOT_SCENE'];
    final scenes = only != null
        ? screenshotScenes.entries.where((e) => e.key == only)
        : screenshotScenes.entries;

    for (final entry in scenes) {
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(useMaterial3: true).copyWith(
              textTheme:
                  ThemeData.dark().textTheme.apply(fontFamily: 'AppSans'),
            ),
            home: entry.value.build(),
          ),
        ),
      );
      // The scene boots asynchronously (shader load + offscreen relief render
      // + optional drawer open). Real async work needs runAsync; then pump so
      // the finished relief and drawer animation land in the tree.
      for (int i = 0; i < 12; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 250)));
        await tester.pump(const Duration(milliseconds: 100));
      }
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await tester.runAsync(() => boundary.toImage(pixelRatio: dpr));
      final data =
          await tester.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
      File('${dir.path}/${entry.key}.png')
          .writeAsBytesSync(data!.buffer.asUint8List());
      // ignore: avoid_print
      print('WROTE ${dir.path}/${entry.key}.png ${physical.width.toInt()}x${physical.height.toInt()}');
    }
  });
}
