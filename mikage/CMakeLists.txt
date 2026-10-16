# RenPyRuntime.framework: Ren'Py as an engine inside Mikage's iOS app.
#
# The framework holds CPython 3.12 (static), every Ren'Py Cython module (as
# built-in modules, from the C that `setup.py generate` writes), pyobjus, and
# the Mikage bridge. Python code (the standard library, Ren'Py's own Python
# and its common/ files) is copied into the framework's base/ folder by
# Mikage's scripts/build-renpy-ios.sh after this builds.
#
# SDL3 is the one SDL3.framework Mikage embeds; its OpenGL ES windows run on
# MetalANGLE, which Ren'Py's GL headers also come from.
cmake_minimum_required(VERSION 3.24)
project(RenPyRuntime LANGUAGES C CXX OBJC OBJCXX ASM)

if(NOT CMAKE_SYSTEM_NAME STREQUAL "iOS")
  message(FATAL_ERROR "RenPyRuntime builds an iOS framework; configure with -DCMAKE_SYSTEM_NAME=iOS")
endif()

get_filename_component(RENPY_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/.." ABSOLUTE)

set(RENPY_PYTHON_PREFIX "" CACHE PATH "CPython 3.12 built for this SDK (include/python3.12, libpython3.12.a)")
set(RENPY_DEPS_PREFIX "" CACHE PATH "vcpkg installed tree for this SDK's triplet")
set(RENPY_FFMPEG_ROOT "" CACHE PATH "Prefix with FFmpeg's headers and static libraries for this SDK")
set(RENPY_SDL3_FRAMEWORK "" CACHE PATH "The SDL3.framework Mikage embeds (for this SDK)")
set(RENPY_METALANGLE_FRAMEWORK "" CACHE PATH "MetalANGLE.framework (for this SDK)")
set(RENPY_PYOBJUS_DIR "" CACHE PATH "Directory with the Cython output pyobjus.c and _runtime.h")
set(RENPY_VERSION_STRING "unknown" CACHE STRING "The Ren'Py version, such as 8.6.0")

file(GLOB_RECURSE RENPY_PYTHON_HEADER "${RENPY_PYTHON_PREFIX}/include/python3.12/Python.h")
if(NOT RENPY_PYTHON_HEADER)
  message(FATAL_ERROR "RENPY_PYTHON_PREFIX has no Python 3.12 headers: '${RENPY_PYTHON_PREFIX}'")
endif()
file(GLOB_RECURSE RENPY_PYTHON_LIBRARY "${RENPY_PYTHON_PREFIX}/lib/libpython3.12.a")
if(NOT RENPY_PYTHON_LIBRARY)
  file(GLOB_RECURSE RENPY_PYTHON_LIBRARY "${RENPY_PYTHON_PREFIX}/lib/python3.12/config-*/libpython3.12.a")
endif()
if(NOT RENPY_PYTHON_LIBRARY)
  message(FATAL_ERROR "RENPY_PYTHON_PREFIX has no libpython3.12.a: '${RENPY_PYTHON_PREFIX}'")
endif()
list(GET RENPY_PYTHON_LIBRARY 0 RENPY_PYTHON_LIBRARY)
foreach(required
    "${RENPY_DEPS_PREFIX}/include/ft2build.h;freetype"
    "${RENPY_DEPS_PREFIX}/include/harfbuzz/hb.h;harfbuzz"
    "${RENPY_DEPS_PREFIX}/include/fribidi/fribidi.h;fribidi"
    "${RENPY_DEPS_PREFIX}/include/SDL3_image/SDL_image.h;sdl3-image"
    "${RENPY_DEPS_PREFIX}/include/assimp/cimport.h;assimp"
    "${RENPY_DEPS_PREFIX}/include/ffi.h;libffi"
    "${RENPY_FFMPEG_ROOT}/include/libavformat/avformat.h;FFmpeg"
    "${RENPY_SDL3_FRAMEWORK}/Headers/SDL.h;SDL3.framework"
    "${RENPY_METALANGLE_FRAMEWORK}/Headers/GLES3/gl3.h;MetalANGLE.framework"
    "${RENPY_PYOBJUS_DIR}/pyobjus.c;pyobjus")
  list(GET required 0 path)
  list(GET required 1 name)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR "${name} is missing: '${path}'")
  endif()
endforeach()
if(NOT EXISTS "${RENPY_ROOT}/src/Setup")
  message(FATAL_ERROR "src/Setup is missing; run `python setup.py generate` in the Ren'Py checkout first.")
