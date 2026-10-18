/// A colourful, production-grade startup banner for a running server.
///
/// [serverBanner] is a pure function — it returns the banner as a string, so
/// it is trivially testable and you choose where it goes (stdout, a logger,
/// a file). Pass `color: stdout.supportsAnsiEscapes` to light it up on a TTY
/// and fall back to clean plain text in a pipe or CI log.
///
/// ```dart
/// stdout.writeln(serverBanner(
///   title: 'nitro_server',
///   version: '1.0.0',
///   uri: server.uri,
///   isolates: server.config.isolates,
///   routes: server.routes,                 // every registered route, listed
///   links: {'docs': '/docs', 'dashboard': '/dashboard'},
///   logo: nitroServerAsciiLogo,            // the big NITRO wordmark
///   color: stdout.supportsAnsiEscapes,
/// ));
/// ```
library;

import 'http_method.dart';

/// The NITRO wordmark, as a CLI-style block banner. Pass it to
/// [serverBanner]'s `logo` argument.
const String nitroServerAsciiLogo = '''
█   █ █████ █████ ████   ███
██  █   █     █   █   █ █   █
█ █ █   █     █   ████  █   █
█  ██   █     █   █  █  █   █
█   █ █████   █   █   █  ███''';

/// ANSI SGR codes, applied only when [on] is true.
String _c(String s, String code, bool on) => on ? '\x1b[${code}m$s\x1b[0m' : s;

/// SGR colour for a route's method/kind, so the list scans at a glance.
String _methodColor(RegisteredRoute r) => switch (r.kind) {
  RouteKind.webSocket => '35', // magenta
  RouteKind.staticResponse => '34', // blue
  RouteKind.handler => switch (r.methodToken) {
    'GET' || 'HEAD' => '32', // green
    'POST' || 'PUT' || 'PATCH' => '33', // yellow
    'DELETE' => '31', // red
    _ => '36', // cyan
  },
};

/// The label shown in the `kind` column.
String _kindLabel(RouteKind kind) => switch (kind) {
  RouteKind.handler => 'handler',
  RouteKind.webSocket => 'websocket',
  RouteKind.staticResponse => 'static',
};

/// Builds the startup banner for a server listening at [uri].
///
/// [routes] (typically `server.routes`) are listed with method, pattern and
/// kind. [links] maps a short label to a path (`/docs`) or an absolute URL
/// (`https://…`); paths are resolved against [uri]. [facts] adds short notes
/// to the metadata row (e.g. `'hot reload on'`); [extra] adds trailing note
/// lines. [logo] is printed above the heading (see [nitroServerAsciiLogo]).
/// [color] turns ANSI colour on; keep it off for non-TTY output.
String serverBanner({
  required String title,
  required Uri uri,
  String? version,
  int isolates = 1,
  int? pid,
  List<RegisteredRoute> routes = const [],
  Map<String, String> links = const {},
  List<String> facts = const [],
  List<String> extra = const [],
  String? logo,
  bool color = true,
}) {
  final b = StringBuffer();
  b.writeln();
  if (logo != null) {
    for (final line in logo.split('\n')) {
      b.writeln('  ${_c(line, '1;36', color)}');
    }
    b.writeln();
  }

  final heading = version == null ? title : '$title v$version';
  b.writeln('  ${_c('◆', '36', color)} ${_c(heading, '1;36', color)}');
  b.writeln('  ${_c('listening on', '2', color)} ${_c('$uri', '1;32', color)}');

  final allFacts = <String>[
    'isolates $isolates',
    if (pid != null) 'pid $pid',
    ...facts,
  ];
  b.writeln('  ${_c(allFacts.join('  ·  '), '2', color)}');

  if (routes.isNotEmpty) {
    b.writeln();
    b.writeln('  ${_c('routes', '1', color)}');
    final methodWidth = routes
        .map((r) => r.methodToken.length)
        .fold(3, (a, b) => a > b ? a : b);
    final patternWidth = routes
        .map((r) => r.pattern.length)
        .fold(0, (a, b) => a > b ? a : b);
    for (final r in routes) {
      final method = _c(
        r.methodToken.padRight(methodWidth),
        _methodColor(r),
        color,
      );
      final pattern = r.pattern.padRight(patternWidth);
      b.writeln(
        '  ${_c('·', '2', color)} $method  $pattern  ${_c(_kindLabel(r.kind), '2', color)}',
      );
    }
  }

  if (links.isNotEmpty) {
    b.writeln();
    final width = links.keys
        .map((k) => k.length)
        .fold(0, (a, b) => a > b ? a : b);
    for (final entry in links.entries) {
      final label = entry.key.padRight(width);
      final target = entry.value.startsWith('http')
          ? entry.value
          : '$uri'.replaceFirst(RegExp(r'/$'), '') + entry.value;
      b.writeln(
        '  ${_c('→', '36', color)} ${_c(label, '1', color)}  ${_c(target, '2;4', color)}',
      );
    }
  }

  if (extra.isNotEmpty) b.writeln();
  for (final line in extra) {
    b.writeln('  ${_c(line, '2', color)}');
  }
  return b.toString();
}
