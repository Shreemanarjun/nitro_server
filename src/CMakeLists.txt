cmake_minimum_required(VERSION 3.10)
project(nitro_server_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Tune for the build host's CPU (-march=native). ON for local/benchmark builds
# where producer == consumer. The release pipeline sets it OFF: a distributed
# prebuilt must run on any CPU of its arch (a lib built on an AVX-512 runner
# would SIGILL elsewhere), and -march=native is also invalid when cross-
# compiling (e.g. x86_64 on an Apple-Silicon host).
option(NITRO_SERVER_NATIVE_TUNE "Optimize for the build host CPU (-march=native)" ON)

# ── Aggressive native optimization flags ──────────────────────────────────────
# Override CMake's default Release flags with CPU-tuned optimizations.
# -O3: aggressive inlining + vectorization
# -march=native: use all native CPU extensions (SSE4, AVX2, NEON, etc.)
# -mtune=native: schedule for the local microarch
# -flto: link-time optimization across TUs (whole-program devirtualization)
# -DNDEBUG: strip assertions and bounds checks
# -fomit-frame-pointer: free up a register on x86_64
# -funroll-loops: unroll hot loops (parser, header scan)
# -fno-math-errno: sqrt/pow inline without the errno dance (the only FP in
#   the engine is the JSON float writer, which reads sign bits itself — no
#   -ffast-math: it would change float semantics for no parsing gain)
# Hardening (the production audit): -fstack-protector-strong,
#   _FORTIFY_SOURCE=2, hidden default visibility (only NITRO_EXPORT symbols
#   leave the library), and on Linux RELRO/NOW + a non-executable stack.
#
# MSVC (cl.exe) understands none of this GCC/Clang syntax. Applying it there
# silently drops CMake's default `/MD /O2`, leaving the build unoptimized AND on
# the static CRT (/MT) — which mismatches vcpkg's dynamic-CRT deps (the
# x64-windows-static-md triplet) and fails linking with unresolved __imp_*.
# So tune only GCC/Clang; MSVC keeps CMake's defaults (/MD /O2 /Ob2 /DNDEBUG).
if(NOT MSVC)
  if(NITRO_SERVER_NATIVE_TUNE)
    set(_nitro_tune "-march=native -mtune=native")
  else()
    set(_nitro_tune "")  # portable baseline for distributed prebuilts
  endif()
  set(_nitro_harden "-fstack-protector-strong -D_FORTIFY_SOURCE=2 -fvisibility=hidden")
  set(CMAKE_C_FLAGS_RELEASE   "-O3 ${_nitro_tune} -DNDEBUG -fomit-frame-pointer -funroll-loops -fno-math-errno ${_nitro_harden}")
  set(CMAKE_CXX_FLAGS_RELEASE "-O3 ${_nitro_tune} -DNDEBUG -fomit-frame-pointer -funroll-loops -fno-math-errno -fno-rtti ${_nitro_harden}")
  # Link-time optimization at the linker level (requires matching compile flags).
  set(CMAKE_EXE_LINKER_FLAGS_RELEASE  "-flto -O3")
  set(CMAKE_SHARED_LINKER_FLAGS_RELEASE "-flto -O3")
endif()

# ── Optimization guard ───────────────────────────────────────────────────────
# The Android Gradle Plugin passes the VARIANT name (e.g. "profile") as
# CMAKE_BUILD_TYPE. CMake only defines per-config flags for
# Debug/Release/RelWithDebInfo/MinSizeRel — an unknown config has EMPTY flag
# sets, so every native source silently compiles at -O0. Flutter's release
# variant maps to RELEASE and is unaffected, but profile builds shipped
# unoptimized native code. Give any non-standard config Release-grade flags.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _NITRO_CFG)
if(NOT MSVC AND NOT "${_NITRO_CFG}" MATCHES "^(DEBUG|RELEASE|RELWITHDEBINFO|MINSIZEREL|)$")
  set(CMAKE_C_FLAGS_${_NITRO_CFG} "-O3 -march=native -mtune=native -DNDEBUG -fomit-frame-pointer -funroll-loops -fno-math-errno -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fvisibility=hidden")
  set(CMAKE_CXX_FLAGS_${_NITRO_CFG} "-O3 -march=native -mtune=native -DNDEBUG -fomit-frame-pointer -funroll-loops -fno-math-errno -fno-rtti -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fvisibility=hidden")
endif()

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM 192f943dc69d43b1
set(GENERATED_CPP "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp")

add_library(nitro_server SHARED
  "nitro_server.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../lib/src/generated/cpp/nitro_server.bridge.g.cpp"
  "dart_api_dl.c"
)

if(NOT ANDROID)
  if(DEFINED NITRO_IMPL_SRC_nitro_server)
    target_sources(nitro_server PRIVATE "${NITRO_IMPL_SRC_nitro_server}")
  else()
    target_sources(nitro_server PRIVATE "HybridNitroServer.cpp")
  endif()
endif()
target_include_directories(nitro_server PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${GENERATED_CPP}"
  "${NITRO_NATIVE}"
)

target_compile_definitions(nitro_server PUBLIC DART_SHARED_LIB)

if(ANDROID)
  target_link_libraries(nitro_server PRIVATE android log)
  target_link_options(nitro_server PRIVATE "-Wl,-z,max-page-size=16384")
endif()

# ── nitro_server engine ──────────────────────────────────────────────────────
# Everything below is hand-maintained but lives OUTSIDE every section
# `nitrogen link` rewrites, so regeneration cannot clobber it.
#
# The block above only compiles the impl TU when NOT ANDROID, because the
# scaffold assumed Android went through Kotlin/JNI. The spec is C++ on every
# platform now, so Android needs it too.
if(ANDROID)
  target_sources(nitro_server PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/HybridNitroServer.cpp")
endif()

include("${CMAKE_CURRENT_SOURCE_DIR}/engine.cmake")
nitro_server_attach_engine(nitro_server)

# ── Warnings and link hardening ──────────────────────────────────────────────
# Every engine TU builds with -Wall -Wextra; CI turns NITRO_SERVER_WERROR on so
# a new warning fails the build there rather than accumulating.
option(NITRO_SERVER_WERROR "Treat compiler warnings as errors" OFF)
if(NOT MSVC)
  # -Wno-missing-field-initializers: aggregate init with defaulted trailing
  # members is idiomatic here (Pending{...}), not a defect.
  target_compile_options(nitro_server PRIVATE -Wall -Wextra
    -Wno-missing-field-initializers
    $<$<BOOL:${NITRO_SERVER_WERROR}>:-Werror>)
  # Vendored (Dart SDK) and nitrogen-generated sources are not ours to fix:
  # compile them quietly so the gate judges only hand-written engine code.
  set_source_files_properties(
    "dart_api_dl.c"
    "${GENERATED_CPP}/nitro_server.bridge.g.cpp"
    PROPERTIES COMPILE_OPTIONS "-w")
  if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
    target_link_options(nitro_server PRIVATE
      "-Wl,-z,relro" "-Wl,-z,now" "-Wl,-z,noexecstack")
  endif()
endif()

# ── Tests (desktop only, opt-in) ─────────────────────────────────────────────
option(NITRO_SERVER_BUILD_TESTS "Build the C++ engine test suite" OFF)
if(NITRO_SERVER_BUILD_TESTS)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../test/cpp"
                   "${CMAKE_CURRENT_BINARY_DIR}/nitro_server_tests")
endif()

# Prebuilt portability (Linux): a distributed engine must not require the
# consumer's libstdc++ to be at least the builder's. With static deps on, fold
# libstdc++/libgcc into the library (its symbols stay hidden — see the
# visibility flags above), so the only runtime requirement left is glibc.
if(NITRO_SERVER_STATIC_DEPS AND CMAKE_SYSTEM_NAME STREQUAL "Linux")
  target_link_options(nitro_server PRIVATE -static-libstdc++ -static-libgcc)
endif()
