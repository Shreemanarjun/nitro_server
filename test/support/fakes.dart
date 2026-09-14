// Fakes for the FFI boundary: every unit test below runs against these, so
// the suite needs no native library and stays fast and hermetic. Only
// `server_e2e_test.dart` loads the real `.so`/`.dylib`.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:nitro_server/src/nitro_server.native.dart';

/// A scriptable [NitroServerNative]. Routes registered here are dispatched by
/// feeding [RawIncomingRequest]s into [heads] — the fake performs no matching
/// itself, so tests control the exact wire values the runner sees.
class FakeNitroServerNative extends NitroServerNative {
  final heads = StreamController<RawIncomingRequest>.broadcast();
  final chunks = StreamController<RawBodyChunk>.broadcast();
  final events = StreamController<RawServerEvent>.broadcast();

  RawServerConfig? lastConfig;
  final registered = <RawRouteConfig>[];
  final unregistered = <(String, String)>[];

  /// Failures to return per operation, keyed by pattern/token. Empty means
  /// success.
  final registerFailures = <String, RawServerStatus>{};
  final unregisterFailures = <String, RawServerStatus>{};
  RawServerStatus startResult = const RawServerStatus(
    errorKind: RawServerErrorKind.none,
    boundPort: 8080,
  );

  final responded = <DrivenResponse>[];
  final acked = <(int, int)>[];
  var configureCalls = 0;
  var startCalls = 0;
  var stopCalls = 0;
  var resetCalls = 0;

  /// Chunked streams: start status/headers by id, data chunks in order,
  /// terminal ids. Assembles nothing — tests assert the wire pieces.
  final streamsStarted = <int, DrivenResponse>{};
  final streamChunks = <int, List<Uint8List>>{};
  final streamsEnded = <int>{};

  @override
  Stream<RawIncomingRequest> get incomingRequests => heads.stream;

  @override
  Stream<RawBodyChunk> get bodyChunks => chunks.stream;

  @override
  Stream<RawServerEvent> get serverEvents => events.stream;

  @override
  String engineVersion() => 'fake/0.0.0';

  @override
  bool supportsTls() => false;

  @override
  void resetNative() => resetCalls++;

  @override
  void configureServer(RawServerConfig config) {
    configureCalls++;
    lastConfig = config;
  }

  @override
  RawServerStatus registerRoute(RawRouteConfig route) {
    registered.add(route);
    return registerFailures[route.pattern] ??
        const RawServerStatus(errorKind: RawServerErrorKind.none);
  }

  @override
  RawServerStatus unregisterRoute(String method, String pattern) {
    unregistered.add((method, pattern));
    return unregisterFailures[pattern] ??
        const RawServerStatus(errorKind: RawServerErrorKind.none);
  }

  @override
  RawServerStatus start() {
    startCalls++;
    return startResult;
  }

  @override
  void stop() => stopCalls++;

  @override
  void respond(
    int requestId,
    int status,
    List<RawHeader> headers,
    Uint8List body,
  ) {
    responded.add(
      DrivenResponse(
        requestId: requestId,
        status: status,
        headers: {for (final h in headers) h.name: h.value},
        body: Uint8List.fromList(body),
      ),
    );
  }

  @override
  void ackBody(int requestId, int ackedChunks) {
    acked.add((requestId, ackedChunks));
  }

  /// Drain seams: [drained] records `beginDrain`, [inFlight] is what
  /// `inFlightRequests` reports (tests script it counting down).
  var drained = false;
  int inFlight = 0;

  @override
  void beginDrain() {
    drained = true;
  }

  @override
  int inFlightRequests() => inFlight > 0 ? inFlight-- : 0;

  /// Live connections the drain also waits on (counts down like inFlight).
  int live = 0;

  @override
  int liveConnections() => live > 0 ? live-- : 0;

  /// File answers by request id: (status, headers, path, offset, length).
  final filesResponded = <int, (int, Map<String, String>, String, int, int)>{};

  @override
  void respondFile(
    int requestId,
    int status,
    List<RawHeader> headers,
    String path,
    int offset,
    int length,
  ) {
    filesResponded[requestId] = (
      status,
      {for (final h in headers) h.name: h.value},
      path,
      offset,
      length,
    );
  }

  /// Ids whose `startStream` throws, standing in for an engine that already
  /// answered (timeout won) and rejected the bridge call.
  final startStreamFailures = <int>{};

