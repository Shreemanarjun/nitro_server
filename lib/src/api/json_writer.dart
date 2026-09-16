/// A fast, native-backed JSON writer.
///
/// The handler drives it token by token; the bytes accumulate in a C++ buffer
/// and cross into Dart once at the end. On a 200-record payload it serializes
/// ~2.5x faster than `jsonEncode` + `utf8.encode` (dart:convert's
/// `JsonUtf8Encoder`), byte-identical to `jsonEncode`. Use it for hot JSON
/// response handlers; for one-off responses `ResponseContext.jsonBody` is
/// simpler.
///
/// ```dart
/// await server.get('/users', (_) => ResponseContext.jsonWriter((w) {
///   w.beginArray();
///   for (final u in users) {
///     w..beginObject()
///      ..key('id')..writeInt(u.id)
///      ..key('name')..writeString(u.name)
///      ..endObject();
///   }
///   w.endArray();
/// }));
/// ```
///
/// Correctness of the shape (matched `begin`/`end`, a key before each object
/// value) is the caller's, exactly like hand-writing JSON. Numbers: [writeInt]
/// and [writeDouble] both format natively, byte-identical to `jsonEncode` for
/// finite values — so `5` and `5.0` are the caller's choice, as with
/// `jsonEncode`.
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'native_loader.dart';

// ── FFI bindings, resolved once against the loaded native library ────────────

typedef _Vp = Pointer<Void>;

final class _JwNative {
  _JwNative._(DynamicLibrary lib)
    : jwNew = lib.lookupFunction<_Vp Function(), _Vp Function()>(
        'nitro_server_jw_new',
      ),
      reset = lib.lookupFunction<Void Function(_Vp), void Function(_Vp)>(
        'nitro_server_jw_reset',
        isLeaf: true,
      ),
      alloc = lib
          .lookupFunction<
            Pointer<Uint8> Function(Int32),
            Pointer<Uint8> Function(int)
          >('nitro_server_jw_alloc'),
      freeBuf = lib.lookupFunction<Void Function(_Vp), void Function(_Vp)>(
        'nitro_server_jw_free_buf',
      ),
      beginObject = lib.lookupFunction<Void Function(_Vp), void Function(_Vp)>(
        'nitro_server_jw_begin_object',
        isLeaf: true,
      ),
      endObject = lib.lookupFunction<Void Function(_Vp), void Function(_Vp)>(
        'nitro_server_jw_end_object',
        isLeaf: true,
      ),
      beginArray = lib.lookupFunction<Void Function(_Vp), void Function(_Vp)>(
        'nitro_server_jw_begin_array',
        isLeaf: true,
      ),
      endArray = lib.lookupFunction<Void Function(_Vp), void Function(_Vp)>(
        'nitro_server_jw_end_array',
        isLeaf: true,
      ),
      keyFn = lib
          .lookupFunction<
            Void Function(_Vp, Pointer<Uint8>, Int32),
            void Function(_Vp, Pointer<Uint8>, int)
          >('nitro_server_jw_key', isLeaf: true),
      intFn = lib
          .lookupFunction<Void Function(_Vp, Int64), void Function(_Vp, int)>(
            'nitro_server_jw_int',
            isLeaf: true,
          ),
      doubleFn = lib
          .lookupFunction<
            Void Function(_Vp, Double),
            void Function(_Vp, double)
          >('nitro_server_jw_double', isLeaf: true),
      stringFn = lib
          .lookupFunction<
            Void Function(_Vp, Pointer<Uint8>, Int32),
            void Function(_Vp, Pointer<Uint8>, int)
          >('nitro_server_jw_string', isLeaf: true),
      boolFn = lib
          .lookupFunction<Void Function(_Vp, Int32), void Function(_Vp, int)>(
            'nitro_server_jw_bool',
            isLeaf: true,
          ),
      nullFn = lib.lookupFunction<Void Function(_Vp), void Function(_Vp)>(
        'nitro_server_jw_null',
        isLeaf: true,
      ),
      rawFn = lib
          .lookupFunction<
            Void Function(_Vp, Pointer<Uint8>, Int32),
            void Function(_Vp, Pointer<Uint8>, int)
          >('nitro_server_jw_raw', isLeaf: true),
      emitTemplate = lib
          .lookupFunction<
            Void Function(
              _Vp,
              Int32,
              Int32,
              Pointer<Pointer<Uint8>>,
              Pointer<Int32>,
              Pointer<Uint8>,
              Pointer<Pointer<Void>>,
            ),
            void Function(
              _Vp,
              int,
              int,
              Pointer<Pointer<Uint8>>,
              Pointer<Int32>,
              Pointer<Uint8>,
              Pointer<Pointer<Void>>,
            )
          >('nitro_server_jw_emit_template', isLeaf: true),
      bytes = lib
          .lookupFunction<
            Pointer<Uint8> Function(_Vp),
            Pointer<Uint8> Function(_Vp)
          >('nitro_server_jw_bytes', isLeaf: true),
      len = lib.lookupFunction<Int32 Function(_Vp), int Function(_Vp)>(
        'nitro_server_jw_len',
        isLeaf: true,
      ),
      freeFinalizer = lib.lookup<NativeFinalizerFunction>(
        'nitro_server_jw_free',
      ),
      freeBufFinalizer = lib.lookup<NativeFinalizerFunction>(
        'nitro_server_jw_free_buf',
      );

