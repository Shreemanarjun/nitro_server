/// Graceful shutdown on process signals.
library;

import 'dart:async';
import 'dart:io';

import 'server.dart';

/// Drives one graceful shutdown of a [NitroServer]: on the first trigger it
/// stops its signal handlers and closes the server, draining in-flight requests
/// up to the configured timeout. Idempotent — later triggers return the same
/// in-progress future. Create it with [shutdownOnSignals].
class GracefulShutdown {
  GracefulShutdown._(this._server, this._drain, this._onSignal);

  final NitroServer _server;
  final Duration _drain;
  final void Function(ProcessSignal signal)? _onSignal;
  final List<StreamSubscription<ProcessSignal>> _subs = [];
  Future<void>? _closing;

  /// True once shutdown has begun.
  bool get isShuttingDown => _closing != null;

  /// Begins graceful shutdown now and returns when the server has closed.
  /// Idempotent: concurrent or repeat calls return the same future. [signal]
  /// is forwarded to the `onSignal` callback when present (the signal handlers
  /// pass the signal that fired).
  Future<void> trigger([ProcessSignal? signal]) {
    final inflight = _closing;
    if (inflight != null) return inflight;
    if (signal != null) _onSignal?.call(signal);
    return _closing = _run();
  }

  Future<void> _run() async {
    await cancel();
    await _server.close(drain: _drain);
  }

  /// Stops listening for signals (the server is unaffected). Called by
  /// [trigger] and automatically when the server closes on its own.
  Future<void> cancel() async {
    final subs = List.of(_subs);
    _subs.clear();
    for (final s in subs) {
      await s.cancel();
    }
  }
}

/// Closes [server] gracefully when the process receives a shutdown signal
/// (`SIGINT`/`SIGTERM` by default — what `Ctrl-C` and container orchestrators
/// send), draining in-flight requests up to [drain]. Returns a
/// [GracefulShutdown] you can also [GracefulShutdown.trigger] programmatically
/// (e.g. from an admin route) or [GracefulShutdown.cancel]. Signal handlers are
/// removed automatically once the server closes.
///
/// ```dart
/// final server = await NitroServer.bind(const ServerConfig(port: 8080), setup);
/// shutdownOnSignals(server); // SIGTERM/SIGINT -> drain -> exit cleanly
/// ```
GracefulShutdown shutdownOnSignals(
  NitroServer server, {
  Duration drain = const Duration(seconds: 10),
  List<ProcessSignal>? signals,
  void Function(ProcessSignal signal)? onSignal,
}) {
  final gs = GracefulShutdown._(server, drain, onSignal);
  final sigs = signals ?? [ProcessSignal.sigint, ProcessSignal.sigterm];
  for (final sig in sigs) {
    gs._subs.add(sig.watch().listen(gs.trigger));
  }
  unawaited(server.onClose.then((_) => gs.cancel()));
  return gs;
}
