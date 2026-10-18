# syntax=docker/dockerfile:1
#
# nitro_server: builds the native C++ engine library and AOT-compiles the server
# entrypoint (bin/server.dart), then ships both in a slim runtime image.
#
#   docker build -t nitro-server .
#   docker run --rm -p 8080:8080 nitro-server
#
# The default engine build has TLS/brotli OFF, so the runtime needs only the C/C++
# runtime. To enable TLS or brotli, add `-DNITRO_SERVER_TLS=ON` (and libssl-dev in
# build / libssl3 in runtime) resp. the brotli flags, below.

# ---- build stage: native engine + AOT server ----
FROM dart:stable AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      cmake clang make && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# Cache dependencies on the pubspec layer.
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

# Build the native engine library (Release) and AOT-compile the server.
COPY . .
RUN dart pub get --offline
RUN cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build/lib --parallel
RUN dart compile exe bin/server.dart -o /app/server

# ---- runtime stage: slim, non-root ----
FROM debian:stable-slim AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libstdc++6 curl && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/server /app/server
COPY --from=build /app/build/lib/libnitro_server.so /app/libnitro_server.so

ENV NITRO_SERVER_DYLIB=/app/libnitro_server.so \
    HOST=0.0.0.0 \
    PORT=8080
EXPOSE 8080

RUN useradd --system --uid 10001 nitro
USER nitro

# Uses the built-in readiness endpoint (503 while draining) so orchestrators and
# `docker run` both see shutdown correctly.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/readyz" || exit 1

ENTRYPOINT ["/app/server"]
