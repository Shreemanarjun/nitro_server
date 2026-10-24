# syntax=docker/dockerfile:1
#
# nitro_server: builds the native C++ engine (all features: TLS, brotli,
# HTTP/2, dependencies linked statically) and the AOT server (bin/server.dart)
# with `dart build cli`, which runs the package's build hook so the engine ships
# inside the bundle as a code asset. Base images are digest-pinned; bump the
# digests deliberately (`docker buildx imagetools inspect <image>`).
#
#   docker build -t nitro-server .
#   docker run --rm -p 8080:8080 nitro-server
#
# Config via env: HOST (0.0.0.0), PORT (8080), ADMIN_USER + ADMIN_PASSWORD (guard
# /metrics, /dashboard, /docs — loopback-only without them), API_TOKEN, API_KEY,
# and every ServerConfig.fromEnv variable (see README "From the environment").

# ---- build stage: native engine + AOT bundle -------------------------------
FROM dart:stable@sha256:efc6116982a4d178babd453b05555b37693316945fd6012a2d10232a940caa19 AS build
RUN apt-get update && apt-get install -y --no-install-recommends \
      cmake clang make pkg-config curl ca-certificates \
      libssl-dev libbrotli-dev libnghttp2-dev zlib1g-dev libzstd-dev \
 && rm -rf /var/lib/apt/lists/*

# libuv from source, static and position-independent: Debian's x86_64 libuv.a
# is not PIC and cannot be linked into the engine's shared object (the arm64
# archive happens to work, which is why this only showed up on amd64 CI).
# Pinned by checksum; installs to /usr/local, where engine.cmake looks first.
ARG LIBUV_VERSION=1.50.0
ARG LIBUV_SHA256=b1ec56444ee3f1e10c8bd3eed16ba47016ed0b94fe42137435aaf2e0bd574579
RUN set -eux; \
    curl -fsSL -o /tmp/libuv.tar.gz "https://github.com/libuv/libuv/archive/refs/tags/v${LIBUV_VERSION}.tar.gz"; \
    echo "${LIBUV_SHA256}  /tmp/libuv.tar.gz" | sha256sum -c -; \
    mkdir -p /tmp/libuv && tar -xzf /tmp/libuv.tar.gz -C /tmp/libuv --strip-components=1; \
    cmake -S /tmp/libuv -B /tmp/libuv/build -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \
      -DLIBUV_BUILD_SHARED=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_INSTALL_PREFIX=/usr/local; \
    cmake --build /tmp/libuv/build --parallel && cmake --install /tmp/libuv/build; \
    rm -rf /tmp/libuv /tmp/libuv.tar.gz
WORKDIR /app

# Resolve dependencies on the pubspec layer. nitro_server is also a Flutter FFI
# plugin, so its pubspec carries a publish-only Flutter SDK constraint; the
# server is plain Dart, so that one line is dropped for the container build.
# pubspec.lock is not committed (a package, not an app): the [k] glob makes
# the copy optional, so the build works from a git checkout and from a dev tree.
COPY pubspec.yaml pubspec.loc[k] ./
RUN sed -i -E "/^\s*flutter:\s*['\"]>=/d" pubspec.yaml && dart pub get

COPY . .
RUN sed -i -E "/^\s*flutter:\s*['\"]>=/d" pubspec.yaml && dart pub get --offline

# Engine: portable (no -march=native — the image runs on any CPU of its arch),
# every feature on, static deps so the runtime image needs no libuv/ssl/brotli
# (Debian's static libcrypto wants zlib + zstd, hence the *-dev here / runtime libs below).
RUN cmake -S src -B build/lib -DCMAKE_BUILD_TYPE=Release \
      -DNITRO_SERVER_NATIVE_TUNE=OFF -DNITRO_SERVER_HTTP2=ON \
      -DNITRO_SERVER_STATIC_DEPS=ON \
 && cmake --build build/lib --parallel

# `dart build cli`, never `dart compile exe`: only the former runs the build
# hook that bundles the engine (bundle/lib/) next to the executable.
# NO_DOWNLOAD: the engine was just built; never reach for a prebuilt here.
RUN NITRO_SERVER_NO_DOWNLOAD=1 dart build cli -t bin/server.dart -o /app/out

# ---- runtime stage: slim, non-root ------------------------------------------
FROM debian:stable-slim@sha256:a717a33469731894e77e912ea7d714e27c2dc38ee6554fd1a3102e92999cfc66 AS runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates libstdc++6 zlib1g libzstd1 curl \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY --from=build /app/out/bundle/ /app/

ENV HOST=0.0.0.0 \
    PORT=8080
EXPOSE 8080

RUN useradd --system --uid 10001 nitro
USER nitro

# The built-in readiness endpoint (503 while draining or when a helper isolate
# died) so orchestrators and `docker run` both see shutdown correctly.
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -fsS "http://127.0.0.1:${PORT}/readyz" || exit 1

ENTRYPOINT ["/app/bin/server"]