endif()

# <SDL3/...> comes from the shared framework, ahead of the copy of SDL's
# headers vcpkg installs with SDL3_image (its libSDL3.a is never linked).
set(RENPY_SDL3_INCLUDE "${CMAKE_CURRENT_BINARY_DIR}/sdl3-include")
file(MAKE_DIRECTORY "${RENPY_SDL3_INCLUDE}")
file(CREATE_LINK "${RENPY_SDL3_FRAMEWORK}/Headers" "${RENPY_SDL3_INCLUDE}/SDL3" SYMBOLIC)
get_filename_component(RENPY_METALANGLE_PARENT "${RENPY_METALANGLE_FRAMEWORK}" DIRECTORY)

# Every module src/Setup lists becomes a built-in. Its Cython C is compiled
# with PyInit_<name> renamed to PyInit_<dotted_name>, as renpy-build does,
# so modules that share a short name (renpy.pygame.display and
# renpy.display) don't collide. Helper C files shared by two modules are
# compiled once.
set(RENPY_MODULES)
set(RENPY_MODULE_SOURCES)
set(seen_objects)
file(STRINGS "${RENPY_ROOT}/src/Setup" setup_lines)
list(APPEND setup_lines "pyobjus.pyobjus ${RENPY_PYOBJUS_DIR}/pyobjus.c")
foreach(line IN LISTS setup_lines)
  string(REGEX REPLACE "#.*$" "" line "${line}")
  string(STRIP "${line}" line)
  if(line STREQUAL "")
    continue()
  endif()
  separate_arguments(parts UNIX_COMMAND "${line}")
  list(POP_FRONT parts module)
  list(APPEND RENPY_MODULES "${module}")
  string(REPLACE "." "_" mangled "${module}")
  string(REGEX REPLACE "^.*\\." "" short "${module}")
  foreach(source IN LISTS parts)
    if(NOT IS_ABSOLUTE "${source}")
      get_filename_component(source "${RENPY_ROOT}/src/${source}" ABSOLUTE)
    endif()
    get_filename_component(object "${source}" NAME_WE)
    if(object IN_LIST seen_objects)
      continue()
    endif()
    list(APPEND seen_objects "${object}")
    list(APPEND RENPY_MODULE_SOURCES "${source}")
    set_source_files_properties("${source}" PROPERTIES
      COMPILE_DEFINITIONS "PyInit_${short}=PyInit_${mangled}")
  endforeach()
endforeach()

set(inittab "${CMAKE_CURRENT_BINARY_DIR}/mikage_renpy_inittab.c")
set(inittab_text "// Generated by mikage/CMakeLists.txt from src/Setup.\n#include <Python.h>\n\n")
foreach(module IN LISTS RENPY_MODULES)
  string(REPLACE "." "_" mangled "${module}")
  string(APPEND inittab_text "PyMODINIT_FUNC PyInit_${mangled}(void);\n")
endforeach()
string(APPEND inittab_text "\nstatic struct _inittab inittab[] = {\n")
foreach(module IN LISTS RENPY_MODULES)
  string(REPLACE "." "_" mangled "${module}")
  string(APPEND inittab_text "    {\"${module}\", PyInit_${mangled}},\n")
endforeach()
string(APPEND inittab_text "    {NULL, NULL},\n};\n\nvoid mikage_renpy_extend_inittab(void)\n{\n    PyImport_ExtendInittab(inittab);\n}\n")
file(CONFIGURE OUTPUT "${inittab}" CONTENT "${inittab_text}" @ONLY)

add_library(RenPyRuntime SHARED
  ${RENPY_MODULE_SOURCES}
  "${inittab}"
  MikageRenPyRuntime.mm
  MikageRenPyFiber.S
  MikageRenPyRuntime.h
  MikageRenPyHooks.h)

target_include_directories(RenPyRuntime PRIVATE
  "${RENPY_SDL3_INCLUDE}"
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${RENPY_ROOT}/src"
  "${RENPY_ROOT}/tmp/gen"
  "${RENPY_PYOBJUS_DIR}"
  "${RENPY_PYTHON_PREFIX}/include/python3.12"
  "${RENPY_FFMPEG_ROOT}/include"
  "${RENPY_DEPS_PREFIX}/include"
  "${RENPY_DEPS_PREFIX}/include/freetype2"
  "${RENPY_DEPS_PREFIX}/include/harfbuzz"
  "${RENPY_DEPS_PREFIX}/include/fribidi")
