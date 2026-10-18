/// Shared ANSI styling for the built-in colourful CLI logs — the startup
/// banner and the access log — so they share one palette. Internal.
library;

/// Wraps [s] in the SGR [code] when [on], else returns it unchanged. Keeping
/// the toggle here means callers never branch on colour themselves.
String ansi(String s, String code, {required bool on}) =>
    on ? '\x1b[${code}m$s\x1b[0m' : s;

/// SGR colour for an HTTP method token: GET/HEAD green, write verbs yellow,
/// DELETE red, everything else cyan — so a log scans by colour.
String methodHue(String method) => switch (method) {
  'GET' || 'HEAD' => '32',
  'POST' || 'PUT' || 'PATCH' => '33',
  'DELETE' => '31',
  _ => '36',
};

/// SGR colour for an HTTP status by class: 5xx red, 4xx yellow, 3xx cyan,
/// else green.
String statusHue(int status) => status >= 500
    ? '31'
    : status >= 400
    ? '33'
    : status >= 300
    ? '36'
    : '32';

/// A compact, human latency string from [micros] microseconds: microseconds
/// below 1ms (`843µs`), milliseconds with two decimals above (`1.23ms`).
String formatLatency(int micros) =>
    micros < 1000 ? '$microsµs' : '${(micros / 1000).toStringAsFixed(2)}ms';
