// Unit tests for the HTTP method value type and the wire mapping tables.
// No native library needed: everything here runs against pure data.
import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/internal/raw_mapping.dart';
import 'package:nitro_server/src/nitro_server.native.dart';
import 'package:test/test.dart';

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

    test('non-custom results are canonical (no per-request allocation)', () {
      // The dispatch hot path calls httpMethodOf once per request; the
      // non-custom branches are `const` records, so repeated calls hand back
      // the same canonical instance instead of allocating. `identical` holds
      // only if that canonicalization is in place.
      for (final raw in RawServerMethod.values) {
        if (raw == RawServerMethod.custom) continue;
        expect(identical(httpMethodOf(raw, ''), httpMethodOf(raw, '')), isTrue);
        expect(
          identical(
            rawMethodOf(HttpMethod.get, ''),
            rawMethodOf(HttpMethod.get, ''),
          ),
          isTrue,
        );
      }
    });
  });
}
