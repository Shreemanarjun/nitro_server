## 1.0.0

First stable release — a production HTTP/1.1 + WebSocket server for Dart and
Flutter, backed by a native multithreaded C++ (libuv) engine over Nitro FFI.

**Engine** — one event loop per core over `SO_REUSEPORT`; adaptive dispatch
across isolates (light handlers stay on one, CPU-bound fan out); `sendfile`,
keep-alive, pipelining, `Expect: 100-continue`, chunked I/O; request-smuggling
defense; optional TLS/brotli (build-time, OpenSSL/libbrotli) with live cert
hot-reload (`server.reloadTls`); draining answers the backlog `503` not a drop.

**Routing & handlers** — trie routing (`:param`, `*`, custom verbs, `group`),
per-route `timeout`/`maxBodyBytes`/`middleware`/`streamBody`; `RequestContext`
(`params`, `query`/`queryParamAll`, `headers`, `cookies`, `body`/`bodyStream`,
`clientIp`, `jsonMap`/`jsonAs<T>`/`multipart`); `ResponseContext`
(text/json/bytes/stream/file/redirect/cookies, RFC 7807 `problem`, SSE via
`sse`, `withHeader`); `Server-Timing` header on every answer; live
`reload([setup])` and graceful `close({drain})`.

**Middleware & production** — `cors`, `compress` (gzip/brotli), colourful or
JSON `accessLog`, `requestId`, `rateLimit` (pluggable `RateLimitStore` for a
limit shared across isolates/hosts), `validateJsonBody` (via `ApiSchema`),
`bearerAuth`/`apiKeyAuth`/`basicAuth`; `serveObservability` (`/healthz`,
`/readyz`, Prometheus `/metrics`, live `/dashboard`); `staticFiles`;
`shutdownOnSignals`.

**OpenAPI + Swagger UI** — `serveOpenApi` / the `OpenApi` wrapper generate the
spec from your routes, with everything Swagger needs out of the box: typed
bodies (`OpenApiRequestBody`, JSON/form/multipart/binary), query/header/cookie
params (`OpenApiParam`, incl. repeatable arrays), auth that drives the Authorize
button (`bearerScheme`/`apiKeyScheme`/`basicScheme`/`oauth2Scheme`/
`openIdConnectScheme` + `requiresAuth`), response models (`responseExample`,
`successStatus`, `OpenApiResponse`), reusable `components.schemas` (`schemaRef`),
and `ApiSchema` as the single source for docs **and** request validation.

**Tooling** — in-memory `NitroTestClient`; `enableHotReload`; the `nitro` CLI
(`serve` JIT+hot-reload / `build` AOT or JIT snapshot, `--bundle-deps` for a
portable native bundle); `serverBanner` startup banner; `ServerConfig.fromEnv`;
a benchmark regression checker; Docker/Fly/Cloud-Run/Netlify deploy recipes
(`docs/deployment.md`).

**Quality** — 100% Dart line coverage, ≥90% C++ engine coverage, ThreadSanitizer
+ AddressSanitizer + libFuzzer in CI, and a reproducible cross-framework
benchmark (vs dart:io/shelf/Go/Node) published on every CI run.
