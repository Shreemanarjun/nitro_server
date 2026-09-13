/// Typed failures for every fallible server call.
library;

/// Base class: every `nitro_server` failure is one of these, never a bare
/// `StateError`, so callers can `on NitroServerException` without enumerating.
abstract class NitroServerException implements Exception {
  const NitroServerException(this.message);
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// `start()` on an already-running server.
class ServerAlreadyRunningException extends NitroServerException {
  const ServerAlreadyRunningException(super.message);
}

/// Any operation that needs a running server (`stop` is exempt: stopping a
/// stopped server is a no-op, not an error).
class ServerNotRunningException extends NitroServerException {
  const ServerNotRunningException(super.message);
}

/// The OS refused the bind (port in use, permission, bad host).
class ServerBindException extends NitroServerException {
  const ServerBindException(super.message);
}

/// A non-empty [TlsConfig] on a build without TLS support.
class ServerTlsException extends NitroServerException {
  const ServerTlsException(super.message);
}

/// Unregistering or dispatching against a route that was never registered.
class RouteNotFoundException extends NitroServerException {
  const RouteNotFoundException(super.message);
}

/// A malformed route pattern or request the engine refused to accept.
class ServerBadRequestException extends NitroServerException {
  const ServerBadRequestException(super.message);
}

/// A handler that outlived its route timeout. Surfaced on the events stream
/// and as the 408 the client received; the late handler result is dropped.
class HandlerTimeoutException extends NitroServerException {
  const HandlerTimeoutException(super.message);
}

/// Anything the engine could not classify. Carries the native message.
class ServerUnknownException extends NitroServerException {
  const ServerUnknownException(super.message);
}
