# Production-readiness audit

**Date:** 2026-10-21  
**Scope:** `nitro_server` v1.0.0 — Dart API, C++/libuv engine, packaging, tests, CI, and deployment path  
**Status:** Findings only; no remediation has been applied

## Status (2026-10-21)

Every finding below was fixed the same day, each behind a regression test;
the sections that follow are the audit as written, kept as the record of what
was found and why each change exists.

| Finding | Fix | Regression test |
| --- | --- | --- |
| P0-1 static traversal / symlinks | `staticFiles`: decode-once + reject, real path under canonical root, `dotfiles`, `followSymlinks` | `static_files_test` containment group, `security_audit_test` P0-1 |
| P0-2 response splitting | runner `_deliver` validates names/values, strips hop-by-hop, 500 + `handlerError`; engine `uvBuildHead` drops unsafe fields; strict request field lines | `test_client_test` header hardening, `uv_reactor_test` HeaderFieldLinesAreStrict / UnsafeOrEngineOwnedHandlerHeaders…, `security_audit_test` P0-2 |
| P0-3 Transfer-Encoding | `uvFraming`: token list, `chunked` only, 501/400 | `uv_reactor_test` TransferEncodingIsAValidatedTokenList, `security_audit_test` P0-3 |
| P0-4 chunk-size parsing | `uvChunkSize`: hex only, `;ext`, overflow, data CRLF, bounded trailers (both decoders) | `uv_reactor_test` ChunkSizeLinesAreStrict, `security_audit_test` P0-4 |
| P0-5 WS inflate bomb | `wsInflate(maxBytes:)` → 1009 | `ws_test` inflate cap + runner 1009 |
| P0-6 500 leaks errors | generic body, `exposeErrorDetails`, `handlerError` event with stack | `test_client_test`, `security_audit_test` P0-6 |
| P0-7 Dockerfile | rebuilt (Flutter line stripped, deps, all features static, `dart build cli`, digest pins); CI `docker` job + Trivy | CI `docker` |
| P0-8 rate-limit keys | `trustedProxies` (IP/CIDR), nearest untrusted hop, `InMemoryRateLimitStore(maxKeys:)` eviction | `middleware_test` rateLimit group |
| P1 h2 deadlines / caps / GOAWAY | `Http2Session`: route match on HEADERS, per-route cap, `sweep()` 408, `goAway()`; reactor sweep drives both | `http2_session_test` (9 new), `uv_reactor_test` Http2DrainSendsGoaway… |
| P1 slow body | `readCb` refreshes activity; `bodyTimeout` stall window on buffered, streamed and h2 bodies → 408 | `uv_reactor_test` SlowBody…/BodyTimeout…/StreamedUpload…, `production_hardening_test` |
| P1 budgets | `maxInFlightRequests` (503 everywhere), `maxConnectionAge`; per-connection memory bound documented (one body on HTTP/1.1 or `maxBufferedBodyBytes` on HTTP/2, plus the write-side caps; × `maxConnections`) — see the second re-audit, row 5 | `uv_reactor_test` InFlightBudget…/MaxConnectionAge…, `production_hardening_test` |
| P1 WS/stream idle | `wsIdleTimeout` ping/pong + 1001; stalled writes already covered by `writeTimeout`; `maxConnectionAge` bounds everything | `uv_reactor_test` WsIdle…/WsPong…, `production_hardening_test` |
| P1 helper isolates | `NitroServer.helperTimeout`, kill + `detachEmitter` + `notice` + readiness | `production_hardening_test` helper group |
| P1 config | `validate()` in `bind`, fail-fast `fromEnv` with every variable + TLS | `context_test` |
| P1 static hardening | dotfiles / no-follow / resolved path; open failures already 404 in-engine | `static_files_test` |
| P1 multipart / JSON | boundary grammar, `maxParts`, `maxPartHeaderBytes`, linear scan; `validateJsonBody(maxErrors:)`; depth test | `multipart_test`, `schema_test` |
| P1 observability | `middleware:`, `maxDashboardViewers`, no-store, `textContent`, status classes, connections, lag, helper gauge, `_sum`; example guarded | `observability_test`, CI `docker` smoke (403 from off-host) |
| P1 error logging | `handlerError` events (verb, path, error, stack) — the pluggable sink | `test_client_test` |
| P1 HTTP/1.1 conformance | `Date`, no CL on 204/304/1xx, full reason table, 405 + `Allow` (h1 + h2), token `Connection` | `uv_reactor_test` ResponseHeadConformance / MethodMismatchIs405…, `router_test.cpp` (allowedMethods), `server_conformance_test`, `production_hardening_test` (405 + Allow), `security_audit_test` P1 |
| P1 proxy / TLS | `trustedProxies`; `TLS_*` env; **PROXY protocol v1/v2** (`ServerConfig.proxyProtocol`: parsed ahead of TLS and h2, source address becomes `clientIp`, missing/malformed header closes + `clientError`); **mutual TLS** (`TlsConfig.clientCaPem/clientCaFile` → client certificate mandatory), `minVersion` (1.2/1.3), `ciphers` / `cipherSuites`; a rejected policy fails `bind` | `uv_reactor_test` ProxyProtocol…, `TlsTest` ProxyProtocolHeaderPrecedesTheHandshake / MutualTls… / MinimumVersionAndCipherPolicy, `production_hardening_test`, `context_test` |
| P2 packaging | digest pins, `.dockerignore`, release gated on tests; every prebuilt gets Sigstore build provenance (`gh attestation verify`), a keyless cosign signature bundle (`<asset>.sigstore.json`, `cosign verify-blob --bundle`) and an SPDX SBOM (`<asset>.spdx.json`). Consumer side: the hook accepts a prebuilt only when it matches `hook/prebuilt_checksums.json`, a digest lock shipped inside the package, and with `NITRO_SERVER_VERIFY_SIGSTORE=1` only when `cosign verify-blob` also passes against the release workflow's identity; `tool/update_prebuilt_lock.sh` fills the lock, `tool/verify_prebuilt_lock.dart` drives the hook's path against a release, and the release workflow's `verify` job runs both with real cosign on every tag — first executed for `v1.0.0` in run 40073440905 (2026-10-24): all five prebuilts cosign-verified and accepted through the hook's path; the lock it produced is in the tree. Exercised end to end on 2026-10-22: a mock release (asset, sidecar, bundle, cosign stand-in) in `prebuilt_lock_test`, and the real `v1.0.0-rc.4` release from GitHub (5/5 assets accepted through the hook's path; a tampered lock refused the real asset). The strict Sigstore path was run with the real cosign 3.1.4 binary through the hook's own function: it accepted GoReleaser `v2.18.3` and Syft `v1.55.0` release assets signed by their GitHub Actions identities (`Verified OK`), refused the same bundles under this package's identity, and refused a tampered bundle (`NITRO_SERVER_REPO=goreleaser/goreleaser NITRO_SERVER_PREBUILT_LOCK=<lock> NITRO_SERVER_VERIFY_SIGSTORE=1 dart tool/verify_prebuilt_lock.dart 2.18.3` reproduces the positive case). The `1.0.0` entry was produced by that run's artifact (five digests); until a version's release exists its entry is empty and the hook builds from source, saying so | `prebuilt_lock_test`, `release.yml` |
| P2 CI | `docker`+Trivy, `fuzz`, `tidy` (`.clang-tidy`), ASan `detect_leaks=1` on Linux, `-Werror` | `ci.yml` |
| P2 build hardening | stack protector, `_FORTIFY_SOURCE=2`, hidden visibility, RELRO/NOW/noexecstack, `-Wall -Wextra`, no `-ffast-math` | `src/CMakeLists.txt` |
| P2 docs | README/deployment/CHANGELOG updated (static/WS bypass, h2 buffering, proxy trust, budgets) | — |
| P2 Swagger/dashboard | pinned 5.17.14 + SRI + CSP, `no-store`, `textContent` | `openapi_test`, `observability_test` |
| P2 tests | all of the above; h2spec floor gate (136) in CI; Autobahn run locally against the real server — it exposed two engine bugs (oversized/fragmented control frames hung the connection instead of 1002; close frames were echoed unvalidated: 1-byte payloads, invalid codes, non-UTF-8 reasons) and the example echo prefixing replies — all fixed, with the suite now a CI gate (any FAILED case fails the job); nightly soak (`tool/soak.dart`) | `uv_reactor_test` WsOversizedOrFragmentedControlFramesAre1002 / WsCloseFramesAreValidated, `ci.yml`, `soak.yml` |

Verified locally on 2026-10-22 against the final engine (after the re-audit
fixes and the second re-audit below): Dart suite 532/532 at 100% line coverage
(3185/3185 lines); C++ suite 191/191 plain, under AddressSanitizer and under
ThreadSanitizer, 93.8% engine line coverage; the default no-HTTP/2
configuration 166/166 under `-Werror`; `tool/fuzz.sh` (head, WS frame, live
reactor) clean; `tool/crash_stress.sh` clean; clang-tidy clean; h2spec 137/146
(floor 136; the 9 misses are the documented nghttp2-leniency cases);
`-Werror` build clean; `docker build` + a running container answering `/readyz`
200, `/metrics` 403 off-host / 200 on loopback, `Date` + `no-store`, 405 +
`Allow`, h2c, 400 on a split header, 404 on encoded traversal, HEALTHCHECK
healthy, the example's protected routes 401 for `admin:dev` until
`BASIC_USER`/`BASIC_PASSWORD` are set and 200 for the configured pair. Found on the way: with `NITRO_SERVER_STATIC_DEPS=ON` the pkg-config
branch linked `libuv.so` anyway (bare `-luv`), so a "static" engine still needed
libuv at runtime — `engine.cmake` now pins `libuv.a`; this affected the release
prebuilts too.

Conformance gates were executed locally before being trusted in CI: h2spec
2.6.0 against the live server scores 137/146 (floor 136; the 9 misses are the
same stream-state and PRIORITY edge cases documented in `doc/http2.md`),
Autobahn 0 FAILED (see the P2 tests row), and the soak (`tool/soak.dart`,
120 s locally; 600 s nightly) ran 2.8 M requests across keep-alive HTTP, 4 KB
echoes, chunked streaming, SSE and WebSocket echo with 0 errors and 7.3% RSS
growth between the quarter mark and the end (limit 25%: a plateau, not a
leak). Everything the audit asked for is
implemented; HTTP/3 stays out of scope by the maintainer's decision
(2026-10-22), release signing is keyless through Sigstore (workflow identity)
rather than key-based, and the consumer side verifies a prebuilt against a
digest lock shipped in the package, with optional cosign verification (see
the P2 packaging row). Performance was re-measured with the blackbox harness
on the final engine, after the re-audit fixes (see "Performance after
hardening" below): standings unchanged, nitro at or above its pre-hardening
numbers on every route.

## Verdict

The core is strong: a libuv multi-loop engine, native `sendfile`, bounded request
bodies, HTTP/1.1 framing checks, optional HTTP/2 and TLS, a WebSocket codec,
graceful drain, observability, 100% Dart / 90% C++ line-coverage gates,
ASan/TSan CI, and a benchmark harness.

It is **not yet safe-by-default for direct internet exposure**. The highest-risk
areas are static-file containment, response-header construction, request
framing, WebSocket decompression, and the shipped Docker image.

## Severity

| Level | Meaning |
|---|---|
| **P0** | Exploitable or a deployment blocker; fix before exposing the server |
| **P1** | Availability, correctness, or operational risk at production scale |
| **P2** | Hardening, conformance, supply-chain, and documentation work |

## P0 — fix before exposing

### 1. Encoded static-file traversal and symlink escape

**Evidence:** `lib/src/api/static_files.dart:118-131`, `:63-68`

`_relativePath` rejects a literal `..` and `\`, then calls
`Uri.decodeComponent(segment)` after that check. A request such as
`/assets/%2e%2e%2fetc%2fpasswd` decodes into `../etc/passwd` and escapes the
configured root. `%2f` and `%5c` are also decoded after validation. `File`
follows symlinks, so a link inside the served directory can point outside it;
there is also a stat-then-sendfile TOCTOU window.

**Fix:**

- Canonicalize the root once at startup.
- Reject encoded separators (`%2f`, `%5c`) and encoded dot segments before and
  after exactly one decode.
- Resolve the final path with symlinks resolved and require it to remain under
  the canonical root plus a path separator.
- Consider opening the file descriptor first and serving from that descriptor.
- Offer an explicit no-symlink / dotfile policy; deny dotfiles by default.

### 2. Response-header injection / response splitting

**Evidence:** `src/engine/UvReactor.cpp:151-178`, `lib/src/api/middleware.dart:111-119`, `src/engine/HttpParse.cpp:52-66`

`uvBuildHead` writes handler-supplied header names and values directly. There is
no token/name validation and no CR/LF/control-character rejection.
`requestId()` echoes an inbound `X-Request-Id` or `X-Correlation-Id` into the
response. The parser trims header names and values but accepts a bare LF inside
a value, so a request containing:

```text
X-Request-Id: ok\nInjected: yes
```

can produce a split response header through the request-ID middleware.

The same primitive is reachable through any application header built from
request data, including cookies and redirects.

**Fix:**

- Build every HTTP/1.1 head through one validating helper.
- Reject header names that are not RFC tokens.
- Reject `\r`, `\n`, NUL, and other control characters in values.
- Strip hop-by-hop and framing headers (`Connection`, `Transfer-Encoding`,
  `Trailer`, `Upgrade`, `Keep-Alive`, `Proxy-*`) from handler responses.
- Validate/regenerate inbound request IDs and cap their length.
- Validate cookie names/values and redirect targets at the API boundary.
- Reject bare LF, obs-fold, and whitespace before the colon in request heads.

### 3. Request-smuggling gaps in `Transfer-Encoding`

**Evidence:** `src/engine/UvReactor.cpp:234-256`, `:1110-1111`

`uvFramingError` treats any `Transfer-Encoding` as “has TE” and rejects only
CL+TE. It does not validate the coding list. Body handling then uses a
case-sensitive substring search:

```cpp
if (te->value.find("chunked") != std::string::npos) chunked = true;
```

Consequences:

- `Transfer-Encoding: Chunked` is treated as no body.
- `Transfer-Encoding: notchunked` is treated as chunked.
- Unsupported codings such as `gzip` are accepted as no-body requests.
- Duplicate TE headers are not rejected.
- Ordering such as `chunked, gzip` is accepted even though `chunked` must be
  final.

Any front proxy that parses TE differently can desynchronize framing.

**Fix:**

- Parse TE as a comma-separated, case-insensitive token list.
- Require exactly one supported coding, `chunked`, and require it to be final.
- Reject every other coding with `501` or `400`.
- Reject duplicate TE and TE on HTTP/1.0.
- Keep the existing CL+TE rejection.
- Drive body parsing from the validated framing result, not a second
  `find()` call.

### 4. Permissive chunk-size parsing

**Evidence:** `src/engine/UvReactor.cpp:267-295`

`decodeChunked` uses `std::strtol` without checking overflow or that the parsed
value ends at the chunk-size line. It also skips the two bytes after chunk data
without verifying they are CRLF, and performs size arithmetic on
attacker-controlled values.

**Fix:**

- Parse with `std::from_chars` and reject overflow, signs, and trailing
  non-extension garbage.
- Validate the data CRLF.
- Cap a chunk size against the remaining body budget before arithmetic.
- Reject malformed trailers and limit trailer count/size.

### 5. WebSocket permessage-deflate bomb

**Evidence:** `lib/src/api/ws.dart:139-148`, `lib/src/internal/server_runner.dart:1324-1329`

Compressed frames are limited by `maxBodyBytes` (10 MB by default), but
`wsInflate` has no output limit. Deflate can expand by roughly three orders of
magnitude, so a small compressed message can exhaust the isolate heap.

**Fix:**

- Inflate incrementally with a hard output cap (`wsMaxMessageBytes`, or a
  configurable ratio).
- Abort with close code `1009` as soon as the cap is crossed.
- Do not accumulate an unbounded `BytesBuilder`.
- Add a compressed-frame fuzz corpus that asserts the cap — done as `ws_test` "a corpus of random compression bombs all close 1009" (seeded random payloads 1 B–4 MiB over the cap) plus the single-bomb case.

### 6. Default 500 response leaks exception text

**Evidence:** `lib/src/internal/server_runner.dart:229-230`

The default error handler returns:

```dart
ResponseContext.text('handler error: $error', status: 500);
```

Exception messages can contain file paths, SQL, tokens, or internal state.

**Fix:**

- Return a generic body plus a correlation ID.
- Log the full error server-side.
- Make leaking details an explicit opt-in for development only.

### 7. Docker image build/runtime blockers

**Evidence:** `Dockerfile`, `src/engine.cmake:37-100`, `src/CMakeLists.txt:5-55`

- The build stage installs `cmake clang make` but not `libuv1-dev` or
  `pkg-config`; `engine.cmake` hard-fails without libuv headers.
- The runtime stage installs no `libuv1`, while the default CMake build links
  libuv dynamically. The engine library will fail to load without it.
- The Docker build does not set `NITRO_SERVER_NATIVE_TUNE=OFF`, so it compiles
  with `-march=native`; an image built on a newer CPU can SIGILL on another
  host.
- HTTP/2 is off by default and the Docker build does not enable it. TLS is
  auto-detected and will also be off unless OpenSSL is installed in the build
  stage.
- Base images use floating tags (`dart:stable`, `debian:stable-slim`).

**Fix:**

- Install `libuv1-dev` and `pkg-config` in the build stage.
- Either install `libuv1` in runtime or build with
  `-DNITRO_SERVER_STATIC_DEPS=ON`.
- Pass `-DNITRO_SERVER_NATIVE_TUNE=OFF`.
- Explicitly enable or document TLS/HTTP/2/brotli.
- Pin base images by digest.
- Add a CI job that runs `docker build`, starts the container, and checks
  `/readyz`.

### 8. Spoofable, unbounded rate-limit keys

**Evidence:** `lib/src/api/middleware.dart:398-404`, `:379-393`

The default key uses the first `X-Forwarded-For` hop, then `X-Real-IP`, before
the socket peer. Any direct client can rotate those headers to bypass the
limit. The in-memory store grows with unique keys and evicts only when a new
key arrives, making spoofed-key traffic both a memory and CPU issue.

**Fix:**

- Add `trustedProxies` / trusted-hop configuration.
- Use the socket peer by default.
- Validate forwarded IP syntax and select the correct hop.
- Cap store size, evict periodically, and define an overflow policy.
- Keep the per-isolate caveat prominent and support a shared store.

## P1 — availability and correctness

### HTTP/2 route timeout and per-route body cap are not enforced

HTTP/1.1 sets `reqDeadline` before dispatch (`UvReactor.cpp:1164-1168`,
`:1283-1287`). HTTP/2 sets no equivalent deadline, and `Http2Session` receives
only the global `maxBodyBytes` (`Http2Session.cpp:25-31`). A handler that never
responds on h2 can hold resources indefinitely; a route’s custom body cap is
ignored on h2.

**Fix:** add per-request deadlines to `Http2Session`, enforce per-route body
caps when dispatching, and test both.

### No HTTP/2 graceful drain

`beginDrain()` only stops new accepts (`UvReactor.cpp:1778`). Existing h2
connections do not receive GOAWAY and can open new streams until the process
force-closes.

**Fix:** send GOAWAY on drain, stop admitting new streams, and allow existing
streams to finish within the drain deadline.

### Slow-body handling is inconsistent

`readCb` does not refresh `lastActive` (`UvReactor.cpp:843-875`), while the idle
sweep uses `keepAliveTimeout` (default 5 s) (`:1745-1749`). A non-streamed
upload that takes longer than 5 s to arrive can be closed as idle. StreamBody
and h2 bodies follow different paths, and h2 has no body deadline at all.

**Fix:** add a configurable request-body deadline refreshed on read progress;
apply it consistently to h1 buffered, h1 streamed, and h2 bodies.

### No global resource budget

- `maxConnections` and `maxConnectionsPerIp` default to `0` (unlimited)
  (`context.dart:67-68`).
- There is no global in-flight request cap.
- There is no total buffered-body budget.
- h2 buffers up to 10 MB per stream (`UvReactor.cpp:1549-1566`), across up to
  128 streams per connection and unlimited connections.
- HTTP streaming write queues are not bounded like the WebSocket queue.

**Fix:** add configurable global/per-IP connection, in-flight, buffered-byte,
and h2-stream budgets; return `503` or close when a budget is exhausted.

### Streaming and WebSocket sessions have no idle lifetime

After the first response byte, `hasDeadline` is cleared. WebSocket connections
stay `busy` and have no server ping/heartbeat or close timeout. A dead peer can
occupy a connection until the OS notices.

**Fix:** add WebSocket ping/pong liveness, a stream idle timeout, and a maximum
session age. Document the semantics.

### Helper isolates are unsupervised

`Isolate.spawn` sends later errors to the same reply port (`server.dart:518-529`).
`reload`, `collectMetrics`, and `close` await `moveNext()` with no timeout
(`:578-590`). A crashed or wedged helper can hang metrics, reload, or shutdown,
while the engine continues dispatching requests to a dead emitter.

**Fix:** supervise helper isolates, add operation timeouts, reflect helper
health in readiness, and define restart/eviction behavior.

### Configuration validation is assert-only and env parsing is lossy

`ServerConfig` constraints are `assert`s (`context.dart:76-90`), which are
disabled in AOT. A negative `maxBodyBytes` silently disables the limit.
`ServerConfig.fromEnv` ignores malformed values and omits `headerTimeout`,
`writeTimeout`, `maxRequestsPerConnection`, `wsMaxBufferBytes`, and all TLS
settings (`:245-281`).

**Fix:** add a runtime `validate()` called by `bind`, make env parsing fail fast,
and add the missing environment variables.

### Static serving hardening

Dotfiles are served, symlink swaps are possible, and file-open/sendfile errors
are not mapped to a clean HTTP response.

**Fix:** dotfile policy, no-follow option, validation before serving, and
explicit `404`/`500` mapping for filesystem failures.

### Multipart and JSON resource limits

`parseMultipart` performs a naive boundary scan with an attacker-controlled
boundary and has no part, header, field, or file-count limits
(`multipart.dart:42-90, 132-139`). JSON decoding and schema validation have no
explicit depth or error-count cap (`schema.dart:145-180`); deeply nested input
can exhaust the isolate stack.

**Fix:** limit boundary length, parts, part headers, field sizes, total parsed
error count, and JSON nesting depth. Use a linear-time boundary search or a
streaming parser for large uploads.

### Observability exposure and gaps

`bin/server.dart` mounts `/metrics`, `/dashboard*`, `/openapi.json`, and `/docs`
on `0.0.0.0` without authentication (`bin/server.dart:31`, `:184-214`). The
example credentials default to `dev`.

The dashboard creates one sampler per viewer and inserts route patterns into
`innerHTML` (`observability.dart:86-120`, `:460`); route patterns are normally
server-controlled, but this is unsafe if they ever become configuration input.
Metrics lack connection, status-code, event-loop-lag, and h2 gauges, and the
latency summary has no `_sum` series (`observability.dart:244-347`).

**Fix:** put operational endpoints behind auth or a loopback/admin listener, add
a viewer cap, use `textContent` for route patterns, and add the missing
metrics.

### No centralized error logging

The default 500 path logs nothing. `accessLog` logs status 500 but not the
error. Add a pluggable structured logger with level, request ID, route, status,
duration, and redacted error details.

### HTTP/1.1 conformance gaps

- No `Date` header on responses.
- `Content-Length: 0` is emitted for `204`/`304`; RFC 9110 forbids CL on 204
  and restricts it on 304.
- `reasonPhrase` returns `Unknown` for common statuses including 206, 304,
  401, 403, 409, 422, 429, 502, and 504 (`src/engine/Common.h:93-106`). Static
  file 206/304 responses therefore use nonstandard reason phrases.
- A method mismatch is answered as `404`; `405` plus `Allow` is not generated.
- `Connection: close` is detected with substring and only two casings, so
  `CLOSE` is missed and `enclose` is treated as close.

**Fix:** add the Date header, correct no-body framing, a complete reason table,
method-aware 405/Allow, and token-based Connection parsing.

### Proxy and TLS production configuration

There is no trusted-proxy or PROXY-protocol support, no TLS environment
configuration, and no mTLS/cipher controls. Clients behind an L4 proxy are all
rate-limited as the proxy IP unless the application supplies a key extractor.

**Fix:** add trusted-proxy configuration, optional PROXY protocol, TLS env vars,
and documented mTLS/cipher policy.

## P2 — hardening, supply chain, documentation

### Packaging and supply chain

- Docker base images are not digest-pinned.
- `.dockerignore` excludes `docs/` but the documentation directory is `doc/`
  (`.dockerignore:20`).
- Release prebuilts have SHA-256 sidecars but no signature, SBOM, or provenance
  attestation.
- The release workflow does not run the test suite before publishing a tag.
- `hook/build.dart` verifies a checksum fetched from the same release channel;
  this does not protect against a compromised release account.

### CI and static analysis

- No Docker build/run gate.
- No fuzz job in CI, despite `test/fuzz` and `tool/fuzz.sh`.
- No clang-tidy, cppcheck, or scan-build gate.
- ASan runs with `detect_leaks=0`, so native leaks are not caught.
- No dependency or image vulnerability scan.

### Build hardening

Release flags use `-ffast-math`, which is unnecessary for HTTP parsing and can
change numeric behavior. There is no warning-as-error gate and no hardening
flags such as stack protector, `_FORTIFY_SOURCE`, RELRO/NOW, or hidden
visibility.

### Documentation drift

- `doc/deployment.md:27` tells users to pass `-DNITRO_SERVER_TLS=ON`, which is
  not a CMake option.
- The Docker image builds with HTTP/2 and TLS off while the README advertises
  them as core features.
- Engine-served static routes and WebSocket routes bypass route middleware and
  route timeouts; this is a security footgun that should be stated loudly.
- h2 streaming is buffered and capped at 10 MB; this should be part of the
  streaming/SSE documentation.
- Proxy trust, body deadlines, and connection-budget behavior are undocumented.

### Documentation and dashboard hygiene

- Swagger UI loads from a floating `swagger-ui-dist@5` unpkg URL without SRI
  (`lib/src/api/openapi/serving.dart:316-328`). Pin an exact version and add SRI,
  or self-host the assets and add CSP.
- The dashboard inserts route patterns via `innerHTML`; use `textContent`.
- Operational endpoints should return `Cache-Control: no-store`.

### Conformance and test expansion

- Add regression tests for every P0 before fixing it: encoded traversal,
  symlink escape, CRLF/LF header injection, TE casing/substring/duplicates,
  chunk-size overflow, WS inflate cap, request-ID reflection, and invalid
  config in AOT.
- Add h2 tests for deadlines, per-route body caps, GOAWAY on drain, and slow
  bodies.
- Add Autobahn and h2spec as CI gates; the repository documents 136/145 for
  h2spec today.
- Add a nightly soak test for memory growth under keep-alive, WebSocket, h2,
  and streaming traffic.

### Performance validation

Any performance change must follow `benchmark/BENCHMARKING.md`: blackbox
cross-framework harness, disjoint pinned cores, interleaved repetitions, median
results, AOT, and keep-alive as the headline. Do not infer performance from the
security fixes above.

## Performance after hardening (2026-10-22, final engine)

One blackbox run on the final engine (after both re-audits; the full report
is tracked at `benchmark/blackbox/REPORT.md`), exactly as
`benchmark/BENCHMARKING.md` prescribes: 6 pinned cores (3 server / 3 load
generator), 5 interleaved reps, 8 s, 64 keep-alive connections,
byte-validated responses, medians. The pre-audit tree (`HEAD`, eccef3f) was
built into the same image and measured in the same interleaved loop
(`run.sh --base HEAD`), so the hardening's cost is a within-run delta, the
only comparison the methodology accepts.

Cross-framework (req/s, `nitro` = `_dylib` build):

| route | nitro | go | node | dart:io | shelf |
| --- | --: | --: | --: | --: | --: |
| `/hello` | 172k | **225k** | 149k | 79k | 51k |
| `/json` | 166k | **220k** | 150k | 71k | 61k |
| `/mw` | 169k | **223k** | 150k | 83k | 61k |
| `/echo` (4 KB POST) | 99k | 80k | **110k** | 64k | 46k |
| `/work` (200 records) | 46k | 17k | **54k** | 8.6k | 8.4k |
| `/static` (engine) | **455k** | 223k | 148k | 75k | 61k |

Hardening cost, pre-audit tree vs final tree, same run (req/s medians):

| route | pre-audit | final | delta |
| --- | --: | --: | --: |
| `/hello` | 177k | 172k | -3.1% |
| `/json` | 172k | 166k | -3.2% |
| `/static` | 460k | 455k | -1.0% |
| `/q?a=1&b=two` | 168k | 158k | -5.7% |
| `/users/42` | 167k | 164k | -1.2% |
| `/files/x` | 171k | 168k | -1.8% |
| `/mw` | 176k | 169k | -3.7% |
| `/work` | 45k | 46k | +1.5% |

Reading: the hardening (a `Date` on every answer, per-answer header and
cookie validation, request-line validation, stream bookkeeping, no
`-ffast-math`, stack protector) costs 1–4% on the trivial routes, with one
route at -5.7% (`/q?a=1&b=two`), and nothing on `/work`, where the
handler dominates. Per-rep spread in this run was within a few percent, so
the deltas are real but small; standings against the other frameworks are
unchanged on every route. `@Native` and `_dylib` agree within 4%. Peak RSS:
nitro 151 MB (3 isolates + engine; the pre-audit tree
153 MB), Go 12 MB, Node 391 MB, dart:io
53 MB, shelf 51 MB.

## What is already production-grade

- Multi-loop libuv engine with native response paths.
- Bounded request bodies and explicit HTTP/1.1 CL/TE/Host framing checks.
- Optional TLS, ALPN h2, h2c, brotli, and WebSocket compression.
- Native `sendfile`, ETag, conditional requests, and byte ranges.
- Graceful drain on signals and a readiness endpoint.
- Metrics, health/readiness, dashboard, access logging, and server events.
- 100% Dart and 90% C++ line-coverage gates.
- ASan/TSan jobs, parser fuzz targets, and a documented benchmark methodology.
- Reasonable package structure and extensive documentation.

## Remediation plan

### Phase 1 — P0 security and deployment

1. Add shared response-header validation and strict request-head/TE/chunk
   parsing.
2. Fix static-path canonicalization and symlink containment.
3. Sanitize request IDs, make default errors generic, and cap WS inflate.
4. Add trusted-proxy rate limiting and a bounded store.
5. Fix the Docker build/runtime and add a container smoke test.
6. Add failing regression tests first, then fixes.

**Exit criteria:** all P0 regressions pass; ASan/TSan and a fuzz smoke run are
clean; `docker build` + `/readyz` passes; malformed requests return a controlled
`400`/`404`/`413` without reflection or connection desync.

### Phase 2 — P1 reliability and correctness

1. h2 deadlines, per-route body caps, GOAWAY drain, and aggregate budgets.
2. Slow-body timer and consistent body timeouts.
3. Helper-isolate supervision and operation timeouts.
4. WebSocket idle/heartbeat/origin policy (`originPolicy([...])` middleware: 403 / WebSocket 4403 unless the `Origin` is listed; `ws_middleware_test`, `middleware_test`) and stream idle limits.
5. Config fail-fast, error logging, static/multipart/JSON hardening.
6. HTTP/1.1 conformance fixes.

### Phase 3 — P2 conformance and operations

1. Operational endpoint auth and metrics expansion.
2. Docker/release pinning, SBOM, signing, and attestation.
3. Fuzz/static-analysis/dependency-scan CI jobs.
4. Documentation corrections and Swagger SRI/CSP.
5. Autobahn/h2spec/nightly soak gates.

## Verification

- Unit/regression tests for each finding, written to fail before the fix.
- C++ tests under ASan and TSan; a leak-enabled run for engine tests.
- Fuzz smoke on PR and longer nightly fuzz runs (`soak.yml` `fuzz` job, 600 s per target).
- `docker build` and a live `/readyz` check in CI.
- Security vectors exercised over real sockets, including encoded paths,
  control characters, duplicate/odd TE, oversized chunks, and compressed WS
  payloads.
- Performance changes measured only with the interleaved blackbox methodology.

## Open decisions

Decided by the maintainer on 2026-10-22 (after the remediation was in place):

1. **Deployment model:** both are supported so neither is privileged — direct
   TLS termination (TLS policy, mutual TLS, cert hot-reload) and
   proxy-fronted operation (`proxyProtocol` for L4 balancers,
   `rateLimit(trustedProxies:)` for HTTP proxies). Defaults assume a proxy is
   *not* trusted until named.
   Confirmed: keep both, proxies untrusted until named.
2. **Breaking changes:** secure-by-default was taken wholesale — untrusted
   request ids are not echoed, wildcard CORS with credentials is refused,
   environment parsing fails fast, the default 500 is generic, a method
   mismatch is 405. The one recommended default *not* changed is a connection
   cap: `maxConnections` stays unlimited (an arbitrary number would break
   someone's load profile silently) with `maxInFlightRequests` and
   `maxConnectionAge` added as explicit, documented budgets. Confirmed: keep
   all of them as shipped.
3. **Scope:** the full remediation (P0 + P1 + P2) was implemented in one pass
   with a regression test written first for every finding, and the gates
   (coverage, sanitizers, fuzz, conformance, container, benchmark) ran on the
   finished tree. Decided: a fresh audit pass over the hardened tree follows;
   its residual findings are recorded in "Re-audit" below.

## Re-audit (2026-10-22)

An independent reading of the hardened tree (a reviewer who had not seen the
fixes) raised 21 residual items: 1 P0, 8 P1, 12 P2. All are fixed; each row
names the test that fails without the fix.

| # | Sev | Finding | Fix | Test |
|---|-----|---------|-----|------|
| 1 | P0 | Cookies bypassed the response-header gate and the streamed (SSE/chunked) head was written raw: a cookie value could split a response | `SetCookie.validationError`; cookies validated like headers in `_deliver` (500 + `handlerError`); streamed heads go through `uvBuildStreamHead` (same filter, `Date`) | `test_client_test` "a Set-Cookie that would split the response is refused"; `uv_reactor_test` StreamHeadIsFilteredAndDated |
| 2 | P1 | 204/304 answers carried a body: leaked into the next keep-alive response, broke h2 framing | bodyless statuses drop the body (h1 and h2) | `uv_reactor_test` BodylessStatusesNeverCarryABody; `security_audit_test` "every answer carries Date; 204 has no Content-Length" |
| 3 | P1 | A Latin-1 byte in a header stranded the request until its deadline (bridge decoder) | UTF-8 header check in `HttpParse` and `Http2Session` → 400 | `production_hardening_test` "a Latin-1 header byte is a 400, never a stranded request" |
| 4 | P1 | A busy connection's read buffer grew without bound | `overBusyBuffer`: 64 KiB + `maxBodyBytes`, then 400 + close | `uv_reactor_test` BusyConnectionBufferIsCapped |
| 5 | P1 | `headerTimeout` was a per-read gap, not a slow-loris deadline | anchored on the first head byte (`headStartedAt`) and on the TLS handshake | `uv_reactor_test` HeaderTimeoutIsAnAbsoluteDeadline; `production_hardening_test` "headerTimeout is absolute" |
| 6 | P1 | An engine 408 left the request pinned in `inFlight` | the timeout releases the pending entry; late answers for retired ids are dropped | `lifecycle_test` (408 releases the pending request) |
| 7 | P1 | `ResponseContext.file` read the whole file on the calling thread while the docs claimed sendfile; directories were served | loop-thread chunked send (`continueFileSend`, 256 KiB per drained write), `S_IFREG` check → 404, docs corrected | `uv_reactor_test` FileAnswersStreamTheExactRangeAndKeepFraming, RespondFileSendsBytesRangesAndHeadOnly; `static_files_test` |
| 8 | P1 | `withHeader` / `withCookie` dropped JsonWriter bodies | both go through `copyWith(cookies:)` | `production_hardening_test` (JsonWriter + `withCookie` over a real socket) |
| 9 | P1 | Multipart refused UTF-8 filenames (what browsers send) | part heads decoded as UTF-8 | `multipart_test` "a UTF-8 filename (what browsers send) parses" |
| 10 | P2 | Request line unvalidated: control bytes / non-ASCII accepted, unknown HTTP versions treated as 1.1, absolute-form targets refused, `Content-Length` not digits-only | visible-ASCII request line, `HTTP/1.0`\|`1.1` only (505 otherwise), origin/asterisk/absolute-form, digits-only lengths | `uv_reactor_test` RequestLineIsValidated, LastHeaderContentLengthIsParsed; Docker smoke `HTTP/9.9` → 505 |
| 11 | P2 | A zero-header HTTP/1.0 request was a 400 | parsed | `uv_reactor_test` (request-line cases) |
| 12 | P2 | Query strings with a bad percent-escape failed the whole request | lenient decoding (`_decodeLenient`) | `context_test` |
| 13 | P2 | IPv4 peers on a dual-stack listener appeared as `::ffff:a.b.c.d` (caps and CIDRs missed) | unmapped in the engine and in `rateLimit` | `uv_reactor_test` DualStackPeersAreReportedAsIPv4; `middleware_test` "an IPv4-mapped IPv6 peer matches v4 CIDRs and keys" |
| 14 | P2 | WebSocket handshake accepted a malformed key / any version | key length and `Sec-WebSocket-Version: 13` strict | `uv_reactor_test` WsHandshakeKeyAndVersionAreStrict, WsWrongVersionIs426 |
| 15 | P2 | Inbound WebSocket bytes a slow handler had not consumed were unbounded | `_WsSessionImpl.maxInbound` = `wsMaxBufferBytes` → 1009 | `ws_test` "WebSocket compression and backpressure" |
| 16 | P2 | A helper isolate's uncaught error arrived on the reply port and was read as an acknowledgement | separate error port with one lifetime listener; boot failures race the hello | `production_hardening_test` uncaught-error test |
| 17 | P2 | `maxConnectionsPerIp` counted the balancer under `proxyProtocol` | per-IP table re-keyed to the PROXY-named client | `uv_reactor_test` PerIpCapFollowsTheProxyNamedClient |
| 18 | P2 | Example credentials hard-coded, compared with `==` | from the environment, `secureEquals` (superseded by the second re-audit, row 6: no defaults at all) | CI `docker` job |
| 19 | P2 | Actions pinned by tag, h2 job without leak detection, Trivy CRITICAL only | every action SHA-pinned, `detect_leaks=1` in sanitize and http2 jobs, Trivy HIGH+CRITICAL | `ci.yml` |
| 20 | P2 | Release published prebuilts without the sanitizer/fuzz gates | release `test` job runs ASan + fuzz before `prebuilt` | `release.yml` |
| 21 | P2 | The hook's download was unbounded (no timeout, no size cap) | `_fetch` 60 s / 64 MiB | `hook/build.dart` |

## Second re-audit (2026-10-22)

A third reading of the tree (after the 21-item re-audit) raised eight more
items. Every one is fixed below; each fix has a test that fails without it.

| # | Finding | Fix | Test |
|---|---------|-----|------|
| 1 | The default (no HTTP/2) build failed under `-Werror`: `draining` and the ALPN `arg` were unused without `NITRO_SERVER_HTTP2`, and CI's first job builds exactly that way | both marked `[[maybe_unused]]`; the no-HTTP/2 `-Werror` configuration now builds and its 166 tests pass | local `build/noh2`, CI job 1 |
| 2 | A helper isolate that died (killed, OOM, `Isolate.exit`, or a fatal uncaught error — Dart's default) stayed "alive" until the next reply timed out: readiness green for a dead helper, up to `helperTimeout` | `Isolate.spawn(onExit:)` port per helper: the exit marks it dead, detaches it from the engine and emits a `notice` the moment it happens; an orderly `close` is not reported | `production_hardening_test`: "a helper that dies is noticed at once" (self-kill) and the uncaught-error test, which now asserts the death is reported |
| 3 | `headerTimeout` reported as extendable by a header-line drip | already absolute in this tree (anchored on the first byte, re-audit item); verified end to end over a real socket: 800 ms deadline, a header line every 300 ms, closed in under 2 s | `production_hardening_test`: "headerTimeout is absolute" |
| 4 | No idle limit on a streaming response: a silent SSE/chunked stream lived until `maxConnectionAge` (default off) | `streamIdleTimeout` (default 5 min, env `STREAM_IDLE_TIMEOUT_MS`): a stream with no write for the window and nothing queued is closed, its id retired (late chunks are no-ops), `clientError` "stream idle timeout" | `uv_reactor_test` StreamIdleTimeout×2, `production_hardening_test` SSE test |
| 5 | No aggregate memory budget: HTTP streaming writes uncapped (only WebSocket had `wsMaxBufferBytes`); an h2 session could buffer 128 streams × `maxBodyBytes`; the `maxConnections × maxBodyBytes` comment was wrong | `streamMaxBufferBytes` (4 MiB): a streaming response whose unsent queue passes it drops the connection; `maxBufferedBodyBytes` (64 MiB, env `MAX_BUFFERED_BODY_BYTES`): an h2 stream reserves its declared `Content-Length` (else its cap) on HEADERS — over the remainder 503 + `Retry-After: 1`, never fits 413, bodyless requests reserve nothing, the reservation is released on stream close and the body buffer freed on dispatch; the memory bound is now documented per connection (README, `ServerConfig` docs) | `uv_reactor_test` StreamBufferCap, `http2_session_test` BodyBudget×2, `server_config_limits_test` |
| 6 | The example image accepted `admin:dev` (and bearer/API key `dev`) whenever the env was unset, even with the other secrets set | no built-in credentials: an unset `API_TOKEN` / `API_KEY` / `BASIC_USER`+`BASIC_PASSWORD` matches nothing (401 to everyone); the startup warning says so | CI `docker` job: 401 for `admin:dev` while `BASIC_*` is unset, 200 for the configured pair and 401 for `admin:dev` once set (also run locally) |
| 7 | PROXY v2 headers over 536 bytes were dropped although v2 allows 16-bit lengths (TLVs such as `PP2_TYPE_SSL`) | the guard is 16 + 65535 | `uv_reactor_test` ProxyProtocolV2AcceptsTlvs (2 KiB TLV) |
| 8 | `rateLimit`, `InMemoryRateLimitStore` and `validateJsonBody` validated with `assert`, which AOT drops | `ArgumentError` | `middleware_test` |

Also from this pass: the blackbox harness gained `run.sh --base <git-ref>`,
which builds the tree at `<ref>` into the same image and measures it
interleaved with the working tree, so two builds can be compared the only way
the methodology allows (see "Performance after hardening").

## Nightly soak finding (2026-10-24)

The first nightly `soak.yml` run on the released tree (run 40077070243)
failed its gate: 5.47 M requests, 0 errors, 11 steady connections, and RSS
growing linearly from 291.9 MB at the quarter mark to 373.0 MB at the end
(27.8%, limit 25%). The slope was ~16 bytes per request. Two causes, both
fixed with tests:

| # | Finding | Fix | Test |
|---|---------|-----|------|
| 1 | Every request that carried a body left its payload log in the engine's `PendingTable` forever: payload bytes are freed on Dart's ack, but the per-request log record is reaped only by `erase()`, which the libuv reactor never called (~100 B per POST; the soak's `/echo` loop alone accounts for the growth) | the reactor orphans the log whenever it retires a request (`lookupReq(erase)` and the connection-close sweep), so it is reaped as soon as acks catch up, or at once if they already have | `pending_table_test` PayloadLogIsReapedOnceAnsweredAndAcked (both orders); `uv_reactor_test` AnsweredAndAckedBodiesLeaveNoPayloadLogBehind |
| 2 | `_wsOpened` ("every WebSocket connection id ever opened") grew by one entry per WebSocket connection for the life of the isolate | bounded to the most recent 1024 ids (ids only grow; an evicted id's late frame lands in the bounded `_wsEarly`) | `ws_test` "the opened-id set is bounded" |

The 120 s local soak used earlier (7.3% growth) was too short to separate
this slope from warm-up; the 600 s nightly is the gate that matters. Bisecting
it also exposed a tooling hazard: once the lock carried a `1.0.0` entry, the
build hook preferred the *released* prebuilt over the repository's own
`build/lib`, so local `dart test` runs and CI's test jobs were exercising the
published engine rather than the tree's. The hook now stages `build/lib`
first (a pub consumer has none and still downloads), and the fixed engine was
re-soaked locally before re-tagging: echo-only traffic now holds ~9 000 small
native blocks on the macOS heap where the released engine had accumulated
2.1 M of them after 85 s (`heap` profile), and the full mix ran 150 s,
3.5 M requests, 0 errors, RSS flat at 284.5 MB from the first minute on
(−1.8% quarter→end). Inside a Linux container (glibc, as CI): echo-only
240 s, 2.07 M requests, RSS 230.4 → 227.7 MB (−1.1%); the full mix 300 s,
5.47 M requests, 0 errors, 288.9 → 332.2 MB (+15.0%) with the curve flat from
t+240 s on (311.5 → 332.1 → 332.2 MB): heap sizing that plateaus, not the
nightly's linear slope. The 600 s nightly remains the gate.

## Remaining maintainer steps

1. **Done (2026-10-24).** `v1.0.0` was tagged at `da1002b`; release run
   40073440905 passed every job: suites, five prebuilts (attested, keylessly
   signed, SBOM), and `verify`, which locked the assets and pulled each back
   through the hook's verification path with real cosign in strict mode — the
   first run of that path against this package's own signed assets. The same
   five assets were then verified locally with cosign 3.1.4 in strict mode
   (`NITRO_SERVER_VERIFY_SIGSTORE=1 dart tool/verify_prebuilt_lock.dart
   1.0.0`: 5/5 accepted) and `gh attestation verify` confirmed the build
   provenance of the Linux x64 asset. The consumer path itself was exercised
   on this machine: `NITRO_SERVER_VERIFY_SIGSTORE=1 dart build cli` ran the
   build hook, which downloaded the macOS arm64 asset, checked it against
   the lock and with cosign, and staged a byte-identical copy of the
   released file (hook output SHA-256 == release asset SHA-256), with an
   empty hook stderr. The first two tag runs failed on
   repository plumbing, each fixed and re-tagged: fuzz sources were
   gitignored, a workflow used the `runner` context in a job `env`, a test read
   pipelined answers assuming two reads, the h2spec gate's `grep` saw escape
   bytes, the Trivy pin referenced a vanished tag, and the Dockerfile copied
   an uncommitted lock file.
2. **Done.** The run's `prebuilt_checksums` artifact was committed as
   `hook/prebuilt_checksums.json` (five `1.0.0` digests, rc.4 entries kept),
   and a consumer project depending on the package from git (pub-cache
   layout, no local engine) built with `dart build cli` in strict mode: the
   hook downloaded the signed macOS asset byte-for-byte, and both the AOT
   bundle and `dart run` served.
3. **Portability rebuild, re-tag pending.** Inspecting the released Linux
   assets showed they were linked on Ubuntu 24.04 and need glibc 2.38 and
   GLIBCXX 3.4.29: Debian 12 and Ubuntu 22.04 hosts could download and verify
   them and then fail at load. The release now builds Linux prebuilts on
   Ubuntu 22.04 with libstdc++ linked in and gates every Linux asset (max
   glibc symbol ≤ 2.35, no GLIBCXX/CXXABI need); the hook skips the prebuilt
   on a Linux host below the floor and builds from source, saying so. After
   committing, move the tag (`git tag -f v1.0.0 && git push -f origin
   v1.0.0`), take the new run's lock artifact, commit it, then
   `dart pub publish`.

## Out of scope

- HTTP/3 and QUIC — decided by the maintainer on 2026-10-22 to stay out of
  scope (the alternatives offered were a design document or an
  implementation behind a build option): not implemented, and never claimed. `HttpProtocol.http3` is accepted (forward-compatible config)
  and behaves as `http2`; the engine negotiates only `h2`/`http/1.1`;
  `doc/http3.md` and the README say to terminate HTTP/3 at a proxy
  (`context_test` covers the env/enum mapping).
- Application authorization and business logic.
- Database, storage, and external-service security.
- Host/container OS hardening beyond the Docker image itself.
