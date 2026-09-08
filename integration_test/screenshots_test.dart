import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:entropy_brush/screenshot_seed.dart';

// App Store screenshot capture. Each scene from screenshot_seed pumps the REAL
// app UI (canvas + controls) seeded with a showcase painting, and is captured
// at the simulator's native resolution. Run on an iPad Pro 12.9"/13" simulator
// so the PNGs come out at an accepted App Store size (2048x2732 / 2064x2752):
//
//   flutter drive --driver=test_driver/integration_test.dart \
//     --target=integration_test/screenshots_test.dart -d <ipad-pro-udid>
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // Give async work (shader load, GPU relief render) time to land before each
  // capture; a running ticker means pumpAndSettle never settles, so we pump a
  // fixed budget instead.
  Future<void> settle(WidgetTester tester,
      {int frames = 26, int ms = 100}) async {
    for (int i = 0; i < frames; i++) {
      await tester.pump(Duration(milliseconds: ms));
    }
  }

  testWidgets('capture App Store screenshots', (tester) async {
    final scenes = screenshotScenes.entries.toList();

    // Pump one scene so an engine surface exists, then convert it to an
    // image-backed layer once (required on iOS before takeScreenshot).
    await tester.pumpWidget(MaterialApp(home: scenes.first.value.build()));
    await settle(tester);
    await binding.convertFlutterSurfaceToImage();

    for (final scene in scenes) {
      await tester.pumpWidget(MaterialApp(home: scene.value.build()));
      await settle(tester);
      await binding.takeScreenshot(scene.key);
    }
  });
}
