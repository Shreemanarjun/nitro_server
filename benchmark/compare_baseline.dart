/// Benchmark regression check: diffs two `compare.dart --json` outputs and
/// flags cases that regressed beyond a threshold. Because absolute numbers vary
/// by machine, this compares a run against a *baseline taken on the same
/// machine* (e.g. the previous commit), so the delta is meaningful.
///
/// ```sh
/// # record a baseline, then compare a later run against it
/// dart run benchmark/compare.dart --keep-alive --json bench-base.json
/// dart run benchmark/compare.dart --keep-alive --json bench-now.json
/// dart run benchmark/compare_baseline.dart \
///   --baseline bench-base.json --current bench-now.json --threshold 0.10
/// ```
///
/// Exits non-zero when any case for `--side` (default `nitro`) drops throughput
/// or inflates p99 by more than `--threshold` (fraction, default 0.10). Lower
/// is better for latency, higher for throughput.
library;

import 'dart:convert';
import 'dart:io';

String? _opt(List<String> args, String name) {
  final i = args.indexOf(name);
  return i != -1 && i + 1 < args.length ? args[i + 1] : null;
}

String _pct(num? now, num? base, {required bool higherIsBetter}) {
  if (now == null || base == null || base == 0) return '   —  ';
  final delta = (now - base) / base;
  final improved = higherIsBetter ? delta >= 0 : delta <= 0;
  final sign = delta >= 0 ? '+' : '';
  final mark = improved ? '✓' : '✗';
  return '$sign${(delta * 100).toStringAsFixed(1)}% $mark';
}

Future<void> main(List<String> args) async {
  final basePath = _opt(args, '--baseline');
  final curPath = _opt(args, '--current');
  final threshold =
      double.tryParse(_opt(args, '--threshold') ?? '0.10') ?? 0.10;
  final side = _opt(args, '--side') ?? 'nitro';
  if (basePath == null || curPath == null) {
    stderr.writeln(
      'usage: compare_baseline --baseline <base.json> --current <now.json> '
      '[--threshold 0.10] [--side nitro]',
    );
    exit(2);
  }

  Map<String, Map<String, Object?>> casesOf(String path) {
    final doc =
        jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    final list = (doc['cases'] as List).cast<Map<String, Object?>>();
    return {for (final c in list) c['case'] as String: c};
  }

  final base = casesOf(basePath);
  final cur = casesOf(curPath);

  stdout.writeln('| case | req/s | seq p99 | load p99 |');
  stdout.writeln('| ---- | ----- | ------- | -------- |');
  var regressed = false;
  for (final entry in cur.entries) {
    final label = entry.key;
    final c = entry.value;
    final b = base[label];
    num? n(Map<String, Object?>? m, String k) => m?[k] as num?;

    final rps = _pct(
      n(c, 'req_per_s'),
      n(b, 'req_per_s'),
      higherIsBetter: true,
    );
    final seq = _pct(
      n(c, 'seq_p99_us'),
      n(b, 'seq_p99_us'),
      higherIsBetter: false,
    );
    final load = _pct(
      n(c, 'load_p99_us'),
      n(b, 'load_p99_us'),
      higherIsBetter: false,
    );
    stdout.writeln('| $label | $rps | $seq | $load |');

    // Gate only the named side's throughput + latency against its own baseline.
    if (label.contains(side) && b != null) {
      final rNow = n(c, 'req_per_s'), rBase = n(b, 'req_per_s');
      if (rNow != null && rBase != null && rBase > 0) {
        if ((rBase - rNow) / rBase > threshold) regressed = true;
      }
      for (final k in ['seq_p99_us', 'load_p99_us']) {
        final now = n(c, k), was = n(b, k);
        if (now != null &&
            was != null &&
            was > 0 &&
            (now - was) / was > threshold) {
          regressed = true;
        }
      }
    }
  }

  if (regressed) {
    stderr.writeln(
      '\nREGRESSION: a "$side" case moved more than '
      '${(threshold * 100).toStringAsFixed(0)}% against the baseline.',
    );
    exit(1);
  }
  stdout.writeln(
    '\nOK: no "$side" regression beyond '
    '${(threshold * 100).toStringAsFixed(0)}%.',
  );
}
