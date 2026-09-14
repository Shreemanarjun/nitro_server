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

/// Whether [loadNitroServerNative] has already opened the library in this
/// isolate. Test seam.
bool get nitroServerNativeLoadedForTesting => _loaded;

/// Resets the load guard, so the next [loadNitroServerNative] call opens the
/// library again. Test seam.
void resetNitroServerNativeLoadedForTesting() => _loaded = false;

/// Platform file name of the built native library.
String nitroServerLibraryName() {
  if (Platform.isMacOS) return 'libnitro_server.dylib';
  if (Platform.isLinux) return 'libnitro_server.so';
  if (Platform.isWindows) return 'nitro_server.dll';
  throw UnsupportedError(
    'nitro_server has no native library for ${Platform.operatingSystem}',
  );
}

/// Candidate locations for the cmake-built library, in priority order.
List<String> nitroServerLibraryCandidates({String? path}) {
  final name = nitroServerLibraryName();
  final candidates = <String>[];
  if (path != null) candidates.add(path);
  final override = Platform.environment['NITRO_SERVER_DYLIB'];
  if (override != null && override.isNotEmpty) candidates.add(override);
  candidates.add('build/lib/$name');
  candidates.add('build/$name');
  return candidates;
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
