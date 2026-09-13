// Unit tests for the public value types and the wire mapping tables.
// No native library needed: everything here runs against fakes and pure data.
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/raw_mapping.dart';
import 'package:nitro_server/src/nitro_server.native.dart';

void main() {
  group('HttpMethod', () {
    test('tokens are uppercase wire values', () {
      expect(HttpMethod.get.token, 'GET');
      expect(HttpMethod.delete.token, 'DELETE');
      expect(HttpMethod.all.token, '*');
    });

    test('custom without a token throws', () {
      expect(() => HttpMethod.custom.token, throwsStateError);
    });

    test('parse round-trips every token', () {
      for (final method in HttpMethod.values) {
        if (method == HttpMethod.custom) continue;
        expect(HttpMethod.parse(method.token).$1, method);
      }
      expect(HttpMethod.parse('PURGE'), (HttpMethod.custom, 'PURGE'));
    });
  });

  group('rawMethodOf/httpMethodOf', () {
    test('every public method maps to a distinct wire method', () {
      final seen = <RawServerMethod>{};
      for (final method in HttpMethod.values) {
        if (method == HttpMethod.custom) continue;
        final (raw, custom) = rawMethodOf(method, '');
        expect(custom, isEmpty);
        expect(seen.add(raw), isTrue, reason: 'duplicate for $method');
      }
    });

    test('custom carries its token both ways', () {
      final (raw, custom) = rawMethodOf(HttpMethod.custom, 'PURGE');
      expect(raw, RawServerMethod.custom);
      expect(custom, 'PURGE');
      expect(httpMethodOf(raw, custom), (HttpMethod.custom, 'PURGE'));
    });

    test('httpMethodOf inverts rawMethodOf for known methods', () {
      for (final method in HttpMethod.values) {
        if (method == HttpMethod.custom) continue;
        final (raw, _) = rawMethodOf(method, '');
        expect(httpMethodOf(raw, ''), (method, ''));
      }
    });
  });

  group('throwIfFailed', () {
    test('none returns the bound port', () {
      expect(
        throwIfFailed(
          const RawServerStatus(
            errorKind: RawServerErrorKind.none,
            boundPort: 4567,
          ),
          operation: 'start',
        ),
        4567,
      );
    });

    test('every error kind maps to its exception type', () {
      final cases = <RawServerErrorKind, Type>{
        RawServerErrorKind.alreadyRunning: ServerAlreadyRunningException,
        RawServerErrorKind.notRunning: ServerNotRunningException,
        RawServerErrorKind.bindFailed: ServerBindException,
        RawServerErrorKind.tlsError: ServerTlsException,
        RawServerErrorKind.routeNotFound: RouteNotFoundException,
        RawServerErrorKind.handlerTimeout: HandlerTimeoutException,
        RawServerErrorKind.requestTooLarge: ServerBadRequestException,
        RawServerErrorKind.badRequest: ServerBadRequestException,
        RawServerErrorKind.responseTooLarge: ServerUnknownException,
        RawServerErrorKind.io: ServerUnknownException,
        RawServerErrorKind.unknown: ServerUnknownException,
      };
      for (final entry in cases.entries) {
        expect(
          () => throwIfFailed(
            RawServerStatus(errorKind: entry.key, errorMessage: 'm'),
            operation: 'op',
          ),
          throwsA(isA<NitroServerException>().having(
            (e) => e.runtimeType.toString(),
            'type',
            entry.value.toString(),
          )),
          reason: 'wrong mapping for ${entry.key}',
        );
      }
    });
  });

  group('ResponseContext', () {
    test('factories set content types', () {
      expect(
        ResponseContext.text('hi').headers['content-type'],
        contains('text/plain'),
      );
      expect(
        ResponseContext.json('{}').headers['content-type'],
        contains('application/json'),
      );
      expect(
        ResponseContext.bytes(Uint8List(0)).headers['content-type'],
        contains('octet-stream'),
      );
    });

    test('null body encodes empty', () {
      expect(const ResponseContext().bodyBytes, isEmpty);
    });

    test('status range is enforced', () {
      expect(() => ResponseContext(status: 99), throwsA(isA<AssertionError>()));
      expect(() => ResponseContext(status: 600), throwsA(isA<AssertionError>()));
    });
  });

  group('RequestContext', () {
    test('header lookup is case-insensitive, param direct', () {
      final context = RequestContext(
        method: HttpMethod.get,
        customMethod: '',
        path: '/users/42',
        query: '',
        queryParameters: const {},
        headers: const {
          'content-type': ['application/json'],
        },
        params: const {'id': '42'},
        routePattern: '/users/:id',
        body: Uint8List(0),
      );
      expect(context.header('Content-Type'), 'application/json');
      expect(context.param('id'), '42');
      expect(context.param('missing'), isNull);
    });
  });
}
