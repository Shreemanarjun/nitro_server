# Protocol conformance

How nitro_server validates that it speaks each wire protocol *correctly*, not
just that its features work. Conformance is tested per protocol, with the same
external gates the major servers (Go `net/http`, nginx, h2o, Netty) use where
they apply.

| Protocol | Status | In-repo conformance suite | External gate (industry standard) |
|----------|--------|---------------------------|-----------------------------------|
| HTTP/1.1 | live | [`test/server_conformance_test.dart`](../test/server_conformance_test.dart) (RFC-cited) + [`test/cpp/uv_reactor_test.cpp`](../test/cpp/uv_reactor_test.cpp) | — (covered by the RFC-cited suite) |
| WebSocket (RFC 6455) | live | `uv_reactor_test.cpp` (WS group, ~20 cases) | **Autobahn\|TestSuite** — runnable against the live server today |
| HTTP/2 (RFC 9113) | live (opt-in `-DNITRO_SERVER_HTTP2=ON`) | [`test/cpp/http2_session_test.cpp`](../test/cpp/http2_session_test.cpp) (adapter) + `uv_reactor_test.cpp` (reactor h2c) | **h2spec 136/145** against the live TLS endpoint |
| HTTP/3 (RFC 9114) | not implemented | — | **h2spec**/quic-interop once built (see [http3.md](http3.md)) |

## HTTP/1.1 — RFC 9110 / 9112 / 3986

`server_conformance_test.dart` drives the live engine over real sockets and
cites the governing RFC section per group:

- **Methods** (RFC 9110 §9) — every standard verb reaches its handler; custom
  verbs round-trip their token.
- **Status codes** (§15) — arbitrary statuses pass through; `204` carries no body.
- **HEAD** (§9.3.2) — headers describe the body, bytes do not follow.
- **Headers** (§5) — duplicates survive; the last line parses; exact
  `content-length` on every response.
- **Query strings** (RFC 3986 §3.4) — empty/single/multi/percent-encoded params.
- **Bodies** (RFC 9112 §6–7) — empty, 1 MB, 5 MB bit-intact; chunked de-chunking;
  `Expect: 100-continue`.
- **Request-smuggling defense** (§6.1/§6.3.3/§3.2) — CL+TE, conflicting/duplicate
  CL, missing/duplicate Host are all `400`.
- **Framing robustness** (§2–3) — split TCP segments, garbage, bad CL, truncated
  body are `400` and the server survives.
- **Keep-alive & pipelining** (§9) — connection reuse, ordered pipelined
  responses, HTTP/1.0 semantics.
- **Routing / static / load** — wildcards, engine 404s, engine-served static
  routes, mixed parallel workload.

The C++ engine suite adds low-level framing conformance (oversized head, chunked
caps, 100-continue, keep-alive deadlines).

## WebSocket — RFC 6455

The engine implements the WebSocket codec; `uv_reactor_test.cpp`'s WS group
covers the same categories the **Autobahn\|TestSuite** exercises:

- Handshake: RFC `Sec-WebSocket-Accept` vector; `426`/`400` for a plain GET,
  wrong version, or missing key; subprotocol negotiation.
- Framing: text/binary decode, **fragment reassembly**, zero-length frames,
  **client-mask enforcement** (an unmasked frame drops the connection).
- Control: **ping → pong**, including a ping interleaved mid-fragmentation;
  server-initiated close; protocol errors close with the right close code.
- `permessage-deflate` (RFC 7692) negotiation + RSV1; backpressure `1009`; WS
  over TLS.

Because WebSocket is live, **Autobahn** can be pointed at a running server for
an independent, exhaustive pass — the in-repo group is the fast CI gate.

## HTTP/2 — RFC 9113

HTTP/2 framing, HPACK, flow control and stream-state conformance are owned by
**nghttp2** (the same library curl, nginx and h2o use) — that is the reason to
build on it rather than hand-roll. nitro_server's conformance surface is the
**adapter** between nghttp2 and the engine's request model, covered by
`http2_session_test.cpp` with an in-process nghttp2 client (no sockets):

- Pseudo-headers → request line (`:method`/`:path` split into path+query/
  `:scheme`/`:authority`); standard and **custom** methods.
- Request completeness on `END_STREAM`; **`bodyComplete` contract** matched to
  the runner (a POST body is never dropped); **trailers** are not folded into
  the head.
- **Multiplexing** — concurrent streams on one connection answered
  independently; response headers echoed; empty-body/`204` closes the stream.
- **HEAD** carries no body (§9.3.2).
- **Body cap** — an over-cap upload (streamed or declared `content-length`) is
  refused `413` before the handler runs (the h2 analogue of the HTTP/1.1 cap);
  `SETTINGS_MAX_HEADER_LIST_SIZE` bounds the header block.
- **Lifecycle** — reset-mid-response is use-after-free-free under ASan; a late
  answer after `stop()` is a no-op; injected request-id allocator avoids
  cross-connection id collisions.

The reactor also has an end-to-end integration test (`uv_reactor_test.cpp`): a
real nghttp2 client drives the live `UvReactor` over a socket via h2c, exercising
preface detection, the loop-thread feed, and the Dart-thread `respond()` hop —
run plain + ASan + TSan in the `http2` CI job (both OSes).

**h2spec** — the standard HTTP/2 conformance tester Go/nginx/h2o gate on — runs
against the live TLS `h2` endpoint and currently passes **136/145** (1 skipped).
The 8 failures are all nghttp2-default-leniency: malformed frames sent to
closed/idle streams and self-referential `PRIORITY`, where nghttp2 answers
`RST_STREAM`/ignores but strict h2spec wants a connection `GOAWAY`. Servers built
on nghttp2 commonly share these deviations; real clients (curl, Go `x/net/http2`,
browsers) are unaffected. The remaining cases are tracked in
[http2.md](http2.md) "Long tail". To reproduce:

```sh
go install github.com/summerwind/h2spec/cmd/h2spec@latest
# start a TLS server built with -DNITRO_SERVER_HTTP2=ON, then:
h2spec -t -k -h 127.0.0.1 -p <port>
```

## Running the suites

```sh
# HTTP/1.1 + WebSocket (Dart live + C++ engine)
dart test test/server_conformance_test.dart
cmake -S src -B build/lib -DNITRO_SERVER_BUILD_TESTS=ON && cmake --build build/lib
./build/lib/nitro_server_tests/nitro_server_engine_tests

# HTTP/2 adapter conformance (opt-in; needs nghttp2)
cmake -S src -B build/h2 -DNITRO_SERVER_BUILD_TESTS=ON -DNITRO_SERVER_HTTP2=ON
cmake --build build/h2 && ./build/h2/nitro_server_tests/nitro_server_engine_tests \
  --gtest_filter='Http2SessionTest.*'
```

CI runs the HTTP/1.1 + WebSocket suites on Ubuntu and macOS (the `test` job) and
the HTTP/2 adapter suite on both (the `http2` job).
