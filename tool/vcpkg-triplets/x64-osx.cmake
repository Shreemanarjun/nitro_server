# Overrides vcpkg's built-in x64-osx: static deps with a pinned macOS floor, so
# the prebuilt loads on macOS 14+ whatever runner builds it (release.yml).
set(VCPKG_TARGET_ARCHITECTURE x64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME Darwin)
set(VCPKG_OSX_ARCHITECTURES x86_64)
set(VCPKG_OSX_DEPLOYMENT_TARGET 14.0)