  final _Vp Function() jwNew;
  final void Function(_Vp) reset;
  final Pointer<Uint8> Function(int) alloc;
  final void Function(_Vp) freeBuf;
  final void Function(_Vp) beginObject;
  final void Function(_Vp) endObject;
  final void Function(_Vp) beginArray;
  final void Function(_Vp) endArray;
  final void Function(_Vp, Pointer<Uint8>, int) keyFn;
  final void Function(_Vp, int) intFn;
  final void Function(_Vp, double) doubleFn;
  final void Function(_Vp, Pointer<Uint8>, int) stringFn;
  final void Function(_Vp, int) boolFn;
  final void Function(_Vp) nullFn;
  final void Function(_Vp, Pointer<Uint8>, int) rawFn;
  final void Function(
    _Vp,
    int,
    int,
    Pointer<Pointer<Uint8>>,
    Pointer<Int32>,
    Pointer<Uint8>,
    Pointer<Pointer<Void>>,
  )
  emitTemplate;
  final Pointer<Uint8> Function(_Vp) bytes;
  final int Function(_Vp) len;
  final Pointer<NativeFinalizerFunction> freeFinalizer;
  final Pointer<NativeFinalizerFunction> freeBufFinalizer;

  static _JwNative? _instance;
  static _JwNative get instance => _instance ??= _load();
  static _JwNative _load() {
    // A Dart CLI process opened the engine dylib by path (see native_loader);
    // reopen it for a handle carrying the writer symbols. When it is bundled
    // (Flutter) there is no path and the symbols are already in the process.
    final path = loadedNitroServerNativePath;
    if (path != null) return _JwNative._(DynamicLibrary.open(path));
    return _JwNative._(DynamicLibrary.process()); // coverage:ignore-line
  }
}

/// A key or string value marshaled to native memory once, so a hot writer can
/// emit it every request without re-encoding. Create tokens for the fixed
/// strings in a response's schema (its keys, and any constant values) at
/// startup and reuse them; the writer's [JsonWriter.key] /
/// [JsonWriter.writeString] pay a `utf8.encode` + copy on every call, which
/// dominates for value-light, key-heavy JSON.
final class JsonToken implements Finalizable {
  /// Marshals [value]'s UTF-8 bytes into native memory (freed when this token
  /// is garbage-collected).
  JsonToken(String value) : this._(utf8.encode(value));

  JsonToken._(Uint8List bytes) : length = bytes.length {
    final n = _JwNative.instance;
    pointer = n.alloc(bytes.isEmpty ? 1 : bytes.length);
    if (bytes.isNotEmpty) pointer.asTypedList(bytes.length).setAll(0, bytes);
    _finalizer.attach(this, pointer.cast(), detach: this);
  }

  /// Native pointer to the token's bytes (internal to [JsonWriter]).
  late final Pointer<Uint8> pointer;

  /// Byte length of the token.
  final int length;

  static final _finalizer = NativeFinalizer(
    _JwNative.instance.freeBufFinalizer,
  );
}

/// A varying numeric column for [JsonWriter.writeTemplatedArray]. Each row's
/// value is rendered exactly as [JsonWriter.writeInt] / [JsonWriter.writeDouble]
/// would, so the array is byte-identical to building it token by token.
sealed class JsonColumn {
  const JsonColumn();

  /// Number of records in the column.
  int get length;
}

