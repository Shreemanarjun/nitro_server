/// Server-side WebSocket sessions (RFC 6455).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'context.dart';

/// One decoded WebSocket message.
class WsMessage {
  /// A text message (opcode 1). The engine validates UTF-8 on receipt.
  const WsMessage.text(this.text) : bytes = null;

  /// A binary message (opcode 2).
  const WsMessage.binary(this.bytes) : text = null;

  /// Text payload, null for binary messages.
  final String? text;

  /// Binary payload, null for text messages.
  final Uint8List? bytes;

  /// True for text messages.
  bool get isText => text != null;

  /// True for binary messages.
  bool get isBinary => bytes != null;
}

/// A live server-side WebSocket session: the upgraded socket.
///
/// The session closes when the route handler returns, when either side
/// calls [close], on peer close, or on server shutdown — whichever comes
/// first. Sends after close are dropped, never errors. Pings are answered
/// by the engine and never surface in [messages].
abstract class WsSession {
  /// The upgrade handshake, delivered like any request: path, query,
  /// headers and `:param` captures are all here.
  RequestContext get handshake;

  /// Decoded text/binary messages. Ends on close.
  Stream<WsMessage> get messages;

  /// The peer's close code once closed (1000 on clean close, 1006 on
  /// transport failure, the sent code on local protocol errors).
  int? get closeCode;

  /// Sends a text message (opcode 1).
  void sendText(String text);

  /// Sends a binary message (opcode 2).
  void sendBytes(Uint8List bytes);

  /// Completes the closing handshake with [code] (default 1000) and reaps
  /// the session. Idempotent.
  Future<void> close([int code = 1000]);
}

/// Answers one WebSocket session. Returning (or throwing) closes the
/// session: `await for`-then-return is the whole read loop. Authenticate
/// before upgrading is impossible — the engine upgrades first — so reject
/// post-accept with `close()` (e.g. `await session.close(4401)`); the
/// handshake request (tokens, cookies) is on [WsSession.handshake].
typedef WsHandler = FutureOr<void> Function(WsSession session);

/// UTF-8 bytes for [text]. Shared with the test client.
Uint8List wsTextBytes(String text) => Uint8List.fromList(utf8.encode(text));
