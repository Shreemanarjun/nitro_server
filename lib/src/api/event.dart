/// Server lifecycle and health events.
library;

/// Mirrors the engine's `ServerEventKind` on the wire (by index — the kind
/// crosses as an int). [clientDisconnect] carries the `requestId` of an
/// in-flight request whose connection closed; the runner uses it to cancel a
/// still-running streaming handler.
enum ServerEventKind {
  started,
  stopped,
  handlerTimeout,
  clientError,
  notice,
  clientDisconnect,

  /// A handler (or middleware) threw, or produced a response the server
  /// refused to send (a header carrying CR/LF). Emitted by the Dart runner,
  /// never by the engine, so it sits after the engine-mirrored kinds. The
  /// message names the error and carries its stack trace; the client only
  /// sees a generic 500 unless `ServerConfig.exposeErrorDetails` is on.
  handlerError,
}

/// An observation from the engine that is not a request: lifecycle, a timed
/// out handler, a malformed client connection. [requestId] is 0 when the event
/// belongs to the server rather than one request.
class ServerEvent {
  const ServerEvent({
    required this.kind,
    required this.requestId,
    required this.message,
  });

  final ServerEventKind kind;
  final int requestId;
  final String message;

  @override
  String toString() => 'ServerEvent($kind, req=$requestId, $message)';
}
