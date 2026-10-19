# syntax=docker/dockerfile:1
#
# Black-box, reproducible benchmark environment for nitro_server.
#
# Builds the native C++ engine, AOT-compiles the compare driver, and ships the
# Go + Node peer sources so `compare.dart` can build/launch them at runtime. The
# entrypoint (run-bench.sh) runs the full compare suite TWICE — once with the
# engine's adaptive dispatch controller (production-realistic) and once with the
# controller PINNED to a fixed width (deterministic) — and writes both tables to
# /out so the controller's effect is visible side by side.
#
# Pin the base image digest + the run-time CPU/mem (see benchmark/docker/bench.sh)
# so anyone gets a comparable, controlled run. Build context is the repo ROOT:
#
#   docker build -f benchmark/docker/Dockerfile -t nitro-bench .
#
# The engine is built with HTTP/2 OFF, matching the headline benchmark build
# (benchmark/run_all.sh). Flip ENGINE_FLAGS to compare other configs.

ARG DART_VERSION=3.9.4
FROM dart:${DART_VERSION} AS bench

# Peers + toolchain. golang-go and nodejs come from the pinned base's apt repo;
# their exact versions are recorded into the results header at run time, so a
# reader always knows what produced the numbers.
RUN apt-get update && apt-get install -y --no-install-recommends \
      cmake clang make golang-go nodejs ca-certificates procps \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Cache deps on the pubspec layer.
COPY pubspec.yaml pubspec.lock ./
RUN dart pub get

# Build everything from source.
COPY . .
RUN dart pub get --offline

ARG ENGINE_FLAGS="-DCMAKE_BUILD_TYPE=Release"
RUN cmake -S src -B build/lib ${ENGINE_FLAGS} \
    && cmake --build build/lib --parallel

RUN mkdir -p build/benchmark \
    && dart compile exe benchmark/compare.dart -o build/benchmark/compare

ENV NITRO_SERVER_DYLIB=/app/build/lib/libnitro_server.so
VOLUME /out
ENTRYPOINT ["bash", "benchmark/docker/run-bench.sh"]
