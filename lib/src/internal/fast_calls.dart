/// Hot-path answer calls: `respond`, `startStream`, `sendStreamChunk` as
/// leaf FFI calls over reusable native buffers.
///
/// The generated bindings are correct but general: per call they allocate
/// an `Arena`, grow a `RecordWriter`, encode the header list into fresh
/// native memory, copy the body into another fresh block, wrap the call in
/// the runtime's error/log plumbing and free both blocks. Every request
/// pays that on the single Dart isolate — the one serial stage of the whole
/// server — so this binding does the same wire encoding (indexed
/// `List<RawHeader>` argument, see Wire.h) into buffers that live for the
/// runner's lifetime and grow only when a response outsizes them. The body
/// copy remains: Dart heap memory has no stable address.
///
/// Symbols, instance id and error slot are the ones the generated binding
/// uses, so the engine cannot tell the two apart. Measured with
/// `tool/perf/respond_bench.dart`.
library;

import 'package:nitro/nitro.dart';

import '../nitro_server.native.dart';

typedef _RespondNative =
    Void Function(
      Int64 instanceId,
      Int64 requestId,
      Int64 status,
      Pointer<Uint8> headers,
      Pointer<Uint8> body,
      Size bodyLength,
      Pointer<NitroErrorFfi> err,
    );
typedef _RespondDart =
    void Function(
      int instanceId,
      int requestId,
      int status,
      Pointer<Uint8> headers,
      Pointer<Uint8> body,
      int bodyLength,
      Pointer<NitroErrorFfi> err,
    );
typedef _StartStreamNative =
    Void Function(
      Int64 instanceId,
      Int64 requestId,
      Int64 status,
      Pointer<Uint8> headers,
      Pointer<NitroErrorFfi> err,
    );
typedef _StartStreamDart =
    void Function(
      int instanceId,
      int requestId,
      int status,
      Pointer<Uint8> headers,
      Pointer<NitroErrorFfi> err,
    );
typedef _SendChunkNative =
    Void Function(
      Int64 instanceId,
      Int64 requestId,
      Pointer<Uint8> chunk,
      Size chunkLength,
      Int8 last,
      Pointer<NitroErrorFfi> err,
    );
typedef _SendChunkDart =
    void Function(
      int instanceId,
      int requestId,
      Pointer<Uint8> chunk,
      int chunkLength,
      int last,
      Pointer<NitroErrorFfi> err,
    );

final class FastCalls {
  FastCalls._(
    this._instanceId,
    this._respond,
    this._startStream,
    this._sendChunk,
  ) {
    _headerView = _headers.asTypedList(_headerCap);
    _headerData = ByteData.sublistView(_headerView);
    _bodyView = _body.asTypedList(_bodyCap);
  }

  /// Binds against the library the generated code loaded. Throws when the
  /// native side is not a real engine (fakes in tests): callers fall back
  /// to the generated bindings.
  factory FastCalls.bind(NitroServerNative native) {
    final instanceId = native.asAnyNativeObject.instanceId;
    final lib = NitroRuntime.loadLib('nitro_server');
    return FastCalls._(
      instanceId,
      lib
          .lookup<NativeFunction<_RespondNative>>('nitro_server_respond')
          .asFunction<_RespondDart>(isLeaf: true),
      lib
          .lookup<NativeFunction<_StartStreamNative>>(
            'nitro_server_start_stream',
          )
          .asFunction<_StartStreamDart>(isLeaf: true),
      lib
          .lookup<NativeFunction<_SendChunkNative>>(
            'nitro_server_send_stream_chunk',
          )
          .asFunction<_SendChunkDart>(isLeaf: true),
    );
  }

  final int _instanceId;
  final _RespondDart _respond;
  final _StartStreamDart _startStream;
  final _SendChunkDart _sendChunk;
  final Pointer<NitroErrorFfi> _err = calloc<NitroErrorFfi>();

  Pointer<Uint8> _headers = malloc<Uint8>(_initialHeaderBytes);
  int _headerCap = _initialHeaderBytes;
  Uint8List _headerView = Uint8List(0);
  ByteData _headerData = ByteData(0);

  Pointer<Uint8> _body = malloc<Uint8>(_initialBodyBytes);
  int _bodyCap = _initialBodyBytes;
  Uint8List _bodyView = Uint8List(0);

  static const _initialHeaderBytes = 2048;
  static const _initialBodyBytes = 64 * 1024;

  bool _disposed = false;

  /// Answers [requestId]. Same contract as the generated `respond`.
  /// [setCookies] are sent as one `set-cookie` header each.
  void respond(
    int requestId,
    int status,
    Map<String, String> headers,
    Uint8List body, [
    List<String> setCookies = const [],
  ]) {
    if (_disposed) return;
    _encodeHeaders(headers, setCookies);
    _stageBody(body);
    _respond(
      _instanceId,
      requestId,
      status,
      _headers,
      _body,
      body.length,
      _err,
    );
    _check();
  }

