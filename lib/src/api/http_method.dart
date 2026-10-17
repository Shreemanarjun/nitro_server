/// HTTP methods a route can match.
library;

/// Mirrors `RawServerMethod` on the wire. `all` matches every method;
/// `custom` carries an explicit token in [HttpMethod.custom].
enum HttpMethod {
  get,
  head,
  post,
  put,
  delete,
  patch,
  options,
  trace,
  all,
  custom;

  /// The wire token: uppercase for known methods, `*` for [all].
  String get token => switch (this) {
    HttpMethod.get => 'GET',
    HttpMethod.head => 'HEAD',
    HttpMethod.post => 'POST',
    HttpMethod.put => 'PUT',
    HttpMethod.delete => 'DELETE',
    HttpMethod.patch => 'PATCH',
    HttpMethod.options => 'OPTIONS',
    HttpMethod.trace => 'TRACE',
    HttpMethod.all => '*',
    HttpMethod.custom => throw StateError(
      'HttpMethod.custom needs HttpMethodX.customToken',
    ),
  };

  /// Parses a wire token back. Unknown tokens become [custom] with [tokenOf].
  static (HttpMethod, String) parse(String token) {
    return switch (token) {
      'GET' => (HttpMethod.get, ''),
      'HEAD' => (HttpMethod.head, ''),
      'POST' => (HttpMethod.post, ''),
      'PUT' => (HttpMethod.put, ''),
      'DELETE' => (HttpMethod.delete, ''),
      'PATCH' => (HttpMethod.patch, ''),
      'OPTIONS' => (HttpMethod.options, ''),
      'TRACE' => (HttpMethod.trace, ''),
      '*' => (HttpMethod.all, ''),
      _ => (HttpMethod.custom, token),
    };
  }
}

/// How a [RegisteredRoute] answers: a Dart [handler], a [webSocket] upgrade, or
/// an engine-served [staticResponse] (`getStatic`/`staticRoute`).
enum RouteKind { handler, webSocket, staticResponse }

/// A route currently registered on a server, as returned by `NitroServer.routes`
/// — a read-only snapshot for introspection (health pages, debugging, checking
/// what a `reload` produced).
class RegisteredRoute {
  const RegisteredRoute({
    required this.method,
    required this.pattern,
    required this.kind,
    this.customMethod = '',
  });

  /// The matched method; [HttpMethod.custom] carries its verb in [customMethod].
  final HttpMethod method;

  /// The custom verb when [method] is [HttpMethod.custom], else empty.
  final String customMethod;

  /// The route pattern (`/users/:id`, `/files/*`, …).
  final String pattern;

  /// Whether the route is a handler, a WebSocket or a static response.
  final RouteKind kind;

  /// The wire method token: `GET`, `POST`, `*`, or the [customMethod] verb.
  String get methodToken =>
      method == HttpMethod.custom ? customMethod : method.token;

  @override
  String toString() => '$methodToken $pattern (${kind.name})';

  @override
  bool operator ==(Object other) =>
      other is RegisteredRoute &&
      other.method == method &&
      other.customMethod == customMethod &&
      other.pattern == pattern &&
      other.kind == kind;

  @override
  int get hashCode => Object.hash(method, customMethod, pattern, kind);
}
