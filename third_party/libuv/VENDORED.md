libuv v1.52.1, vendored for the Android/iOS builds of the engine (hook/build.dart
compiles it from these sources; desktop builds use the system/vcpkg libuv).

- source: https://github.com/libuv/libuv/archive/refs/tags/v1.52.1.tar.gz
- sha256: 478baf2599bfbc882c355288c9cb6f92e0e7dda435fa04031fa5b607cf3f414c
- kept: include/, src/, LICENSE*, CMakeLists.txt (reference for the source lists);
  dropped: tests, docs, build scripts.
