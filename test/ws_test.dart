/// WebSocket behavior: the sealed message type and client-driven compression
/// and backpressure (in-memory client), plus the runner-level WS session seams
/// driven through the fake native backend.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/server_runner.dart';
import 'package:nitro_server/src/nitro_server.native.dart';
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

import 'support/fakes.dart';

void main() {
  group('client', () {
    late NitroTestClient client;

    setUp(() async {
      client = await NitroTestClient.start();
    });

    tearDown(() async {
      await client.close();
    });

    group('WebSocket compression and backpressure', () {
      test('deflate and inflate round-trip, and strip the sync tail', () {
        final text = Uint8List.fromList(utf8.encode('hello ' * 100));
        final packed = wsDeflate(text);
        expect(packed.length, lessThan(text.length));
        expect(packed.sublist(packed.length - 4), isNot([0, 0, 0xff, 0xff]));
        expect(wsInflate(packed), text);
        expect(wsInflate(wsDeflate(Uint8List(0))), isEmpty);
        expect(
          () => wsInflate(Uint8List.fromList([0xff, 0xff, 0xff])),
          throwsA(anything),
        );
      });

      test('a session compresses long messages only when negotiated', () async {
        final seen = <WsMessage>[];
        await client.server.ws('/c', (session) async {
          seen.add(await session.messages.first);
          expect(session.sendText('x' * 1000), 0);
          expect(session.bufferedBytes, 0);
          expect(session.sendText('short'), 0);
          expect(session.compressed, isTrue);
        });
        await client.server.ws('/plain', (session) async {
          expect(session.compressed, isFalse);
          session.sendText('y' * 1000);
        });
        final ws = await client.ws(
          '/c',
          headers: {'sec-websocket-extensions': 'permessage-deflate'},
        );
        ws.sendText('in');
        expect((await ws.messages.first).text, 'x' * 1000);
        await ws.close();
        final plain = await client.ws('/plain');
        expect((await plain.messages.first).text, 'y' * 1000);
        await plain.close();
        expect(seen.single.text, 'in');
      });

      test('ServerConfig carries the new limits through copyWith', () {
        const base = ServerConfig();
        expect(base.writeTimeout, const Duration(seconds: 30));
        expect(base.wsMaxBufferBytes, 1024 * 1024);
        expect(base.wsCompression, isTrue);
        expect(
          base.protocol,
          HttpProtocol.http2,
        ); // ships all protocols by default
        final c = base.copyWith(
          writeTimeout: const Duration(seconds: 1),
          wsMaxBufferBytes: 4096,
          wsCompression: false,
          protocol: HttpProtocol.http1,
        );
        expect(c.writeTimeout, const Duration(seconds: 1));
        expect(c.wsMaxBufferBytes, 4096);
        expect(c.wsCompression, isFalse);
        expect(c.protocol, HttpProtocol.http1);
        expect(c.copyWith(port: 1).wsMaxBufferBytes, 4096);
        expect(c.copyWith(port: 1).protocol, HttpProtocol.http1); // sticky
        expect(
          () => ServerConfig(wsMaxBufferBytes: 0),
          throwsA(isA<AssertionError>()),
        );
      });
    });

    group('WsMessage', () {
      test('is sealed with text and binary variants', () {
        const text = WsMessage.text('hi');
        final binary = WsMessage.binary(Uint8List.fromList([1, 2]));
        String describe(WsMessage m) => switch (m) {
          WsText(:final text) => 'text:$text',
          WsBinary(:final bytes) => 'binary:${bytes.length}',
        };
        expect(describe(text), 'text:hi');
        expect(describe(binary), 'binary:2');
        expect(text.isText, isTrue);
        expect(text.isBinary, isFalse);
        expect(text.bytes, isNull);
        expect(binary.text, isNull);
        expect(binary.isBinary, isTrue);
        expect(text.toString(), 'WsText(hi)');
        expect(binary.toString(), 'WsBinary(2 bytes)');
      });
    });
  });

  group('runner', () {
    late FakeNitroServerNative fake;
    late ServerRunner runner;

    setUp(() {
      fake = FakeNitroServerNative();
      runner = ServerRunner(fake);
    });

    tearDown(() async {
      await runner.close();
      await fake.close();
    });

    Future<void> addGet(String pattern, [RequestHandler? handler]) async {
      runner.addRoute(
        HttpMethod.get,
        '',
        pattern,
        null,
        handler ?? (_) async => const ResponseContext(),
      );
      await Future<void>.delayed(Duration.zero);
    }

    group('websockets', () {
      Future<WsSession> openSession(
        int id, {
        String path = '/chat',
        String pattern = '/chat',
        List<RawRouteParam> params = const [],
        WsHandler? handler,
      }) async {
        final opened = Completer<WsSession>();
        runner.addWsRoute(pattern, (session) async {
          if (!opened.isCompleted) opened.complete(session);
          await handler?.call(session);
        });
        await Future<void>.delayed(Duration.zero);
        fake.heads.add(
          fakeHead(
            requestId: id,
            path: path,
            routePattern: pattern,
            params: params,
          ),
        );
        return opened.future.timeout(const Duration(seconds: 5));
      }

      void inject(int id, int kind, Uint8List payload, [int code = 0]) {
        fake.wsOut.add(
          RawWsMessage(
            payload: payload,
            connectionId: id,
            kind: kind,
            aux: code,
          ),
        );
      }

      Future<void> waitWsClosed(int id) async {
        for (var i = 0; i < 200; i++) {
          if (fake.wsClosed.any((c) => c.$1 == id)) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        throw StateError('no wsClose for $id');
      }

      test(
        'session seams: live ids, close code, shutdown on runner close',
        () async {
          final session = await openSession(590);
          expect(runner.wsSessionIdsForTesting, {590});
          expect(session.closeCode, isNull);
          // Runner shutdown reaps the session without a native close call: the
          // engine is already stopped by then.
          await runner.close();
          expect(session.closeCode, 1006);
          expect(runner.wsSessionIdsForTesting, isEmpty);
          expect(fake.wsClosed, isEmpty);
          // Sends after shutdown are dropped, never errors.
          session.sendText('late');
          expect(fake.wsSent, isEmpty);
        },
      );

      test('open dispatches with the handshake pattern and params', () async {
        final session = await openSession(
          600,
          path: '/rooms/lobby',
          pattern: '/rooms/:room',
          params: const [RawRouteParam(name: 'room', value: 'lobby')],
        );
        expect(session.handshake.param('room'), 'lobby');
        expect(session.handshake.path, '/rooms/lobby');
        expect(session.handshake.routePattern, '/rooms/:room');
        await session.close();
        await waitWsClosed(600);
        expect(fake.wsClosed.single, (600, 1000));
      });

      test('text and binary messages reach the handler in order', () async {
        final received = <WsMessage>[];
        final done = Completer<void>();
        await openSession(
          601,
          handler: (session) async {
            await for (final message in session.messages) {
              received.add(message);
            }
            done.complete();
          },
        );
        inject(601, 1, Uint8List.fromList('hi'.codeUnits));
        inject(601, 2, Uint8List.fromList([1, 2, 3]));
        inject(601, 8, Uint8List(0), 1000);
        await done.future.timeout(const Duration(seconds: 5));
        expect(received, hasLength(2));
        expect(received[0].isText, isTrue);
        expect(received[0].text, 'hi');
        expect(received[1].isBinary, isTrue);
        expect(received[1].bytes, orderedEquals([1, 2, 3]));
        // Peer-initiated close echoes the peer code (a no-op on the reaped
        // engine side) so close observers complete deterministically.
        expect(fake.wsClosed.single, (601, 1000));
      });

      test('inbound frames ack cumulatively so native payloads are freed', () async {
        // Regression: the engine's ackBody second argument is an absolute
        // cumulative sequence — it frees tracked payloads with seq < count.
        // A constant 1 frees only the first frame and leaks every inbound
        // buffer after it for the life of the socket. Each frame must ack a
        // rising count.
        final done = Completer<void>();
        var seen = 0;
        await openSession(
          610,
          handler: (session) async {
            await for (final _ in session.messages) {
              if (++seen == 3) done.complete();
            }
          },
        );
        inject(610, 1, Uint8List.fromList('a'.codeUnits));
        inject(610, 1, Uint8List.fromList('bb'.codeUnits));
        inject(610, 1, Uint8List.fromList('ccc'.codeUnits));
        await done.future.timeout(const Duration(seconds: 5));
        final counts = fake.acked
            .where((a) => a.$1 == 610)
            .map((a) => a.$2)
            .toList();
        expect(counts, [1, 2, 3], reason: 'cumulative ack, not constant 1');
      });

      test(
        'frames that beat the open are parked and replayed in order',
        () async {
          // The open head and the message stream have no cross-ordering, so a
          // client's first frames can reach the runner before the session opens.
          final received = <WsMessage>[];
          final gotBoth = Completer<void>();
          runner.addWsRoute('/chat', (session) async {
            await for (final message in session.messages) {
              received.add(message);
              if (received.length == 2) gotBoth.complete();
            }
          });
          await Future<void>.delayed(Duration.zero);
          inject(700, 1, Uint8List.fromList('first'.codeUnits));
          inject(700, 2, Uint8List.fromList([7, 8, 9]));
          await Future<void>.delayed(Duration.zero);
          expect(runner.wsEarlyFrameCountForTesting, 2);
          // The open lands: parked frames replay before any live frame.
          fake.heads.add(
            fakeHead(requestId: 700, path: '/chat', routePattern: '/chat'),
          );
          await gotBoth.future.timeout(const Duration(seconds: 5));
          expect(runner.wsEarlyFrameCountForTesting, 0);
          expect(received[0].text, 'first');
          expect(received[1].bytes, orderedEquals([7, 8, 9]));
        },
      );

      test('a parked close finishes the session and halts replay', () async {
        final received = <WsMessage>[];
        runner.addWsRoute('/chat', (session) async {
          await for (final message in session.messages) {
            received.add(message);
          }
        });
        await Future<void>.delayed(Duration.zero);
        inject(701, 8, Uint8List(0), 1000); // close, parked first
        inject(701, 1, Uint8List.fromList('after'.codeUnits)); // never replayed
        await Future<void>.delayed(Duration.zero);
        fake.heads.add(
          fakeHead(requestId: 701, path: '/chat', routePattern: '/chat'),
        );
        await waitWsClosed(701);
        expect(fake.wsClosed.single, (701, 1000));
        expect(received, isEmpty); // replay broke on the close
        expect(runner.wsEarlyFrameCountForTesting, 0);
      });

      test(
        'a frame after a session closed is dropped, not re-parked',
        () async {
          final session = await openSession(702);
          await session.close();
          await waitWsClosed(702);
          // 702 is in _wsOpened now: a late frame is a stale post-close resend.
          inject(702, 1, Uint8List.fromList('late'.codeUnits));
          await Future<void>.delayed(Duration.zero);
          expect(runner.wsEarlyFrameCountForTesting, 0);
          expect(runner.wsSessionIdsForTesting, isEmpty);
        },
      );

      test('parked pre-open frames are bounded', () async {
        runner.addWsRoute('/chat', (_) async {});
        await Future<void>.delayed(Duration.zero);
        // 1030 frames on distinct ids that never open: the cap evicts the oldest.
        for (var id = 5000; id < 5000 + 1030; id++) {
          inject(id, 1, Uint8List.fromList([1]));
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(runner.wsEarlyFrameCountForTesting, lessThanOrEqualTo(1024));
      });

      test(
        'sends report the queue depth and inflate compressed input',
        () async {
          fake.wsBuffered = 77;
          final got = Completer<WsMessage>();
          final session = await openSession(
            640,
            handler: (s) async {
              got.complete(await s.messages.first);
              await Completer<void>().future;
            },
          );
          expect(session.sendText('a'), 77);
          expect(session.bufferedBytes, 77);
          expect(session.sendBytes(Uint8List(1)), 77);
          // Sessions opened without the extension never compress.
          expect(session.compressed, isFalse);
          expect(fake.wsSentCompressed, isEmpty);
          // A compressed inbound frame (aux 1) is inflated before delivery.
          inject(
            640,
            1,
            wsDeflate(Uint8List.fromList(utf8.encode('zipped'))),
            1,
          );
          expect((await got.future).text, 'zipped');
          // Undecodable compressed data closes with 1007.
          inject(640, 2, Uint8List.fromList([1, 2, 3]), 1);
          await waitWsClosed(640);
          expect(fake.wsClosed.single, (640, 1007));
          expect(session.sendText('late'), -1);
        },
      );

      test('a bridge failure on send reads as -1, never a throw', () async {
        final session = await openSession(642);
        fake.wsSendThrows = true;
        expect(session.sendText('x'), -1);
        expect(session.bufferedBytes, -1);
        fake.wsSendThrows = false;
        await session.close();
      });

      test('a negotiated session compresses long sends', () async {
        runner.addWsRoute('/z', (s) async {
          s.sendText('a' * 1000);
          s.sendText('tiny');
          await Completer<void>().future;
        });
        await Future<void>.delayed(Duration.zero);
        fake.heads.add(
          fakeHead(
            requestId: 641,
            path: '/z',
            routePattern: '/z',
            headers: const [
              RawHeader(
                name: 'sec-websocket-extensions',
                value: 'permessage-deflate',
              ),
            ],
          ),
        );
        for (var i = 0; i < 200 && fake.wsSent.length < 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(fake.wsSent, hasLength(2));
        expect(fake.wsSentCompressed, [0]);
        expect(wsInflate(fake.wsSent[0].$2), utf8.encode('a' * 1000));
        expect(utf8.decode(fake.wsSent[1].$2), 'tiny');
        // Inflated text that is not UTF-8 closes with 1007.
        inject(641, 1, wsDeflate(Uint8List.fromList([0xff, 0xfe])), 1);
        await waitWsClosed(641);
        expect(fake.wsClosed.last, (641, 1007));
      });

      test('sends ride wsSend with the right opcode flag', () async {
        final session = await openSession(602);
        session.sendText('yo');
        session.sendBytes(Uint8List.fromList([9]));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        expect(fake.wsSent, hasLength(2));
        expect(fake.wsSent[0].$1, 602);
        expect(String.fromCharCodes(fake.wsSent[0].$2), 'yo');
        expect(fake.wsSent[0].$3, isFalse);
        expect(fake.wsSent[1].$2, orderedEquals([9]));
        expect(fake.wsSent[1].$3, isTrue);
        await session.close();
      });

      test('a throwing handler closes with 1011', () async {
        await openSession(
          603,
          handler: (_) async {
            throw StateError('handler died');
          },
        );
        await waitWsClosed(603);
        expect(fake.wsClosed.single, (603, 1011));
      });

      test('messages for unknown sessions are acked and dropped', () async {
        await addGet('/unrelated');
        inject(604, 1, Uint8List.fromList('ghost'.codeUnits));
        await Future<void>.delayed(const Duration(milliseconds: 30));
        // Copied then acked (zero-copy contract), bytes dropped, no crash.
        expect(fake.acked.any((a) => a.$1 == 604), isTrue);
      });

      test('registering ws evicts http on the same pattern and back', () async {
        var httpCalls = 0;
        var wsCalls = 0;
        runner.addRoute(HttpMethod.get, '', '/dupe', null, (_) async {
          httpCalls++;
          return const ResponseContext();
        });
        runner.addWsRoute('/dupe', (_) async {
          wsCalls++;
        });
        await Future<void>.delayed(Duration.zero);
        fake.heads.add(
          fakeHead(requestId: 605, path: '/dupe', routePattern: '/dupe'),
        );
        await waitWsClosed(605);
        expect(wsCalls, 1);
        expect(httpCalls, 0);

        runner.addRoute(HttpMethod.get, '', '/dupe', null, (_) async {
          httpCalls++;
          return const ResponseContext();
        });
        await Future<void>.delayed(Duration.zero);
        final response = await driveRequest(
          fake,
          requestId: 606,
          path: '/dupe',
          routePattern: '/dupe',
        );
        expect(response.status, 200);
        expect(httpCalls, 1);
        expect(wsCalls, 1);
      });

      test('unroute removes the ws route', () async {
        await openSession(607, pattern: '/bye');
        await Future<void>.delayed(Duration.zero);
        runner.removeRoute(HttpMethod.get, '', '/bye');
        final response = await driveRequest(
          fake,
          requestId: 608,
          path: '/bye',
          routePattern: '/bye',
        );
        expect(response.status, 404);
      });

      test('close is idempotent and drops late sends', () async {
        final session = await openSession(609);
        await session.close();
        await session.close();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fake.wsClosed.where((c) => c.$1 == 609), hasLength(1));
        session.sendText('late');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(fake.wsSent.where((s) => s.$1 == 609), isEmpty);
      });
    });
  });
}
