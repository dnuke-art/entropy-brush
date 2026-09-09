import 'dart:math' as math;

import 'paint_grid.dart';

/// One bristle: an anchor on the brush head and a tip with mass that lags
/// behind it. The lag + splay is what makes marks look brushed rather than
/// stamped — fast strokes whip the tips out behind the head, a starved tip
/// scumbles and skips.
class Bristle {
  Bristle(this.restX, this.restY);

  /// Rest offset from the head centre, in canvas px (defines the fan layout).
  final double restX, restY;

  /// Current tip position in canvas px.
  double tipX = 0, tipY = 0;
  double velX = 0, velY = 0;

  /// Paint carried by this bristle and its colour.
  double load = 0;
  double r = 0, g = 0, b = 0;

  /// Scattering strength of the paint on this bristle (two-constant KM "S").
  double s = PaintGrid.defaultPigmentS;

  /// Per-bristle character: [gain] scales how much this hair lays down (and how
  /// fast it drains, so some hairs dry before others); [rscale] varies its track
  /// width. Together they break the stroke into individual bristle striations.
  double gain = 1.0;
  double rscale = 1.0;

  bool initialised = false;
}

/// Brush parameters the user can feel from day one.
class BrushConfig {
  BrushConfig({
    this.bristleCount = 80,
    this.headRadius = 14.0,
    this.stiffness = 240.0,
    this.damping = 14.0,
    this.splay = 0.9,
    this.loadCapacity = 1.6,
    this.depositRate = 2.2,
    this.pickupRate = 0.2,
    this.mileage = 0.7,
    this.bristleLength = 9.0,
    this.displacement = 0.15,
    this.infiniteLoad = false,
    this.dwellBuildup = 1.2,
  });

  int bristleCount;

  /// Radius of the bristle fan at rest, in canvas px.
  double headRadius;

  /// Spring constant pulling each tip toward its (moving) anchor.
  double stiffness;

  /// Velocity damping on the tips.
  double damping;

  /// How much the fan spreads with stroke speed.
  double splay;

  /// Paint a fully loaded bristle holds.
  double loadCapacity;

  /// Volume deposited per second at full load and full pressure.
  double depositRate;

  /// Thickness lifted per second when picking paint back up.
  double pickupRate;

  /// How far a load goes: 0 = drains 1:1 with paint laid (runs dry fast),
  /// 1 = sips from a deep reservoir (lasts ~10x longer). The "useful compromise".
  double mileage;

  /// Length of the bristle contact footprint (px) at full pressure — the brush
  /// flattens against the paper so deposition leads and the tips trail behind.
  double bristleLength;

  /// How strongly the trailing tips plow / push wet paint into ridges (0..1).
  double displacement;

  /// When true the brush never runs dry — load is topped up every step, so you
  /// can paint continuously without reloading.
  bool infiniteLoad;

  /// How much extra paint a slow/dwelling stroke lays (velocity → volume). This
  /// is the *only* coupling from speed to drips: more dwell → more paint → more
  /// likely to pass the drip yield. 0 = speed-independent deposition.
  double dwellBuildup;

  BrushConfig copy() => BrushConfig(
        bristleCount: bristleCount,
        headRadius: headRadius,
        stiffness: stiffness,
        damping: damping,
        splay: splay,
        loadCapacity: loadCapacity,
        depositRate: depositRate,
        pickupRate: pickupRate,
        mileage: mileage,
        bristleLength: bristleLength,
        displacement: displacement,
        infiniteLoad: infiniteLoad,
        dwellBuildup: dwellBuildup,
      );
}

/// A single sampled point of input — abstracted so a stylus can later supply
/// real pressure and tilt where the mouse supplies defaults.
class StrokeSample {
  StrokeSample(this.x, this.y, {this.pressure = 1.0, this.tiltX = 0, this.tiltY = 0});
  final double x, y;
  final double pressure;
  final double tiltX, tiltY;
}

class Brush {
  Brush(this.config, {int seed = 1}) : _rng = math.Random(seed) {
    rebuildBristles();
  }

  BrushConfig config;
  final math.Random _rng;

  final List<Bristle> bristles = [];

  double x = 0, y = 0;
  bool _down = false;

  /// How much the brush is dwelling (0 = fast stroke, 1 = slow/stopped). Slow
  /// strokes lay more paint per length, so paint pools where you slow down.
  double dwell = 0;

  // Loaded pigment for the next reload (colour + scattering strength).
  double _loadR = 0.1, _loadG = 0.2, _loadB = 0.7;
  double _loadS = 0.35;

  void setPigment(double r, double g, double b,
      [double s = PaintGrid.defaultPigmentS]) {
    _loadR = r;
    _loadG = g;
    _loadB = b;
    _loadS = s;
  }