  @override
  void startStream(int requestId, int status, List<RawHeader> headers) {
    if (startStreamFailures.contains(requestId)) {
      throw StateError('startStream rejected for $requestId');
    }
    streamsStarted[requestId] = DrivenResponse(
      requestId: requestId,
      status: status,
      headers: {for (final h in headers) h.name: h.value},
      body: Uint8List(0),
    );
  }

  @override
  void sendStreamChunk(int requestId, Uint8List chunk, bool last) {
    if (chunk.isNotEmpty) {
      (streamChunks[requestId] ??= []).add(Uint8List.fromList(chunk));
    }
    if (last) streamsEnded.add(requestId);
  }

  /// WebSocket surface: outbound frames + close calls by connection id.
  final wsOut = StreamController<RawWsMessage>.broadcast();
  final wsSent = <(int, Uint8List, bool)>[];
  final wsSentCompressed = <int>[];
  final wsClosed = <(int, int)>[];

  /// What `wsSend` reports as still buffered (tests script backpressure).
  int wsBuffered = 0;

  /// When set, `wsSend` throws like a bridge call on a disposed instance.
  bool wsSendThrows = false;

  @override
  Stream<RawWsMessage> get wsMessages => wsOut.stream;

  @override
  int wsSend(
    int connectionId,
    Uint8List payload,
    bool binary,
    bool compressed,
  ) {
    if (wsSendThrows) throw StateError('bridge gone');
    wsSent.add((connectionId, Uint8List.fromList(payload), binary));
    if (compressed) wsSentCompressed.add(wsSent.length - 1);
    return wsBuffered;
  }

  @override
  void wsClose(int connectionId, int code) {
    wsClosed.add((connectionId, code));
  }

  Future<void> close() async {
    await heads.close();
    await chunks.close();
    await events.close();
    await wsOut.close();
  }
}

class DrivenResponse {
  DrivenResponse({
    required this.requestId,
    required this.status,
    required this.headers,
    required this.body,
  });

  final int requestId;
  final int status;
  final Map<String, String> headers;
  final Uint8List body;
}

/// Builds a head the way the engine would emit one for a matched route.
RawIncomingRequest fakeHead({
  required int requestId,
  RawServerMethod method = RawServerMethod.get,
  String customMethod = '',
  String path = '/',
  String query = '',
  List<RawHeader> headers = const [],
  bool hasBody = false,
  int contentLength = 0,
  String routePattern = '/',
  List<RawRouteParam> params = const [],
}) {
  return RawIncomingRequest(
    requestId: requestId,
    method: method,
    customMethod: customMethod,
    path: path,
    query: query,
    headers: headers,
    contentLength: contentLength,
    hasBody: hasBody,
    routePattern: routePattern,
    params: params,
  );
}

RawBodyChunk fakeData(int requestId, List<int> bytes) {
  return RawBodyChunk(
    bytes: Uint8List.fromList(bytes),
    requestId: requestId,
    kind: RawBodyKind.data.index,
    aux: 0,
  );
}

RawBodyChunk fakeEnd(int requestId) {
  return RawBodyChunk(
    bytes: Uint8List(0),
    requestId: requestId,
    kind: RawBodyKind.end.index,
    aux: 0,
  );
}

/// Drives one request through [runner]'s fake: emits the head (with an
/// optional body) and completes when the fake records the response.
Future<DrivenResponse> driveRequest(
  FakeNitroServerNative fake, {
  required int requestId,
  RawServerMethod method = RawServerMethod.get,
  String customMethod = '',
  String path = '/',
  String routePattern = '/',
  List<RawRouteParam> params = const [],
  List<int> body = const [],
}) async {
  fake.heads.add(
    fakeHead(
      requestId: requestId,
      method: method,
      customMethod: customMethod,
      path: path,
      hasBody: body.isNotEmpty,
      contentLength: body.length,
      routePattern: routePattern,
      params: params,
    ),
  );
  if (body.isNotEmpty) {
    fake.chunks.add(fakeData(requestId, body));
    fake.chunks.add(fakeEnd(requestId));
  }
  // The dispatch runs on a microtask; poll briefly rather than sleeping blind.
  for (var i = 0; i < 200; i++) {
    if (fake.responded.any((r) => r.requestId == requestId)) break;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  return fake.responded.firstWhere((r) => r.requestId == requestId);
}