target_compile_definitions(RenPyRuntime PRIVATE
  RENPY_MIKAGE=1
  # display.pyx includes SDL_main.h; Mikage owns main().
  SDL_MAIN_HANDLED=1
  OBJC_OLD_DISPATCH_PROTOTYPES=1
  "MIKAGE_RENPY_VERSION=\"${RENPY_VERSION_STRING}\"")
target_compile_options(RenPyRuntime PRIVATE
  "-F${RENPY_METALANGLE_PARENT}"
  $<$<COMPILE_LANGUAGE:C>:-Wno-unused-function -Wno-unreachable-code -Wno-deprecated-declarations
    -Wno-incompatible-function-pointer-types -Wno-int-conversion>)
# Ren'Py's own C (not pyobjus, not the bridge) reaches SDL's waits and swaps
# through the hooks, so the bridge can hand control back to the app. Joined
# -include, since Xcode passes per-source options through without SHELL:.
foreach(source IN LISTS RENPY_MODULE_SOURCES)
  if(NOT source MATCHES "pyobjus\\.c$")
    set_property(SOURCE "${source}" APPEND PROPERTY COMPILE_OPTIONS
      "-include${CMAKE_CURRENT_SOURCE_DIR}/MikageRenPyHooks.h")
  endif()
endforeach()
set_source_files_properties(MikageRenPyRuntime.mm PROPERTIES COMPILE_OPTIONS "-fobjc-arc")

# Every static library vcpkg installed for this SDK except its own SDL3.
file(GLOB RENPY_DEPS_LIBRARIES "${RENPY_DEPS_PREFIX}/lib/*.a")
list(FILTER RENPY_DEPS_LIBRARIES EXCLUDE REGEX "/libSDL3(_test)?\\.a$")
set(RENPY_FFMPEG_LIBRARIES)
foreach(name avformat avcodec swresample swscale avutil)
  if(NOT EXISTS "${RENPY_FFMPEG_ROOT}/lib/lib${name}.a")
    message(FATAL_ERROR "FFmpeg library missing: ${RENPY_FFMPEG_ROOT}/lib/lib${name}.a")
  endif()
  list(APPEND RENPY_FFMPEG_LIBRARIES "${RENPY_FFMPEG_ROOT}/lib/lib${name}.a")
endforeach()

target_link_libraries(RenPyRuntime PRIVATE
  "${RENPY_PYTHON_LIBRARY}"
  ${RENPY_FFMPEG_LIBRARIES}
  ${RENPY_DEPS_LIBRARIES}
  "${RENPY_SDL3_FRAMEWORK}"
  "-F${RENPY_METALANGLE_PARENT}"
  "-framework MetalANGLE"
  iconv
  "-framework Foundation"
  "-framework UIKit"
  "-framework AVFoundation"
  "-framework AudioToolbox"
  "-framework CoreAudio"
  "-framework CoreFoundation"
  "-framework CoreMedia"
  "-framework CoreVideo"
  "-framework VideoToolbox"
  "-framework Security"
  "-framework SystemConfiguration"
  "-Wl,-exported_symbols_list,${CMAKE_CURRENT_SOURCE_DIR}/exported_symbols.txt")

set_target_properties(RenPyRuntime PROPERTIES
  FRAMEWORK TRUE
  PUBLIC_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/MikageRenPyRuntime.h"
  MACOSX_FRAMEWORK_IDENTIFIER "moe.cheney233.mikage.renpy-runtime"
  XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "moe.cheney233.mikage.renpy-runtime"
  XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED "NO"
  XCODE_ATTRIBUTE_DEFINES_MODULE "YES"
  XCODE_ATTRIBUTE_CLANG_ENABLE_MODULES "YES"
  XCODE_ATTRIBUTE_MODULEMAP_FILE "${CMAKE_CURRENT_SOURCE_DIR}/module.modulemap"
  XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2"
  XCODE_ATTRIBUTE_GCC_C_LANGUAGE_STANDARD "gnu11"
  XCODE_ATTRIBUTE_CLANG_CXX_LANGUAGE_STANDARD "c++17"
  XCODE_ATTRIBUTE_LD_DYLIB_INSTALL_NAME "@rpath/RenPyRuntime.framework/RenPyRuntime"
  XCODE_ATTRIBUTE_LD_RUNPATH_SEARCH_PATHS "@executable_path/Frameworks @loader_path/..")