  /// Same contract as the generated `startStream`.
  void startStream(
    int requestId,
    int status,
    Map<String, String> headers, [
    List<String> setCookies = const [],
  ]) {
    if (_disposed) return;
    _encodeHeaders(headers, setCookies);
    _startStream(_instanceId, requestId, status, _headers, _err);
    _check();
  }

  /// Same contract as the generated `sendStreamChunk`.
  void sendStreamChunk(int requestId, Uint8List chunk, bool last) {
    if (_disposed) return;
    _stageBody(chunk);
    _sendChunk(_instanceId, requestId, _body, chunk.length, last ? 1 : 0, _err);
    _check();
  }

  /// Frees the native buffers. The runner calls this on close.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    malloc.free(_headers);
    malloc.free(_body);
    calloc.free(_err);
  }

  void _check() {
    if (_err.ref.hasError != 0) NitroRuntime.throwIfOutParamError(_err);
  }

  void _stageBody(Uint8List bytes) {
    if (bytes.length > _bodyCap) _growBody(bytes.length);
    if (bytes.isNotEmpty) _bodyView.setRange(0, bytes.length, bytes);
  }

  void _encodeHeaders(Map<String, String> headers, List<String> setCookies) {
    final need = headerListBytes(headers, setCookies);
    if (need > _headerCap) _growHeaders(need);
    encodeHeaderList(headers, _headerView, _headerData, setCookies);
  }

  /// Upper bound on the encoded size of [headers] plus [setCookies]: 3 bytes
  /// per UTF-16 unit (the UTF-8 worst case) plus the fixed framing.
  static int headerListBytes(
    Map<String, String> headers, [
    List<String> setCookies = const [],
  ]) {
    var need = 8 + 8 * (headers.length + setCookies.length);
    for (final entry in headers.entries) {
      need += 8 + 3 * (entry.key.length + entry.value.length);
    }
    for (final cookie in setCookies) {
      need += 8 + 3 * (_setCookie.length + cookie.length);
    }
    return need;
  }

  static const _setCookie = 'set-cookie';

  /// Encodes [headers] as an indexed `List<RawHeader>` argument into [view]
  /// (which must hold [headerListBytes]): `[i32 payloadLen][i32 count]
  /// [i64 offset × count][items…]`, each item `[i32 len][utf8 name]
  /// [i32 len][utf8 value]`, offsets payload-relative (from the byte after
  /// the outer length). [data] is a `ByteData` over the same bytes. Returns
  /// the total encoded length. Byte-identical to
  /// `RecordWriter.encodeIndexedList` — a test pins that.
  static int encodeHeaderList(
    Map<String, String> headers,
    Uint8List view,
    ByteData data, [
    List<String> setCookies = const [],
  ]) {
    final count = headers.length + setCookies.length;
    data.setInt32(4, count, Endian.little);
    var pos = 8 + 8 * count;
    var i = 0;
    for (final entry in headers.entries) {
      data.setInt64(8 + 8 * i, pos - 4, Endian.little);
      pos = _putString(pos, entry.key, view, data);
      pos = _putString(pos, entry.value, view, data);
      i++;
    }
    for (final cookie in setCookies) {
      data.setInt64(8 + 8 * i, pos - 4, Endian.little);
      pos = _putString(pos, _setCookie, view, data);
      pos = _putString(pos, cookie, view, data);
      i++;
    }
    data.setInt32(0, pos - 4, Endian.little);
    return pos;
  }

  /// Writes `[i32 len][utf8]` at [pos]; ASCII takes the direct path, other
  /// text goes through the encoder. Returns the position after the string.
  static int _putString(int pos, String s, Uint8List view, ByteData data) {
    final start = pos + 4;
    var end = start;
    for (var i = 0; i < s.length; i++) {
      final unit = s.codeUnitAt(i);
      if (unit >= 0x80) {
        final encoded = utf8.encode(s);
        view.setRange(start, start + encoded.length, encoded);
        data.setInt32(pos, encoded.length, Endian.little);
        return start + encoded.length;
      }
      view[end++] = unit;
    }
    data.setInt32(pos, end - start, Endian.little);
    return end;
  }

  void _growHeaders(int need) {
    var cap = _headerCap;
    while (cap < need) {
      cap *= 2;
    }
    malloc.free(_headers);
    _headers = malloc<Uint8>(cap);
    _headerCap = cap;
    _headerView = _headers.asTypedList(cap);
    _headerData = ByteData.sublistView(_headerView);
  }

  void _growBody(int need) {
    var cap = _bodyCap;
    while (cap < need) {
      cap *= 2;
    }
    malloc.free(_body);
    _body = malloc<Uint8>(cap);
    _bodyCap = cap;
    _bodyView = _body.asTypedList(cap);
  }
}
