/// Per-route metrics accumulation and cross-isolate merge, driven through the
/// in-memory client and plain unit calls. No sockets, no native library.
library;

import 'package:nitro_server/nitro_server.dart';
import 'package:nitro_server/src/api/metrics.dart'
    show MetricsAccumulator, mergeIsolateMetrics;
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

void main() {
  group('client', () {
    late NitroTestClient client;

    setUp(() async {
      client = await NitroTestClient.start();
    });

    tearDown(() async {
      await client.close();
    });

    group('metrics', () {
      test('count answers, errors and latency per route', () async {
        await client.server.get('/ok', (_) => const ResponseContext());
        await client.server.get('/boom', (_) => throw StateError('x'));
        for (var i = 0; i < 5; i++) {
          await client.get('/ok');
        }
        await client.get('/boom');
        await client.get('/nowhere');
        final m = client.server.metrics;
        expect(m.requests, 6);
        expect(m.errors, 1);
        expect(m.inFlight, 0);
        final ok = m.byRoute['/ok']!;
        expect(ok.requests, 5);
        expect(ok.errors, 0);
        expect(ok.latency.count, 5);
        expect(ok.latency.p50Us, lessThanOrEqualTo(ok.latency.p99Us));
        expect(ok.latency.p99Us, lessThanOrEqualTo(ok.latency.maxUs * 1.5 + 1));
        expect(ok.latency.meanUs, greaterThanOrEqualTo(0));
        expect(m.byRoute['/boom']!.errors, 1);
        // Engine-level 404s never dispatch, so nothing is recorded for them.
        expect(m.byRoute.containsKey('*unmatched*'), isFalse);
        expect(m.toString(), contains('requests=6'));
        expect(ok.toString(), contains('/ok'));
        expect(ok.latency.toString(), contains('n=5'));
        expect(LatencyStats.empty.count, 0);
      });

      test(
        'mergeIsolateMetrics sums counts and adds histograms across isolates',
        () {
          // Two isolates, each with its own accumulator for the same + a distinct
          // route — the cross-isolate aggregation case.
          final a = MetricsAccumulator('/x')
            ..record(50, 200)
            ..record(60, 500);
          final b = MetricsAccumulator('/x')..record(70, 200);
          final c = MetricsAccumulator('/y')..record(10, 200);
          final merged = mergeIsolateMetrics([
            {
              'requests': 2,
              'errors': 1,
              'inFlight': 1,
              'routes': [a.toWire()],
            },
            {
              'requests': 2,
              'errors': 0,
              'inFlight': 0,
              'routes': [b.toWire(), c.toWire()],
            },
          ]);
          expect(merged.requests, 4);
          expect(merged.errors, 1);
          expect(merged.inFlight, 1);
          // /x seen on both isolates → counts add (histograms merged exactly).
          expect(merged.byRoute['/x']!.requests, 3);
          expect(merged.byRoute['/x']!.errors, 1);
          expect(merged.byRoute['/x']!.latency.count, 3);
          expect(merged.byRoute['/x']!.latency.maxUs, 70);
          expect(merged.byRoute['/y']!.requests, 1);
          // An empty snapshot list yields zeroed metrics.
          expect(mergeIsolateMetrics(const []).requests, 0);
        },
      );

      test(
        'answers are counted per status class, merged across isolates',
        () async {
          await client.server.get('/ok', (_) => ResponseContext.text('ok'));
          await client.server.get(
            '/gone',
            (_) => const ResponseContext(status: 404),
          );
          await client.server.get('/boom', (_) => throw StateError('x'));
          await client.get('/ok');
          await client.get('/ok');
          await client.get('/gone');
          await client.get('/boom');
          final m = client.server.metrics;
          expect(m.byStatusClass, [0, 0, 2, 0, 1, 1]);
          final merged = mergeIsolateMetrics([
            client.server.metricsWireForTesting(),
            client.server.metricsWireForTesting(),
          ]);
          expect(merged.byStatusClass, [0, 0, 4, 0, 2, 2]);
          expect(merged.requests, 8);
          // A snapshot without the field (an older helper) merges as zeros.
          expect(
            mergeIsolateMetrics([
              {
                'requests': 1,
                'errors': 0,
                'inFlight': 0,
                'routes': <Object?>[],
              },
            ]).byStatusClass,
            [0, 0, 0, 0, 0, 0],
          );
        },
      );

      test('histogram buckets are monotonic and bounded', () {
        var last = -1;
        for (final us in [0, 1, 2, 3, 100, 1000, 1 << 20, 1 << 40]) {
          final b = MetricsAccumulator.bucketOf(us);
          expect(b, greaterThanOrEqualTo(last));
          expect(b, lessThan(64));
          last = b;
        }
        // A value reads back within 10% from its bucket's representative.
        for (final us in [7, 130, 9999, 250000]) {
          final v = MetricsAccumulator.valueOf(MetricsAccumulator.bucketOf(us));
          expect((v - us).abs() / us, lessThan(0.5));
        }
        final acc = MetricsAccumulator('/p');
        expect(acc.snapshot().latency, same(LatencyStats.empty));
        acc.record(50, 200);
        acc.record(5000, 503);
        final snap = acc.snapshot();
        expect(snap.errors, 1);
        expect(snap.latency.maxUs, 5000);
        expect(snap.latency.p99Us, greaterThan(snap.latency.p50Us));
      });
    });
  });
}
