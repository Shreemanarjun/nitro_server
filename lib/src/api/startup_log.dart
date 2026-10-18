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
///   routes: server.routes,                 // grouped by type, sorted by path
///   links: {'docs': '/docs', 'dashboard': '/dashboard'},
///   logo: nitroServerAsciiLogo,            // the big NITRO wordmark
///   color: stdout.supportsAnsiEscapes,
/// ));
/// ```
library;

import '../internal/ansi.dart';
import 'http_method.dart';

/// The NITRO wordmark, as a CLI-style block banner. Pass it to
/// [serverBanner]'s `logo` argument.
const String nitroServerAsciiLogo = '''
█   █ █████ █████ ████   ███
██  █   █     █   █   █ █   █
█ █ █   █     █   ████  █   █
█  ██   █     █   █  █  █   █
█   █ █████   █   █   █  ███''';

/// Route kinds in display order, with their section label.
const _routeSections = [
  (RouteKind.handler, 'handlers'),
  (RouteKind.webSocket, 'websockets'),
  (RouteKind.staticResponse, 'static'),
];

/// SGR colour for a route row: WebSocket magenta, static blue, else by verb.
String _routeHue(RegisteredRoute r) => switch (r.kind) {
  RouteKind.webSocket => '35',
  RouteKind.staticResponse => '34',
  RouteKind.handler => methodHue(r.methodToken),
};

/// Builds the startup banner for a server listening at [uri].
///
/// [routes] (typically `server.routes`) are listed **grouped by kind**
/// (handlers, websockets, static) and **sorted by pattern** within each group,
/// so a route is easy to find. [links] maps a short label to a path (`/docs`)
/// or an absolute URL (`https://…`); paths are resolved against [uri]. [facts]
/// adds short notes to the metadata row (e.g. `'hot reload on'`); [extra] adds
/// trailing note lines. [logo] is printed above the heading (see
/// [nitroServerAsciiLogo]). [color] turns ANSI colour on; keep it off for
/// non-TTY output.
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
      b.writeln('  ${ansi(line, '1;36', on: color)}');
    }
    b.writeln();
  }

  final heading = version == null ? title : '$title v$version';
  b.writeln(
    '  ${ansi('◆', '36', on: color)} ${ansi(heading, '1;36', on: color)}',
  );
  b.writeln(
    '  ${ansi('listening on', '2', on: color)} ${ansi('$uri', '1;32', on: color)}',
  );

  final allFacts = <String>[
    'isolates $isolates',
    if (pid != null) 'pid $pid',
    ...facts,
  ];
  b.writeln('  ${ansi(allFacts.join('  ·  '), '2', on: color)}');

  if (routes.isNotEmpty) {
    b.writeln();
    b.writeln('  ${ansi('routes', '1', on: color)}');
    for (final (kind, label) in _routeSections) {
      final group = routes.where((r) => r.kind == kind).toList()
        ..sort((a, b) => a.pattern.compareTo(b.pattern));
      if (group.isEmpty) continue;
      b.writeln('  ${ansi(label, '2', on: color)}');
      final methodWidth = group
          .map((r) => r.methodToken.length)
          .fold(3, (a, b) => a > b ? a : b);
      for (final r in group) {
        final method = ansi(
          r.methodToken.padRight(methodWidth),
          _routeHue(r),
          on: color,
        );
        b.writeln('    ${ansi('·', '2', on: color)} $method  ${r.pattern}');
      }
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
        '  ${ansi('→', '36', on: color)} ${ansi(label, '1', on: color)}  ${ansi(target, '2;4', on: color)}',
      );
    }
  }

  if (extra.isNotEmpty) b.writeln();
  for (final line in extra) {
    b.writeln('  ${ansi(line, '2', on: color)}');
  }
  return b.toString();
}
