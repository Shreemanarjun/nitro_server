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

include(GoogleTest)
gtest_discover_tests(nitro_server_engine_tests)
