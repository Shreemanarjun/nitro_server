/// The HTTP verb shorthands shared by [NitroServer] and [RouteGroup].
library;

import 'context.dart';
import 'http_method.dart';

/// The `get`/`post`/`put`/`delete`/`patch`/`options`/`head`/`all` shorthands,
/// shared by `NitroServer` and `RouteGroup` — which differ only in their
/// `Future<T>` self-type (so calls chain to the right object) and in how they
/// register. The host supplies [route]; every shorthand funnels through it, so
/// the common case stays one line:
///
/// ```dart
/// await server.get('/hello', (_) async => ResponseContext.text('hi'));
/// ```
mixin RouteRegistrar<T> {
  /// Registers [handler] for [method] + [pattern]; the verb shorthands below
  /// all delegate here. See the host (`NitroServer.route` / `RouteGroup.route`)
  /// for the exact semantics of each parameter.
  Future<T> route(
    HttpMethod method,
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    String customMethod = '',
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  });

  /// Shorthand for `route(HttpMethod.get, …)`.
  Future<T> get(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.get,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
  );

  /// Shorthand for `route(HttpMethod.head, …)`.
  Future<T> head(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.head,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
  );

  /// Shorthand for `route(HttpMethod.post, …)`; supports [streamBody] uploads.
  Future<T> post(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  }) => route(
    HttpMethod.post,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
    streamBody: streamBody,
    maxBodyBytes: maxBodyBytes,
  );

  /// Shorthand for `route(HttpMethod.put, …)`; supports [streamBody] uploads.
  Future<T> put(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  }) => route(
    HttpMethod.put,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
    streamBody: streamBody,
    maxBodyBytes: maxBodyBytes,
  );

  /// Shorthand for `route(HttpMethod.delete, …)`.
  Future<T> delete(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.delete,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
  );

  /// Shorthand for `route(HttpMethod.patch, …)`; supports [streamBody] uploads.
  Future<T> patch(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
    bool streamBody = false,
    int? maxBodyBytes,
  }) => route(
    HttpMethod.patch,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
    streamBody: streamBody,
    maxBodyBytes: maxBodyBytes,
  );

  /// Shorthand for `route(HttpMethod.options, …)`.
  Future<T> options(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.options,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
  );

  /// Matches every method — handy for echo, proxy and fallback routes.
  Future<T> all(
    String pattern,
    RequestHandler handler, {
    Duration? timeout,
    List<Middleware>? middleware,
  }) => route(
    HttpMethod.all,
    pattern,
    handler,
    timeout: timeout,
    middleware: middleware,
  );
}
