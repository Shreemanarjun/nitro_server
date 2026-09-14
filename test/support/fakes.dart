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

  @override
  void startStream(int requestId, int status, List<RawHeader> headers) {
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

  Future<void> close() async {
    await heads.close();
    await chunks.close();
    await events.close();
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
  String path = '/',
  String routePattern = '/',
  List<RawRouteParam> params = const [],
  List<int> body = const [],
}) async {
  fake.heads.add(
    fakeHead(
      requestId: requestId,
      method: method,
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


