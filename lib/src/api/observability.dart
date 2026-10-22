/// Observability endpoints: Prometheus metrics, liveness/readiness, and a live
/// production dashboard (KPI cards + per-route table) pushed over WebSocket.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'context.dart';
import 'metrics.dart';
import 'server.dart';

/// Registers operational endpoints on [server]. Every path is configurable, so
/// nothing is forced onto a fixed URL:
///
/// * [healthPath] (`/healthz`) — liveness: `200 ok` while the process serves.
/// * [readyPath] (`/readyz`) — readiness: `200 ready`, or `503 draining` once
///   closing. Pass [ready] to drive it yourself; by default it flips when
///   [NitroServer.close] runs.
/// * [metricsPath] (`/metrics`) — Prometheus text (see [prometheusFormat]).
/// * [dashboardPath] (`/dashboard`) — a self-contained HTML dashboard with KPI
///   cards (throughput, CPU, memory, in-flight, errors, uptime) and a per-route
///   table. It live-updates over a WebSocket at [dashboardWsPath]
///   (`/dashboard/ws`), falling back to polling the JSON feed at
///   [dashboardDataPath] (`/dashboard.json`). [refreshInterval] sets the push
///   cadence; [dashboardTitle] the heading; [openApiDocsUrl] adds an API-docs
///   link (embedded as an iframe when [embedOpenApi] is true). Pass
///   [dashboardPath]`: null` to skip the dashboard entirely.
///
/// Exposure: [metricsPath] and the dashboard reveal route names, traffic and
/// resource use, so on a public listener wrap them — [middleware] runs in
/// front of `/metrics`, the dashboard page, its JSON feed and its WebSocket
/// (`[basicAuth(...)]`, an IP allow-list, …). The liveness/readiness probes
/// stay open so orchestrators can reach them. Every operational answer is
/// `Cache-Control: no-store`. [maxDashboardViewers] bounds live dashboard
/// sessions (each costs a sampler + timer); a viewer past it is closed 1013.
/// Readiness also reflects helper-isolate health ([NitroServer.helpersHealthy])
/// unless [ready] replaces it.
///
/// ```dart
/// await serveObservability(server); // /metrics, /healthz, /readyz, /dashboard
/// await serveObservability(server, middleware: [basicAuth(checkAdmin)]);
/// ```
Future<void> serveObservability(
  NitroServer server, {
  String metricsPath = '/metrics',
  String healthPath = '/healthz',
  String readyPath = '/readyz',
  String? dashboardPath = '/dashboard',
  String dashboardDataPath = '/dashboard.json',
  String dashboardWsPath = '/dashboard/ws',
  Duration refreshInterval = const Duration(seconds: 2),
  String dashboardTitle = 'nitro_server',
  String? openApiDocsUrl = '/docs',
  bool embedOpenApi = false,
  bool Function()? ready,
  String prefix = 'nitro',
  List<Middleware> middleware = const [],
  int maxDashboardViewers = 16,
}) async {
  var up = true;
  unawaited(server.onClose.then((_) => up = false));
  final isReady = ready ?? () => up && server.helpersHealthy;
  const noStore = {'cache-control': 'no-store'};
  final lag = EventLoopLagProbe.shared..retain(server.onClose);
  await server.get(
    healthPath,
    (_) => ResponseContext.text('ok', headers: noStore),
  );
  await server.get(
    readyPath,
    (_) => isReady()
        ? ResponseContext.text('ready', headers: noStore)
        : ResponseContext.text('draining', status: 503, headers: noStore),
  );
  await server.get(metricsPath, (_) async {
    // Aggregated across every isolate by default, so a scrape reflects the
    // whole server, not just the isolate that answered /metrics.
    final metrics = await server.aggregatedMetrics();
    return ResponseContext(
      headers: const {
        'content-type': 'text/plain; version=0.0.4; charset=utf-8',
        ...noStore,
      },
      body: Uint8List.fromList(
        utf8.encode(
          prometheusFormat(
            metrics,
            prefix: prefix,
            gauges: {
              'connections': server.liveConnections,
              'event_loop_lag_seconds': lag.lastLagMicros / 1e6,
              'helper_isolates_alive': server.helpersAlive,
            },
          ),
        ),
      ),
    );
  }, middleware: middleware);
  if (dashboardPath == null) return;

  // JSON feed (polling fallback): a fresh sampler per request still yields the
  // totals; throughput needs successive samples, which the WS feed provides.
  final pollSampler = StatsSampler();
  await server.get(dashboardDataPath, (_) async {
    final metrics = await server.aggregatedMetrics();
    return ResponseContext(
      headers: const {
        'content-type': 'application/json; charset=utf-8',
        ...noStore,
      },
      body: Uint8List.fromList(
        utf8.encode(
          jsonEncode(
            pollSampler.sample(
              metrics,
              connections: server.liveConnections,
              eventLoopLagMicros: lag.lastLagMicros,
            ),
          ),
        ),
      ),
    );
  }, middleware: middleware);
  // WebSocket feed: one sampler per viewer, pushed every [refreshInterval].
  // Each session is independent; the timer is torn down the instant the peer
  // goes away (a failed send) or the stream ends, and a throwing sample never
  // escapes the timer — so opening/closing many dashboards can neither leak
  // timers nor crash the isolate. Viewers are capped: past the cap a session
  // is closed 1013 (try again later) before any sampler exists.
  var viewers = 0;
  await server.ws(dashboardWsPath, middleware: middleware, (session) async {
    if (viewers >= maxDashboardViewers) {
      await session.close(1013);
      return;
    }
    viewers++;
    final sampler = StatsSampler();
    Timer? timer;
    void stop() {
      timer?.cancel();
      timer = null;
    }

    Future<void> push() async {
      // Defensive teardown paths (peer vanished mid-interval, a sample threw,
      // or the cross-isolate aggregate failed): the reliable close path is the
      // `drain` + `finally` below.
      // coverage:ignore-start
      try {
        final metrics = await server.aggregatedMetrics();
        final frame = jsonEncode(
          sampler.sample(
            metrics,
            connections: server.liveConnections,
            eventLoopLagMicros: lag.lastLagMicros,
          ),
        );
        if (session.sendText(frame) < 0) stop();
      } catch (_) {
        stop();
      }
      // coverage:ignore-end
    }

    unawaited(push()); // immediate first frame
    timer = Timer.periodic(refreshInterval, (_) => unawaited(push()));
    try {
      await session.messages.drain<void>(); // until the peer closes
    } finally {
      stop();
      viewers--;
    }
  });
  final page = _dashboardHtml(
    dashboardTitle,
    dashboardWsPath,
    dashboardDataPath,
    openApiDocsUrl,
    embedOpenApi,
  );
  await server.get(
    dashboardPath,
    (_) => ResponseContext.html(page).withHeader('cache-control', 'no-store'),
    middleware: middleware,
  );
}

