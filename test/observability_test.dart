import 'package:nitro_server/nitro_server.dart';
// Implementation import for the internal CPU helpers (same package).
import 'package:nitro_server/src/api/observability.dart'
    show cpuPercent, parseProcStatTicks;
import 'package:nitro_server/testing.dart';
import 'package:test/test.dart';

ServerMetrics _metrics() => const ServerMetrics(
  requests: 123,
  errors: 4,
  inFlight: 2,
  byRoute: {
    '/users/:id': RouteMetrics(
      pattern: '/users/:id',
      requests: 50,
      errors: 1,
      latency: LatencyStats(
        count: 50,
        meanUs: 120,
        maxUs: 900,
        p50Us: 100,
        p90Us: 300,
        p99Us: 800,
      ),
    ),
  },
);

void main() {
  group('prometheusFormat', () {
    test('emits process totals, per-route series and a latency summary', () {
      final out = prometheusFormat(_metrics());
      expect(out, contains('# TYPE nitro_requests_total counter'));
      expect(out, contains('\nnitro_requests_total 123\n'));
      expect(out, contains('\nnitro_errors_total 4\n'));
      expect(out, contains('# TYPE nitro_in_flight gauge'));
      expect(out, contains('\nnitro_in_flight 2\n'));
      expect(
        out,
        contains('nitro_route_requests_total{route="/users/:id"} 50'),
      );
      expect(out, contains('nitro_route_errors_total{route="/users/:id"} 1'));
      expect(
        out,
        contains(
          'nitro_route_latency_microseconds{route="/users/:id",quantile="0.5"} 100',
        ),
      );
      expect(
        out,
        contains(
          'nitro_route_latency_microseconds{route="/users/:id",quantile="0.99"} 800',
        ),
      );
      expect(
        out,
        contains(
          'nitro_route_latency_microseconds_count{route="/users/:id"} 50',
        ),
      );
    });

    test('honours a custom prefix and escapes label values', () {
      final out = prometheusFormat(
        const ServerMetrics(
          requests: 1,
          errors: 0,
          inFlight: 0,
          byRoute: {
            r'/a"\b': RouteMetrics(
              pattern: r'/a"\b',
              requests: 1,
              errors: 0,
              latency: LatencyStats.empty,
            ),
          },
        ),
        prefix: 'app',
      );
      expect(out, contains('\napp_requests_total 1\n'));
      expect(out, contains(r'route="/a\"\\b"'));
    });
  });

  group('metricsJson / serverStatsJson', () {
    test('metricsJson snapshots totals and per-route rows', () {
      final j = metricsJson(_metrics());
      expect(j['requests'], 123);
      expect(j['errors'], 4);
      expect(j['inFlight'], 2);
      final r = (j['routes'] as List).first as Map<String, Object?>;
      expect(r['pattern'], '/users/:id');
      expect(r['p99us'], 800);
      expect(r['maxUs'], 900);
    });

    test('serverStatsJson adds gauges, rounding and a null-CPU case', () {
      final withCpu = serverStatsJson(
        _metrics(),
        reqPerSec: 1234.567,
        rssBytes: 33 * 1048576,
        cpuPercent: 42.449,
        uptimeSeconds: 61,
      );
      expect(withCpu['requests'], 123);
      expect(withCpu['reqPerSec'], 1234.6); // 1 dp
      expect(withCpu['rssBytes'], 33 * 1048576);
      expect(withCpu['cpuPercent'], 42.4);
      expect(withCpu['uptimeSeconds'], 61);

      final noCpu = serverStatsJson(
        _metrics(),
        reqPerSec: 0,
        rssBytes: 1,
        cpuPercent: null,
        uptimeSeconds: 0,
      );
      expect(noCpu['cpuPercent'], isNull);
    });
  });

  group('CPU helpers', () {
    test('parseProcStatTicks reads utime+stime past a parenthesised comm', () {
      // pid (comm) state ppid ... fields; utime=field14, stime=field15.
      const stat =
          '1234 (my proc) S 1 1 1 0 -1 0 0 0 0 0 100 50 0 0 20 0 1 0 999';
      expect(parseProcStatTicks(stat), 150); // 100 + 50
    });

    test('cpuPercent computes a normalized delta and handles nulls', () {
      // 200 ticks over 1s on >=1 core => (2.0s busy)/1/cores*100, clamped.
      final pct = cpuPercent(200, 0, 1.0);
      expect(pct, isNotNull);
      expect(pct, inInclusiveRange(0, 100));
      expect(cpuPercent(null, 0, 1.0), isNull);
      expect(cpuPercent(100, null, 1.0), isNull);
      expect(cpuPercent(100, 0, 0), isNull); // non-positive dt
    });

    test('StatsSampler yields the live fields', () {
      final sampler = StatsSampler();
      final s = sampler.sample(_metrics());
      expect(
        s.keys,
        containsAll(['reqPerSec', 'rssBytes', 'cpuPercent', 'uptimeSeconds']),
      );
      expect(s['rssBytes'], greaterThan(0)); // real RSS
      expect(s['requests'], 123);
    });
  });

  group('serveObservability endpoints', () {
    late NitroTestClient client;
    setUp(() => NitroTestClient.start().then((c) => client = c));
    tearDown(() => client.close());

    test('exposes /healthz, /readyz and /metrics', () async {
      await serveObservability(client.server);
      await client.server.get('/x', (_) => ResponseContext.text('x'));
      await client.get('/x');

      expect((await client.get('/healthz')).text(), 'ok');
      final ready = await client.get('/readyz');
      expect(ready.status, 200);
      expect(ready.text(), 'ready');
      final metrics = await client.get('/metrics');
      expect(metrics.status, 200);
      expect(
        metrics.text(),
        contains('nitro_route_requests_total{route="/x"}'),
      );
    });

    test('dashboard page + JSON feed + embedded docs link', () async {
      await client.server.get('/x', (_) => ResponseContext.text('x'));
      await serveObservability(
        client.server,
        dashboardTitle: 'Demo',
        embedOpenApi: true,
      );
      await client.get('/x');

      final page = await client.get('/dashboard');
      expect(page.status, 200);
      expect(page.headers['content-type'], contains('text/html'));
      expect(page.text(), contains('Demo'));
      expect(page.text(), contains("'/dashboard/ws'")); // WS feed wired
      expect(page.text(), contains("fetch('/dashboard.json'")); // poll fallback
      expect(page.text(), contains('API docs')); // docs button
      expect(page.text(), contains('<iframe')); // embedded docs

      final data = await client.get('/dashboard.json');
      expect(data.status, 200);
      final j = data.json() as Map<String, Object?>;
      expect(
        j.keys,
        containsAll(['requests', 'reqPerSec', 'rssBytes', 'routes']),
      );
    });

    test('dashboard pushes live frames over WebSocket', () async {
      await serveObservability(
        client.server,
        refreshInterval: const Duration(milliseconds: 30),
      );
      final conn = await client.ws('/dashboard/ws');
      final frames = await conn.messages
          .take(2) // immediate frame + one periodic push
          .map((m) => (m as WsText).text)
          .toList()
          .timeout(const Duration(seconds: 2));
      await conn.close();
      expect(frames, hasLength(2));
      final first = (frames.first.isNotEmpty) ? frames.first : '{}';
      expect(first, contains('reqPerSec'));
    });

    test('many concurrent dashboards each stream and close cleanly', () async {
      await serveObservability(
        client.server,
        refreshInterval: const Duration(milliseconds: 20),
      );
      final conns = await Future.wait([
        for (var i = 0; i < 8; i++) client.ws('/dashboard/ws'),
      ]);
      // Each independent session delivers frames.
      final firsts = await Future.wait([
        for (final c in conns)
          c.messages
              .map((m) => (m as WsText).text)
              .first
              .timeout(const Duration(seconds: 2)),
      ]);
      expect(firsts, hasLength(8));
      expect(firsts.every((f) => f.contains('reqPerSec')), isTrue);
      // Closing all must not hang (timers torn down per session).
      await Future.wait([for (final c in conns) c.close()]);
    });

    test('dashboard with the docs link disabled', () async {
      await serveObservability(client.server, openApiDocsUrl: null);
      final page = await client.get('/dashboard');
      expect(page.status, 200);
      expect(page.text(), isNot(contains('API docs')));
      expect(page.text(), isNot(contains('<iframe')));
    });

    test('paths overridable, readiness driven, whole dashboard off', () async {
      await serveObservability(
        client.server,
        readyPath: '/ready',
        metricsPath: '/m',
        prefix: 'svc',
        ready: () => false,
        dashboardPath: null, // dashboard + feeds disabled
      );
      final r = await client.get('/ready');
      expect(r.status, 503);
      expect(r.text(), 'draining');
      expect((await client.get('/m')).text(), contains('svc_requests_total'));
      expect((await client.get('/dashboard')).status, 404);
      expect((await client.get('/dashboard.json')).status, 404);
    });
  });
}
