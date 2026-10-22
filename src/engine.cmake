# ── Static dependency linking (optional) ─────────────────────────────────────
# -DNITRO_SERVER_STATIC_DEPS=ON links libuv/OpenSSL/brotli/nghttp2 as static
# archives so the engine library is self-contained — the shape the release
# prebuilts ship (`hook/build.dart` downloads one, no system libs needed). Needs
# the static archives (`.a`/`.lib`) installed for each dep; the release workflow
# arranges that per platform. Off by default: a normal build links the usual
# shared libraries.
option(NITRO_SERVER_STATIC_DEPS "Statically link native deps into the engine" OFF)

# ── TLS (OpenSSL, optional) ──────────────────────────────────────────────────
# Links OpenSSL and defines NITRO_SERVER_TLS when it is found; otherwise the
# engine builds without TLS and `supportsTls()` reports false (a TLS config
# then fails `start()` with a clear error). Homebrew installs off the default
# search path, so hint OPENSSL_ROOT_DIR before find_package.
function(nitro_server_attach_tls target)
  if(NOT DEFINED OPENSSL_ROOT_DIR AND NOT DEFINED ENV{OPENSSL_ROOT_DIR})
    foreach(cand /opt/homebrew/opt/openssl@3 /usr/local/opt/openssl@3)
      if(EXISTS "${cand}")
        set(OPENSSL_ROOT_DIR "${cand}")
        break()
      endif()
    endforeach()
  endif()
  if(NITRO_SERVER_STATIC_DEPS)
    set(OPENSSL_USE_STATIC_LIBS ON)  # honoured by FindOpenSSL: picks lib*.a
  endif()
  find_package(OpenSSL QUIET)
  if(OpenSSL_FOUND)
    target_link_libraries(${target} PRIVATE OpenSSL::SSL OpenSSL::Crypto)
    target_compile_definitions(${target} PRIVATE NITRO_SERVER_TLS=1)
    message(STATUS "nitro_server: TLS enabled (OpenSSL ${OPENSSL_VERSION})")
  else()
    message(STATUS "nitro_server: OpenSSL not found; building without TLS")
  endif()
endfunction()

