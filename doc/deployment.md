# Deploying nitro_server

nitro_server is a **persistent native process**: an AOT-compiled (or JIT) Dart
binary plus a C++ engine library (`libnitro_server.so`/`.dylib`/`.dll`) it loads
over FFI. So it deploys to anything that runs a long-lived container or VM —
**not** to serverless/function platforms, which spin up ephemeral workers with no
place for the native library or the event-loop threads.

The universal artifact is the **Docker image**; everything else wraps it, and
`nitro deploy` writes what each host needs.

## One command per host: `nitro deploy`

```sh
dart run nitro_server:nitro deploy <docker|cloudflare|netlify|vercel> [options]
```

It writes the files the host needs next to your project and prints the
commands that finish the deployment; `--run` executes them. Existing files
are kept (`--force` overwrites), so you can hand-edit a generated config and
re-run safely. Options and defaults: `nitro --help`.

| target | writes | runs the server? |
| --- | --- | --- |
| `docker` | `Dockerfile`, `.dockerignore` | yes — the image for Fly.io, Render, Railway, Cloud Run, Kubernetes, any VM |
| `cloudflare` | the same + `worker.js`, `wrangler.jsonc`, `package.json` | yes — Cloudflare Containers behind a Worker |
| `netlify` | `netlify.toml` | no — static site, `/api/*` and `/ws` proxied to `--backend` |
| `vercel` | `vercel.json` | no — static site, `/api/*` rewritten to `--backend` |

## Docker (`nitro deploy docker`)

```sh
dart run nitro_server:nitro deploy docker --name my-api        # writes Dockerfile + .dockerignore
docker build --platform linux/amd64 -t my-api .                  # or: nitro deploy docker --run
docker run --rm -p 8080:8080 my-api
curl -i http://localhost:8080/readyz
```

What the generated image does:

- **Build stage** (`dart:stable`): `dart pub get`, then `dart build cli -t
  bin/server.dart`. The nitro_server build hook downloads the prebuilt engine
  for the image's platform from the GitHub release and verifies it against the
  digest lock shipped in the package, so the image needs **no cmake and no
  C++ toolchain**. Set `NITRO_SERVER_VERIFY_SIGSTORE=1` in the build stage to
  also require a passing `cosign verify-blob`.
- **Flutter stub.** nitro_server also carries a Flutter FFI-plugin block, and
  pub refuses to resolve such a package unless a Flutter SDK is visible. The
  build stage points `FLUTTER_ROOT` at a two-line stub (the version file pub
  reads); nothing from Flutter is used. The same trick works on a developer
  machine with a standalone Dart SDK, or use the `dart` that ships with
  Flutter.
- **Runtime stage** (`debian:stable-slim`): the AOT bundle, `ca-certificates`
  and `curl` (for the `HEALTHCHECK`), a non-root user, `HOST=0.0.0.0`,
  `PORT=8080`. The prebuilt engine is static (libuv, OpenSSL, brotli, nghttp2
  and libstdc++ linked in) and runs on glibc 2.35+.
- **Static files.** Directories named `public`, `assets` or `web` next to the
  pubspec are copied into the runtime image (`--assets dir1,dir2` to choose),
  so `staticFiles('public')` and `ResponseContext.file('public/…')` work in
  the container exactly as they do locally.
- Options: `--entry bin/other.dart`, `--port 9000`, `--health /healthz`,
  `--platform host` (build for the machine you are on; the default
  `linux/amd64` is what the hosts below run, and on Apple Silicon needs Docker
  Desktop or another Docker with BuildKit).

Configure the container with environment variables: `HOST`, `PORT` and every
`ServerConfig.fromEnv` variable (timeouts, budgets, `TLS_*`, `PROXY_PROTOCOL`;
see the README). `bin/server.dart` guards `/metrics`, `/dashboard`, `/docs`
with `ADMIN_USER`/`ADMIN_PASSWORD` (loopback-only when unset) and keeps its
example API routes closed until `API_TOKEN`, `API_KEY` and
`BASIC_USER`+`BASIC_PASSWORD` are set.

The repository's own [`Dockerfile`](../Dockerfile) is different: it compiles
the engine from source for CI. Applications should use the generated one.

## Cloudflare Containers (`nitro deploy cloudflare`)