  /// The pigment that would be applied on the next reload (for recording).
  List<double> get loadColor => [_loadR, _loadG, _loadB];

  /// Scattering strength of the loaded pigment (for recording).
  double get loadS => _loadS;

  /// Lay out the bristle fan: jittered radial positions so the brush has an
  /// irregular edge rather than a clean disc.
  void rebuildBristles() {
    bristles.clear();
    final int n = config.bristleCount;
    for (int i = 0; i < n; i++) {
      // Concentric-ish distribution with jitter.
      final double frac = (i + 0.5) / n;
      final double rad = math.sqrt(frac) * config.headRadius;
      final double ang = i * 2.399963 + (_rng.nextDouble() - 0.5) * 0.6;
      final double jr = rad * (0.85 + _rng.nextDouble() * 0.3);
      final br = Bristle(math.cos(ang) * jr, math.sin(ang) * jr);
      br.gain = 0.55 + _rng.nextDouble() * 0.9; // 0.55..1.45
      br.rscale = 0.7 + _rng.nextDouble() * 0.6; // 0.7..1.3
      bristles.add(br);
    }
  }

  /// Fully reload the brush with the current pigment.
  void reload() {
    for (final br in bristles) {
      br.load = config.loadCapacity;
      br.r = _loadR;
      br.g = _loadG;
      br.b = _loadB;
      br.s = _loadS;
    }
  }

  double get averageLoad {
    if (bristles.isEmpty) return 0;
    double s = 0;
    for (final br in bristles) {
      s += br.load;
    }
    return s / bristles.length;
  }

  /// Begin a stroke: snap tips to the head so the first dab isn't a smear.
  void begin(StrokeSample s) {
    x = s.x;
    y = s.y;
    _down = true;
    for (final br in bristles) {
      br.tipX = x + br.restX;
      br.tipY = y + br.restY;
      br.velX = 0;
      br.velY = 0;
      br.initialised = true;
    }
  }

  void end() => _down = false;

  /// Release a pool of paint at the lift point, scaled by how much the brush was
  /// dwelling (slow lift → bigger pool). Drawn from the remaining load, so it's
  /// conserved. This is where end-of-stroke drips originate.
  void layPool(PaintGrid grid) {
    if (bristles.isEmpty || dwell <= 0.02) return;
    final double frac = (0.15 * config.dwellBuildup * dwell).clamp(0.0, 0.6);
    final int n = bristles.length;
    double amount = 0, pr = 0, pg = 0, pb = 0, ps = 0;
    for (final br in bristles) {
      amount += br.load * frac;
      pr += br.r;
      pg += br.g;
      pb += br.b;
      ps += br.s;
    }
    if (amount <= 0) return;
    grid.deposit(x, y, config.headRadius * 0.55, amount, pr / n, pg / n, pb / n,
        coverage: 1.0, ps: ps / n);
    for (final br in bristles) {
      br.load -= br.load * frac;
    }
  }

