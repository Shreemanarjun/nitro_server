/// Dart-only native library loading for `nitro_server`.
///
/// Flutter apps never touch this file: the tooling builds and bundles the
/// `ffiPlugin` native library automatically. Dart CLI programs (benchmarks,
/// servers, `dart test`) build it with cmake and load it explicitly:
///
/// ```dart
/// import 'package:nitro_server/nitro_server.dart';
///
/// void main() async {
///   loadNitroServerNative(); // opens build/lib/libnitro_server.dylib (.so/.dll)
///   final server = await NitroServer.bind();
///   // ...
/// }
/// ```
///
/// The lookup order is: explicit [path] → `NITRO_SERVER_DYLIB` env var →
/// conventional cmake outputs relative to [Directory.current]
/// (`build/lib/<name>`, `build/<name>`). The call is idempotent.
library;

import 'dart:ffi';
import 'dart:io';

bool _loaded = false;
String? _loadedPath;

/// The absolute path [loadNitroServerNative] opened in this isolate, or null
/// when the library came bundled (Flutter) or was never loaded explicitly.
/// Helper isolates open the same file so their bindings resolve.
String? get loadedNitroServerNativePath => _loadedPath;

/// Whether [loadNitroServerNative] has already opened the library in this
/// isolate. Test seam.
bool get nitroServerNativeLoadedForTesting => _loaded;

/// Resets the load guard, so the next [loadNitroServerNative] call opens the
/// library again. Test seam.
void resetNitroServerNativeLoadedForTesting() => _loaded = false;

const _libraryNames = {
  'macos': 'libnitro_server.dylib',
  'linux': 'libnitro_server.so',
  'windows': 'nitro_server.dll',
};

/// Platform file name of the built native library, for [operatingSystem]
/// (default: the current one). Throws [UnsupportedError] elsewhere.
String nitroServerLibraryName({String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  return _libraryNames[os] ??
      (throw UnsupportedError('nitro_server has no native library for $os'));
}

/// Candidate locations for the cmake-built library, in priority order:
/// [path], then `NITRO_SERVER_DYLIB` from [environment] (default: the
/// process environment), then the conventional cmake outputs.
List<String> nitroServerLibraryCandidates({
  String? path,
  Map<String, String>? environment,
}) {
  final name = nitroServerLibraryName();
  final override = (environment ?? Platform.environment)['NITRO_SERVER_DYLIB'];
  return [
    ?path,
    if (override != null && override.isNotEmpty) override,
    'build/lib/$name',
    'build/$name',
  ];
}

/// Opens the native library so the generated bindings can resolve it.
///
/// On Apple platforms Nitro resolves symbols through
/// `DynamicLibrary.process()`, i.e. images already loaded into the process —
/// opening the dylib here is what makes the plugin visible. The same call is
/// harmless on Linux/Windows.
///
/// Throws [StateError] listing every searched path when nothing exists.
/// Pass an explicit [path] (or set `NITRO_SERVER_DYLIB`) to skip the search.
String loadNitroServerNative({String? path}) {
  if (_loaded) return 'already loaded';
  for (final candidate in nitroServerLibraryCandidates(path: path)) {
    if (File(candidate).existsSync()) {
      final absolute = File(candidate).absolute.path;
      DynamicLibrary.open(absolute);
      _loaded = true;
      _loadedPath = absolute;
      return absolute;
    }
  }
  throw StateError(
    'nitro_server native library not found. Build it first:\n'
    '  cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release\n'
    '  cmake --build build/lib --parallel\n'
    'Searched: ${nitroServerLibraryCandidates(path: path).join(', ')}\n'
    'or pass an explicit path / set NITRO_SERVER_DYLIB.',
  );
}
