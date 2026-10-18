// serverBanner: a pure builder, so the whole thing is asserted here — the
// colour on/off branches, the ASCII logo, the route table (every kind and
// method colour), link alignment and path resolution, facts and extras.
import 'package:nitro_server/nitro_server.dart';
import 'package:test/test.dart';

void main() {
  final uri = Uri.parse('http://0.0.0.0:8080');

  // One route per method-colour / kind branch in the banner.
  const routes = [
    RegisteredRoute(
      method: HttpMethod.get,
      pattern: '/',
      kind: RouteKind.handler,
    ),
    RegisteredRoute(
      method: HttpMethod.head,
      pattern: '/h',
      kind: RouteKind.handler,
    ),
    RegisteredRoute(
      method: HttpMethod.post,
      pattern: '/users',
      kind: RouteKind.handler,
    ),
    RegisteredRoute(
      method: HttpMethod.delete,
      pattern: '/users/:id',
      kind: RouteKind.handler,
    ),
    RegisteredRoute(
      method: HttpMethod.options,
      pattern: '/opt',
      kind: RouteKind.handler,
    ),
    RegisteredRoute(
      method: HttpMethod.custom,
      customMethod: 'PURGE',
      pattern: '/c',
      kind: RouteKind.handler,
    ),
    RegisteredRoute(
      method: HttpMethod.get,
      pattern: '/ws',
      kind: RouteKind.webSocket,
    ),
    RegisteredRoute(
      method: HttpMethod.get,
      pattern: '/static',
      kind: RouteKind.staticResponse,
    ),
  ];

  test('plain (no colour) carries every fact and no escape codes', () {
    final out = serverBanner(
      title: 'nitro_server',
      version: '1.0.0',
      uri: uri,
      isolates: 2,
      pid: 4242,
      links: const {'docs': '/docs', 'dashboard': '/dashboard'},
      facts: const ['hot reload on', 'timing on'],
      extra: const ['ready · press Ctrl-C to stop'],
      color: false,
    );
    expect(out, isNot(contains('\x1b[')));
    expect(out, contains('nitro_server v1.0.0'));
    expect(out, contains('http://0.0.0.0:8080'));
    expect(out, contains('isolates 2'));
    expect(out, contains('pid 4242'));
    expect(out, contains('hot reload on'));
    expect(out, contains('timing on'));
    // A relative link resolves against the server uri.
    expect(out, contains('http://0.0.0.0:8080/docs'));
    expect(out, contains('ready · press Ctrl-C to stop'));
  });

  test('colour (the default) wraps text in ANSI escapes', () {
    final out = serverBanner(title: 'nitro_server', uri: uri);
    expect(out, contains('\x1b['));
  });

  test('version, pid, links and extra are all optional', () {
    final out = serverBanner(title: 'srv', uri: uri, color: false);
    expect(out, contains('srv'));
    expect(out, isNot(contains(' v'))); // no version suffix
    expect(out, isNot(contains('pid'))); // no pid fact
    expect(out, isNot(contains('routes'))); // no route table
    expect(out, contains('isolates 1')); // default
  });

  test('the ASCII logo is printed above the heading', () {
    final out = serverBanner(
      title: 'nitro_server',
      uri: uri,
      logo: nitroServerAsciiLogo,
      color: false,
    );
    // The first glyph row of the NITRO wordmark.
    expect(out, contains('█   █ █████ █████'));
  });

  test('every route is listed with its kind, plain and coloured', () {
    final plain = serverBanner(
      title: 'srv',
      uri: uri,
      routes: routes,
      color: false,
    );
    expect(plain, contains('routes'));
    expect(plain, contains('GET'));
    expect(plain, contains('PURGE'));
    expect(plain, contains('/users/:id'));
    expect(plain, contains('handler'));
    expect(plain, contains('websocket'));
    expect(plain, contains('static'));

    // Coloured output tints each method by kind/verb.
    final colour = serverBanner(title: 'srv', uri: uri, routes: routes);
    expect(colour, contains('\x1b[32m')); // GET/HEAD green
    expect(colour, contains('\x1b[33m')); // POST yellow
    expect(colour, contains('\x1b[31m')); // DELETE red
    expect(colour, contains('\x1b[36m')); // OPTIONS/custom cyan
    expect(colour, contains('\x1b[35m')); // websocket magenta
    expect(colour, contains('\x1b[34m')); // static blue
  });

  test('an absolute link is used verbatim, not re-resolved', () {
    final out = serverBanner(
      title: 'srv',
      uri: uri,
      links: const {'status': 'https://status.example.com'},
      color: false,
    );
    expect(out, contains('https://status.example.com'));
    // Not double-prefixed with the server origin.
    expect(out, isNot(contains('8080https://')));
  });

  test('links align to the widest label', () {
    final out = serverBanner(
      title: 'srv',
      uri: uri,
      links: const {'a': '/a', 'longlabel': '/b'},
      color: false,
    );
    expect(out, contains('→ a          ')); // 'a' + pad to 9, then gap
    expect(out, contains('→ longlabel  '));
  });
}
