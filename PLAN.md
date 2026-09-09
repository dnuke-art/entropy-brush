# Plan / TODO

Running list of planned work. See `README.md` and `docs/simulation.md` for the
current model; this file is the "next up" backlog.

## Palette & pigments

- [ ] **Custom color picker for pigment swatches.** Add a small tap area in the
      **upper-right corner** of each pigment swatch that pops up a color picker,
      so a swatch's pigment can be recolored to any custom color (not just the
      four presets). Persist the chosen color for the session.

- [ ] **Add "medium" as a selectable option alongside pigments.** A non-pigment
      medium (linseed/glaze/transparent extender) selectable like a swatch. Loading
      medium thins/extends without adding pigment — lower opacity, more flow/gloss,
      lets you make glazes and washes. Mixing medium into a pigment on the palette
      should reduce its tinting strength (KM concentration), not just lighten it.

- [ ] **Load the brush from the *transition* of mixes on the palette.** Today
      loading samples a single spot. Instead, capture the **sequence/gradient of
      colors the load stroke passes over** on the palette, so the brush picks up
      multiple hues along its length/load and a single canvas stroke then
      **transitions through those colors** as it plays out (like a real brush
      dragged through several piles of paint). Needs the brush load to hold an
      ordered color profile rather than one flat color.

## App Store release — iPad app (STARTED 2026-09-08)

Shipping entropybrush to the Apple App Store as an **iPad-only** app, via the
`app-store-release` skill (Linux, no Mac; GitHub Actions macOS runner + the
persistent Distribution cert on team `W527ZN3X52`). Decisions: **iPad-only**,
**touch-first** (Apple Pencil pressure/tilt is a later follow-up), and **fix
spin perf before submitting**.

- Bundle id: `com.dnuke.entropybrush` (registered App ID `GXPQ9QQ846`, UNIVERSAL;
  lowercase + `com.` to match the `com.<owner>.<app>` house convention). Display
  name: `entropybrush`.

**Phase 1 — iOS target (DONE)**
- [x] `flutter create --platforms=ios --org art.dnuke .`
- [x] iPad-only (`TARGETED_DEVICE_FAMILY = 2`), `ITSAppUsesNonExemptEncryption
      = false`, display name `entropybrush`, real pubspec description.
- [x] Removed boilerplate `test/widget_test.dart` (referenced a nonexistent
      `MyApp`). Note: `flutter create` also auto-edited `analysis_options.yaml`
      (added `analyzer: exclude:` for build/platform dirs) and refreshed
      `pubspec.lock` — both benign, uncommitted.

