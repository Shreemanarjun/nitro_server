cmake_minimum_required(VERSION 3.10)
project(nitro_server_library VERSION 0.0.1 LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# ── Optimization guard ───────────────────────────────────────────────────────
# The Android Gradle Plugin passes the VARIANT name (e.g. "profile") as
# CMAKE_BUILD_TYPE. CMake only defines per-config flags for
# Debug/Release/RelWithDebInfo/MinSizeRel — an unknown config has EMPTY flag
# sets, so every native source silently compiles at -O0. Flutter's release
# variant maps to RELEASE and is unaffected, but profile builds shipped
# unoptimized native code. Give any non-standard config Release-grade flags.
string(TOUPPER "${CMAKE_BUILD_TYPE}" _NITRO_CFG)
if(NOT "${_NITRO_CFG}" MATCHES "^(DEBUG|RELEASE|RELWITHDEBINFO|MINSIZEREL|)$")
  set(CMAKE_C_FLAGS_${_NITRO_CFG} "-O2 -DNDEBUG")
  set(CMAKE_CXX_FLAGS_${_NITRO_CFG} "-O2 -DNDEBUG")
endif()

set(NITRO_NATIVE "${CMAKE_CURRENT_SOURCE_DIR}/native")
# NITRO_LINK_SPEC_CHECKSUM 56fb6deac5f50ffb
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

# ── Tests (desktop only, opt-in) ─────────────────────────────────────────────
option(NITRO_SERVER_BUILD_TESTS "Build the C++ engine test suite" OFF)
if(NITRO_SERVER_BUILD_TESTS)
  add_subdirectory("${CMAKE_CURRENT_SOURCE_DIR}/../test/cpp"
                   "${CMAKE_CURRENT_BINARY_DIR}/nitro_server_tests")
endif()