/// Samples live server stats: throughput (requests/sec since the last sample),
/// resident memory, best-effort CPU%, and uptime, plus the [metricsJson] body.
/// Stateful — keep one per viewer so each sees throughput at its own cadence.
class StatsSampler {
  StatsSampler() : _startedAt = DateTime.now() {
    _lastAt = _startedAt;
    _lastCpuTicks = _readCpuTicks();
  }

  final DateTime _startedAt;
  late DateTime _lastAt;
  int _lastRequests = 0;
  int? _lastCpuTicks;

  /// A stats snapshot for [metrics]. Call periodically (throughput and CPU are
  /// deltas against the previous call). [connections] and
  /// [eventLoopLagMicros] are live gauges the caller reads from the server.
  Map<String, Object?> sample(
    ServerMetrics metrics, {
    int connections = 0,
    int eventLoopLagMicros = 0,
  }) {
    final now = DateTime.now();
    final dt = now.difference(_lastAt).inMicroseconds / 1e6;
    final reqPerSec = dt > 0 ? (metrics.requests - _lastRequests) / dt : 0.0;
    final ticks = _readCpuTicks();
    final cpu = cpuPercent(ticks, _lastCpuTicks, dt);
    _lastRequests = metrics.requests;
    _lastAt = now;
    _lastCpuTicks = ticks;
    return serverStatsJson(
      metrics,
      reqPerSec: reqPerSec,
      rssBytes: _rss(),
      cpuPercent: cpu,
      uptimeSeconds: now.difference(_startedAt).inSeconds,
      connections: connections,
      eventLoopLagMicros: eventLoopLagMicros,
    );
  }
}

