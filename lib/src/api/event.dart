/// Server lifecycle and health events.
library;

/// Mirrors `RawServerEventKind` on the wire.
enum ServerEventKind { started, stopped, handlerTimeout, clientError, notice }

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