# ── libuv (reactor I/O core) ─────────────────────────────────────────────────
# The engine's connection multiplexing runs on a libuv event loop (one per
# worker), which scales flat to thousands of keep-alive connections where a
# thread-per-connection pool dips. Found via CMake config or pkg-config;
# Homebrew installs off the default search path, so hint it first. Building
# from source (FetchContent) is the path for the Flutter plugin's cross-compiled
# targets — added when those platforms are wired.
function(nitro_server_attach_libuv target)
  find_package(libuv CONFIG QUIET)
  if(libuv_FOUND)
    # Static build prefers the static archive target (libuv::uv_a).
    if(NITRO_SERVER_STATIC_DEPS AND TARGET libuv::uv_a)
      target_link_libraries(${target} PRIVATE libuv::uv_a)
    elseif(TARGET libuv::uv)
      target_link_libraries(${target} PRIVATE libuv::uv)
    elseif(TARGET libuv::uv_a)
      target_link_libraries(${target} PRIVATE libuv::uv_a)
    endif()
    target_compile_definitions(${target} PRIVATE NITRO_SERVER_LIBUV=1)
    message(STATUS "nitro_server: libuv found (CONFIG)")
    return()
  endif()
  find_package(PkgConfig QUIET)
  if(PkgConfig_FOUND)
    pkg_check_modules(LIBUV QUIET libuv)
    if(LIBUV_FOUND)
      if(NITRO_SERVER_STATIC_DEPS AND LIBUV_STATIC_LIBRARIES)
        # `pkg-config --static` yields bare names (uv;pthread;dl;rt); linking
        # `uv` lets the linker prefer libuv.so where both exist (Debian,
        # Homebrew), leaving a "static" engine that still needs libuv.so.1 at
        # runtime. Pin the archive itself; keep the rest of the static list.
        find_library(NITRO_LIBUV_A NAMES libuv.a uv_a
          HINTS ${LIBUV_STATIC_LIBRARY_DIRS} ${LIBUV_LIBRARY_DIRS}
                /opt/homebrew/lib /usr/local/lib /usr/lib
                /usr/lib/${CMAKE_LIBRARY_ARCHITECTURE})
        if(NITRO_LIBUV_A)
          set(_uv_libs ${NITRO_LIBUV_A})
          foreach(_l ${LIBUV_STATIC_LIBRARIES})
            if(NOT _l STREQUAL "uv")
              list(APPEND _uv_libs ${_l})
            endif()
          endforeach()
          message(STATUS "nitro_server: libuv linked statically (${NITRO_LIBUV_A})")
        else()
          set(_uv_libs ${LIBUV_STATIC_LIBRARIES})
        endif()
      else()
        set(_uv_libs ${LIBUV_LIBRARIES})
      endif()
      target_include_directories(${target} PRIVATE ${LIBUV_INCLUDE_DIRS})
      target_link_libraries(${target} PRIVATE ${_uv_libs})
      target_link_directories(${target} PRIVATE ${LIBUV_LIBRARY_DIRS})
      target_compile_definitions(${target} PRIVATE NITRO_SERVER_LIBUV=1)
      message(STATUS "nitro_server: libuv found (pkg-config ${LIBUV_VERSION})")
      return()
    endif()
  endif()
  # Last-resort fallback (no pkg-config): hint well-known prefixes directly,
  # including the bare `/usr` where Linux distro packages (libuv1-dev) land. A
  # static build restricts the search to archives so libuv links statically
  # (.lib on MSVC, .a elsewhere).
  if(NITRO_SERVER_STATIC_DEPS)
    if(WIN32)
      set(CMAKE_FIND_LIBRARY_SUFFIXES .lib)  # function-scoped: only libuv here
    else()
      set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
    endif()
  endif()
  foreach(cand /opt/homebrew /usr/local /usr /opt/homebrew/opt/libuv /usr/local/opt/libuv)
    if(EXISTS "${cand}/include/uv.h")
      target_include_directories(${target} PRIVATE "${cand}/include")
      find_library(NITRO_LIBUV_LIB NAMES uv libuv HINTS "${cand}/lib")
      if(NITRO_LIBUV_LIB)
        target_link_libraries(${target} PRIVATE "${NITRO_LIBUV_LIB}")
        target_compile_definitions(${target} PRIVATE NITRO_SERVER_LIBUV=1)
        message(STATUS "nitro_server: libuv found at ${cand}")
        return()
      endif()
    endif()
  endforeach()
  message(FATAL_ERROR "nitro_server: libuv not found — install libuv "
    "(brew install libuv / apt install libuv1-dev)")
endfunction()

