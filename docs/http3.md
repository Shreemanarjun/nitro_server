# HTTP/3 (QUIC) — design and status

**Status: not implemented, and not buildable in the current toolchain.** HTTP/3
runs HTTP semantics over **QUIC** (a UDP transport with its own TLS 1.3
handshake, streams, loss recovery and congestion control). It is a much larger
undertaking than HTTP/2 and has a hard dependency this environment does not
satisfy.

## Why it's blocked

1. **No QUIC library present.** HTTP/3 needs a QUIC stack (`ngtcp2`) plus an
   HTTP/3 binding (`nghttp3`). Neither is installed here (`ngtcp2`/`nghttp3`
   absent), so the code could not even link.
2. **QUIC-capable TLS.** QUIC uses TLS 1.3 through a special handshake API
   (`SSL_set_quic_method` / `SSL_provide_quic_data`). Stock OpenSSL lacked a
   usable server QUIC API for years; it needs a QUIC-enabled OpenSSL
   (3.5+ server QUIC), **quictls**, or **BoringSSL**. The engine's current
   OpenSSL link is not guaranteed to provide it.
3. **UDP, not TCP.** The whole reactor is built on libuv **TCP** (`uv_tcp_*`,
   `SO_REUSEPORT` accept). QUIC is UDP (`uv_udp_*`): there is no accept/connection
   model — every datagram is demuxed to a connection by its QUIC connection id,
   with a fresh per-connection state machine. This is a second I/O path beside
   the existing TCP one, not a tweak to it.

## Plan (when prioritised)

Build on **ngtcp2 + nghttp3** (the pairing curl and nginx's HTTP/3 use), over a
QUIC-capable TLS:

1. **UDP reactor.** Add a `uv_udp_t` per loop thread bound to the TLS port over
   UDP. On each datagram, look up (or create) the QUIC connection by its
   destination connection id and feed the bytes to `ngtcp2_conn_read_pkt`.
2. **QUIC handshake.** Wire ngtcp2's TLS callbacks to the QUIC TLS backend
   (quictls/BoringSSL/OpenSSL-3.5-QUIC); manage keys, 0-RTT (optional), and
   connection-id rotation. This is the bulk of the risk.
3. **HTTP/3 binding.** Attach an `nghttp3_conn` to each QUIC connection; QPACK
   header (de)compression and request/response framing live there. Map each
   HTTP/3 request stream onto the engine's existing `Emitter.emitHead` /
   `emitBodyData` / `emitBodyEnd` — the **same** seam HTTP/1.1 (and the planned
   HTTP/2) use, so the Dart runner, routing, middleware and handlers are
   unchanged.
4. **Loss recovery, flow control, congestion control.** ngtcp2 owns these;
   drive its timers off the loop (`uv_timer_t`) and its send queue into
   `uv_udp_send`.
5. **ALPN + Alt-Svc.** Advertise `h3` over QUIC ALPN, and emit an `Alt-Svc:
   h3=":443"` header from the HTTP/1.1/HTTP/2 path so browsers discover and
   upgrade to HTTP/3.
6. **Config & lifecycle.** A `ServerConfig.http3` flag; a `CONNECTION_CLOSE`
   sweep on drain.

## What already fits

The `Emitter` seam again pays off: HTTP/3 slots in as a third wire behind it,
with no handler/routing/OpenAPI/test-client changes. Everything above the seam
is transport-agnostic.

## Effort

Substantially larger than HTTP/2 — the QUIC transport (handshake, loss
recovery, congestion control, UDP demux, migration) dominates, and the TLS
dependency is a packaging problem of its own. Do **HTTP/2 first** (see
[`http2.md`](http2.md)); HTTP/3 is a later, separately-scoped effort. Until
then, terminate HTTP/3 at a proxy/CDN (nginx, Cloudflare, Envoy) that speaks h3
to clients and HTTP/1.1 to nitro_server.
```
