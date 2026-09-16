/// The engine's native Brotli codec, reached through the generated
/// `NitroServerNative` bridge (its `brotliEncode` / `brotliDecode` /
/// `supportsBrotli` methods).
///
/// Dart's `dart:io` has gzip/zlib but no brotli, so the engine links libbrotli
/// and exposes it. Optional, like the engine's TLS: when the engine was built
/// without libbrotli — or the native library was never loaded (pure-Dart use
/// before `loadNitroServerNative`) — [brotliAvailable] is false and the
/// `compress()` middleware falls back to gzip.
library;

import 'dart:typed_data';

import '../nitro_server.native.dart';

/// Whether native brotli is usable: the engine library is loaded into this
/// process and was built with libbrotli. False (never throwing) in pure-Dart
/// use where the engine dylib was never opened, so `compress()` falls back to
/// gzip. Checked once by `compress()`.
bool brotliAvailable() {
  try {
    return NitroServerNative.engine.supportsBrotli();
  } on Object {
    return false; // engine not loaded, or brotli not built in
  }
}

/// Brotli-encodes [body] at [quality] (0–11) in text mode. Callers must have
/// confirmed [brotliAvailable] first.
Uint8List brotliCompress(Uint8List body, int quality) =>
    NitroServerNative.engine.brotliEncode(body, quality);

/// Brotli-decodes [data], the inverse of [brotliCompress]. Exposed so round-trip
/// tests can verify output — Dart's `dart:io` has no brotli decoder. Callers
/// must have confirmed [brotliAvailable] first.
Uint8List brotliDecompress(Uint8List data) =>
    NitroServerNative.engine.brotliDecode(data);