/// Measures this isolate's event-loop lag: a 100 ms periodic timer records
/// how late each tick fires. A saturated isolate (a long synchronous handler,
/// GC pressure) shows up here before it shows up as latency. One shared probe
/// per isolate; [retain] keeps it alive until the given future completes and
/// no other holder remains.
class EventLoopLagProbe {
  EventLoopLagProbe._();

  static final shared = EventLoopLagProbe._();
  static const _period = Duration(milliseconds: 100);

  Timer? _timer;
  int _holders = 0;
  int _lastLagMicros = 0;
  late DateTime _expected;

  /// Lateness of the most recent tick, in microseconds (0 before the first).
  int get lastLagMicros => _lastLagMicros;

  /// Whether the probe timer is running.
  bool get running => _timer != null;

  /// Starts the probe (if idle) and releases it when [until] completes.
  void retain(Future<void> until) {
    _holders++;
    if (_timer == null) {
      _expected = DateTime.now().add(_period);
      _timer = Timer.periodic(_period, (_) {
        final now = DateTime.now();
        final lag = now.difference(_expected).inMicroseconds;
        _lastLagMicros = lag < 0 ? 0 : lag;
        _expected = now.add(_period);
      });
    }
    unawaited(until.then((_) => _release()));
  }

  void _release() {
    if (--_holders > 0) return;
    _timer?.cancel();
    _timer = null;
    _lastLagMicros = 0;
  }
}

/// A JSON-ready stats document: process totals, live gauges and a per-route
/// list. Pure — the [StatsSampler] supplies the gauges.
Map<String, Object?> serverStatsJson(
  ServerMetrics metrics, {
  required double reqPerSec,
  required int rssBytes,
  required double? cpuPercent,
  required int uptimeSeconds,
  int connections = 0,
  int eventLoopLagMicros = 0,
}) => {
  ...metricsJson(metrics),
  'reqPerSec': double.parse(reqPerSec.toStringAsFixed(1)),
  'rssBytes': rssBytes,
  'cpuPercent': cpuPercent == null
      ? null
      : double.parse(cpuPercent.toStringAsFixed(1)),
  'uptimeSeconds': uptimeSeconds,
  'connections': connections,
  'eventLoopLagMs': double.parse(
    (eventLoopLagMicros / 1000).toStringAsFixed(1),
  ),
};

/// A JSON-ready snapshot of [metrics]: process totals plus a per-route list.
/// Backs the dashboard feed and is handy for a custom UI.
Map<String, Object?> metricsJson(ServerMetrics metrics) => {
  'requests': metrics.requests,
  'errors': metrics.errors,
  'inFlight': metrics.inFlight,
  'byStatusClass': {
    for (var c = 1; c <= 5; c++) '${c}xx': metrics.byStatusClass[c],
  },
  'routes': [
    for (final r in metrics.byRoute.values)
      {
        'pattern': r.pattern,
        'requests': r.requests,
        'errors': r.errors,
        'count': r.latency.count,
        'p50us': r.latency.p50Us,
        'p90us': r.latency.p90Us,
        'p99us': r.latency.p99Us,
        'maxUs': r.latency.maxUs,
      },
  ],
};

/// Process resident set size in bytes.
int _rss() => ProcessInfo.currentRss;

/// Combined user+system CPU ticks for this process, or null when unavailable
/// (non-Linux, or `/proc` unreadable). Best-effort — the dashboard shows "n/a".
int? _readCpuTicks() {
  try {
    return parseProcStatTicks(File('/proc/self/stat').readAsStringSync());
  } catch (_) {
    return null;
  }
}

