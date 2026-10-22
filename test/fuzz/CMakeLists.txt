# libFuzzer targets for the engine (clang only). Driven by tool/fuzz.sh:
#   cmake -S test/fuzz -B build/fuzz -DCMAKE_CXX_COMPILER=clang++
cmake_minimum_required(VERSION 3.10)
project(nitro_server_fuzz LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(SRC "${CMAKE_CURRENT_SOURCE_DIR}/../../src")

# Parser/codec fuzzers: just the head parser and the WS frame decoder, no I/O.
# WsCodec is header-only and parseMethod is inline in Common.h, so only the
# head parser's TU is linked (and nothing that pulls in the libuv reactor).
foreach(target head_fuzz ws_frame_fuzz)
  add_executable(${target}
    ${target}.cpp
    "${SRC}/engine/HttpParse.cpp"
  )
  target_include_directories(${target} PRIVATE
    "${SRC}" "${SRC}/engine" "${SRC}/../lib/src/generated/cpp" "${SRC}/native")
  target_compile_options(${target} PRIVATE
    -fsanitize=fuzzer,address -fno-omit-frame-pointer -g -O1)
  target_link_options(${target} PRIVATE -fsanitize=fuzzer,address)
  target_link_libraries(${target} PRIVATE pthread)
endforeach()

# server_fuzz drives a live libuv reactor over a real socket, so it needs the
# reactor TU and libuv. Skipped when libuv is absent (find it Homebrew-off-path).
find_library(FUZZ_LIBUV NAMES uv libuv
  HINTS /opt/homebrew/lib /usr/local/lib /opt/homebrew/opt/libuv/lib /usr/local/opt/libuv/lib)
find_path(FUZZ_LIBUV_INCLUDE uv.h
  HINTS /opt/homebrew/include /usr/local/include /opt/homebrew/opt/libuv/include /usr/local/opt/libuv/include)
if(FUZZ_LIBUV AND FUZZ_LIBUV_INCLUDE)
  add_executable(server_fuzz
    server_fuzz.cpp
    "${SRC}/engine/Router.cpp"
    "${SRC}/engine/HttpParse.cpp"
    "${SRC}/engine/EngineRegistry.cpp"
    "${SRC}/engine/UvReactor.cpp"
  )
  target_include_directories(server_fuzz PRIVATE
    "${SRC}" "${SRC}/engine" "${SRC}/../lib/src/generated/cpp" "${SRC}/native"
    "${FUZZ_LIBUV_INCLUDE}")
  target_compile_definitions(server_fuzz PRIVATE NITRO_SERVER_LIBUV=1)
  target_compile_options(server_fuzz PRIVATE
    -fsanitize=fuzzer,address -fno-omit-frame-pointer -g -O1)
  target_link_options(server_fuzz PRIVATE -fsanitize=fuzzer,address)
  target_link_libraries(server_fuzz PRIVATE pthread "${FUZZ_LIBUV}")
else()
  message(WARNING "libuv not found — skipping server_fuzz (parser fuzzers still build)")
endif()
