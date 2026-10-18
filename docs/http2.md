# HTTP/2 — design and status

**Status: not implemented.** nitro_server speaks HTTP/1.1 (keep-alive,
pipelining, chunked, `Expect: 100-continue`) and RFC 6455 WebSocket. HTTP/2 is
the one protocol gap and is tracked here with a concrete implementation plan, so
the work is scoped rather than hand-waved.

Why it isn't a quick add: HTTP/2 is not "HTTP/1.1 with a new framing." It is a
binary, multiplexed protocol with HPACK header compression, per-stream and
per-connection flow control, stream prioritisation, SETTINGS negotiation, and
CONTINUATION framing — a correct implementation is a substantial engine
subsystem, not a parser tweak. Advertising `h2` over ALPN without that subsystem
would break every HTTP/2 client, so the engine deliberately negotiates only
`http/1.1` today.

## Plan

Build it on **nghttp2** (the same library curl, nginx and Envoy use) rather than
hand-rolling HPACK/flow-control — hand-rolling those correctly is where HTTP/2
implementations go wrong.

1. **ALPN.** `reactorAlpnSelect` (`UvReactor.cpp`) currently selects
   `http/1.1`. Offer `h2` first, then `http/1.1`, and branch the connection into
   an HTTP/2 or HTTP/1.1 path on the selected protocol. Plaintext h2c (upgrade
   or prior-knowledge) is out of scope — HTTP/2 in practice is over TLS.
2. **Per-connection session.** Attach an `nghttp2_session` to each h2 `Conn`.
   Feed socket bytes (post-TLS-decrypt, reusing the existing memory-BIO path)
   to `nghttp2_session_mem_recv`; drain `nghttp2_session_mem_send` into the
   existing write queue (`writeAnswer`/`tlsRawWrite`). No new I/O path — h2 reuses
   the loop-thread read/write the engine already has.
3. **Stream → request.** Map each HTTP/2 stream to the engine's existing request
   model: on `on_begin_headers`/`on_header` assemble a `ParsedHead` (`:method`,
   `:path`, `:authority`, headers), on end-of-stream emit it through the **same**
   `Emitter.emitHead`/`emitBodyData`/`emitBodyEnd` the HTTP/1.1 path uses — so
   the Dart runner, routing, middleware and handlers are entirely unchanged. A
   stream id replaces the keep-alive request id; `respond`/stream answers write
   back on that stream.
4. **Flow control & multiplexing.** Honour `WINDOW_UPDATE` and `SETTINGS`
   (`nghttp2` manages the windows); map `respond`/`sendStreamChunk` to
   `nghttp2_submit_response` + `DATA` frames with the deferred/resume callback so
   a slow stream back-pressures without blocking the connection's other streams.
5. **Config & lifecycle.** A `ServerConfig.http2` flag (default off while
   experimental); `GOAWAY` on drain, slotting into the existing `beginDrain`
   path.

## What already fits

The architecture is favourable: one loop thread per core, a per-connection state
object, a TLS memory-BIO pipeline, and an `Emitter` seam that already decouples
the wire from the Dart runner. HTTP/2 slots in as an alternate wire behind that
seam — handlers, routing, OpenAPI and the test client need **no** changes.

## Effort

A correct, flow-controlled, nghttp2-backed implementation with a sanitiser-clean
test suite is on the order of weeks, dominated by the streaming/back-pressure
and GOAWAY/drain edge cases. It is deferred until prioritised; HTTP/1.1 keep-alive
+ a reverse proxy (nginx/Envoy terminating h2) covers most deployments in the
meantime.
