# Deploying nitro_server

nitro_server is a **persistent native process**: an AOT-compiled (or JIT) Dart
binary plus a C++ engine library (`libnitro_server.so`/`.dylib`/`.dll`) it loads
over FFI. So it deploys to anything that runs a long-lived container or VM —
**not** to serverless/function platforms, which spin up ephemeral workers with no
place for the native library or the event-loop threads.

The universal artifact is the **Docker image**; everything else wraps it.

## Docker (the base artifact)

```sh
docker build -t nitro-server .
docker run --rm -p 8080:8080 nitro-server
# → http://localhost:8080  (/, /hello/:name, /metrics, /healthz, /readyz, /docs)
```

The multi-stage [`Dockerfile`](../Dockerfile) builds the native engine with
cmake (**TLS, brotli and HTTP/2 on**, deps as Debian shared libraries, no
`-march=native` so the image runs on any CPU of its arch), then AOT-compiles
[`bin/server.dart`](../bin/server.dart) with `dart build cli` — the only build
that runs the package hook, so the engine ships inside the bundle as a code
asset — and copies the bundle into a slim, non-root, digest-pinned
`debian:stable-slim` runtime (no libuv/OpenSSL/brotli/nghttp2 needed there). It
exposes `8080` and adds a `HEALTHCHECK` hitting `/readyz`.

- Config via env: `HOST` (default `0.0.0.0`), `PORT` (default `8080`), plus
  every `ServerConfig.fromEnv` variable (body/idle/age timeouts, in-flight
  budget, TLS as `TLS_CERT_FILE`+`TLS_KEY_FILE` or `TLS_CERT_PEM`+`TLS_KEY_PEM`,
  …) — see the README's "From the environment".
- **Operational endpoints are guarded.** `/metrics`, `/dashboard*`,
  `/openapi.json` and `/docs` require HTTP basic auth when `ADMIN_USER` and
  `ADMIN_PASSWORD` are set, and are **loopback-only otherwise** (403 from any
  other address). `/healthz` and `/readyz` stay open for probes. The example's
  protected API routes have no built-in credentials: they answer 401 to
  everyone until `API_TOKEN`, `API_KEY` and `BASIC_USER`+`BASIC_PASSWORD` are
  set (the server prints a warning while any is unset).
- Serving TLS directly: set the `TLS_*` variables (the engine in the image has
  OpenSSL) — `TLS_MIN_VERSION=1.3`, `TLS_CIPHERS`/`TLS_CIPHER_SUITES`, and
  `TLS_CLIENT_CA_FILE` for mutual TLS; otherwise terminate TLS at the proxy.
  Behind an L4 balancer set `PROXY_PROTOCOL=1` so the real client address
  reaches rate limits and logs (the listener must then be reachable only
  through the balancer); behind an HTTP proxy use
  `rateLimit(trustedProxies: [...])`.
- Prebuilt engines on GitHub Releases carry a SHA-256 sidecar, Sigstore build
  provenance (`gh attestation verify <asset> --repo <owner>/<repo>`), a keyless
  signature bundle (`cosign verify-blob --bundle <asset>.sigstore.json
  --certificate-identity-regexp 'github.com/<owner>/<repo>/'
  --certificate-oidc-issuer https://token.actions.githubusercontent.com <asset>`)
  and an SPDX SBOM.
- CI builds this image, starts it, checks `/readyz` and scans the runtime
  layer with Trivy (unfixed CRITICAL fails) on every push (`docker` job).

[`docker-compose.yml`](../docker-compose.yml) runs it locally with a
`stop_grace_period` longer than the drain window so graceful shutdown completes.

## Graceful shutdown (containers/orchestrators)

`bin/server.dart` calls `shutdownOnSignals(server, drain: ...)`, so SIGTERM/SIGINT
(what Docker, k8s and Fly send) **drain in-flight requests** before exit. Make the
platform's grace period longer than the drain:

- Docker Compose: `stop_grace_period: 20s` (drain is 15s).
- Kubernetes: `terminationGracePeriodSeconds: 20`.

During the drain new connections get `503 Connection: close`, HTTP/2 sessions
receive GOAWAY and close once their streams finish, and `/readyz` answers 503
so load balancers stop routing before the listener closes.

## Health & metrics

`bin/server.dart` calls `serveObservability(server)`, exposing:

| endpoint | use |
| --- | --- |
| `/healthz` | liveness — `200 ok` while the process runs |
| `/readyz` | readiness — `200 ready`, `503 draining` once shutting down |
| `/metrics` | Prometheus text: requests, errors, in-flight, `responses_total{class}`, connections, event-loop lag, helper-isolate health, per-route counts + latency summary (`quantile`, `_sum`, `_count`) |

Point your orchestrator's probes at these and Prometheus at `/metrics`
(authenticated — see above). Readiness also drops to 503 when a helper isolate
is declared dead (`NitroServer.helperTimeout`), so a degraded replica is
rotated out rather than served at reduced capacity for ever.

## Fly.io

```sh
fly launch --dockerfile Dockerfile   # or use the committed fly.toml
fly deploy
```

[`fly.toml`](../fly.toml) wires the `/readyz` health check and HTTPS. Fly sends
SIGINT→SIGTERM on deploy/stop, which the drain handles.

## Render / Railway / Google Cloud Run

All run a container from the `Dockerfile` directly:

- **Render:** a Web Service, Docker runtime, health check path `/healthz`.
- **Railway:** deploy from the repo; it detects the `Dockerfile`.
- **Cloud Run:** `gcloud run deploy --source .` (port `8080`, min instances ≥ 1 if
  you want no cold starts; Cloud Run sends SIGTERM for graceful shutdown).

## Kubernetes

Run the image with HTTP probes and a graceful drain:

```yaml
spec:
  terminationGracePeriodSeconds: 20   # > the 15s drain
  containers:
    - name: nitro
      image: your-registry/nitro-server:latest
      ports: [{ containerPort: 8080 }]
      livenessProbe:  { httpGet: { path: /healthz, port: 8080 }, periodSeconds: 10 }
      readinessProbe: { httpGet: { path: /readyz,  port: 8080 }, periodSeconds: 5 }
      resources:
        requests: { cpu: "500m", memory: "64Mi" }
        limits:   { cpu: "2",    memory: "256Mi" }
```

A Prometheus `ServiceMonitor` scraping `/metrics` completes the picture.

## Netlify (static frontend + proxied backend)

Netlify can't host the persistent native server, so the pattern is: **Netlify
serves your static frontend and proxies API/WebSocket calls to nitro running on a
container host** (Fly.io/Render/Cloud Run above). [`netlify.toml`](../netlify.toml)
rewrites `/api/*` → your backend and `/ws` → its WebSocket; set the backend URL
there. The same applies to any static/CDN host (Vercel, Cloudflare Pages) fronting
a nitro backend.

## Scaling notes

- `bin/server.dart` runs one handler isolate (optimal for light/IO-bound routes —
  the engine already uses every core). For **CPU-bound handlers**, raise
  `ServerConfig.isolates` (e.g. to `Platform.numberOfProcessors`); the engine's
  adaptive dispatch then fans out only when it helps. If you do, register the
  observability/OpenAPI routes inside `setup` so every isolate serves them. See
  [`../benchmark/BENCHMARKING.md`](../benchmark/BENCHMARKING.md).
- Scale horizontally by running more replicas behind the platform's load
  balancer; nitro is lean (~30 MB RSS under load) so replicas are cheap.
