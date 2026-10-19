# HTTP/2 — design and status

**Status: implemented and live (behind `-DNITRO_SERVER_HTTP2=ON`).** A server
built with the flag serves HTTP/2 end to end — over TLS via ALPN (`h2`) and
cleartext via the h2c prior-knowledge preface — alongside HTTP/1.1 (keep-alive,
pipelining, chunked, `Expect: 100-continue`) and RFC 6455 WebSocket. It is built
on **nghttp2** (the library curl, nginx and Envoy use) rather than hand-rolling
HPACK/flow-control.

Verified live: `curl --http2` (TLS/ALPN) and `curl --http2-prior-knowledge`
(h2c) and a pure-Go `x/net/http2` client all round-trip GET/POST correctly; the
reactor wiring is ASan- and TSan-clean (the `http2` CI job runs the suite plain +
ASan + TSan on Ubuntu and macOS). **h2spec conformance: 136/145** against the live
TLS endpoint — see [conformance.md](conformance.md) for the 8 long-tail items
(all nghttp2-default-leniency on malformed frames to closed streams / PRIORITY
edge cases; real clients are unaffected).

Everything is gated behind `-DNITRO_SERVER_HTTP2=ON` (off by default). A default
build never links nghttp2 and negotiates only `http/1.1`, so `h2` is never
advertised without the data path behind it.

## Reactor wiring ([`src/engine/UvReactor.cpp`](../src/engine/UvReactor.cpp))

- **Negotiation.** `reactorAlpnSelect` offers `h2` then `http/1.1`; after the TLS
  handshake, `SSL_get0_alpn_selected == "h2"` attaches an `Http2Session`
  (`createH2Session`). On a plaintext connection, the `PRI * HTTP/2.0` preface is
  detected in `processConn` (h2c prior-knowledge).
- **Runtime toggle.** All of the above is gated on `cfg_.http2`, set from
  `ServerConfig(protocol:)` (`HttpProtocol.http1` → the ALPN callback offers only
  `http/1.1` and the h2c preface is ignored; `.http2`/`.http3` → `h2` on). So the
  engine ships with HTTP/2 compiled in and each server chooses its max protocol
  at runtime — no rebuild to disable it.
- **Inbound.** Decrypted/raw bytes feed the session (`feedH2`) on the loop
  thread; the session emits requests through the existing `Emitter`.
- **Outbound (thread-safe).** A Dart `respond()` arrives on an isolate thread; it
  is enqueued to the owning connection's loop and run as `Http2Session::respond`
  inside `onAsync` on the **loop thread**, so nghttp2 is never touched off it.
  The write-sink is `writeRaw` (which encrypts when the conn is TLS). The
  injected id allocator registers `reqLoc_` so the answer finds its session.
- **Lifecycle.** The connection closes once nghttp2 reports the session finished
  (GOAWAY / peer GOAWAY → wants neither read nor write), so a conformant peer is
  never left waiting on a half-open socket.

## Serve core — `Http2Session` ([`src/engine/Http2Session.{h,cpp}`](../src/engine/Http2Session.cpp))


## Done — `Http2Session` ([`src/engine/Http2Session.{h,cpp}`](../src/engine/Http2Session.cpp))

A per-connection `nghttp2_session` wrapper, the h2 analogue of the HTTP/1.1 path
on `UvReactor`, decoupled from sockets by two `std::function` seams (`feed()` in,
a `WriteSink` out):

- **Inbound.** `on_begin_headers`/`on_header` assemble `:method`/`:path`
  (split into path+query)/`:scheme`/`:authority` + headers per stream; on
  `END_STREAM` the request is emitted through the **same**
  `Emitter.emitHead`/`emitBodyData`/`emitBodyEnd` seam HTTP/1.1 uses — so routing
  (`Router::match`), middleware, handlers, OpenAPI and the Dart runner are
  entirely unchanged.
- **Outbound.** `respond(requestId, status, headers, body)` maps the engine
  request id back to its h2 stream and calls `nghttp2_submit_response` with a
  data provider over the response buffer. A **HEAD** response carries the headers
  but no body (RFC 9110 §9.3.2), like the HTTP/1.1 path.
- **Security, in-unit.** A request body cap (`maxBodyBytes` ctor arg, `<= 0` =
  unlimited) refuses an over-cap upload `413` before the handler runs — enforced
  both up front on a declared `content-length` and as the body accrues (a lying
  or chunked upload). `SETTINGS_MAX_HEADER_LIST_SIZE` bounds the header block.
  The session owns these guards so it is safe standalone — the reactor only
  passes the configured value; there is no "advertise h2 before the cap exists"
  window.
- **Lifecycle, in-unit.** An injected `IdAllocator` lets the reactor share its
  global request-id space across every connection (no per-session id collision);
  `stop()` makes `feed()`/`respond()` no-ops so a late answer or stray bytes in
  the drain window cannot drive a half-dead session.