  /// Advance the brush toward sample [s] over [dt] seconds, depositing into and
  /// lifting from [grid]. Pressure scales how hard bristles press (more contact,
  /// more deposit). The head is moved to [s]; tips follow by spring + damping.
  void step(StrokeSample s, double dt, PaintGrid grid) {
    if (!_down) return;
    final double mvx = s.x - x, mvy = s.y - y;
    final double mvlen = math.sqrt(mvx * mvx + mvy * mvy);
    final double dirX = mvlen > 1e-4 ? mvx / mvlen : 0.0;
    final double dirY = mvlen > 1e-4 ? mvy / mvlen : 0.0;
    final double speed = mvlen / (dt > 1e-5 ? dt : 1e-5);
    x = s.x;
    y = s.y;

    final double press = s.pressure.clamp(0.05, 1.0);
    // Splay grows the fan with speed and pressure: drag spreads the bristles.
    final double splayScale =
        1.0 + config.splay * (press * 0.4 + (speed / 800.0).clamp(0.0, 1.5));
    // Finer base contact so individual bristle tracks read as striations.
    final double contactBase = 0.8 + press * 0.9;

    final List<double> picked = [0, 0, 0];
    final List<double> pickedS = [0]; // scattering of the picked-up paint

    for (final br in bristles) {
      if (!br.initialised) {
        br.tipX = x + br.restX;
        br.tipY = y + br.restY;
        br.initialised = true;
      }

      // Infinite paint: keep the hair topped up AND refreshed to the loaded
      // pigment, so it never runs dry and never drifts toward the canvas colour.
      if (config.infiniteLoad) {
        br.load = config.loadCapacity;
        br.r = _loadR;
        br.g = _loadG;
        br.b = _loadB;
        br.s = _loadS;
      }

      // Anchor = head centre + splayed rest offset.
      final double ax = x + br.restX * splayScale;
      final double ay = y + br.restY * splayScale;

      // Spring-damper integration (semi-implicit Euler).
      final double fx = (ax - br.tipX) * config.stiffness - br.velX * config.damping;
      final double fy = (ay - br.tipY) * config.stiffness - br.velY * config.damping;
      br.velX += fx * dt;
      br.velY += fy * dt;
      br.tipX += br.velX * dt;
      br.tipY += br.velY * dt;

      // Deposit: lay a steady amount of paint while loaded, then taper to a
      // dry-brush skip in the last stretch. Crucially, the load is consumed
      // *more slowly* than paint is laid (mileage) — a real brush holds a deep
      // reservoir, so a loaded stroke covers a useful distance before drying.
      final double loadFrac =
          config.loadCapacity > 0 ? br.load / config.loadCapacity : 0.0;
      final double gate = (loadFrac * 3.0).clamp(0.0, 1.0);
      // Dwell boost: slow strokes lay more paint per length (so it pools where
      // the brush slows and at stroke ends — the classic place drips begin).
      final double dwellBoost = 1.0 + config.dwellBuildup * dwell;
      double laid = config.depositRate * press * dt * gate * br.gain * dwellBoost;
      final double consumeRate = (1.0 - 0.9 * config.mileage).clamp(0.1, 1.0);
      double consumed = laid * consumeRate;
      if (consumed > br.load) {
        laid *= br.load <= 0 ? 0.0 : br.load / consumed;
        consumed = br.load;
      }
      if (laid > 0) {
        // Coverage = how deep into the canvas tooth this bristle reaches. Full
        // load + pressure floods the valleys; as it runs dry only the tooth
        // peaks catch paint → drybrush / scumble with the canvas showing through.
        final double coverage =
            (loadFrac * (0.45 + 0.55 * press)).clamp(0.0, 1.0);
        final double rb = contactBase * br.rscale;

        if (mvlen < 1e-4 || config.bristleLength <= 0) {
          // Stationary dab.
          grid.deposit(br.tipX, br.tipY, rb, laid, br.r, br.g, br.b,
              coverage: coverage, ps: br.s);
        } else {
          // The brush flattens with pressure: contact runs from a leading belly
          // (ahead of the lagging tip, where most paint is laid and the patch is
          // widest) back to the trailing tip (less paint, narrower).
          final double contactLen =
              config.bristleLength * (0.25 + 0.75 * press) * br.gain;
          final double leadX = br.tipX + dirX * contactLen;
          final double leadY = br.tipY + dirY * contactLen;
          grid.deposit(leadX, leadY, rb * (1.0 + 0.6 * press), laid * 0.65,
              br.r, br.g, br.b,
              coverage: coverage, ps: br.s);
          grid.deposit(br.tipX, br.tipY, rb * 0.8, laid * 0.35, br.r, br.g,
              br.b,
              coverage: coverage * 0.85, ps: br.s);
        }
        br.load -= consumed;

        // Trailing tip plows wet paint: scrape a little from just ahead of the
        // tip and pile it behind, building ridges as the stroke continues.
        if (config.displacement > 0) {
          final double frac = (config.displacement * press * 0.4)
              .clamp(0.0, 0.5);
          final double moved = grid.scrape(
              br.tipX + dirX * 1.2, br.tipY + dirY * 1.2, rb, frac, picked,
              outS: pickedS);
          if (moved > 0) {
            grid.pile(br.tipX - dirX * 1.0, br.tipY - dirY * 1.0, rb * 1.1,
                moved, picked[0], picked[1], picked[2],
                ps: pickedS[0]);
          }
        }
      }

      // Wet-on-wet smear: the bristle reads the wet paint it's dragging through
      // and shifts its colour toward it. Read-only — no paint removed, load not
      // refilled. Gated by how much paint is actually there (wetFactor) so
      // dragging over thin/bare canvas barely shifts the hair (no muddy fade).
      // Skipped entirely under infinite paint, which holds a fixed colour.
      if (!config.infiniteLoad) {
        final double under = grid.sampleColor(
            br.tipX, br.tipY, contactBase * br.rscale, picked,
            outS: pickedS);
        if (under > 0.01) {
          final double wetFactor = (under / (under + 0.4)).clamp(0.0, 1.0);
          final double mix =
              (config.pickupRate * press * dt * 6.0 * wetFactor)
                  .clamp(0.0, 0.4);
          br.r += (picked[0] - br.r) * mix;
          br.g += (picked[1] - br.g) * mix;
          br.b += (picked[2] - br.b) * mix;
          br.s += (pickedS[0] - br.s) * mix;
        }
      }
    }
  }
}
