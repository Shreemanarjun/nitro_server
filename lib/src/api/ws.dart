/// Server-side WebSocket sessions (RFC 6455).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'context.dart';

/// One decoded WebSocket message: a [WsText] or a [WsBinary]. Sealed, so
/// a `switch` over it is exhaustive; the [text]/[bytes] accessors remain
/// for code that checks [isText] instead.
sealed class WsMessage {
  const WsMessage();

  /// A text message (opcode 1). The engine validates UTF-8 on receipt.
  const factory WsMessage.text(String text) = WsText;

  /// A binary message (opcode 2).
  const factory WsMessage.binary(Uint8List bytes) = WsBinary;

  /// Text payload, null for binary messages.
  String? get text;

  /// Binary payload, null for text messages.
  Uint8List? get bytes;

  /// True for text messages.
  bool get isText => this is WsText;

  /// True for binary messages.
  bool get isBinary => this is WsBinary;
}

/// A text message (opcode 1).
final class WsText extends WsMessage {
  const WsText(this.text);

  @override
  final String text;

  @override
  Uint8List? get bytes => null;

  @override
  String toString() => 'WsText($text)';
}

/// A binary message (opcode 2).
final class WsBinary extends WsMessage {
  const WsBinary(this.bytes);

  @override
  final Uint8List bytes;

  @override
  String? get text => null;

  @override
  String toString() => 'WsBinary(${bytes.length} bytes)';
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
