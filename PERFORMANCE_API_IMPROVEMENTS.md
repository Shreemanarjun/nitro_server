# Performance + Easy API — improvement plan ✅ DONE

Source: audit of `lib/src/internal/server_runner.dart`, `lib/src/api/*`,
`src/engine/ServerInstance.cpp`, `src/engine/Router.cpp`, `src/HybridNitroServer.cpp`.

Verified: 56/56 C++ engine tests, 187/187 Dart tests, `benchmark/compare.dart --quick`
(nitro leads `/hello` 178µs vs 253/263, `/json` 176µs vs 192/216, echo 217µs;
throughput 11628 vs 6604/7823 req/s @32). WebSocket data transfer
remains the only deferred future (frame codec + message API).

## 1. Native hot path

| # | Change | Why | Risk | Status |
|---|--------|-----|------|--------|
| N1 | Allocation-free header compare (`iequals`, no `lower()` alloc) in `findHeader`, `clientWantsKeepAlive`, response loop | `lower()` allocates a `string` per header per lookup (4 lookups × H headers per req) | low | ✅ done (`ServerInstance.cpp`) |
| N2 | Precompute `methodKey` + `allKey` once per `Router::match` instead of per visited node | `pickEntry` builds a `string` key on every node visit | low | ✅ done (`Router::match`: `mkey`/`akey` + `pick` lambda) |
| N3 | `Router::match` without per-branch `vector<RouteParam>` copies (parent-linked frames, winning chain walked once) | DFS copies params vector per frame | medium | ✅ done (`Router.cpp`: arena + parent indices) |
| N4 | `kBodyEmitBytes` 32k → 64k | halves `malloc` + `ackBody` FFI crossings on uploads | low | ✅ done |
| N5 | `writev` send path on POSIX (header + body, 1 syscall, no copy); keep 2-send fallback on Windows | removes `<=128k` copy into `head_out` and 2nd syscall for large bodies | medium | ✅ done (`ServerInstance.cpp`) |
| N6 | Default workers `max(8, 2×cores)` instead of `1×cores` | worker parks on Dart `respond`; 1×cores stalls under concurrent slow handlers | low | ✅ done (`ServerInstance::start`) |
| N7 | `string_view` zero-copy request-line parser, IPv6 dual-stack | removes ~5 `substr` allocs/req | higher | ✅ done — `parseHead` parses views (only target/query/headers/custom copied into owning strings); `parseMethod` gained a `string_view` overload; `start()` binds `AF_INET6` for v6-literal hosts with `IPV6_V6ONLY=0` (`::` serves v4-mapped too); invalid hosts fail honestly |
| N8 (follow-up) | `string_view` path split + transparent trie lookup in `Router::match` | removes per-segment `std::string` construction on every match | low | ✅ done — `split` returns views, `statik` uses `std::less<>`; microbench (13-route table, 200k matches): 353.5 → 279.8 ns/req (−21%), identical results |

## 2. Dart dispatch

| # | Change | Why | Status |
|---|--------|-----|--------|
| D1 | Two-level handler table `Map<methodToken, Map<pattern, handler>>`, no `'$token $pattern'` concat per request | 1–2 allocs saved on every hit path | ✅ done (`ServerRunner._routes`) |
| D2 | Lazy `queryParameters`/`params`: skip `Uri.splitQueryString` + params-map when empty; share const `{}` | GET hot path does zero map work | ✅ done (`_dispatch`) |
| D3 | Precompute combined middleware once per `use()`; per-request does 1 closure instead of N-fold | `reversed.fold` allocates N closures/req | ✅ done (`_composeAll`/`_recompose`, `piped` per route entry) |
| D4 | `respond` fast-path for empty headers (`const []`), reuse `_emptyBody` | small-answer fast path | ✅ done (`_answer`, `_emptyBody`) |

## 3. Easy API (all backward-compatible)

| # | Change | Status |
|---|--------|--------|
| E1 | `RequestHandler = FutureOr<ResponseContext> Function(...)`; dispatch via `Future.sync` so sync handlers skip an event-loop turn | ✅ done (`context.dart`, `ServerRunner._dispatch`) |
| E2 | `route/get/post/.../use/unroute` return `Future<NitroServer>` (`this`) for chaining; `await server.get(...)` still compiles | ✅ done (`server.dart`) |
| E3 | `ResponseContext.jsonBody(Object)` + `redirect(url)` helpers; keep `json(String)` (raw) + `jsonMap` untouched | ✅ done (`context.dart`) |
| E4 | `ServerConfig.copyWith()` + `NitroServer.bindWith({host, port, ...})` sugar | ✅ done (`context.dart`, `server.dart`) |
| E5 | Per-route `middleware:` param + `RouteGroup.use()` (route-local list composed after globals) | ✅ done (`server.dart`, `route_group.dart`, `server_runner.dart`) |
| E6 | Built-in `cors()` middleware | ✅ done (`middleware.dart`) |
| E7 | In-memory test client + WebSocket 426 + response streaming (WS data transfer stays future) | ✅ done — `package:nitro_server/testing.dart` (`NitroTestClient`); engine answers RFC 6455 handshakes with `426` + `Sec-WebSocket-Version: 13` before routing; `ResponseContext.stream` + `startStream`/`sendStreamChunk` bridge + engine chunked writes (`Transfer-Encoding: chunked`, timeout bounds first byte, keep-alive evaluated per stream). WebSocket data transfer remains ⏳ deferred (frame codec + message API) |

## Order of work

1. ✅ N1 + N2 + N4 + N6 (safe native) + C++ tests.
2. ✅ D1 + D3 + D4 (safe Dart) + `dart test`.
3. ✅ E1–E6 (API, backward-compatible) + `dart test`.
4. ✅ N3 + N5 (riskier native) behind the same test suites.
5. ✅ Re-ran `benchmark/compare.dart --quick` — no numbers quoted, nitro leads `/hello` + `/json` latency.
