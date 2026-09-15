// Unity translation unit for Apple platforms (CocoaPods/SwiftPM glob a single
// forwarded TU). CMake platforms compile each source separately instead — see
// engine.cmake. Keep this list identical to NITRO_SERVER_ENGINE_SOURCES.
#include "Router.cpp"
#include "HttpParse.cpp"
#include "EngineRegistry.cpp"
#include "UvReactor.cpp"  // compiles to nothing unless NITRO_SERVER_LIBUV