# ── Brotli (response compression, optional) ──────────────────────────────────
# Links libbrotli and defines NITRO_SERVER_BROTLI when found; otherwise the
# engine builds without it and nitro_server_brotli_available() reports 0, so the
# compress() middleware falls back to gzip. Found via pkg-config (Ubuntu's
# libbrotli-dev, Homebrew's brotli.pc) with a Homebrew-prefix fallback. Needs
# all three components: encoder, decoder (round-trip tests) and common.
function(nitro_server_attach_brotli target)
  find_package(PkgConfig QUIET)
  if(PkgConfig_FOUND)
    pkg_check_modules(BROTLI QUIET libbrotlienc libbrotlidec libbrotlicommon)
    if(BROTLI_FOUND)
      set(_brotli_libs ${BROTLI_LIBRARIES})
      if(NITRO_SERVER_STATIC_DEPS)
        if(WIN32)
          set(CMAKE_FIND_LIBRARY_SUFFIXES .lib)  # MSVC static archive
        else()
          set(CMAKE_FIND_LIBRARY_SUFFIXES .a)  # resolve archives, not the .dylib
        endif()
        set(_brotli_a "")
        foreach(_c brotlienc brotlidec brotlicommon)
          find_library(NITRO_BROTLI_${_c}_A NAMES ${_c}
            HINTS ${BROTLI_LIBRARY_DIRS} /opt/homebrew/lib /usr/local/lib /usr/lib)
          if(NITRO_BROTLI_${_c}_A)
            list(APPEND _brotli_a ${NITRO_BROTLI_${_c}_A})
          endif()
        endforeach()
        # enc+dec+common must all resolve as archives, else keep the shared libs.
        list(LENGTH _brotli_a _n)
        if(_n EQUAL 3)
          set(_brotli_libs ${_brotli_a})
        endif()
      endif()
      target_include_directories(${target} PRIVATE ${BROTLI_INCLUDE_DIRS})
      target_link_libraries(${target} PRIVATE ${_brotli_libs})
      target_link_directories(${target} PRIVATE ${BROTLI_LIBRARY_DIRS})
      target_compile_definitions(${target} PRIVATE NITRO_SERVER_BROTLI=1)
      message(STATUS "nitro_server: Brotli enabled (pkg-config ${BROTLI_libbrotlienc_VERSION})")
      return()
    endif()
  endif()
  foreach(cand /opt/homebrew/opt/brotli /usr/local/opt/brotli /opt/homebrew /usr/local)
    if(EXISTS "${cand}/include/brotli/encode.h")
      find_library(NITRO_BROTLI_ENC NAMES brotlienc HINTS "${cand}/lib")
      find_library(NITRO_BROTLI_DEC NAMES brotlidec HINTS "${cand}/lib")
      find_library(NITRO_BROTLI_COM NAMES brotlicommon HINTS "${cand}/lib")
      if(NITRO_BROTLI_ENC AND NITRO_BROTLI_DEC AND NITRO_BROTLI_COM)
        target_include_directories(${target} PRIVATE "${cand}/include")
        target_link_libraries(${target} PRIVATE
          "${NITRO_BROTLI_ENC}" "${NITRO_BROTLI_DEC}" "${NITRO_BROTLI_COM}")
        target_compile_definitions(${target} PRIVATE NITRO_SERVER_BROTLI=1)
        message(STATUS "nitro_server: Brotli enabled at ${cand}")
        return()
      endif()
    endif()
  endforeach()
  message(STATUS "nitro_server: Brotli not found; building without it (gzip only)")
endfunction()

# ── HTTP/2 (nghttp2, optional, off by default) ───────────────────────────────
# Opt in with -DNITRO_SERVER_HTTP2=ON. When requested AND nghttp2 is found,
# links it and defines NITRO_SERVER_HTTP2=1 so the engine serves HTTP/2 (ALPN
# `h2` over TLS, and h2c); otherwise the engine stays HTTP/1.1-only and never
# advertises `h2` over ALPN. See doc/http2.md.
option(NITRO_SERVER_HTTP2 "Build with HTTP/2 (nghttp2)" OFF)
function(nitro_server_attach_http2 target)
  if(NOT NITRO_SERVER_HTTP2)
    return()
  endif()
  find_package(PkgConfig QUIET)
  if(PkgConfig_FOUND)
    pkg_check_modules(NGHTTP2 QUIET libnghttp2)
    if(NGHTTP2_FOUND)
      set(_nghttp2_libs ${NGHTTP2_LIBRARIES})
      if(NITRO_SERVER_STATIC_DEPS)
        # pkg-config's static list is link names the linker still resolves to
        # the shared lib, so resolve the archive path explicitly (.lib on MSVC,
        # .a elsewhere).
        if(WIN32)
          set(CMAKE_FIND_LIBRARY_SUFFIXES .lib)
        else()
          set(CMAKE_FIND_LIBRARY_SUFFIXES .a)
        endif()
        find_library(NITRO_NGHTTP2_A NAMES nghttp2
          HINTS ${NGHTTP2_LIBRARY_DIRS} /opt/homebrew/lib /usr/local/lib /usr/lib)
        if(NITRO_NGHTTP2_A)
          set(_nghttp2_libs ${NITRO_NGHTTP2_A})
        endif()
      endif()
      target_include_directories(${target} PRIVATE ${NGHTTP2_INCLUDE_DIRS})
      target_link_libraries(${target} PRIVATE ${_nghttp2_libs})
      target_link_directories(${target} PRIVATE ${NGHTTP2_LIBRARY_DIRS})
      target_compile_definitions(${target} PRIVATE NITRO_SERVER_HTTP2=1)
      message(STATUS "nitro_server: HTTP/2 enabled (nghttp2 ${NGHTTP2_libnghttp2_VERSION})")
      return()
    endif()
  endif()
  foreach(cand /opt/homebrew/opt/libnghttp2 /usr/local/opt/libnghttp2
               /opt/homebrew/opt/nghttp2 /usr/local/opt/nghttp2 /usr /usr/local)
    if(EXISTS "${cand}/include/nghttp2/nghttp2.h")
      find_library(NITRO_NGHTTP2_LIB NAMES nghttp2 HINTS "${cand}/lib")
      if(NITRO_NGHTTP2_LIB)
        target_include_directories(${target} PRIVATE "${cand}/include")
        target_link_libraries(${target} PRIVATE "${NITRO_NGHTTP2_LIB}")
        target_compile_definitions(${target} PRIVATE NITRO_SERVER_HTTP2=1)
        message(STATUS "nitro_server: HTTP/2 enabled (nghttp2 at ${cand})")
        return()
      endif()
    endif()
  endforeach()
  message(FATAL_ERROR "nitro_server: NITRO_SERVER_HTTP2=ON but nghttp2 not found")
