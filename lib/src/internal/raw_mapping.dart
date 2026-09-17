/// Total mapping between wire records and the public API.
///
/// Every `RawServerErrorKind` maps to exactly one [NitroServerException]
/// subtype, and every public enum maps to exactly one wire value. The tables
/// here are exhaustive by construction (`switch` over the enum, no default),
/// so adding a case on either side breaks compilation until the other side
/// follows.
library;

import '../api/exceptions.dart';
import '../api/http_method.dart';
import '../nitro_server.native.dart';

/// Throws the typed exception for a failed [RawServerStatus]. A `none`
/// status returns the envelope's `boundPort` instead.
int throwIfFailed(RawServerStatus status, {required String operation}) {
  // Switch expression, exhaustive with no default: adding a
  // RawServerErrorKind breaks compilation until a mapping follows.
  return switch (status.errorKind) {
    RawServerErrorKind.none => status.boundPort,
    RawServerErrorKind.alreadyRunning => throw ServerAlreadyRunningException(
      '$operation: ${status.errorMessage}',
    ),
    RawServerErrorKind.notRunning => throw ServerNotRunningException(
      '$operation: ${status.errorMessage}',
    ),
    RawServerErrorKind.bindFailed => throw ServerBindException(
      '$operation: ${status.errorMessage}',
    ),
    RawServerErrorKind.tlsError => throw ServerTlsException(
      '$operation: ${status.errorMessage}',
    ),
    RawServerErrorKind.routeNotFound => throw RouteNotFoundException(
      '$operation: ${status.errorMessage}',
    ),
    RawServerErrorKind.handlerTimeout => throw HandlerTimeoutException(
      '$operation: ${status.errorMessage}',
    ),
    RawServerErrorKind.requestTooLarge || RawServerErrorKind.badRequest =>
      throw ServerBadRequestException('$operation: ${status.errorMessage}'),
    RawServerErrorKind.responseTooLarge ||
    RawServerErrorKind.io ||
    RawServerErrorKind.unknown => throw ServerUnknownException(
      '$operation: ${status.errorMessage}',
    ),
  };
}

/// Maps a public method to its wire value plus custom token.
///
/// Every non-custom result is a `const` record, so it is canonicalized to a
/// single shared instance instead of allocating one per call.
(RawServerMethod, String) rawMethodOf(HttpMethod method, String customToken) {
  return switch (method) {
    HttpMethod.get => const (RawServerMethod.get, ''),
    HttpMethod.head => const (RawServerMethod.head, ''),
    HttpMethod.post => const (RawServerMethod.post, ''),
    HttpMethod.put => const (RawServerMethod.put, ''),
    HttpMethod.delete => const (RawServerMethod.delete, ''),
    HttpMethod.patch => const (RawServerMethod.patch, ''),
    HttpMethod.options => const (RawServerMethod.options, ''),
    HttpMethod.trace => const (RawServerMethod.trace, ''),
    HttpMethod.all => const (RawServerMethod.all, ''),
    HttpMethod.custom => (RawServerMethod.custom, customToken),
  };
}

/// Maps a wire method back to the public enum plus custom token.
///
/// On the request hot path (once per dispatch): the non-custom branches are
/// `const` records, canonicalized to shared instances — no per-request record
/// allocation for a standard HTTP method.
(HttpMethod, String) httpMethodOf(RawServerMethod method, String custom) {
  return switch (method) {
    RawServerMethod.get => const (HttpMethod.get, ''),
    RawServerMethod.head => const (HttpMethod.head, ''),
    RawServerMethod.post => const (HttpMethod.post, ''),
    RawServerMethod.put => const (HttpMethod.put, ''),
    RawServerMethod.delete => const (HttpMethod.delete, ''),
    RawServerMethod.patch => const (HttpMethod.patch, ''),
    RawServerMethod.options => const (HttpMethod.options, ''),
    RawServerMethod.trace => const (HttpMethod.trace, ''),
    RawServerMethod.all => const (HttpMethod.all, ''),
    RawServerMethod.custom => (HttpMethod.custom, custom),
  };
}

/// The wire form of request headers (see `RawIncomingRequest.packedHeaders`):
/// `name\u0000value` pairs joined by `\u0000`, empty for none.
String packHeaders(Iterable<MapEntry<String, String>> headers) {
  final buffer = StringBuffer();
  var first = true;
  for (final entry in headers) {
    if (!first) buffer.writeCharCode(0);
    first = false;
    buffer
      ..write(entry.key)
      ..writeCharCode(0)
      ..write(entry.value);
  }
  return buffer.toString();
}
