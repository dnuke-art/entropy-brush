import 'dart:convert';

/// One recorded action in a painting performance. The timeline of these IS the
/// digital twin: replay them through the sim to reproduce the painting, or
/// later translate them into machine motion (G-code) for a physical print.
enum TwinOpKind { down, move, up, reload }

class TwinOp {
  TwinOp(
    this.t,
    this.kind, {
    this.x = 0,
    this.y = 0,
    this.pressure = 1.0,
    this.r = 0,
    this.g = 0,
    this.b = 0,
    this.s = 0.6,
  });

  /// Seconds from the start of the recording.
  final double t;
  final TwinOpKind kind;

  /// Stroke position in grid coordinates, and contact pressure (0..1). For a
  /// 3-axis machine, pressure maps to Z depth.
  final double x, y, pressure;

  /// Pigment colour for a [TwinOpKind.reload].
  final double r, g, b;

  /// Pigment scattering strength (two-constant Kubelka-Munk "S": opacity /
  /// tinting strength) for a [TwinOpKind.reload]. Optional in the format —
  /// v1/v2 recordings without it replay with a neutral 0.6.
  final double s;

  Map<String, dynamic> toJson() => {
        't': t,
        'k': kind.index,
        if (kind != TwinOpKind.reload) ...{
          'x': x,
          'y': y,
          'p': pressure,
        },
        if (kind == TwinOpKind.reload) ...{
          'r': r,
          'g': g,
          'b': b,
          's': s,
        },
      };

  factory TwinOp.fromJson(Map<String, dynamic> j) => TwinOp(
        (j['t'] as num).toDouble(),
        TwinOpKind.values[j['k'] as int],
        x: (j['x'] as num?)?.toDouble() ?? 0,
        y: (j['y'] as num?)?.toDouble() ?? 0,
        pressure: (j['p'] as num?)?.toDouble() ?? 1.0,
        r: (j['r'] as num?)?.toDouble() ?? 0,
        g: (j['g'] as num?)?.toDouble() ?? 0,
        b: (j['b'] as num?)?.toDouble() ?? 0,
        s: (j['s'] as num?)?.toDouble() ?? 0.6,
      );
}

/// A complete recorded painting — the portable, **machine-agnostic** "print".
///
/// This is the hand-off contract to a downstream machine driver (e.g. a separate
/// paintbot/CNC project). It carries *intent*, not kinematics: where the brush
/// went, how hard, and in what colour. The driver owns everything hardware
/// (kinematics, Z/pressure mechanism, paint-well routing, firmware/G-code).
///
/// Coordinates ([TwinOp.x],[TwinOp.y]) are in grid cells, 0..[gridSize]. Divide
/// by [gridSize] for 0..1 normalized canvas coords; multiply by [mmPerCell] for
/// millimetres. [pressure] is 0..1 (contact force / Z depth — machine-defined).
/// Reload ops carry the loaded pigment as linear RGB 0..1. See
/// docs/interface/performance-format.md for the full schema.
class TwinPerformance {
  TwinPerformance(this.gridSize, this.ops, {this.sizeMm = 0});

  /// Internal sim resolution; op x,y are in cells of this grid.
  final int gridSize;

  /// Intended physical size of the *longer* canvas side, in mm (0 = unspecified,
  /// the driver picks). A design hint, not a constraint.
  final double sizeMm;

  final List<TwinOp> ops;

  double get duration => ops.isEmpty ? 0 : ops.last.t;
  int get strokeCount =>
      ops.where((o) => o.kind == TwinOpKind.down).length;

  /// Millimetres per grid cell, given [sizeMm] (0 if unspecified).
  double get mmPerCell => sizeMm > 0 ? sizeMm / gridSize : 0;

  Map<String, dynamic> toJson() => {
        'format': 'entropy-brush-performance',
        'version': 2,
        'canvas': {'gridSize': gridSize, 'sizeMm': sizeMm},
        'ops': ops.map((o) => o.toJson()).toList(),
      };

  String encode() => const JsonEncoder.withIndent('  ').convert(toJson());

  factory TwinPerformance.decode(String s) {
    final j = json.decode(s) as Map<String, dynamic>;
    // v2 nests canvas info; v1 had gridSize at the top level.
    final canvas = j['canvas'] as Map<String, dynamic>?;
    final int gridSize =
        (canvas?['gridSize'] ?? j['gridSize'] ?? 768) as int;
    final double sizeMm =
        ((canvas?['sizeMm'] ?? 0) as num).toDouble();
    return TwinPerformance(
      gridSize,
      (j['ops'] as List)
          .map((e) => TwinOp.fromJson(e as Map<String, dynamic>))
          .toList(),
      sizeMm: sizeMm,
    );
  }
}