- **Extensible.** Implements the [`ProtocolSession`](../src/engine/ProtocolSession.h)
  interface (`feed`/`respond`/`pump`/`wantRead`/`wantWrite`/`stop`) — the seam a
  future HTTP/3 (QUIC) session plugs into unchanged above the Emitter. See
  [http3.md](http3.md).
- **Portability.** Uses the v1 (`ssize_t`) nghttp2 API, which every nghttp2
  version ships — the `nghttp2_ssize` `*2` forms are absent before ~1.61 and
  distros ship older (Ubuntu 24.04 = 1.59). Verified on macOS (1.69) and
  Linux/GCC+(g++/clang)-ASan (1.59) in CI (the `http2` job).
- **Tested.** A self-contained googletest
  ([`test/cpp/http2_session_test.cpp`](../test/cpp/http2_session_test.cpp))
  drives an in-process nghttp2 **client** against `Http2Session` through
  mem-buffers (no sockets): GET/POST round-trips, multiplexed concurrent streams,
  HEAD-has-no-body, response-header echo, body-cap `413` (streamed + declared),
  reset-mid-response (ASan-clean), `stop()` liveness, shared id allocator,
  custom methods, trailers ignored. See [conformance.md](conformance.md).

## Long tail — refinements beyond the MVP

The serve path is live and sanitiser-clean; these are hardening/quality items,
not blockers. None affect the GET/POST/multiplexed-JSON-API core that real
clients exercise.

1. **h2spec: the 8 remaining cases** (136/145). All are nghttp2-default-leniency
   on malformed frames sent to closed/idle streams and self-referential PRIORITY
   — nghttp2 answers `RST_STREAM`/ignores where strict h2spec wants a connection
   `GOAWAY`. Closing them means nghttp2 strict-mode options and per-callback
   `GOAWAY` submission; weigh against the core-stability risk. Servers built on
   nghttp2 commonly share these deviations.
2. **Streaming request bodies.** The core buffers the full POST body before one
   `emitBodyData` (fine for routing + the cap). For true streaming, move
   `emitHead` to the HEADERS frame (`bodyComplete=false`) and emit per
   `on_data_chunk_recv`, `emitBodyEnd` on the last DATA.
3. **Streaming responses.** A handler's `startStream`/chunks over h2 are buffered
   and sent as one DATA body (`H2StreamAccum`). Now bounded + hardened: the
   buffer is capped at `maxBodyBytes` (an indefinite/oversized stream answers
   `503` instead of growing without bound — OOM-safe, and valid since no bytes
   are on the wire yet); a **HEAD** stream answers headers-only immediately
   rather than buffering a discarded body; and an h2 connection with open
   streams is never idle-reaped mid-request (it carries no `c->busy`). The
   remaining follow-up is *true* incremental delivery: a per-frame `nghttp2`
   data provider (deferred read + `nghttp2_session_resume_data`) fed from the
   chunk stream, with `WINDOW_UPDATE` back-pressure driving `pump()` from
   `onWrite` — so large/SSE responses stream byte-for-byte instead of
   buffer-then-flush.
4. **Static & WebSocket routes over h2.** `emitComplete` dispatches a matched
   `staticResponse` to Dart rather than serving it in-engine, and an h2 request
   to a WebSocket route is dispatched rather than refused (h2 has no HTTP/1.1
   `Upgrade`).
5. **`GOAWAY` on drain.** `beginDrain` closes h2 connections via the normal path;
   a graceful `GOAWAY(last-stream-id)` sweep would let in-flight streams finish.
6. **Adaptive dispatch within a connection.** An `Http2Session` binds one
   `Emitter` (isolate) for its lifetime; per-request `nextEmitter()` would spread
   a single busy h2 connection's streams across isolates.
7. **Client-disconnect handler cancel.** `onCloseConn` now drops a closing
   connection's in-flight `reqLoc_`/`h2StreamAccum_` entries (no engine-side
   leak when a client disconnects mid-stream, h1 and h2 alike). The remaining
   follow-up is telling the Dart runner to cancel the handler's outbound stream
   subscription so an indefinite source (`Stream.periodic` SSE) stops producing
   — that needs a `ClientDisconnect` server-event kind carrying the request id
   (a `RawServerEventKind` addition → bridge regen) which `_onEvent` handles by
   `_outbound.remove(id)?.cancel()`. Until then a disconnected indefinite stream
   keeps running in Dart (the engine no-ops its writes; no leak, but wasted CPU).

## What makes it fit

The architecture pays off: one loop thread per core, a per-connection state
object, a TLS memory-BIO pipeline, and an `Emitter` seam that decouples the wire
from the Dart runner. HTTP/2 slots in behind that seam — handlers, routing,
OpenAPI, middleware and the Dart runner are **unchanged**, and the
[`ProtocolSession`](../src/engine/ProtocolSession.h) interface is the same seam a
future HTTP/3 (QUIC) session plugs into (see [http3.md](http3.md)).
