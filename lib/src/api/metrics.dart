/// Per-route request metrics: counts, error counts and latency quantiles,
/// kept by the runner and read as immutable snapshots.
library;

import 'dart:math' as math;

/// Latency summary of one route (microseconds).
class LatencyStats {
  const LatencyStats({
    required this.count,
    required this.meanUs,
    required this.maxUs,
    required this.p50Us,
    required this.p90Us,
    required this.p99Us,
  });

  static const empty = LatencyStats(
    count: 0,
    meanUs: 0,
    maxUs: 0,
    p50Us: 0,
    p90Us: 0,
    p99Us: 0,
  );

  final int count;
  final double meanUs;
  final int maxUs;

  /// Quantiles from a log-scale histogram: exact to within 10% of the value.
  final int p50Us;
  final int p90Us;
  final int p99Us;

  @override
  String toString() =>
      'LatencyStats(n=$count, mean=${meanUs.toStringAsFixed(0)}µs, '
      'p50=$p50Us, p90=$p90Us, p99=$p99Us, max=$maxUs)';
}

/// Metrics of one route pattern (or `*unmatched*` for not-found answers).
class RouteMetrics {
  const RouteMetrics({
    required this.pattern,
    required this.requests,
    required this.errors,
    required this.latency,
  });

  final String pattern;

  /// Answered requests.
  final int requests;

  /// Answers with a 5xx status.
  final int errors;
  final LatencyStats latency;

  @override
  String toString() =>
      'RouteMetrics($pattern, requests=$requests, errors=$errors, $latency)';
}

/// A point-in-time view of a server's metrics. Cheap to take: the runner
/// keeps counters and a fixed histogram per route, nothing per request
/// beyond a timestamp.
class ServerMetrics {
  const ServerMetrics({
    required this.requests,
    required this.errors,
    required this.inFlight,
    required this.byRoute,
  });

  /// Answered requests, every route.
  final int requests;

  /// 5xx answers, every route.
  final int errors;

  /// Requests dispatched and not yet answered.
  final int inFlight;

  /// Per route pattern, insertion-ordered by first request.
  final Map<String, RouteMetrics> byRoute;

  @override
  String toString() =>
      'ServerMetrics(requests=$requests, errors=$errors, inFlight=$inFlight, '
      'routes=${byRoute.length})';
}

/// Mutable per-route accumulator behind [RouteMetrics]. Latencies land in
/// 64 log₂-ish buckets (two per power of two), so quantiles cost nothing
/// per request and read out within 10% of the true value.
class MetricsAccumulator {
  MetricsAccumulator(this.pattern);

  final String pattern;
  int requests = 0;
  int errors = 0;
  int maxUs = 0;
  int sumUs = 0;
  final List<int> buckets = List.filled(_bucketCount, 0);

  static const _bucketCount = 64;

  /// Bucket index for [us]: 0 for < 1 µs, then two per doubling.
  static int bucketOf(int us) {
    if (us < 1) return 0;
    final log = math.log(us) / math.ln2;
    return (log * 2).floor().clamp(0, _bucketCount - 1) + 1 <= _bucketCount - 1
        ? (log * 2).floor() + 1
        : _bucketCount - 1;
  }

  /// Representative value (geometric middle) of bucket [index].
  static int valueOf(int index) {
    if (index == 0) return 0;
    return math.pow(2, (index - 1 + 0.5) / 2).round();
  }

  void record(int us, int status) {
    requests++;
    if (status >= 500) errors++;
    if (us > maxUs) maxUs = us;
    sumUs += us;
    buckets[bucketOf(us)]++;
  }

  int _quantile(double q) {
    final target = (q * requests).ceil().clamp(1, requests);
    var seen = 0;
    for (var i = 0; i < buckets.length; i++) {
      seen += buckets[i];
      if (seen >= target) return valueOf(i);
    }
    // Unreachable: the buckets sum to [requests], so the loop returns.
    return maxUs; // coverage:ignore-line
  }

  RouteMetrics snapshot() => RouteMetrics(
    pattern: pattern,
    requests: requests,
    errors: errors,
    latency: requests == 0
        ? LatencyStats.empty
        : LatencyStats(
            count: requests,
            meanUs: sumUs / requests,
            maxUs: maxUs,
            p50Us: _quantile(0.5),
            p90Us: _quantile(0.9),
            p99Us: _quantile(0.99),
          ),
  );
}