endfunction()

# ── nitro_server engine ────────────────────────────────────────────────────
# Compiles src/engine/*.cpp and links the result into the plugin library.
# Mirrors nitro_http's engine.cmake: Apple platforms compile the unity TU
# (forwarded from ios/Classes + macos/Classes into HybridNitroServer.cpp),
# CMake platforms compile each TU separately for faster incremental builds.
set(NITRO_SERVER_ENGINE_SOURCES
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/Router.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/HttpParse.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/JsonWriter.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/EngineRegistry.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/UvReactor.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/Brotli.cpp"
  # Fully #ifdef NITRO_SERVER_HTTP2-guarded: compiles to nothing by default.
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/Http2Session.cpp"
)

function(nitro_server_attach_engine target)
  if(APPLE)
    # Unity build via HybridNitroServer.cpp's #include of EngineUnity.cpp.
    target_compile_definitions(${target} PRIVATE NITRO_SERVER_APPLE_UNITY=1)
  else()
    target_compile_definitions(${target} PRIVATE NITRO_SERVER_ENGINE_SEPARATE_TUS=1)
    target_sources(${target} PRIVATE ${NITRO_SERVER_ENGINE_SOURCES})
  endif()
  target_include_directories(${target} PRIVATE
    "${CMAKE_CURRENT_SOURCE_DIR}"
    "${CMAKE_CURRENT_SOURCE_DIR}/engine"
  )
  nitro_server_attach_tls(${target})
  nitro_server_attach_libuv(${target})
  nitro_server_attach_brotli(${target})
  nitro_server_attach_http2(${target})
  if(WIN32)
    target_compile_definitions(${target} PRIVATE
      WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
    target_compile_options(${target} PRIVATE /EHsc)
    target_link_libraries(${target} PRIVATE ws2_32)
    if(NITRO_SERVER_STATIC_DEPS)
      # Static OpenSSL + libuv pull in these Win32 import libs transitively.
      # The pkg-config / manual find_library paths (unlike the CONFIG targets)
      # don't inherit them, so list them here. Harmless if a target already
      # carries some; the linker dedupes.
      target_link_libraries(${target} PRIVATE
        crypt32 bcrypt advapi32 user32 gdi32          # static OpenSSL 3
        psapi iphlpapi userenv dbghelp ole32 shell32) # static libuv
      # Static nghttp2's API is declared __declspec(dllimport) unless the
      # consumer defines NGHTTP2_STATICLIB (else unresolved __imp_nghttp2_*).
      if(NITRO_SERVER_HTTP2)
        target_compile_definitions(${target} PRIVATE NGHTTP2_STATICLIB)
      endif()
    endif()
  else()
    target_link_libraries(${target} PRIVATE pthread)
    if(APPLE)
      target_link_libraries(${target} PRIVATE resolv)
    endif()
  endif()
endfunction()
