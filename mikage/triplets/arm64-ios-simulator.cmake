set(VCPKG_TARGET_ARCHITECTURE arm64)
set(VCPKG_CRT_LINKAGE dynamic)
set(VCPKG_LIBRARY_LINKAGE static)
set(VCPKG_CMAKE_SYSTEM_NAME iOS)
set(VCPKG_OSX_SYSROOT iphonesimulator)
set(VCPKG_OSX_DEPLOYMENT_TARGET 13.0)
# Mikage only links the Release framework. Avoid building an unused Debug
# variant of each dependency in the iOS CI path.
set(VCPKG_BUILD_TYPE release)
# libffi's configure must see a cross build: vcpkg passes the same
# aarch64-apple-darwin for --host and --build on Apple Silicon. This is the
# host renpy-build uses for libffi on iOS.
if(PORT STREQUAL "libffi")
    set(VCPKG_MAKE_BUILD_TRIPLET "--host=aarch64-ios-darwin21")
endif()
