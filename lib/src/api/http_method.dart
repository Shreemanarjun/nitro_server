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
