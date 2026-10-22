## 1.0.0

First stable release: HTTP/1.1 + WebSocket (+ optional HTTP/2, TLS, brotli)
server for Dart/Flutter on a native C++ (libuv) engine over Nitro FFI.

- Engine: one event loop per core (`SO_REUSEPORT`), adaptive isolate dispatch,
  keep-alive, pipelining, `Expect: 100-continue`, chunked I/O, chunked native
  file send, `getStatic` fast path; optional HTTP/2 (ALPN `h2` + h2c, h2spec
  137/146), TLS with cert hot-reload, mutual TLS and TLS policy, HAProxy
  PROXY v1/v2.
- Routing: trie router (`:param`, `*`, custom verbs, `group`), per-route
  `timeout` / `maxBodyBytes` / `middleware` / `streamBody`, WebSocket routes
  with middleware, `RequestContext` / `ResponseContext` (json, bytes, stream,
  file, SSE, cookies, RFC 7807), `Server-Timing`, live `reload`, graceful
  `close({drain})`.
- Middleware: `cors`, `compress` (gzip/brotli), `accessLog`, `requestId`,
  `rateLimit` (pluggable store, `trustedProxies`), `validateJsonBody`,
  `bearerAuth` / `apiKeyAuth` / `basicAuth`, `originPolicy`, `staticFiles`,
  `serveObservability` (`/healthz`, `/readyz`, Prometheus, dashboard),
  `shutdownOnSignals`.
- OpenAPI 3 + Swagger UI from the routes (`serveOpenApi`, `ApiSchema` for docs
  and validation).
- Tooling: `NitroTestClient`, hot reload, `nitro` CLI (`serve`, `build`),
  `ServerConfig.fromEnv`, benchmark harness, deploy recipes.
- Limits (all in `ServerConfig`, all from env): `maxBodyBytes`,
  `maxConnections`, `maxConnectionsPerIp`, `maxRequestsPerConnection`,
  `maxInFlightRequests`, `maxBufferedBodyBytes` (HTTP/2 body budget),
  `headerTimeout` (absolute), `bodyTimeout`, `writeTimeout`,
  `keepAliveTimeout`, `maxConnectionAge`, `wsIdleTimeout`, `wsMaxBufferBytes`,
  `streamIdleTimeout`, `streamMaxBufferBytes`.
- Security: static-file containment, header/cookie validation (CR/LF → 500 +
  `handlerError`), strict request parsing (control bytes, `Transfer-Encoding`
  token list, chunk sizes, UTF-8 headers, HTTP version → 505), generic 500
  body, bounded buffers everywhere, RFC 6455 frame validation
  (Autobahn-clean), helper-isolate supervision (wedged or dead helpers are
  killed, detached, reported; `/readyz` 503).
- Supply chain: SHA-pinned actions, `-Werror`, ASan/TSan/fuzz/clang-tidy/
  Trivy/h2spec/Autobahn in CI, nightly soak + long fuzz, release signed (Sigstore provenance,
  keyless cosign bundle, SPDX SBOM); the build hook verifies a prebuilt
  against `hook/prebuilt_checksums.json` (shipped in the package) and,
  with `NITRO_SERVER_VERIFY_SIGSTORE=1`, `cosign verify-blob`.
- Breaking vs. the release candidates: `ServerConfig` validates in `bind`
  (`validate()`), not `assert`; the default 500 body is generic; a method
  mismatch is 405; `ServerEventKind.handlerError` added; the example server
  has no built-in credentials.
- Quality gates: 100% Dart line coverage, ≥90% C++ coverage, blackbox
  benchmark (`benchmark/blackbox/run.sh`, `--base <ref>` for A/B).
