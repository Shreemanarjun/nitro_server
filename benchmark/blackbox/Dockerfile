# syntax=docker/dockerfile:1
#
# TRUE-BLACKBOX cross-framework benchmark image. Each framework is an opaque
# HTTP server; the external load generator (oha) hits it over loopback on
# DISJOINT pinned cores. Builds in-container for reproducibility:
#   * the C++ engine (cmake, Release)                 -> build/lib/libnitro_server.so
#   * compare.dart AOT, @Native code-asset bridge     -> compare_native   (serves nitro/dartio/shelf)
#   * compare.dart AOT, _dylib bridge                 -> compare_dylib    (nitro over DynamicLibrary.open)
#   * Go net/http server                              -> compare_go_server
#   * Node http server                                -> run via `node`
#   * ion_web (pure-Dart HTTP/1.1 on dart:io sockets) -> ion_server_bin
#
# Dart base: nitro is Dart-only, so pub resolves without the Flutter SDK. We
# only strip nitro_server's own `flutter:` ENV constraint (it exists solely to
# publish the ffiPlugin platforms block; the Dart code is Flutter-free). The
# nitro* packages resolve from pub.dev like any other dependency.
#
# Build context is the repo ROOT (run.sh handles it):
#   docker build -f benchmark/blackbox/Dockerfile -t nitro-blackbox .
FROM dart:stable AS build

RUN apt-get update && apt-get install -y --no-install-recommends \
      git cmake clang make pkg-config golang-go nodejs python3 ca-certificates procps curl \
      libssl-dev libuv1-dev libbrotli-dev \
    && rm -rf /var/lib/apt/lists/*

# oha (blackbox load generator): pinned, arch-matched prebuilt static binary.
ARG OHA_VERSION=v1.16.0
RUN set -eux; arch="$(dpkg --print-architecture)"; \
    case "$arch" in amd64) o=oha-linux-amd64 ;; arm64) o=oha-linux-arm64 ;; *) echo "no oha for $arch" >&2; exit 1 ;; esac; \
    curl -fsSL -o /usr/local/bin/oha "https://github.com/hatoo/oha/releases/download/${OHA_VERSION}/${o}"; \
    chmod +x /usr/local/bin/oha; oha --version

WORKDIR /app
COPY . .

# Repoint local nitro overrides at the vendored copies + drop the publish-only
# Flutter SDK env constraint (see fix_pubspec.py). rm the lock so pub resolves
# the rewritten paths fresh. The script prints the final paths into the log.
RUN rm -f pubspec.lock && python3 benchmark/blackbox/fix_pubspec.py
RUN dart pub get

# 1. engine (Release) -> build/lib/libnitro_server.so  (both bridges link this)
ARG ENGINE_FLAGS="-DCMAKE_BUILD_TYPE=Release"
RUN cmake -S src -B build/lib $ENGINE_FLAGS && cmake --build build/lib --parallel

# 2. @Native compare bundle. MUST use `dart build cli`, NOT `dart compile exe`:
# `dart compile exe` does not run build hooks, so it bundles no code assets and
# the @Native externals abort at runtime ("No available native assets"). `dart
# build cli` runs the hook + link, bundling the engine into
# build/native_cli/bundle/{bin/compare, lib/libnitro_server.so}; the loader finds
# the .so via its exeDir/../lib candidate.
RUN dart run build_runner build && dart build cli -t benchmark/compare.dart -o build/native_cli

# 3. _dylib compare binary (toggle native_assets off, regenerate, compile, restore)
RUN cp build.yaml /tmp/build.yaml.bak && cp lib/src/nitro_server.g.dart /tmp/g.native.bak; \
    sed -i '/options:/d; /native_assets: true/d' build.yaml; \
    dart run build_runner build; \
    dart compile exe benchmark/compare.dart -o compare_dylib; \
    cp /tmp/build.yaml.bak build.yaml && cp /tmp/g.native.bak lib/src/nitro_server.g.dart

# 3b. Optional A/B baseline (`run.sh --base <ref>`): the tree at <ref>, exported
# into benchmark/blackbox/base/, built exactly like step 1+3 and served as
# `nitro-base`, so two nitro builds are measured interleaved in ONE run.
ARG BASE_REF=""
ENV BASE_REF="$BASE_REF"
RUN if [ -f benchmark/blackbox/base/pubspec.yaml ]; then set -e; cd benchmark/blackbox/base; \
      rm -f pubspec.lock; python3 /app/benchmark/blackbox/fix_pubspec.py; dart pub get; \
      cmake -S src -B build/lib $ENGINE_FLAGS && cmake --build build/lib --parallel; \
      sed -i '/options:/d; /native_assets: true/d' build.yaml; dart run build_runner build; \
      dart compile exe benchmark/compare.dart -o /app/compare_dylib_base; \
      cp build/lib/libnitro_server.so /app/libnitro_server_base.so; fi

# 4a. ion_web server (its own package, so ion_web never enters nitro_server's
# dependency graph): AOT, same routes and bytes as the other sides.
RUN cd benchmark/ion_server && dart pub get && dart compile exe bin/server.dart -o /app/ion_server_bin

# 4. Go server + 4 KiB POST body for /echo
RUN go build -o compare_go_server benchmark/compare_go_server.go
RUN head -c 4096 /dev/zero | tr '\0' 'x' > benchmark/blackbox/echo4k.bin

# Fair defaults — override at `docker run` time (see run.sh). SRV/CLI cores are
# DISJOINT so client and server never steal each other's CPU.
ENV SRV_CORES=0-1 CLI_CORES=2-3 REPS=5 DURATION=10s CONNECTIONS=64 OUT=/out
RUN chmod +x benchmark/blackbox/orchestrate.sh
ENTRYPOINT ["bash", "benchmark/blackbox/orchestrate.sh"]
