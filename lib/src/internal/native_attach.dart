/// The one-time handshake between a Dart isolate incarnation and the native
/// engine. Same shape as `nitro_http`: a hot restart tears down the Dart
/// isolate but the plugin's native side is process state — accept loops keep
/// listening, connection threads stay parked, routes stay registered. Nothing
/// in Flutter tells a plugin this happened, so the reset runs itself.
library;

import 'dart:isolate';

import '../nitro_server.native.dart';
import 'instance_keys.dart';

bool _attached = false;

/// Whether the handshake has already run in this isolate. Test seam.
bool get nativeAttachedForTesting => _attached;

/// Forgets the handshake, so the next call runs it again. Test seam: a test
/// cannot restart the isolate, but it can put this back the way a restart does.
void resetNativeAttachForTesting() => _attached = false;

/// Reconciles native state with this isolate incarnation. Idempotent, and cheap
/// enough to call on every path that reaches native.
void ensureNativeAttached() {
  if (_attached) return;
  // Set BEFORE the work: `resetNative` builds an engine-role instance, and a
  // re-entrant call must see the handshake as already under way rather than
  // recursing into it.
  _attached = true;

  // Only the isolate that owns the plugin may reconcile it. A background
  // isolate reaching native would otherwise stop the servers the root isolate
  // has running — its own statics are fresh, so it cannot tell a hot restart
  // from simply being new.
  //
  // (Each server instance owns its streams with a single subscriber, so
  // driving one server from several isolates is unsupported anyway.)
  if (Isolate.current.debugName != 'main') return;

  NitroServerNative.forKey(kEngineKey).resetNative();
}

/// Builds the native instance for [key], reconciling this incarnation first.
///
/// Every native role goes through here rather than calling `forKey` directly,
/// so the handshake cannot be missed by a caller that reaches native by an
/// unusual route and so the ordering is fixed: reconcile, then create.
NitroServerNative attachedNative(String key) {
  ensureNativeAttached();
  return NitroServerNative.forKey(key);
}