/// An integer column (rendered like [JsonWriter.writeInt]).
final class IntColumn extends JsonColumn {
  const IntColumn(this.values);

  /// The per-record values.
  final Int64List values;

  @override
  int get length => values.length;
}

/// A double column (rendered like [JsonWriter.writeDouble]). Values must be
/// finite, as with `jsonEncode`.
final class DoubleColumn extends JsonColumn {
  const DoubleColumn(this.values);

  /// The per-record values.
  final Float64List values;

  @override
  int get length => values.length;
}

/// Builds a JSON document straight into a native byte buffer. Create one per
/// hot handler and reuse it via [reset], or use [ResponseContext.jsonWriter].
/// Call [dispose] to release native memory (a finalizer reclaims it if you
/// forget).
final class JsonWriter implements Finalizable {
  JsonWriter() : _n = _JwNative.instance, _w = _JwNative.instance.jwNew() {
    _finalizer.attach(this, _w, detach: this);
  }

  final _JwNative _n;
  final _Vp _w;
  Pointer<Uint8> _scratch = nullptr;
  int _scratchCap = 0;
  bool _disposed = false;

  static final _finalizer = NativeFinalizer(_JwNative.instance.freeFinalizer);

  /// Clears the buffer so the writer can serialize the next document.
  void reset() => _n.reset(_w);

  void beginObject() => _n.beginObject(_w);
  void endObject() => _n.endObject(_w);
  void beginArray() => _n.beginArray(_w);
  void endArray() => _n.endArray(_w);

  /// Writes an object key (the value follows). UTF-8 and JSON-escaped. Pays a
  /// `utf8.encode` + copy per call; use [keyToken] in hot loops.
  void key(String name) {
    final (ptr, n) = _marshal(name);
    _n.keyFn(_w, ptr, n);
  }

  /// Writes a pre-marshaled object key (the value follows). No re-encoding.
  void keyToken(JsonToken name) => _n.keyFn(_w, name.pointer, name.length);

  /// Writes a pre-marshaled string value. No re-encoding.
  void writeStringToken(JsonToken value) =>
      _n.stringFn(_w, value.pointer, value.length);

  /// Writes an integer value.
  void writeInt(int value) => _n.intFn(_w, value);

