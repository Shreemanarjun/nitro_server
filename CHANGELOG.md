## 1.0.1

- `ServerDefaults`: every `ServerConfig` default in one exported class;
  `ServerConfig`, the runner and helper isolates all read from it.
- New `ServerConfig` switches, all defaulting to the 1.0.0 behaviour:
  `serverHeader` (`x-server` value; `null` sends none), `keepAliveHeader`
  (`Keep-Alive: timeout=N` line; the engine change needs the 1.0.1 prebuilts),
  `collectMetrics` (per-route metrics; off skips the per-request bookkeeping).
- `nitro deploy <docker|cloudflare|netlify|vercel>`: writes what the host
  needs (Dockerfile with the prebuilt engine, Cloudflare Containers Worker +
  `wrangler.jsonc`, `netlify.toml`, `vercel.json`); `--run` runs the deploy
  commands; `public`/`assets`/`web` are copied into the image (`--assets`).
  The generated Dockerfile builds on `dart:stable` via a `FLUTTER_ROOT` stub.
  Guides in `doc/deployment.md`.
- `netlify.toml`: WebSocket proxy rule removed (Netlify's proxy does not carry
  upgrades and ends proxied requests after 26 s).
- Benchmarks: ion_web joins the blackbox harness (`benchmark/ion_server`);
  reports validate header bytes as well as bodies, alternate framework order
  per rep, and record the image and rerun command.

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
  against `prebuilt_checksums.json` (shipped in the package) and,
  with `NITRO_SERVER_VERIFY_SIGSTORE=1`, `cosign verify-blob`. Linux prebuilts
  are built on Ubuntu 22.04 with libstdc++ linked in (glibc 2.35 floor, gated
  in the release workflow); macOS prebuilts need macOS 14+.
- Breaking vs. the release candidates: `ServerConfig` validates in `bind`
  (`validate()`), not `assert`; the default 500 body is generic; a method
  mismatch is 405; `ServerEventKind.handlerError` added; the example server
  has no built-in credentials.
- Build hook: a `build/lib` engine built in the package tree is used ahead of
  a prebuilt (tests in the repo and in CI run the tree's engine); a Linux host
  below the prebuilt's glibc floor builds from source instead.
- Fixed before publishing, found by the nightly soak: a per-request payload-log
  leak in the engine for requests with bodies, and an unbounded set of
  WebSocket connection ids.
- Quality gates: 100% Dart line coverage, ≥90% C++ coverage, blackbox
  benchmark (`benchmark/blackbox/run.sh`, `--base <ref>` for A/B).
