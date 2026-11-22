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

import 'package:nitro/nitro.dart';

import '../nitro_server.native.dart';

// The writer and every byte buffer are native handles from the engine bridge
// (`NitroServerNative.json*`): owned handles free themselves on GC, and the
// per-token calls are `@nitroFast` leaf calls over memory reused across calls.
final NitroServerNative _n = NitroServerNative.engine;

void _freeBuffer(NativeHandle<Uint8>? h) {
  if (h != null) _n.jsonFreeBuffer(h);
}

// A view of [h]'s memory typed for the untyped (`NativeHandle<Void>`) params.
NativeHandle<Void> _voidView(NativeHandle<Uint8> h) =>
    NativeHandle<Void>(h.pointer.cast());

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

  JsonToken._(Uint8List bytes)
    : length = bytes.length,
      handle = _n.jsonAlloc(bytes.length) {
    _finalizer.attach(this, handle);
    if (bytes.isNotEmpty) pointer.asTypedList(bytes.length).setAll(0, bytes);
  }

  /// Native handle to the token's bytes (internal to [JsonWriter]); freed when
  /// the token is garbage-collected.
  final NativeHandle<Uint8> handle;

  /// Native pointer to the token's bytes (internal to [JsonWriter]).
  Pointer<Uint8> get pointer => handle.pointer;

  /// Byte length of the token.
  final int length;

  static final _finalizer = Finalizer<NativeHandle<Uint8>>(_n.jsonFreeBuffer);
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
  JsonWriter() : _w = _n.jsonCreate() {
    _finalizer.attach(this, _w, detach: this);
    _growScratch(64);
  }

  final NativeHandle<Void> _w;
  NativeHandle<Uint8>? _scratchHandle;
  Pointer<Uint8> _scratch = nullptr;
  int _scratchCap = 0;
  bool _disposed = false;

  static final _finalizer = Finalizer<NativeHandle<Void>>(_n.jsonFree);

  /// Clears the buffer so the writer can serialize the next document.
  void reset() => _n.jsonReset(_w);

  void beginObject() => _n.jsonBeginObject(_w);
  void endObject() => _n.jsonEndObject(_w);
  void beginArray() => _n.jsonBeginArray(_w);
  void endArray() => _n.jsonEndArray(_w);

  /// Writes an object key (the value follows). UTF-8 and JSON-escaped. Pays a
  /// `utf8.encode` + copy per call; use [keyToken] in hot loops.
  void key(String name) {
    final n = _marshal(name); // may grow (replace) the scratch
    _n.jsonKey(_w, _scratchHandle!, n);
  }

  /// Writes a pre-marshaled object key (the value follows). No re-encoding.
  void keyToken(JsonToken name) => _n.jsonKey(_w, name.handle, name.length);

  /// Writes a pre-marshaled string value. No re-encoding.
  void writeStringToken(JsonToken value) =>
      _n.jsonString(_w, value.handle, value.length);

  /// Writes an integer value.
  void writeInt(int value) => _n.jsonInt(_w, value);

  /// Writes a double value, rendered natively byte-identically to `jsonEncode`
  /// (Dart's `double.toString()` shape). Throws for non-finite values, as
  /// `jsonEncode` does.
  void writeDouble(double value) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'not a finite JSON number');
    }
    _n.jsonDouble(_w, value);
  }

  /// Writes a `num` as an integer or a double, matching its runtime type.
  void writeNum(num value) =>
      value is int ? writeInt(value) : writeDouble(value as double);

  /// Writes a string value. UTF-8 and JSON-escaped.
  void writeString(String value) {
    // Win ②: escape+encode in one Dart pass, then memcpy via jw_raw — the
    // native side no longer re-scans every byte to escape (jw_string).
    final n = _marshalEscaped(value); // may grow (replace) the scratch
    _n.jsonRaw(_w, _scratchHandle!, n);
  }

  void writeBool(bool value) => _n.jsonBool(_w, value);
  void writeNull() => _n.jsonNull(_w);

  /// Serializes an arbitrary JSON [value] (`Map`, `List`, `String`, `int`,
  /// `double`, `bool`, `null`) by walking it and driving the writer directly —
  /// no intermediate `String` like `jsonEncode` + `utf8.encode`, so it is the
  /// fast path behind [ResponseContext.jsonBody]. A non-JSON object is asked
  /// for `.toJson()` (as `jsonEncode` does); if it has none, a
  /// [JsonUnsupportedObjectError] is thrown naming the type.
  void writeValue(Object? value) {
    switch (value) {
      case null:
        writeNull();
      case final bool b:
        writeBool(b);
      case final int i:
        writeInt(i);
      case final double d:
        writeDouble(d);
      case final String s:
        writeString(s);
      case final Map<dynamic, dynamic> m:
        beginObject();
        for (final e in m.entries) {
          key(e.key.toString());
          writeValue(e.value);
        }
        endObject();
      case final List<dynamic> l:
        beginArray();
        for (final v in l) {
          writeValue(v);
        }
        endArray();
      default:
        final Object? converted;
        try {
          converted = (value as dynamic).toJson();
        } catch (_) {
          throw JsonUnsupportedObjectError(value);
        }
        writeValue(converted);
    }
  }

  /// Writes already-encoded JSON [fragment] verbatim as one value (e.g. a
  /// cached sub-document). The caller guarantees it is valid JSON.
  void writeRaw(String fragment) {
    final n = _marshal(fragment); // may grow (replace) the scratch
    _n.jsonRaw(_w, _scratchHandle!, n);
  }

  // Reused scratch for writeTemplatedArray's native argument arrays: the k+1
  // segment (pointer, length) pairs, the k column type tags and data pointers,
  // and one buffer holding every column's values back to back.
  NativeHandle<Uint8>? _segPtrs;
  NativeHandle<Uint8>? _segLens;
  int _segCap = 0;
  NativeHandle<Uint8>? _colTypes;
  NativeHandle<Uint8>? _colData;
  int _colCap = 0;
  NativeHandle<Uint8>? _colBuf;
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
      _freeBuffer(_segPtrs);
      _freeBuffer(_segLens);
      _segPtrs = _n.jsonAlloc((k + 1) * sizeOf<Pointer<Uint8>>());
      _segLens = _n.jsonAlloc((k + 1) * sizeOf<Int32>());
      _segCap = k + 1;
    }
    if (k > _colCap) {
      _freeBuffer(_colTypes);
      _freeBuffer(_colData);
      _colTypes = _n.jsonAlloc(k);
      _colData = _n.jsonAlloc(k * sizeOf<Pointer<Void>>());
      _colCap = k;
    }
    final need = k * n * 8;
    if (need > _colBufCap) {
      _freeBuffer(_colBuf);
      _colBuf = _n.jsonAlloc(need);
      _colBufCap = need;
    }
    final segPtrs = _segPtrs!.pointer.cast<Pointer<Uint8>>();
    final segLens = _segLens!.pointer.cast<Int32>();
    final colTypes = _colTypes!.pointer;
    final colData = _colData!.pointer.cast<Pointer<Void>>();
    final colBuf = _colBuf!.pointer;
    for (var c = 0; c < k; c++) {
      segPtrs[c] = segments[c].pointer;
      segLens[c] = segments[c].length;
      final col = columns[c];
      if (col.length != n) {
        throw ArgumentError(
          'every column must be the same length '
          '(column $c has ${col.length}, expected $n)',
        );
      }
      final slice = Pointer<Uint8>.fromAddress(colBuf.address + c * n * 8);
      colData[c] = slice.cast();
      switch (col) {
        case IntColumn():
          colTypes[c] = 0;
          slice.cast<Int64>().asTypedList(n).setAll(0, col.values);
        case DoubleColumn():
          colTypes[c] = 1;
          slice.cast<Double>().asTypedList(n).setAll(0, col.values);
      }
    }
    segPtrs[k] = segments[k].pointer;
    segLens[k] = segments[k].length;
    _n.jsonEmitTemplate(
      _w,
      n,
      k,
      _voidView(_segPtrs!),
      _voidView(_segLens!),
      _colTypes!,
      _voidView(_colData!),
    );
  }

  /// The bytes written so far, copied into a Dart-owned list.
  Uint8List toBytes() {
    final n = _n.jsonLength(_w);
    return Uint8List.fromList(_n.jsonBytes(_w).pointer.asTypedList(n));
  }

  /// The native buffer pointer + byte length, for answering straight from the
  /// writer (win ③) — the engine reads these synchronously in `respond`,
  /// skipping [toBytes]'s writer→Dart copy and the answerer's stage copy. Valid
  /// until the next [reset]/[dispose]; the caller must not dispose the writer
  /// before the (synchronous) respond returns.
  Pointer<Uint8> get nativeBufferPointer => _n.jsonBytes(_w).pointer;
  int get byteLength => _n.jsonLength(_w);

  /// Releases native memory. Idempotent; the writer must not be used after.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _freeBuffer(_scratchHandle);
    _freeBuffer(_segPtrs);
    _freeBuffer(_segLens);
    _freeBuffer(_colTypes);
    _freeBuffer(_colData);
    _freeBuffer(_colBuf);
    _finalizer.detach(this);
    _n.jsonFree(_w);
  }

  // ── Pooling (hot response path) ────────────────────────────────────────────
  // Per-isolate free-list so `ResponseContext.jsonWriter` reuses a native writer
  // buffer across requests. A fresh jwNew/jwFree per request churned the native
  // allocator (it kept the freed pages), climbing RSS into the GBs under
  // sustained large-response load. The pool caps LIVE writers at [_poolMax];
  // a burst past it disposes the extras. Statics are per-isolate (no race), and
  // a checked-out writer is off the list until [release].
  static final List<JsonWriter> _pool = <JsonWriter>[];
  static const int _poolMax = 256;
  bool _pooled = false; // in the free-list — guards a double [release]

  /// Checks out a cleared writer from the per-isolate pool (or makes one). Pair
  /// with [release] once the response bytes have been read by the engine.
  static JsonWriter checkout() {
    if (_pool.isEmpty) return JsonWriter();
    final w = _pool.removeLast();
    w._pooled = false;
    return w;
  }

  /// Returns this writer to the pool for reuse (clearing it first), or disposes
  /// it when the pool is full. Idempotent; the caller must not use the writer
  /// afterward. A no-op if already pooled (so a stray double-release can't alias
  /// one writer to two responses) or disposed.
  void release() {
    if (_disposed || _pooled) return;
    if (_pool.length < _poolMax) {
      reset();
      _pooled = true;
      _pool.add(this);
    } else {
      dispose();
    }
  }

  // Copies [s]'s UTF-8 bytes into a reused native scratch buffer and returns
  // the length: the native calls read the scratch, and Dart lists
  // have no stable one without a copy.
  // ASCII fast path: 1 byte per code unit, written straight into the native
  // scratch — no intermediate Dart list and no second copy (~3-4x faster than
  // utf8.encode + setAll for ASCII, the common case for JSON keys/values). The
  // first non-ASCII code unit falls back to full UTF-8; bytes are identical
  // either way. (The native key/string/raw fns escape + append, so _marshal
  // only has to land the UTF-8 bytes in the scratch.)
  int _marshal(String s) {
    final n = s.length;
    if (n > _scratchCap) _growScratch(n);
    if (n != 0) {
      final out = _scratch.asTypedList(_scratchCap);
      for (var i = 0; i < n; i++) {
        final c = s.codeUnitAt(i);
        if (c >= 0x80) return _marshalUtf8(s);
        out[i] = c;
      }
    }
    return n;
  }

  int _marshalUtf8(String s) {
    final bytes = utf8.encode(s);
    if (bytes.length > _scratchCap) _growScratch(bytes.length);
    if (bytes.isNotEmpty) _scratch.asTypedList(bytes.length).setAll(0, bytes);
    return bytes.length;
  }

  void _growScratch(int need) {
    _freeBuffer(_scratchHandle);
    final handle = _n.jsonAlloc(need);
    _scratchHandle = handle;
    _scratch = handle.pointer;
    _scratchCap = need;
  }

  static const _hexDigits = '0123456789abcdef';

  // Win ②: escape + UTF-8-encode [s] into the scratch as a complete JSON string
  // token `"<escaped>"` in one Dart pass, so the native side only has to memcpy
  // it in (`jw_raw`) instead of re-scanning every byte to escape (`jw_string`
  // -> writeEscaped). One scalar pass over the data instead of two. ASCII fast
  // path copies a byte per code unit; the first non-ASCII unit re-does it via
  // UTF-8. Bytes are identical to the native escaper either way.
  int _marshalEscaped(String s) {
    final n = s.length;
    // ponytail: worst case every char -> \u00XX (6B) + 2 quotes; transient and
    // reused, grown only when a longer string arrives. Swap for a per-char
    // grow-check if scratch memory on huge strings ever matters.
    final cap = n * 6 + 2;
    if (cap > _scratchCap) _growScratch(cap);
    final out = _scratch.asTypedList(_scratchCap);
    var j = 0;
    out[j++] = 0x22; // "
    for (var i = 0; i < n; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x80) return _marshalEscapedUtf8(s);
      if (c < 0x20 || c == 0x22 || c == 0x5c) {
        j = _escapeByte(out, j, c);
      } else {
        out[j++] = c;
      }
    }
    out[j++] = 0x22; // "
    return j;
  }

  int _marshalEscapedUtf8(String s) {
    final bytes = utf8.encode(s);
    final cap = bytes.length * 6 + 2;
    if (cap > _scratchCap) _growScratch(cap);
    final out = _scratch.asTypedList(_scratchCap);
    var j = 0;
    out[j++] = 0x22;
    for (final c in bytes) {
      if (c < 0x20 || c == 0x22 || c == 0x5c) {
        j = _escapeByte(out, j, c);
      } else {
        out[j++] =
            c; // >= 0x80 UTF-8 bytes copy as-is (JSON does not escape them)
      }
    }
    out[j++] = 0x22;
    return j;
  }

  int _escapeByte(Uint8List out, int j, int c) {
    out[j++] = 0x5c; // backslash
    switch (c) {
      case 0x22:
        out[j++] = 0x22;
      case 0x5c:
        out[j++] = 0x5c;
      case 0x08:
        out[j++] = 0x62; // \b
      case 0x0c:
        out[j++] = 0x66; // \f
      case 0x0a:
        out[j++] = 0x6e; // \n
      case 0x0d:
        out[j++] = 0x72; // \r
      case 0x09:
        out[j++] = 0x74; // \t
      default: // other control chars < 0x20 -> \u00XX
        out[j++] = 0x75; // u
        out[j++] = 0x30; // 0
        out[j++] = 0x30; // 0
        out[j++] = _hexDigits.codeUnitAt(c >> 4);
        out[j++] = _hexDigits.codeUnitAt(c & 0xf);
    }
    return j;
  }
}