  /// Writes a double value, rendered natively byte-identically to `jsonEncode`
  /// (Dart's `double.toString()` shape). Throws for non-finite values, as
  /// `jsonEncode` does.
  void writeDouble(double value) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'not a finite JSON number');
    }
    _n.doubleFn(_w, value);
  }

  /// Writes a `num` as an integer or a double, matching its runtime type.
  void writeNum(num value) =>
      value is int ? writeInt(value) : writeDouble(value as double);

  /// Writes a string value. UTF-8 and JSON-escaped.
  void writeString(String value) {
    final (ptr, n) = _marshal(value);
    _n.stringFn(_w, ptr, n);
  }

  void writeBool(bool value) => _n.boolFn(_w, value ? 1 : 0);
  void writeNull() => _n.nullFn(_w);

  /// Writes already-encoded JSON [fragment] verbatim as one value (e.g. a
  /// cached sub-document). The caller guarantees it is valid JSON.
  void writeRaw(String fragment) {
    final (ptr, n) = _marshal(fragment);
    _n.rawFn(_w, ptr, n);
  }

  // Reused scratch for writeTemplatedArray's native argument arrays: the k+1
  // segment (pointer, length) pairs, the k column type tags and data pointers,
  // and one buffer holding every column's values back to back.
  Pointer<Pointer<Uint8>> _segPtrs = nullptr;
  Pointer<Int32> _segLens = nullptr;
  int _segCap = 0;
  Pointer<Uint8> _colTypes = nullptr;
  Pointer<Pointer<Void>> _colData = nullptr;
  int _colCap = 0;
  Pointer<Uint8> _colBuf = nullptr;
  int _colBufCap = 0;

  /// Writes a JSON array of records built from a fixed template, in one native
  /// call — the engine runs the whole loop, so a hot handler pays no per-token
  /// method call or FFI crossing. For a fixed-schema array whose only varying
  /// fields are numeric (the common `[{id, ...metrics}, …]` response), this is
  /// the fast path; the token-by-token methods stay for irregular shapes.
  ///
  /// [segments] are the constant bytes around and between the varying values —
  /// interned [JsonToken]s built once. [columns] are the varying numeric
  /// fields ([IntColumn]/[DoubleColumn]); the array holds `columns.first.length`
  /// records, and each record is
  /// `segments[0] col[0][i] segments[1] col[1][i] … columns.last[i] segments[last]`.
  /// There must be exactly one more segment than columns, and every column the
  /// same length. Example — `[{"id":0,"score":0.0},…]`:
  ///
  /// ```dart
  /// w.writeTemplatedArray(
  ///   [JsonToken('{"id":'), JsonToken(',"score":'), JsonToken('}')],
  ///   [IntColumn(ids), DoubleColumn(scores)],
  /// );
  /// ```
  void writeTemplatedArray(List<JsonToken> segments, List<JsonColumn> columns) {
    final k = columns.length;
    if (segments.length != k + 1) {
      throw ArgumentError(
        'writeTemplatedArray needs one more segment than '
        'columns (${segments.length} segments, $k columns)',
      );
    }
    final n = k == 0 ? 0 : columns.first.length;
    if (k + 1 > _segCap) {
      if (_segPtrs != nullptr) _n.freeBuf(_segPtrs.cast());
      if (_segLens != nullptr) _n.freeBuf(_segLens.cast());
      _segPtrs = _n.alloc((k + 1) * sizeOf<Pointer<Uint8>>()).cast();
      _segLens = _n.alloc((k + 1) * sizeOf<Int32>()).cast();
      _segCap = k + 1;
    }
    if (k > _colCap) {
      if (_colTypes != nullptr) _n.freeBuf(_colTypes.cast());
      if (_colData != nullptr) _n.freeBuf(_colData.cast());
      _colTypes = _n.alloc(k);
      _colData = _n.alloc(k * sizeOf<Pointer<Void>>()).cast();
      _colCap = k;
    }
    final need = k * n * 8;
    if (need > _colBufCap) {
      if (_colBuf != nullptr) _n.freeBuf(_colBuf.cast());
      _colBuf = _n.alloc(need);
      _colBufCap = need;
    }
    for (var c = 0; c < k; c++) {
      _segPtrs[c] = segments[c].pointer;
      _segLens[c] = segments[c].length;
      final col = columns[c];
      if (col.length != n) {
        throw ArgumentError(
          'every column must be the same length '
          '(column $c has ${col.length}, expected $n)',
        );
      }
      final slice = Pointer<Uint8>.fromAddress(_colBuf.address + c * n * 8);
      _colData[c] = slice.cast();
      switch (col) {
        case IntColumn():
          _colTypes[c] = 0;
          slice.cast<Int64>().asTypedList(n).setAll(0, col.values);
        case DoubleColumn():
          _colTypes[c] = 1;
          slice.cast<Double>().asTypedList(n).setAll(0, col.values);
      }
    }
    _segPtrs[k] = segments[k].pointer;
    _segLens[k] = segments[k].length;
    _n.emitTemplate(_w, n, k, _segPtrs, _segLens, _colTypes, _colData);
  }

  /// The bytes written so far, copied into a Dart-owned list.
  Uint8List toBytes() {
    final n = _n.len(_w);
    return Uint8List.fromList(_n.bytes(_w).asTypedList(n));
  }

  /// Releases native memory. Idempotent; the writer must not be used after.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    if (_scratch != nullptr) _n.freeBuf(_scratch.cast());
    if (_segPtrs != nullptr) _n.freeBuf(_segPtrs.cast());
    if (_segLens != nullptr) _n.freeBuf(_segLens.cast());
    if (_colTypes != nullptr) _n.freeBuf(_colTypes.cast());
    if (_colData != nullptr) _n.freeBuf(_colData.cast());
    if (_colBuf != nullptr) _n.freeBuf(_colBuf.cast());
    _n.freeBuf(_w);
  }

  // Copies [s]'s UTF-8 bytes into a reused native scratch buffer and returns
  // (pointer, length): the FFI calls take a native pointer, and Dart lists
  // have no stable one without a copy.
  (Pointer<Uint8>, int) _marshal(String s) {
    final bytes = utf8.encode(s);
    if (bytes.length > _scratchCap) {
      if (_scratch != nullptr) _n.freeBuf(_scratch.cast());
      _scratch = _n.alloc(bytes.length);
      _scratchCap = bytes.length;
    }
    if (bytes.isNotEmpty) _scratch.asTypedList(bytes.length).setAll(0, bytes);
    return (_scratch, bytes.length);
  }
}