**Phase 2 — make it good on iPad (IN PROGRESS)**
- [x] Spin perf fix (Performance § item #1). `PaintController._syncSpinQuality()`
      auto-drops the grid to `spinQuality` (default `qualityLow` 384) on
      spin-start and restores on stop; `autoSpinQuality` gates it. Detected via a
      spin-start/stop transition inside `frame()` — no UI/API change. Measured
      scaling (linear in cells): flooded flow step 768²=32.9 ms, 512²=15.0 ms →
      384²≈8.4 ms, so a 768² spin frame drops ~171 ms → ~44 ms (**6 → ~23 fps**).
- [x] Lighter base grid on mobile: `main.dart` now picks `qualityMed` (512) on
      iOS/Android (was desktop `qualityHigh` 768), same as web.
- [ ] **On-device tuning (TestFlight):** measure spin on the target iPad and
      lower `spinQuality` (→256?) and/or the base grid if needed — mobile CPU is
      weaker than the desktop numbers above; can't measure it from Linux.
- [x] iPad touch gestures (`paint_canvas.dart`): 1 finger paints (tap=dab,
      drag=stroke); 2 fingers pan + pinch-zoom (midpoint-anchored); strokes
      deferred until move/lift so framing leaves no stray dab. Orbit gizmo
      enlarged 78→112 (separate widget → orbit+paint simultaneously still works).
      Shipped in build 34272470976 (TestFlight, 2026-09-08) — needs on-device feel check.
- [x] App icon wired in (impasto brushstroke; source at `ios/appstore/icon.svg`).
      Placeholder — may revisit the art.
- [ ] iPad UX pass: control panel + canvas sizing for touch, safe-area insets,
      verify the relief FragmentShader renders under Impeller on iOS.
- [x] Fixed iOS export: was writing to a desktop `~/entropybrush-exports` path
      that fails in the sandbox. Now `exporter_io.dart` writes to the app's temp
      dir on mobile and hands files to the system share sheet (`share_plus` +
      `path_provider`); desktop keeps the visible folder. Needs on-device check.

**Phase 3 — release pipeline (skill automates)**
- [x] `.github/workflows/ios.yml` (tag `ios-v*`, `runs-on: macos-26`, imports the
      persistent team dist cert via `IOS_P12_BASE64`/`IOS_P12_PASSWORD`, cloud
      auth via ASC key, `-allowProvisioningUpdates`, `DEVELOPMENT_TEAM=W527ZN3X52`)
      → TestFlight. `ios/ExportOptionsCI.plist` = app-store-connect/upload/auto.
      Modeled on `dnewcome/curiate`; CI gate is `flutter analyze` (repo's tests
      are diagnostic scripts that make `flutter test` exit non-zero).
- [x] 5 repo secrets set on `dnuke-art/entropy-brush` (`APP_STORE_CONNECT_P8`,
      `APP_STORE_CONNECT_KEY_ID` 737KQRD655, `APP_STORE_CONNECT_ISSUER_ID`,
      `IOS_P12_BASE64`, `IOS_P12_PASSWORD`).
- [x] Register the App ID `com.dnuke.entropybrush` (ASC API — `GXPQ9QQ846`).
- [x] Create the ASC app record (SKU `entropybrush-ios-001`, Full access).
- [x] **First build green**: tag `ios-v1.0.0` → Actions run #34267429826 succeeded
      (macos-26, persistent-cert import + archive + upload all passed); IPA
      uploaded to TestFlight 2026-09-08. Built on branch `ios-app-setup`.
      (Minor: `actions/checkout@v4.2.2` throws a Node-20 deprecation warning —
      bump to `@v5` eventually.)
- [ ] Merge `ios-app-setup` → `main` now that the build is proven green.
- [ ] TestFlight internal testing: create/enable an internal group + automatic
      distribution, add self as tester, install via TestFlight app on the iPad.
- [ ] On-device: feel the spin perf; tune `spinQuality` (→256?) if needed.
- [x] Privacy + support pages LIVE (`entropybrush.art/privacy.html`,
      `/support.html`) — after reconnecting DO to the `dnuke-art` repo owner.
- [~] Automated screenshots: `ios-screenshots.yml` drives the real app on an
      iPad Pro 13" simulator (integration_test + `lib/screenshot_seed.dart`
      showcase scenes: hero, spin, impasto, mixing) → artifact
      `appstore-screenshots-ipad-13` at 2064×2752. Iterating on the seed visuals
      via CI (can't render iOS locally). Mirrors cadsketch's pipeline.
- [ ] ASC listing via `tools/asc_listing.py` (metadata drafted), then App
      Privacy + Submit.
- [ ] Screenshots at the app's own iPad 13" render size (2064×2752), no alpha.
- [ ] Fill App Store Connect via `tools/asc_listing.py` (metadata/, screenshots/).
- [ ] Manual clicks: App Privacy questionnaire + Submit for Review.

## Performance — wet-region drying fix (2026-09-09)

Thick paint dried far too slowly, so the flow sim kept re-simulating the whole
painted area every frame (worst during spin-art: adding marks tanked the frame
rate). Root cause measured (`test/dry_probe.dart`): dry-out time grew unbounded
with thickness — 0.08→22s, 1.58→70s, 5.92→**132s**. Fix in `flowStep`: cap the
`thickness·8` dry-slowdown multiplier and raise the wet-drop threshold
0.004→0.02 (below it paint barely flows, so it only bloats the wet bbox). After:
0.08→16s, 1.58→47s, 5.92→**47s (bounded)**; paint conservation unchanged. Added
`PaintGrid.hasWet`/`wetArea` getters for diagnostics.

## Performance — spin on iPad + build versioning (2026-09-09)

Spin stayed slow after the drying fix because *during* spin the paint is flung
across the whole canvas, so the wet region is inherently the full grid: cost =
substeps × full-grid flow step. Measured full-grid step: 512²=14.2 ms,
384²=8.4 ms, **256²=3.9 ms**, 192²=2.4 ms. iPad spin was 384²×5 ≈ 42 ms/frame
(~12-16 fps). Fix (`main.dart`, mobile only): `spinQuality=256`,
`maxSpinSubsteps=3` → ≈12 ms/frame (~45-55 fps). Coarser cells move paint
farther per step so the fling feel holds (~90%); the base grid restores when
spin stops. `maxSpinSubsteps` is a new controller dial (default 16).

Build versioning: manual (workflow_dispatch) builds now auto-bump the marketing
version to `<major.minor>.<run#>` so every TestFlight build is a distinct
version (no more identical "1.0.0"s); explicit `ios-v*` tags still set it
directly. Build number stays Unix epoch (monotonic; kept under 2^31 — a
readable datestamp would exceed the existing epoch numbers / risk Apple's cap).
Bumping the version costs no build time.

## Spin: paint piling into the corners (2026-09-09)

User report: after the spin speed-up, flung paint went to the corners far more.
Cause: grid anisotropy in the body-force cap. Paint moves on a 4-connected grid
and the spin force's x and y parts were each capped independently at `gcap`, so
a *saturated* diagonal flow moved √2× farther per step than an axis-aligned one.
It only bites at saturation — and fewer, bigger substeps (`spinCf` is `/iters`)
on a coarser grid saturate constantly. Fix (`flowStep`): cap the body-force
displacement as a Euclidean vector, so every direction gets the same
displacement per step. Measured (`test/spin_isotropy_probe.dart`, pure
centrifugal spin, diagonal-sector mass ÷ axis-sector mass; isotropic ≈ 1.0):
**before 10.75 → after 0.745**. Residual mild axis bias is inherent to the
4-connected grid (a diagonal force can only land on an x/y neighbour). Paint
conservation and spin tests unchanged.

## Performance — making the sim faster (PAUSED 2026-07-29)

Investigated but not yet implemented. The complaint is spin-art mode; normal
painting is already fine.

### Where the time goes (measured, `dart run test/perf_probe.dart`, 768²)

- One brush dab's flow: **0.23 ms** — already cheap (wet-bbox bounded).
- Full-grid encode (height + albedo): **7.1 ms** — every painted/spun frame
  (throttled to 30 Hz for continuous modes).
- One *flooded* flow step (spin, whole canvas wet): **32.9 ms**.
- Spin runs `min(16, 2 + spinSpeed·2)` substeps/frame (5 at default
  `spinSpeed 1.5`), because each explicit step moves paint only ~1 cell (CFL).
  So **768² spin ≈ 5 × 32.9 + 7 ≈ 171 ms/frame ≈ 6 fps** — that's the problem.
- Scaling is ~linear in cell count (512² flooded step = 15.0 ms; encode 3.1 ms).

### The ceiling problem

The flow is a *scatter*-based stencil on the CPU. Every CPU lever has a low
ceiling; only the GPU changes the game:

- WASM: already tested — **no gain** (V8 already JITs the Float32List loops).
- Float32x4 SIMD: up to ~4× on desktop, ~0 on web; needs the scatter→gather
  reformulation first (conditional neighbor-writes don't vectorize).
- Isolate parallelism: ~Ncores, but Dart isolates don't share mutable memory
  (per-frame copy eats the win); also needs gather (scatter has row-boundary
  write races).
- **GPU ping-pong shaders: 10–50×.** The real answer. But Flutter's
  `FragmentShader` has no good multi-pass render-to-texture feedback, so this
  means owning a WebGL/WebGPU context — i.e. moving the render+sim core out of
  Flutter (web: `<canvas>` + three.js/WebGPU; desktop: native GL surface). This
  is the real fork behind "maybe ditch Flutter."

### Plan (in priority order)

- [ ] **1. Auto-drop resolution while spinning (do first; keeps Flutter).**
      Spin is fast and blurry — 768² is invisible there. Have `frame()` switch
      to a `spinQuality` on spin-start and restore on stop (`setQuality` already
      resamples + preserves the painting). 384² → spin frame ~171 → **~43 ms
      (23 fps)**; 256² → **~19 ms (50 fps)**. Low risk, ~an afternoon.
- [ ] **2. Scatter→gather reformulation of `flowStep`, then Float32x4 on
      desktop.** ~2–4× on desktop, no web benefit. Worth it mainly because the
      gather form is the prerequisite for both SIMD and threads. Days of work.
- [ ] **3. GPU flow-step prototype (the real decision).** Build a throwaway
      WebGPU ping-pong of *just* the flow step on one spin scene, measure the
      speedup, and use that hard number to decide whether to move the sim/render
      core off Flutter. Reference architecture: the toolcraft.sh liquid-metal
      demo (React + Vite + three.js/WebGL2 + custom GLSL).

- [x] **Dirty-rect encode (done).** `encodeHeightRGBA`/`encodeAlbedoRGBA` now
      re-pack only the grid's dirty rect into the reused buffer (full-pack only
      when fresh or whole-grid-invalidated). Measured: a brush-dab encode dropped
      ~3.2 ms (512²) / 7.3 ms → **~0.01 ms** — the per-frame painting CPU cost is
      now ~free. Spin still full-encodes (whole grid dirty), but that's covered
      by the auto-quality drop. The texture *upload* + `toImage` stay full-image
      (the remaining per-rebuild GPU cost; would need drawing the shader straight
      onto the slab to remove `picture.toImage()`, a bigger rework).
