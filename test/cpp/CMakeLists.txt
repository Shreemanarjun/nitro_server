# C++ engine test suite (GoogleTest, desktop only, opt-in via
# -DNITRO_SERVER_BUILD_TESTS=ON). Mirrors nitro_http's test/cpp.
cmake_minimum_required(VERSION 3.10)
project(nitro_server_engine_tests LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

include(FetchContent)
FetchContent_Declare(
  googletest
  URL https://github.com/google/googletest/archive/v1.14.0.zip
)
set(gtest_force_shared_crt ON CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(googletest)

add_executable(nitro_server_engine_tests
  router_test.cpp
  pending_table_test.cpp
  combiner_test.cpp
  engine_units_test.cpp
  wire_test.cpp
  server_test.cpp
  "${CMAKE_CURRENT_SOURCE_DIR}/../../src/engine/Router.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../src/engine/ServerInstance.cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../src/engine/EngineRegistry.cpp"
)

target_include_directories(nitro_server_engine_tests PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../../src"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../src/engine"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../lib/src/generated/cpp"
  "${CMAKE_CURRENT_SOURCE_DIR}/../../src/native"
)

if(WIN32)
  target_compile_definitions(nitro_server_engine_tests PRIVATE
    WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
  target_compile_options(nitro_server_engine_tests PRIVATE /EHsc)
  target_link_libraries(nitro_server_engine_tests PRIVATE
    gtest_main ws2_32)
else()
  target_link_libraries(nitro_server_engine_tests PRIVATE
    gtest_main pthread)
endif()

# -DNITRO_SERVER_SANITIZE=thread|address|undefined: instrumented test build.
set(NITRO_SERVER_SANITIZE "" CACHE STRING "Sanitizer for the engine test build")
if(NITRO_SERVER_SANITIZE)
  target_compile_options(nitro_server_engine_tests PRIVATE
    -fsanitize=${NITRO_SERVER_SANITIZE} -fno-omit-frame-pointer -g -O1)
  target_link_options(nitro_server_engine_tests PRIVATE
    -fsanitize=${NITRO_SERVER_SANITIZE})
endif()

# -DNITRO_SERVER_COVERAGE=ON: clang source-based coverage for tool/cpp_coverage.sh.
option(NITRO_SERVER_COVERAGE "Instrument the engine test build for llvm-cov" OFF)
if(NITRO_SERVER_COVERAGE)
  target_compile_options(nitro_server_engine_tests PRIVATE
    -fprofile-instr-generate -fcoverage-mapping -O0 -g)
  target_link_options(nitro_server_engine_tests PRIVATE -fprofile-instr-generate)
endif()

# TLS: link OpenSSL and define NITRO_SERVER_TLS when found (Homebrew off-path).
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
  target_link_libraries(nitro_server_engine_tests PRIVATE OpenSSL::SSL OpenSSL::Crypto)
  target_compile_definitions(nitro_server_engine_tests PRIVATE NITRO_SERVER_TLS=1)
endif()

include(GoogleTest)
gtest_discover_tests(nitro_server_engine_tests)