/// Parses `utime + stime` (clock ticks) from a `/proc/<pid>/stat` line. The
/// `comm` field may contain spaces/parens, so fields are read after the final
/// `)`. Pure, for testing the Linux CPU path on any host.
int parseProcStatTicks(String stat) {
  final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
  // After `comm`, field 3 (state) is index 0, so utime (14) is 11, stime 12.
  return int.parse(fields[11]) + int.parse(fields[12]);
}

/// CPU% from a tick delta over [dtSec], normalized across all cores. Assumes the
/// usual 100 Hz `USER_HZ`. Returns null when either tick reading is missing.
double? cpuPercent(int? ticks, int? lastTicks, double dtSec) {
  if (ticks == null || lastTicks == null || dtSec <= 0) return null;
  const userHz = 100.0;
  final cores = Platform.numberOfProcessors;
  final busySec = (ticks - lastTicks) / userHz;
  return (busySec / dtSec / cores * 100).clamp(0, 100).toDouble();
}

/// Renders [metrics] as a Prometheus text-exposition document (version 0.0.4):
/// process totals as counters/gauge, answers per status class, and per-route
/// request/error counters plus a latency summary (p50/p90/p99 as `quantile`
/// series, `_sum` and `_count`, in microseconds). [gauges] adds live
/// process gauges (`serveObservability` passes connections, event-loop lag and
/// helper-isolate health). Metric names are prefixed with [prefix] (`nitro`
/// by default). Pure and allocation-light — safe to call per scrape.
String prometheusFormat(
  ServerMetrics metrics, {
  String prefix = 'nitro',
  Map<String, num> gauges = const {},
}) {
  final b = StringBuffer();
  void metric(
    String name,
    String type,
    String help,
    Object value, [
    String labels = '',
  ]) {
    b
      ..write('# HELP ')
      ..write(prefix)
      ..write('_')
      ..write(name)
      ..write(' ')
      ..write(help)
      ..write('\n')
      ..write('# TYPE ')
      ..write(prefix)
      ..write('_')
      ..write(name)
      ..write(' ')
      ..write(type)
      ..write('\n')
      ..write(prefix)
      ..write('_')
      ..write(name)
      ..write(labels)
      ..write(' ')
      ..write(value)
      ..write('\n');
  }

  metric(
    'requests_total',
    'counter',
    'Total answered requests.',
    metrics.requests,
  );
  metric('errors_total', 'counter', 'Total 5xx answers.', metrics.errors);
  metric(
    'in_flight',
    'gauge',
    'Requests dispatched and not yet answered.',
    metrics.inFlight,
  );
  for (final g in gauges.entries) {
    metric(g.key, 'gauge', 'Live process gauge.', g.value);
  }
  b
    ..write('# HELP ')
    ..write(prefix)
    ..write('_responses_total Answers per status class.\n')
    ..write('# TYPE ')
    ..write(prefix)
    ..write('_responses_total counter\n');
  for (var c = 1; c <= 5; c++) {
    b
      ..write(prefix)
      ..write('_responses_total{class="')
      ..write(c)
      ..write('xx"} ')
      ..write(metrics.byStatusClass[c])
      ..write('\n');
  }

  // Per-route series share one HELP/TYPE header, then one line per route.
  void series(
    String name,
    String type,
    String help,
    int Function(RouteMetrics r) pick,
  ) {
    b
      ..write('# HELP ')
      ..write(prefix)
      ..write('_')
      ..write(name)
      ..write(' ')
      ..write(help)
      ..write('\n')
      ..write('# TYPE ')
      ..write(prefix)
      ..write('_')
      ..write(name)
      ..write(' ')
      ..write(type)
      ..write('\n');
    for (final r in metrics.byRoute.values) {
      b
        ..write(prefix)
        ..write('_')
        ..write(name)
        ..write('{route="')
        ..write(_escape(r.pattern))
        ..write('"} ')
        ..write(pick(r))
        ..write('\n');
    }
  }

  series(
    'route_requests_total',
    'counter',
    'Answered requests per route.',
    (r) => r.requests,
  );
  series(
    'route_errors_total',
    'counter',
    '5xx answers per route.',
    (r) => r.errors,
  );

  // Latency summary: p50/p90/p99 as quantile series plus the sample count.
  b
    ..write('# HELP ')
    ..write(prefix)
    ..write('_route_latency_microseconds Request latency per route.\n')
    ..write('# TYPE ')
    ..write(prefix)
    ..write('_route_latency_microseconds summary\n');
  for (final r in metrics.byRoute.values) {
    final route = _escape(r.pattern);
    void q(String quantile, int v) {
      b
        ..write(prefix)
        ..write('_route_latency_microseconds{route="')
        ..write(route)
        ..write('",quantile="')
        ..write(quantile)
        ..write('"} ')
        ..write(v)
        ..write('\n');
    }

    q('0.5', r.latency.p50Us);
    q('0.9', r.latency.p90Us);
    q('0.99', r.latency.p99Us);
    b
      ..write(prefix)
      ..write('_route_latency_microseconds_sum{route="')
      ..write(route)
      ..write('"} ')
      ..write(r.latency.sumUs)
      ..write('\n')
      ..write(prefix)
      ..write('_route_latency_microseconds_count{route="')
      ..write(route)
      ..write('"} ')
      ..write(r.latency.count)
      ..write('\n');
  }
  return b.toString();
}

