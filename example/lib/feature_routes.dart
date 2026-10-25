/// Every response/transport type nitro_server offers, registered next to the
/// demo's buttons so `tool/smoke.dart` can prove each one works on the device
/// the app runs on (iOS, Android, macOS, Linux, Windows).
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';

Future<void> registerFeatureRoutes(NitroServer server) async {
  // WebSocket: text back with a prefix, binary back verbatim.
  await server.ws('/ws', (session) async {
    await for (final m in session.messages) {
      if (m is WsText) session.sendText('echo: ${m.text}');
      if (m is WsBinary) session.sendBytes(m.bytes);
    }
  });

  // Server-sent events: three ticks, then the stream ends.
  await server.get(
    '/events',
    (_) => ResponseContext.sse(
      Stream.periodic(
        const Duration(milliseconds: 50),
        (i) => SseEvent('tick $i', event: 'tick', id: '$i'),
      ).take(3),
    ),
  );

  // Chunked streaming response.
  await server.get(
    '/stream',
    (_) => ResponseContext.stream(
      Stream<Uint8List>.periodic(
        const Duration(milliseconds: 20),
        (i) => Uint8List.fromList(utf8.encode('chunk $i\n')),
      ).take(5),
      contentType: 'text/plain',
    ),
  );

  // Engine-served bytes (no Dart round trip).
  await server.getStatic(
    '/static',
    utf8.encode('static ok'),
    contentType: 'text/plain',
  );

  // Streaming JSON writer.
  await server.get(
    '/report',
    (_) => ResponseContext.jsonWriter((w) {
      w
        ..beginObject()
        ..key('rows')
        ..beginArray();
      for (var i = 0; i < 3; i++) {
        w
          ..beginObject()
          ..key('id')
          ..writeInt(i)
          ..key('score')
          ..writeDouble(i * 1.5)
          ..endObject();
      }
      w
        ..endArray()
        ..endObject();
    }),
  );

  // Multipart upload.
  await server.post(
    '/upload',
    (r) => ResponseContext.jsonBody({
      'parts': [
        for (final p in r.multipart())
          {'name': p.name, 'file': p.isFile, 'bytes': p.bytes.length},
      ],
    }),
  );

  // Streamed request body.
  await server.post('/ingest', (r) async {
    var total = 0;
    await for (final chunk in r.bodyStream!) {
      total += chunk.length;
    }
    return ResponseContext.jsonBody({'bytes': total});
  }, streamBody: true);

  // gzip compression (brotli is not built for mobile; gzip always is).
  final big = 'nitro ' * 2000;
  await server.get(
    '/big',
    (_) => ResponseContext.text(big),
    middleware: [compress(minBytes: 256)],
  );

  // Cookies, redirect, RFC 7807 problem, query + path params, custom verb.
  await server.get(
    '/login',
    (_) =>
        ResponseContext.text('ok')
            .withCookie(SetCookie('session', 'abc', httpOnly: true, path: '/')),
  );
  await server.get(
    '/whoami',
    (r) => ResponseContext.jsonBody({'session': r.cookies['session']}),
  );
  await server.get('/go', (_) => ResponseContext.redirect('/hello'));
  await server.get(
    '/problem',
    (_) => ResponseContext.problem(title: 'Nope', status: 422, detail: 'demo'),
  );
  await server.get(
    '/search/:kind',
    (r) => ResponseContext.jsonBody({
      'kind': r.param('kind'),
      'q': r.queryParam('q'),
    }),
  );
  await server.route(
    HttpMethod.custom,
    '/report',
    (_) => ResponseContext.text('custom verb'),
    customMethod: 'REPORT',
  );
}
