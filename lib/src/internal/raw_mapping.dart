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
  switch (status.errorKind) {
    case RawServerErrorKind.none:
      return status.boundPort;
    case RawServerErrorKind.alreadyRunning:
      throw ServerAlreadyRunningException('$operation: ${status.errorMessage}');
    case RawServerErrorKind.notRunning:
      throw ServerNotRunningException('$operation: ${status.errorMessage}');
    case RawServerErrorKind.bindFailed:
      throw ServerBindException('$operation: ${status.errorMessage}');
    case RawServerErrorKind.tlsError:
      throw ServerTlsException('$operation: ${status.errorMessage}');
    case RawServerErrorKind.routeNotFound:
      throw RouteNotFoundException('$operation: ${status.errorMessage}');
    case RawServerErrorKind.handlerTimeout:
      throw HandlerTimeoutException('$operation: ${status.errorMessage}');
    case RawServerErrorKind.requestTooLarge:
    case RawServerErrorKind.badRequest:
      throw ServerBadRequestException('$operation: ${status.errorMessage}');
    case RawServerErrorKind.responseTooLarge:
    case RawServerErrorKind.io:
    case RawServerErrorKind.unknown:
      throw ServerUnknownException('$operation: ${status.errorMessage}');
  }
}

/// Maps a public method to its wire value plus custom token.
(RawServerMethod, String) rawMethodOf(HttpMethod method, String customToken) {
  return switch (method) {
    HttpMethod.get => (RawServerMethod.get, ''),
    HttpMethod.head => (RawServerMethod.head, ''),
    HttpMethod.post => (RawServerMethod.post, ''),
    HttpMethod.put => (RawServerMethod.put, ''),
    HttpMethod.delete => (RawServerMethod.delete, ''),
    HttpMethod.patch => (RawServerMethod.patch, ''),
    HttpMethod.options => (RawServerMethod.options, ''),
    HttpMethod.trace => (RawServerMethod.trace, ''),
    HttpMethod.all => (RawServerMethod.all, ''),
    HttpMethod.custom => (RawServerMethod.custom, customToken),
  };
}

/// Maps a wire method back to the public enum plus custom token.
(HttpMethod, String) httpMethodOf(RawServerMethod method, String custom) {
  return switch (method) {
    RawServerMethod.get => (HttpMethod.get, ''),
    RawServerMethod.head => (HttpMethod.head, ''),
    RawServerMethod.post => (HttpMethod.post, ''),
    RawServerMethod.put => (HttpMethod.put, ''),
    RawServerMethod.delete => (HttpMethod.delete, ''),
    RawServerMethod.patch => (HttpMethod.patch, ''),
    RawServerMethod.options => (HttpMethod.options, ''),
    RawServerMethod.trace => (HttpMethod.trace, ''),
    RawServerMethod.all => (HttpMethod.all, ''),
    RawServerMethod.custom => (HttpMethod.custom, custom),
  };
}