Cloudflare runs your Docker image on its network; a tiny Worker is the
ingress and forwards requests to the container through a Durable Object.
Workers and Pages alone cannot run nitro (no native code, no sockets).

```sh
dart run nitro_server:nitro deploy cloudflare --name my-api --instance-type basic --instances 3
npm install                      # @cloudflare/containers + wrangler
npx wrangler dev                  # optional: Worker + container on your machine, http://localhost:8787
npx wrangler login                # once
npx wrangler deploy               # builds the linux/amd64 image, pushes it, deploys the Worker
curl -i https://my-api.<your-subdomain>.workers.dev/readyz
```

Wrangler builds the image with Docker's BuildKit (`docker buildx`). Docker
Desktop ships it; with colima run `brew install docker-buildx` and link
`$(brew --prefix)/lib/docker/cli-plugins/docker-buildx` into
`~/.docker/cli-plugins/`. On an Apple Silicon machine the amd64 image builds
under emulation (about a minute for the Dart build; `wrangler deploy --dry-run`
runs the whole build without uploading).

What you get and what to know:

- `worker.js` spreads requests over `--instances` container instances
  (`getByName`), proxies WebSockets through `fetch()`, and sets `sleepAfter`
  (`--sleep-after`, default 15 m). A sleeping instance cold-starts in 1–3 s;
  if that first connection is dropped (the helper answers 500), the Worker
  retries a bodyless request once, so the caller sees the 200.
- TLS, HTTP/2 and HTTP/3 terminate at Cloudflare; the container receives
  HTTP/1.1, so the `TLS_*` variables and `HTTP_PROTOCOL` do not matter there.
- The client address inside the container is Cloudflare's. Rate-limit on the
  header it sets: `rateLimit(keyExtractor: (r) => r.header('cf-connecting-ip') ?? r.clientIp)`.
- Instances are stopped when idle, so in-process state (the default rate-limit
  store, per-instance `metrics`) is per instance and not durable; use a shared
  `RateLimitStore` and scrape `/metrics` per instance.
- Sizing: `--instance-type lite|basic|standard-1|standard-2|standard-3|standard-4`
  (1/16 vCPU · 256 MiB up to 4 vCPU · 12 GiB). A nitro container idles around
  150 MB with three isolates; `basic` (1/4 vCPU, 1 GiB) fits a small API.
- Only HTTP and WebSocket reach the container; no raw TCP/UDP.

## Netlify (`nitro deploy netlify`)

Netlify hosts your static site and proxies API and WebSocket traffic to a
nitro backend running on a container host (any of the above).

```sh
dart run nitro_server:nitro deploy netlify --backend https://my-api.fly.dev --publish dist
npx netlify deploy --prod --dir dist          # or: nitro deploy netlify ... --run
```

`netlify.toml` proxies `--api-prefix` (default `/api`) with `status = 200`
(a transparent proxy, not a redirect) and the WebSocket path (`--ws-path`,
default `/ws`) to the `wss://` form of the backend.

## Vercel (`nitro deploy vercel`)

Same pattern as Netlify; Vercel Functions cannot run the native server.

```sh
dart run nitro_server:nitro deploy vercel --backend https://my-api.fly.dev
npx vercel --prod                            # or: nitro deploy vercel ... --run
```

`vercel.json` rewrites `--api-prefix` (default `/api`) to the backend.
Vercel rewrites do not carry WebSocket upgrades: connect WebSocket clients to
the backend URL directly.

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
dart run nitro_server:nitro deploy docker --name my-api   # Dockerfile
fly launch --dockerfile Dockerfile                        # or use the committed fly.toml
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

## Scaling notes

- `bin/server.dart` runs one handler isolate (optimal for light/IO-bound routes —
  the engine already uses every core). For **CPU-bound handlers**, raise
  `ServerConfig.isolates` (e.g. to `Platform.numberOfProcessors`); the engine's
  adaptive dispatch then fans out only when it helps. If you do, register the
  observability/OpenAPI routes inside `setup` so every isolate serves them. See
  [`../benchmark/BENCHMARKING.md`](../benchmark/BENCHMARKING.md).
- Scale horizontally by running more replicas behind the platform's load
  balancer; nitro is lean (~30 MB RSS under load) so replicas are cheap.
