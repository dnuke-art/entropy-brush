import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../export/exporter.dart';
import '../paint_controller.dart';
import 'palette_canvas.dart';

class _Pigment {
  const _Pigment(this.name, this.r, this.g, this.b, this.s);
  final String name;
  final double r, g, b;

  /// Scattering strength (two-constant KM "S"): opacity / tinting strength.
  /// Titanium White is a very strong scatterer — that's what lets it tint.
  final double s;
  Color get color => Color.fromARGB(
      255, (r * 255).round(), (g * 255).round(), (b * 255).round());
}

/// Height of a single pigment swatch — the mixing palette matches it.
const double _swatchHeight = 40;

const _pigments = <_Pigment>[
  _Pigment('Ultramarine', 0.12, 0.20, 0.62, 0.5), // semi-transparent
  _Pigment('Cadmium Red', 0.78, 0.12, 0.10, 0.6), // opaque
  _Pigment('Cadmium Yellow', 0.92, 0.78, 0.12, 0.6), // opaque
  _Pigment('Titanium White', 0.95, 0.94, 0.90, 4.0), // strong scatterer
  // Glazing medium: no absorption, almost no scattering. On its own it lays
  // transparent relief (gloss/varnish strokes); mixed into a pigment on the
  // palette it dilutes K and S together, so the pigment becomes a pale,
  // transparent glaze/wash over the ground instead of an opaque body colour.
  _Pigment('Medium (glaze)', 1.0, 1.0, 1.0, 0.05),
];

const String _buildTag = String.fromEnvironment('BUILD_TAG');

class ControlPanel extends StatefulWidget {
  const ControlPanel({super.key, required this.controller});

  final PaintController controller;

  @override
  State<ControlPanel> createState() => _ControlPanelState();
}

class _ControlPanelState extends State<ControlPanel> {
  int _selectedPigment = 0;

  PaintController get c => widget.controller;

  void _selectPigment(int i) {
    final p = _pigments[i];
    c.setPigment(p.r, p.g, p.b, s: p.s);
    c.reloadBrush();
    setState(() => _selectedPigment = i);
  }

  // The webcam / SpaceMouse inputs are desktop robot-integration features
  // (they listen on UDP for tools/hand_tracker.py and tools/spacemouse.py),
  // so on iPad/phone they'd just be dead buttons — hide them there.
  bool get _isMobile =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.android;

  Future<void> _export(Future<String> Function() fn, String kind) async {
    try {
      final path = await fn();
      if (!mounted) return;
      // On mobile hand the file to the share sheet (anchored to this panel on
      // iPad); on desktop it's already in a visible folder, so report the path.
      final box = context.findRenderObject() as RenderBox?;
      final origin = (box != null && box.hasSize)
          ? box.localToGlobal(Offset.zero) & box.size
          : null;
      final shared = await Exporter.share([path], origin: origin);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(shared ? 'Exported $kind' : 'Saved $kind → $path')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$kind export failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cfg = c.brush.config;
    final light = c.light;

    // Material, not a plain coloured box: the SwitchListTiles below paint their
    // ink on the nearest Material, and a ColoredBox in between trips a debug
    // assertion (which also broke the integration-test screenshot capture).
    return Material(
      color: const Color(0xFF202024),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          const Text('entropybrush',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          const Text('physically simulated bristles · impasto relief',
              style: TextStyle(fontSize: 11, color: Colors.white38)),
          const SizedBox(height: 6),
          // Build tag — confirm you're running the latest. CI passes
          // --dart-define=BUILD_TAG=<version (build)>; local/dev builds and
          // the screenshot renderer leave it empty and show nothing.
          if (_buildTag.isNotEmpty) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.teal.shade700,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text('build: $_buildTag',
                  style: const TextStyle(
                      fontSize: 11, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 10),
          ],
          const SizedBox(height: 6),

          _heading('Performance'),
          AnimatedBuilder(
            animation: c,
            builder: (context, _) => Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(
                      value: PaintController.qualityLow, label: Text('Low')),
                  ButtonSegment(
                      value: PaintController.qualityMed, label: Text('Med')),
                  ButtonSegment(
                      value: PaintController.qualityHigh, label: Text('High')),
                ],
                selected: {c.gridQuality},
                onSelectionChanged: (s) => setState(() => c.setQuality(s.first)),
              ),
            ),
          ),
          const SizedBox(height: 4),
          const Text(
              'grid resolution · lower = smoother spin & drips (esp. web/VR), '
              'higher = crisper relief',
              style: TextStyle(fontSize: 10, color: Colors.white30)),
          const SizedBox(height: 16),

          _heading('Pigment'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (int i = 0; i < _pigments.length; i++)
                _Swatch(
                  pigment: _pigments[i],
                  selected: i == _selectedPigment,
                  onTap: () => _selectPigment(i),
                ),
            ],
          ),
          const SizedBox(height: 16),

