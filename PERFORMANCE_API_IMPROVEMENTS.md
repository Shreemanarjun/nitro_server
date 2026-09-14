# Performance + Easy API — improvement plan

Source: audit of `lib/src/internal/server_runner.dart`, `lib/src/api/*`,
`src/engine/ServerInstance.cpp`, `src/engine/Router.cpp`, `src/HybridNitroServer.cpp`.

## 1. Native hot path

| # | Change | Why | Risk |
|---|--------|-----|------|
| N1 | Allocation-free header compare (`iequals`, no `lower()` alloc) in `findHeader`, `clientWantsKeepAlive`, response loop | `lower()` allocates a `string` per header per lookup (4 lookups × H headers per req) | low |
| N2 | Precompute `methodKey` + `allKey` once per `Router::match` instead of per visited node | `pickEntry` builds a `string` key on every node visit | low |
| N3 | `Router::match` without per-branch `vector<RouteParam>` copies (single param stack + backtrack) | DFS copies params vector per frame | medium |
| N4 | `kBodyEmitBytes` 32k → 64k | halves `malloc` + `ackBody` FFI crossings on uploads | low |
| N5 | `writev` send path on POSIX (header + body, 1 syscall, no copy); keep 2-send fallback on Windows | removes `<=128k` copy into `head_out` and 2nd syscall for large bodies | medium |
| N6 | Default workers `max(8, 2×cores)` instead of `1×cores` | worker parks on Dart `respond`; 1×cores stalls under concurrent slow handlers | low |
| N7 (future) | `string_view` zero-copy request-line parser, IPv6 dual-stack | removes ~5 `substr` allocs/req | higher — deferred |

## 2. Dart dispatch

| # | Change | Why |
|---|--------|-----|
| D1 | Two-level handler table `Map<methodToken, Map<pattern, handler>>`, no `'$token $pattern'` concat per request | 1–2 allocs saved on every hit path |
| D2 | Lazy `queryParameters`/`params`: skip `Uri.splitQueryString` + params-map when empty; share const `{}` | GET hot path does zero map work |
| D3 | Precompute combined middleware once per `use()`; per-request does 1 closure instead of N-fold | `reversed.fold` allocates N closures/req |
| D4 | `respond` fast-path for empty headers (`const []`), reuse `_emptyBody` | small-answer fast path |

## 3. Easy API (all backward-compatible)

| # | Change |
|---|--------|
| E1 | `RequestHandler = FutureOr<ResponseContext> Function(...)`; dispatch via `Future.sync` so sync handlers skip an event-loop turn |
| E2 | `route/get/post/.../use/unroute` return `Future<NitroServer>` (`this`) for chaining; `await server.get(...)` still compiles |
| E3 | `ResponseContext.jsonBody(Object)` + `redirect(url)` helpers; keep `json(String)` (raw) + `jsonMap` untouched |
| E4 | `ServerConfig.copyWith()` + `NitroServer.bindWith({host, port, ...})` sugar |
| E5 | Per-route `middleware:` param + `RouteGroup.use()` (route-local list composed after globals) |
| E6 | Built-in `cors()` middleware |
| E7 (future) | In-memory test client, request/response streaming, WebSocket 426 — tracked, not in this pass |

## Order of work

1. N1 + N2 + N4 + N6 (safe native) + C++ tests.
2. D1 + D3 + D4 (safe Dart) + `dart test`.
3. E1–E6 (API, backward-compatible) + `dart test`.
4. N3 + N5 (riskier native) behind the same test suites.
5. Re-run `benchmark/compare.dart --quick` before quoting numbers.
