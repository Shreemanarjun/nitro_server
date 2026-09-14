/// Dart-only library loading: candidate order, platform names, the load
/// guard, and the error when nothing is found. The real open is exercised
/// against the built library; without it those tests skip.
library;

import 'dart:io';

import 'package:nitro_server/src/api/native_loader.dart';
import 'package:test/test.dart';

void main() {
  test('library names per platform, unsupported throws', () {
    expect(
      nitroServerLibraryName(operatingSystem: 'macos'),
      endsWith('.dylib'),
    );
    expect(nitroServerLibraryName(operatingSystem: 'linux'), endsWith('.so'));
    expect(
      nitroServerLibraryName(operatingSystem: 'windows'),
      endsWith('.dll'),
    );
    expect(
      () => nitroServerLibraryName(operatingSystem: 'fuchsia'),
      throwsUnsupportedError,
    );
    expect(
      nitroServerLibraryName(),
      nitroServerLibraryName(operatingSystem: Platform.operatingSystem),
    );
  });

  test('candidates: explicit path, then env override, then cmake outputs', () {
    final name = nitroServerLibraryName();
    expect(
      nitroServerLibraryCandidates(
        path: '/x/lib.dylib',
        environment: const {'NITRO_SERVER_DYLIB': '/env/lib.dylib'},
      ),
      ['/x/lib.dylib', '/env/lib.dylib', 'build/lib/$name', 'build/$name'],
    );
    expect(
      nitroServerLibraryCandidates(
        environment: const {'NITRO_SERVER_DYLIB': ''},
      ),
      ['build/lib/$name', 'build/$name'],
    );
    // The process environment is the default source.
    expect(nitroServerLibraryCandidates(), contains('build/lib/$name'));
  });

  group('loading', () {
    final built = File('build/lib/${nitroServerLibraryName()}');
    final skip = built.existsSync() ? null : 'native library not built';

    tearDown(resetNitroServerNativeLoadedForTesting);

    test('opens the built library once, then reports already loaded', () {
      resetNitroServerNativeLoadedForTesting();
      expect(nitroServerNativeLoadedForTesting, isFalse);
      final path = loadNitroServerNative(path: built.path);
      expect(path, built.absolute.path);
      expect(loadedNitroServerNativePath, built.absolute.path);
      expect(nitroServerNativeLoadedForTesting, isTrue);
      expect(loadNitroServerNative(), 'already loaded');
    }, skip: skip);

    test('a search that finds nothing names every path it tried', () {
      final previous = Directory.current;
      Directory.current = Directory.systemTemp;
      try {
        expect(
          () => loadNitroServerNative(path: '/definitely/not/here.dylib'),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('/definitely/not/here.dylib'),
            ),
          ),
        );
      } finally {
        Directory.current = previous;
      }
    });
  });
}