          _heading('Mixing palette'),
          const Text('press & hold to squeeze paint · drag to spread & mix',
              style: TextStyle(fontSize: 10, color: Colors.white30)),
          const SizedBox(height: 8),
          PaletteCanvas(controller: c, height: _swatchHeight),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: () {
                    c.loadBrushFromPalette();
                    setState(() => _selectedPigment = -1);
                  },
                  child: const Text('Load brush'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: c.clearPalette,
                  child: const Text('Clear'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Live brush load.
          AnimatedBuilder(
            animation: c,
            builder: (context, _) {
              final frac = cfg.loadCapacity > 0
                  ? (c.brush.averageLoad / cfg.loadCapacity).clamp(0.0, 1.0)
                  : 0.0;
              return Row(
                children: [
                  const Text('Load', style: TextStyle(fontSize: 12)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: LinearProgressIndicator(
                      value: frac,
                      minHeight: 6,
                      backgroundColor: Colors.white12,
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonal(
                  onPressed: c.reloadBrush,
                  child: const Text('Reload'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: c.clearCanvas,
                  child: const Text('Clear'),
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: const Text('Infinite paint', style: TextStyle(fontSize: 13)),
            subtitle: const Text('never run dry — no reloading',
                style: TextStyle(fontSize: 10, color: Colors.white38)),
            value: c.brush.config.infiniteLoad,
            onChanged: (v) {
              setState(() {
                c.brush.config.infiniteLoad = v;
                if (v) c.reloadBrush();
              });
            },
          ),
          AnimatedBuilder(
            animation: c,
            builder: (context, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Pour mode (no brush)',
                  style: TextStyle(fontSize: 13)),
              subtitle: const Text('pen down pours flowing liquid paint',
                  style: TextStyle(fontSize: 10, color: Colors.white38)),
              value: c.pourMode,
              onChanged: (v) => setState(() => c.pourMode = v),
            ),
          ),

          const SizedBox(height: 16),
          _heading('Brush'),
          _intSlider('Bristles', cfg.bristleCount.toDouble(), 8, 400, (v) {
            cfg.bristleCount = v.round();
            c.rebuildBristles();
            c.reloadBrush();
          }),
          _slider('Head radius', cfg.headRadius, 4, 40, (v) {
            cfg.headRadius = v;
            c.rebuildBristles();
            c.reloadBrush();
          }),
          _slider('Stiffness', cfg.stiffness, 40, 600, (v) => cfg.stiffness = v),
          _slider('Damping', cfg.damping, 2, 40, (v) => cfg.damping = v),
          _slider('Splay', cfg.splay, 0, 2.5, (v) => cfg.splay = v),
          _slider('Load capacity', cfg.loadCapacity, 0.2, 4, (v) {
            cfg.loadCapacity = v;
          }),
          _slider('Paint mileage', cfg.mileage, 0.0, 1.0, (v) {
            cfg.mileage = v;
          }),
          _slider('Deposit rate', cfg.depositRate, 0.5, 6,
              (v) => cfg.depositRate = v),
          _slider('Bristle length', cfg.bristleLength, 0, 24,
              (v) => cfg.bristleLength = v),
          _slider('Paint displacement', cfg.displacement, 0, 1,
              (v) => cfg.displacement = v),
          _slider('Dwell buildup', cfg.dwellBuildup, 0, 3,
              (v) => cfg.dwellBuildup = v),
          _slider('Pressure', c.pressure, 0.05, 1, (v) => c.pressure = v),

          const SizedBox(height: 16),
          _heading('Wet flow'),
          _slider('Flow (leveling)', c.flowRate, 0.0, 1.0,
              (v) => c.flowRate = v),
          // 0 = paint sets the instant it's laid (no leveling, no drips): pure
          // impasto that keeps every bristle mark exactly as brushed.
          _slider('Dry time (s)', c.dryTime, 0.0, 10.0, (v) => c.dryTime = v),
          AnimatedBuilder(
            animation: c,
            builder: (context, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Gravity drips', style: TextStyle(fontSize: 13)),
              subtitle: const Text('world-down, per canvas tilt (drip down-screen)',
                  style: TextStyle(fontSize: 10, color: Colors.white38)),
              value: c.gravityDrips,
              onChanged: (v) => setState(() => c.gravityDrips = v),
            ),
          ),
          _slider('Gravity strength', c.gravityStrength, 0.1, 3.0,
              (v) => c.gravityStrength = v),
          _slider('Drip threshold', c.dripYield, 0.0, 0.4,
              (v) => c.dripYield = v),
          _slider('Drip wander', c.dripWander, 0.0, 1.0,
              (v) => c.dripWander = v),
          AnimatedBuilder(
            animation: c,
            builder: (context, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Spin (centrifugal)',
                  style: TextStyle(fontSize: 13)),
              subtitle: const Text('spinning flings wet paint out to the rim',
                  style: TextStyle(fontSize: 10, color: Colors.white38)),
              value: c.spinning,
              onChanged: (v) => setState(() => c.spinning = v),
            ),
          ),
          _slider('Spin speed', c.spinSpeed, 0.0, 6.0, (v) => c.spinSpeed = v),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                c.squareUp();
                setState(() {});
              },
              icon: const Icon(Icons.crop_square, size: 16),
              label: const Text('Square up canvas'),
            ),
          ),
          AnimatedBuilder(
            animation: c,
            builder: (context, _) => SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Clockwise', style: TextStyle(fontSize: 13)),
              subtitle: const Text('spin direction (flips the spiral)',
                  style: TextStyle(fontSize: 10, color: Colors.white38)),
              value: c.spinCW,
              onChanged: (v) => setState(() => c.spinCW = v),
            ),
          ),

          const SizedBox(height: 16),
          _heading('Paint'),
          _slider('Body (thickness)', c.grid.profile.body, 0.3, 3.0,
              (v) => c.grid.profile.body = v),
          _slider('Viscosity', c.grid.profile.viscosity, 0.2, 4.0,
              (v) => c.grid.profile.viscosity = v),
          _slider('Lumpiness', c.grid.profile.lumpiness, 0, 1,
              (v) => c.grid.profile.lumpiness = v),
          _slider('Grain', c.grid.profile.grain, 0.02, 0.4,
              (v) => c.grid.profile.grain = v),
          _slider('Opacity', c.grid.profile.opacity, 0.3, 2.0,
              (v) => c.grid.profile.opacity = v),
          _slider('Smear (wet-on-wet)', cfg.pickupRate, 0, 0.6,
              (v) => cfg.pickupRate = v),

          const SizedBox(height: 16),
          _heading('Light & relief'),
          _slider('Azimuth', light.azimuth, 0, 6.28, (v) {
            light.azimuth = v;
            c.lightChanged();
          }),
          _slider('Elevation', light.elevation, 0.1, 1.5, (v) {
            light.elevation = v;
            c.lightChanged();
          }),
          _slider('Relief', light.heightScale, 100, 2500, (v) {
            light.heightScale = v;
            c.lightChanged();
          }),
          _slider('Specular', light.specular, 0, 1, (v) {
            light.specular = v;
            c.lightChanged();
          }),
          _slider('Ambient', light.ambient, 0, 0.8, (v) {
            light.ambient = v;
            c.lightChanged();
          }),
          _slider('Cavity shadow', light.occlusion, 0, 1, (v) {
            light.occlusion = v;
            c.lightChanged();
          }),
          _slider('Wet gloss', light.gloss, 0, 1, (v) {
            light.gloss = v;
            c.lightChanged();
          }),
          _slider('Fill light', light.fill, 0, 1, (v) {
            light.fill = v;
            c.lightChanged();
          }),
          _slider('Saturation', light.saturation, 0.6, 1.6, (v) {
            light.saturation = v;
            c.lightChanged();
          }),

          const SizedBox(height: 16),
          _heading('View (tilt · zoom · pan)'),
          _slider('Tilt X (pitch)', c.tiltX, -1.309, 1.309, (v) {
            c.tiltX = v;
            c.viewChanged();
          }),
          _slider('Tilt Y (yaw)', c.tiltY, -1.309, 1.309, (v) {
            c.tiltY = v;
            c.viewChanged();
          }),
          _slider('Zoom', c.zoom, 0.5, 12.0, (v) {
            c.zoom = v;
            c.viewChanged();
          }),
          _slider('Pan X', c.panX, -1.5, 1.5, (v) {
            c.panX = v;
            c.viewChanged();
          }),
          _slider('Pan Y', c.panY, -1.5, 1.5, (v) {
            c.panY = v;
            c.viewChanged();
          }),
          _slider('Canvas rotate', c.canvasRoll, -3.14159, 3.14159, (v) {
            c.resetSpin(); // the slider is the whole orientation
            c.canvasRoll = v;
            c.viewChanged();
          }),
          const Text('two-finger twist on the canvas also rotates it',
              style: TextStyle(fontSize: 10, color: Colors.white30)),
          _slider('Canvas thickness', c.canvasThicknessFrac, 0.0, 0.2, (v) {
            c.canvasThicknessFrac = v;
            c.viewChanged();
          }),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                c.tiltX = PaintController.defaultTiltX;
                c.tiltY = PaintController.defaultTiltY;
                c.zoom = 1.0;
                c.panX = 0;
                c.panY = 0;
                c.canvasRoll = 0;
                c.resetSpin();
                c.viewChanged();
                setState(() {});
              },
              child: const Text('Reset view'),
            ),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () {
                c.squareUp();
                setState(() {});
              },
              child: const Text('Square up (nearest 90°)'),
            ),
          ),

          const SizedBox(height: 16),
          _heading('Canvas texture'),
          _slider('Tooth depth', c.canvasAmplitude, 0.0, 1.5, (v) {
            c.canvasAmplitude = v;
            c.applyCanvasTexture();
          }),
          _slider('Tooth scale', c.canvasScale, 0.04, 0.5, (v) {
            c.canvasScale = v;
            c.applyCanvasTexture();
          }),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: c.newCanvasTexture,
              child: const Text('New weave'),
            ),
          ),

          if (!_isMobile) ...[
            const SizedBox(height: 16),
            _heading('Webcam input'),
            AnimatedBuilder(
              animation: c,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.tonal(
                    onPressed: c.toggleCamera,
                    style: c.cameraOn
                        ? FilledButton.styleFrom(
                            backgroundColor: Colors.teal.shade400)
                        : null,
                    child: Text(c.cameraOn ? 'Stop webcam' : 'Start webcam'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    c.cameraStatus ?? 'pinch thumb+index to paint',
                    style:
                        const TextStyle(fontSize: 10, color: Colors.white38),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 16),
            _heading('SpaceMouse (6DOF view)'),
            AnimatedBuilder(
              animation: c,
              builder: (context, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  FilledButton.tonal(
                    onPressed: c.toggleSpaceMouse,
                    style: c.spaceMouseOn
                        ? FilledButton.styleFrom(
                            backgroundColor: Colors.indigo.shade400)
                        : null,
                    child: Text(
                        c.spaceMouseOn ? 'Stop SpaceMouse' : 'Start SpaceMouse'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    c.spaceMouseStatus ??
                        'pan/zoom/tilt the view · run tools/spacemouse.py',
                    style:
                        const TextStyle(fontSize: 10, color: Colors.white38),
                  ),
                ],
              ),
            ),
            _slider(
                'Pan speed', c.smPanSpeed, 0.2, 5.0, (v) => c.smPanSpeed = v),
            _slider('Zoom speed', c.smZoomSpeed, 0.1, 3.0,
                (v) => c.smZoomSpeed = v),
          ],
          _slider('Tilt speed', c.smTiltSpeed, 0.2, 4.0,
              (v) => c.smTiltSpeed = v),

          const SizedBox(height: 16),
          _heading('Twin (record / replay)'),
          AnimatedBuilder(
            animation: c,
            builder: (context, _) {
              final hasPerf = c.lastPerformance != null;
              final canReplay = hasPerf && !c.recording && !c.replaying;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: c.replaying
                              ? null
                              : () => c.recording
                                  ? c.stopRecording()
                                  : c.startRecording(),
                          style: c.recording
                              ? FilledButton.styleFrom(
                                  backgroundColor: Colors.red.shade400)
                              : null,
                          child: Text(c.recording ? '■ Stop' : '● Record'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: FilledButton.tonal(
                          onPressed: c.replaying
                              ? c.stopReplay
                              : (canReplay ? () => c.startReplay() : null),
                          child: Text(c.replaying ? 'Stop' : 'Replay'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  OutlinedButton(
                    onPressed: (hasPerf && !c.recording)
                        ? () => _export(c.savePerformance, 'print')
                        : null,
                    child: const Text('Save print (.json)'),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    c.recording
                        ? 'recording…'
                        : c.replaying
                            ? 'replaying…'
                            : hasPerf
                                ? '${c.lastPerformance!.strokeCount} strokes · '
                                    '${c.lastPerformance!.duration.toStringAsFixed(1)}s captured'
                                : 'record a performance to replay it',
                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                  ),
                ],
              );
            },
          ),

          const SizedBox(height: 16),
          _heading('Export scale (mm)'),
          _slider('Size (longer side)', c.exportSizeMm, 20, 300,
              (v) => c.exportSizeMm = v),
          _slider('Relief height', c.exportReliefMm, 0.5, 20,
              (v) => c.exportReliefMm = v),
          _slider('STL base', c.exportBaseMm, 0.5, 10,
              (v) => c.exportBaseMm = v),
          _slider('Mesh resolution', c.exportResolution.toDouble(), 96, 512,
              (v) => c.exportResolution = v.round()),

          const SizedBox(height: 12),
          _heading('Export'),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: () => _export(c.exportPng, 'PNG'),
                  child: const Text('PNG'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => _export(c.exportGlb, 'GLB'),
                  child: const Text('GLB'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: FilledButton(
                  onPressed: () => _export(c.exportStl, 'STL'),
                  child: const Text('STL'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text('GLB = colour mesh · STL = watertight solid (printing)\n'
              'saved to ~/entropybrush-exports',
              style: TextStyle(fontSize: 10, color: Colors.white30)),
        ],
      ),
    );
  }

  Widget _heading(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(t.toUpperCase(),
            style: const TextStyle(
                fontSize: 11,
                letterSpacing: 1.2,
                color: Colors.white54,
                fontWeight: FontWeight.w600)),
      );

  Widget _slider(String label, double value, double min, double max,
      ValueChanged<double> onChanged) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 12)),
            Text(value.toStringAsFixed(value < 10 ? 2 : 0),
                style: const TextStyle(fontSize: 11, color: Colors.white38)),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 2,
            overlayShape: SliderComponentShape.noOverlay,
          ),
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: (v) => setState(() => onChanged(v)),
          ),
        ),
      ],
    );
  }

  Widget _intSlider(String label, double value, double min, double max,
          ValueChanged<double> onChanged) =>
      _slider(label, value, min, max, onChanged);
}

class _Swatch extends StatelessWidget {
  const _Swatch(
      {required this.pigment, required this.selected, required this.onTap});

  final _Pigment pigment;
  final bool selected;
  final VoidCallback onTap;

  /// A glazing medium (near-zero scattering) is transparent, so draw it as a
  /// glassy sheen over the panel instead of a solid chip.
  bool get _isMedium => pigment.s < 0.1;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: _swatchHeight,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _isMedium ? null : pigment.color,
          gradient: _isMedium
              ? const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [Color(0x66FFFFFF), Color(0x14FFFFFF), Color(0x4DFFFFFF)],
                )
              : null,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 2.5 : 1,
          ),
        ),
        child: _isMedium
            ? const Text('glaze',
                style: TextStyle(fontSize: 10, color: Colors.white70))
            : null,
      ),
    );
  }
}