/// Escapes a Prometheus label value: backslash, double-quote and newline.
String _escape(String v) =>
    v.replaceAll('\\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n');

/// A self-contained production dashboard: no external assets. Live-updates over
/// the WebSocket at [wsPath], falling back to polling [dataPath]; KPI cards +
/// per-route table; an API-docs link ([docsUrl], embedded when [embed]).
String _dashboardHtml(
  String title,
  String wsPath,
  String dataPath,
  String? docsUrl,
  bool embed,
) {
  final t = _htmlEscape(title);
  final ws = _jsString(wsPath);
  final data = _jsString(dataPath);
  final docsBtn = docsUrl == null
      ? ''
      : '<a class="btn" href="${_htmlEscape(docsUrl)}" target="_blank" rel="noopener">API docs ↗</a>';
  final docsFrame = (docsUrl != null && embed)
      ? '<iframe class="docs" src="${_htmlEscape(docsUrl)}" title="API docs"></iframe>'
      : '';
  return '''
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>$t — dashboard</title>
<style>
  :root{--bg:#0f1115;--card:#171a21;--line:#262b36;--fg:#e6e9ef;--muted:#8b93a7;--accent:#4f8cff;--err:#ff6b6b;--ok:#2ecc71}
  *{box-sizing:border-box} body{margin:0;font:14px system-ui,-apple-system,sans-serif;background:var(--bg);color:var(--fg)}
  header{display:flex;align-items:center;gap:.8rem;padding:1rem 1.5rem;border-bottom:1px solid var(--line)}
  header h1{font-size:1.1rem;margin:0;font-weight:600} .spacer{flex:1}
  .dot{width:.6rem;height:.6rem;border-radius:50%;background:var(--muted)} .dot.live{background:var(--ok);box-shadow:0 0 .5rem var(--ok)}
  .btn{color:var(--fg);text-decoration:none;border:1px solid var(--line);border-radius:6px;padding:.4rem .7rem;font-size:.85rem}
  .btn:hover{border-color:var(--accent)}
  main{padding:1.5rem}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:1rem;margin-bottom:1.5rem}
  .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:1rem}
  .card .n{font-size:1.7rem;font-weight:700;letter-spacing:-.02em} .card .l{color:var(--muted);font-size:.8rem;margin-top:.2rem}
  .card .n.err{color:var(--err)}
  table{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:10px;overflow:hidden}
  th,td{padding:.55rem .9rem;text-align:right;border-bottom:1px solid var(--line)} tr:last-child td{border-bottom:0}
  th{color:var(--muted);font-weight:600;font-size:.78rem;text-transform:uppercase;letter-spacing:.04em}
  th:first-child,td:first-child{text-align:left;font-family:ui-monospace,SFMono-Regular,monospace}
  td.err{color:var(--err)} .docs{width:100%;height:60vh;border:1px solid var(--line);border-radius:10px;margin-top:1.5rem;background:#fff}
  .foot{color:var(--muted);font-size:.78rem;margin-top:1rem}
</style>
</head>
<body>
<header>
  <span class="dot" id="dot"></span><h1>$t</h1><span class="spacer"></span>$docsBtn
</header>
<main>
  <div class="cards">
    <div class="card"><div class="n" id="rps">–</div><div class="l">throughput (req/s)</div></div>
    <div class="card"><div class="n" id="req">–</div><div class="l">total requests</div></div>
    <div class="card"><div class="n err" id="err">–</div><div class="l">5xx errors</div></div>
    <div class="card"><div class="n" id="inf">–</div><div class="l">in flight</div></div>
    <div class="card"><div class="n" id="cpu">–</div><div class="l">cpu</div></div>
    <div class="card"><div class="n" id="mem">–</div><div class="l">memory (rss)</div></div>
    <div class="card"><div class="n" id="up">–</div><div class="l">uptime</div></div>
  </div>
  <table>
    <thead><tr><th>route</th><th>req</th><th>5xx</th><th>p50</th><th>p90</th><th>p99</th><th>max</th></tr></thead>
    <tbody id="rows"></tbody>
  </table>
  $docsFrame
  <div class="foot" id="foot">connecting…</div>
</main>
<script>
const \$ = id => document.getElementById(id);
const ms = us => us >= 1000 ? (us/1000).toFixed(2)+' ms' : us+' µs';
const mb = b => (b/1048576).toFixed(1)+' MB';
const dur = s => s>=3600 ? (s/3600).toFixed(1)+' h' : s>=60 ? (s/60).toFixed(1)+' m' : s+' s';
function render(m){
  \$('rps').textContent = m.reqPerSec.toFixed(1);
  \$('req').textContent = m.requests;
  \$('err').textContent = m.errors;
  \$('inf').textContent = m.inFlight;
  \$('cpu').textContent = m.cpuPercent==null ? 'n/a' : m.cpuPercent.toFixed(1)+' %';
  \$('mem').textContent = mb(m.rssBytes);
  \$('up').textContent = dur(m.uptimeSeconds);
  const rows = \$('rows');
  rows.replaceChildren(...m.routes.map(r => {
    const tr = document.createElement('tr');
    const cells = [r.pattern, r.requests, r.errors, ms(r.p50us), ms(r.p90us), ms(r.p99us), ms(r.maxUs)];
    cells.forEach((v, i) => {
      const td = document.createElement('td');
      td.textContent = String(v); // text, never markup: patterns are data
      if (i === 2 && r.errors) td.className = 'err';
      tr.appendChild(td);
    });
    return tr;
  }));
  \$('foot').textContent = 'updated '+new Date().toLocaleTimeString();
}
function live(on){ \$('dot').classList.toggle('live', on); }
let poll=null;
function startPolling(){
  if(poll) return;
  const tick = async()=>{ try{ render(await (await fetch('$data',{cache:'no-store'})).json()); live(true);}catch(e){ live(false);} };
  tick(); poll=setInterval(tick,2000);
}
function connect(){
  try{
    const proto = location.protocol==='https:'?'wss':'ws';
    const sock = new WebSocket(proto+'://'+location.host+'$ws');
    sock.onopen = ()=>{ live(true); if(poll){clearInterval(poll);poll=null;} };
    sock.onmessage = ev => render(JSON.parse(ev.data));
    sock.onclose = ()=>{ live(false); startPolling(); setTimeout(connect, 5000); };
    sock.onerror = ()=> sock.close();
  }catch(e){ startPolling(); }
}
connect();
</script>
</body>
</html>
''';
}

String _htmlEscape(String s) =>
    s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _jsString(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");
