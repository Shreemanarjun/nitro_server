# HTTP/2 — design and status

**Status: partially implemented — the serve core (`Http2Session`) is in, the
reactor wiring is not.** nitro_server speaks HTTP/1.1 (keep-alive, pipelining,
chunked, `Expect: 100-continue`) and RFC 6455 WebSocket. HTTP/2 is built on
**nghttp2** (the library curl, nginx and Envoy use) rather than hand-rolling
HPACK/flow-control. The protocol core — a per-connection session that turns h2
frames into the engine's existing request model — exists and is tested; what
remains is grafting it onto the libuv reactor's accept/TLS/read/write loop.

Everything here is gated behind `-DNITRO_SERVER_HTTP2=ON` (off by default). A
default build never links nghttp2 and the engine negotiates only `http/1.1`, so
`h2` is never advertised without a working data path behind it.

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
  data provider over the response buffer.
- **Portability.** Uses the v1 (`ssize_t`) nghttp2 API, which every nghttp2
  version ships — the `nghttp2_ssize` `*2` forms are absent before ~1.61 and
  distros ship older (Ubuntu 24.04 = 1.59). Verified on macOS (1.69) and
  Linux/GCC+clang-ASan (1.59) in CI (the `http2` job).
- **Tested.** A self-contained googletest
  ([`test/cpp/http2_session_test.cpp`](../test/cpp/http2_session_test.cpp))
  drives an in-process nghttp2 **client** session against `Http2Session` through
  mem-buffers (no sockets): a GET round-trips `:status` + body, and a POST
  streams its DATA to the Emitter. ASan-clean.

## Remaining — reactor integration

1. **ALPN.** `reactorAlpnSelect` (`UvReactor.cpp`) selects `http/1.1` today. With
   `NITRO_SERVER_HTTP2`, register `SSL_CTX_set_alpn_select_cb` offering `h2`
   then `http/1.1`, and branch the connection to `Http2Session` vs the HTTP/1.1
   parser on the negotiated protocol. Plaintext h2c is out of scope — h2 in
   practice is over TLS.
2. **Per-connection ownership.** Hold an `Http2Session` on the h2 `Conn`,
   constructed with the connection's `clientIp`, the shared `Router`, and a
   `WriteSink` that writes to the existing TLS/libuv out-queue
   (`writeAnswer`/`tlsRawWrite`). No new I/O path.
3. **Driving the seams.** Call `feed()` from `readCb` with decrypted bytes and
   `pump()` from `onWrite` when a blocked socket drains, so queued DATA flushes
   under flow control.
4. **Answer routing.** A `requestId → Conn` map (the `reqLoc`/pending-table
   analogue) so the Dart `respond` reaches the owning `Http2Session`.
5. **Request body cap — security blocker.** `onDataChunk` currently appends to a
   per-stream buffer with **no size limit** — the h2 path has no equivalent of
   the `413` the HTTP/1.1 path enforces (`maxBodyBytes`). Integration MUST thread
   `cfg_.maxBodyBytes` (+ the route override) into the session and RST the stream
   (`413`/`ENHANCE_YOUR_CALM`) when exceeded, rejecting up front when a declared
   `content-length` already exceeds the cap. **Do not advertise `h2` until this
   lands**, or h2 becomes an unguarded OOM vector HTTP/1.1 rejects. (The header
   block is already capped via `SETTINGS_MAX_HEADER_LIST_SIZE`.)
6. **Streaming uploads, flow control, lifecycle.** The core buffers the full
   request body before one `emitBodyData` (fine for routing; see the `ponytail:`
   note) — move `emitHead` to the HEADERS frame and emit per `on_data_chunk_recv`
   for true streaming. `GOAWAY` on `beginDrain`; a `ServerConfig.http2` flag.
7. **Static & WebSocket routes.** `emitComplete` dispatches every matched route
   to Dart. Integration should serve `route.staticResponse` in-engine (as the
   HTTP/1.1 path does) and refuse `route.isWebSocket` with a `400`/`501` (h2 has
   no HTTP/1.1 `Upgrade`).

## What already fits

The architecture is favourable: one loop thread per core, a per-connection state
object, a TLS memory-BIO pipeline, and an `Emitter` seam that already decouples
the wire from the Dart runner. HTTP/2 slots in as an alternate wire behind that
seam — handlers, routing, OpenAPI and the test client need **no** changes.

## Effort

The serve core is done and sanitiser-clean. The remaining reactor integration
(ALPN branch, per-connection session, `feed()`/`pump()` from the read/write
callbacks, answer routing) is the bulk of the wiring; streaming-upload
back-pressure and `GOAWAY`/drain edge cases are the long tail. Until it lands,
HTTP/1.1 keep-alive + a reverse proxy (nginx/Envoy terminating h2) covers most
deployments.
