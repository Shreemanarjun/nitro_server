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
    if(TARGET libuv::uv)
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
      target_include_directories(${target} PRIVATE ${LIBUV_INCLUDE_DIRS})
      target_link_libraries(${target} PRIVATE ${LIBUV_LIBRARIES})
      target_link_directories(${target} PRIVATE ${LIBUV_LIBRARY_DIRS})
      target_compile_definitions(${target} PRIVATE NITRO_SERVER_LIBUV=1)
      message(STATUS "nitro_server: libuv found (pkg-config ${LIBUV_VERSION})")
      return()
    endif()
  endif()
  # Homebrew fallback: hint the well-known prefixes directly.
  foreach(cand /opt/homebrew /usr/local /opt/homebrew/opt/libuv /usr/local/opt/libuv)
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

# ── nitro_server engine ────────────────────────────────────────────────────
# Compiles src/engine/*.cpp and links the result into the plugin library.
# Mirrors nitro_http's engine.cmake: Apple platforms compile the unity TU
# (forwarded from ios/Classes + macos/Classes into HybridNitroServer.cpp),
# CMake platforms compile each TU separately for faster incremental builds.
set(NITRO_SERVER_ENGINE_SOURCES
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/Router.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/ServerInstance.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/EngineRegistry.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/engine/UvReactor.cpp"
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
  if(WIN32)
    target_compile_definitions(${target} PRIVATE
      WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
    target_compile_options(${target} PRIVATE /EHsc)
    target_link_libraries(${target} PRIVATE ws2_32)
  else()
    target_link_libraries(${target} PRIVATE pthread)
    if(APPLE)
      target_link_libraries(${target} PRIVATE resolv)
    endif()
  endif()
endfunction()
