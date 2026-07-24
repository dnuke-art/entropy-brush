// Export facade. Desktop writes files to `~/entropybrush-exports`; web streams
// each export to a browser download. Selected by conditional import so the web
// bundle never pulls in `dart:io`.
//
// Keyed on `dart.library.js_interop` (true on ALL web compilers) rather than
// `dart.library.html` (true only on dart2js) — otherwise a dart2wasm build,
// where `dart:html` doesn't exist, would fall back to the `dart:io` exporter
// and fail to compile.
export 'exporter_io.dart' if (dart.library.js_interop) 'exporter_web.dart';
