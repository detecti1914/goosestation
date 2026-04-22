#!/usr/bin/env bash
# Patch: latest → HEAD
# M = smart ed (indent→s, del→d, add→a), A = copy file, D = rm
set -e
echo 'GOOSIFYING...'

# Rewrite: CMakeLists.txt
rm -f 'CMakeLists.txt'
cat > 'CMakeLists.txt' <<'PATCHEND'
# SPDX-License-Identifier: GPL-2.0-or-later
# GooseStation libretro top-level CMake. Independent build entry point so that
# upstream's restrictively-licensed CMakeLists.txt is never modified.

cmake_minimum_required(VERSION 3.19)
project(goosestation C CXX)

cmake_policy(SET CMP0069 NEW)
set(CMAKE_POLICY_DEFAULT_CMP0069 NEW)

if(${CMAKE_SOURCE_DIR} STREQUAL ${CMAKE_BINARY_DIR})
  message(FATAL_ERROR "In-tree builds are not supported. Use cmake -B <dir>.")
endif()

if(NOT CMAKE_BUILD_TYPE MATCHES "Debug|Devel|MinSizeRel|RelWithDebInfo|Release")
  message(FATAL_ERROR "CMAKE_BUILD_TYPE not set. Please set it first.")
endif()

set(CMAKE_MODULE_PATH "${CMAKE_SOURCE_DIR}/CMakeModules/" "${CMAKE_SOURCE_DIR}/cmake/")

set(BUILD_LIBRETRO ON CACHE BOOL "Build the GooseStation libretro core" FORCE)

include(DuckStationUtils)

detect_operating_system()
detect_compiler()
detect_architecture()
detect_page_size()
detect_cache_line_size()

include(DuckStationBuildOptions)
include(GooseStationDependencies)
include(DuckStationCompilerRequirement)

if(LINUX OR BSD OR ANDROID)
  include(CheckPIESupported)
  check_pie_supported()
  set(CMAKE_POSITION_INDEPENDENT_CODE TRUE)
endif()

if(COMPILER_CLANG OR COMPILER_GCC)
  include(CheckCXXFlag)
  check_cxx_flag(-Wall COMPILER_SUPPORTS_WALL)
  check_cxx_flag(-Wno-invalid-offsetof COMPILER_SUPPORTS_OFFSETOF)
endif()

set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fno-exceptions -fno-rtti")

if("${CMAKE_BUILD_TYPE}" STREQUAL "Release" AND (COMPILER_CLANG OR COMPILER_GCC))
  file(RELATIVE_PATH source_dir_remap "${CMAKE_BINARY_DIR}" "${CMAKE_SOURCE_DIR}")
  string(REGEX REPLACE "\/+$" "" source_dir_remap "${source_dir_remap}")
  set(source_dir_remap_str "\"${CMAKE_SOURCE_DIR}\"=\"${source_dir_remap}\"")
  set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -ffile-prefix-map=${source_dir_remap_str}")
  set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -ffile-prefix-map=${source_dir_remap_str}")
endif()

set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}/bin")

if(CMAKE_SIZEOF_VOID_P EQUAL 4)
  add_definitions("-D_FILE_OFFSET_BITS=64")
endif()

add_subdirectory(dep)
add_subdirectory(src)
PATCHEND
# Modify: CMakeModules/DuckStationBuildSummary.cmake
ed -s 'CMakeModules/DuckStationBuildSummary.cmake' <<'PATCHEND'
24,41d
wq
PATCHEND
# Modify: CMakeModules/DuckStationUtils.cmake
ed -s 'CMakeModules/DuckStationUtils.cmake' <<'PATCHEND'
27a
	elseif(ANDROID)
		message(STATUS "Building for Android.")
.
wq
PATCHEND
mkdir -p 'CMakeModules'
# Add: CMakeModules/GooseAndroidDepsAliases.cmake
cat > 'CMakeModules/GooseAndroidDepsAliases.cmake' <<'PATCHEND'
# Android libretro build: synthesize targets that build-android-deps.sh doesn't
# provide (deps are built static-only, and upstream shaderc ships no CMake
# config at all).

if(NOT BUILD_LIBRETRO)
  return()
endif()
if(NOT (ANDROID OR (WIN32 AND NOT MSVC)))
  return()
endif()

if(TARGET zstd::libzstd_static AND NOT TARGET zstd::libzstd_shared)
  add_library(zstd::libzstd_shared INTERFACE IMPORTED)
  set_target_properties(zstd::libzstd_shared PROPERTIES
    INTERFACE_LINK_LIBRARIES "zstd::libzstd_static")
endif()

if(TARGET libjpeg-turbo::jpeg-static AND NOT TARGET libjpeg-turbo::jpeg)
  add_library(libjpeg-turbo::jpeg INTERFACE IMPORTED)
  set_target_properties(libjpeg-turbo::jpeg PROPERTIES
    INTERFACE_LINK_LIBRARIES "libjpeg-turbo::jpeg-static")
endif()

if(ENABLE_VULKAN AND NOT TARGET Shaderc::shaderc_shared)
  find_path(_shaderc_inc shaderc/shaderc.hpp
            HINTS ${CMAKE_PREFIX_PATH} PATH_SUFFIXES include REQUIRED)
  find_library(_shaderc_lib shaderc_shared
               HINTS ${CMAKE_PREFIX_PATH} PATH_SUFFIXES lib REQUIRED)
  add_library(Shaderc::shaderc_shared SHARED IMPORTED)
  set_target_properties(Shaderc::shaderc_shared PROPERTIES
    IMPORTED_LOCATION "${_shaderc_lib}"
    INTERFACE_INCLUDE_DIRECTORIES "${_shaderc_inc}"
    INTERFACE_COMPILE_DEFINITIONS "SHADERC_SHAREDLIB")
  unset(_shaderc_inc CACHE)
  unset(_shaderc_lib CACHE)
endif()
PATCHEND
mkdir -p 'CMakeModules'
# Add: CMakeModules/GooseLibretroLinking.cmake
cat > 'CMakeModules/GooseLibretroLinking.cmake' <<'PATCHEND'
# Static-link shaderc and spirv-cross into libretro cores on Android and on
# Windows mingw. dlopen is impractical on Android (RetroArch loads cores with
# RTLD_LOCAL, Play Store sandbox makes shipping extra .so files awkward); on
# Windows nobody installs shaderc/spirv-cross system-wide, so the same logic
# applies — bake them into the .dll.

if(NOT BUILD_LIBRETRO)
  return()
endif()
if(NOT (ANDROID OR (WIN32 AND NOT MSVC)))
  return()
endif()

# shaderc_combined.a bundles shaderc + SPIRV-Tools + glslang into one archive.
find_library(SHADERC_COMBINED_LIB shaderc_combined HINTS "${CMAKE_PREFIX_PATH}" PATH_SUFFIXES lib)
if(SHADERC_COMBINED_LIB)
  target_link_libraries(util PRIVATE ${SHADERC_COMBINED_LIB})
else()
  message(WARNING "shaderc_combined not found, falling back to shared")
  target_link_libraries(util PRIVATE Shaderc::shaderc_shared)
endif()

# spirv-cross: prefer static libs if available, otherwise fall back to shared.
find_library(SPIRV_CROSS_C_STATIC spirv-cross-c HINTS "${CMAKE_PREFIX_PATH}" PATH_SUFFIXES lib)
if(SPIRV_CROSS_C_STATIC)
  # spirv-cross-c depends on spirv-cross-glsl, -hlsl, -msl, -cpp, -reflect, -core.
  foreach(_comp core reflect cpp glsl hlsl msl)
    find_library(_lib spirv-cross-${_comp} HINTS "${CMAKE_PREFIX_PATH}" PATH_SUFFIXES lib)
    if(_lib)
      list(APPEND _spirv_cross_libs ${_lib})
    endif()
    unset(_lib CACHE)
  endforeach()
  target_link_libraries(util PRIVATE ${SPIRV_CROSS_C_STATIC} ${_spirv_cross_libs})
else()
  target_link_libraries(util PRIVATE spirv-cross-c-shared)
endif()
PATCHEND
mkdir -p 'CMakeModules'
# Add: CMakeModules/GooseStationDependencies.cmake
cat > 'CMakeModules/GooseStationDependencies.cmake' <<'PATCHEND'
# SPDX-License-Identifier: GPL-2.0-or-later
# Libretro-only dependency resolution. All libs come from the system, not bundled.

set(THREADS_PREFER_PTHREAD_FLAG ON)
find_package(Threads REQUIRED)

if(NOT WIN32 AND NOT APPLE AND NOT ANDROID)
  find_package(PkgConfig REQUIRED)
endif()

find_package(PNG REQUIRED)
find_package(ZLIB REQUIRED)
find_package(zstd REQUIRED)
find_package(WebP REQUIRED)
find_package(libjpeg-turbo REQUIRED)
find_package(cpuinfo REQUIRED)

if(ENABLE_VULKAN)
  if(NOT ANDROID)
    find_package(Shaderc REQUIRED)
  endif()
  # Android builds spirv-cross statically (linked into the core); desktop uses
  # the shared lib (loaded via dlopen at runtime). Try shared first, fall back
  # to static. src/util/CMakeLists.txt already handles either target.
  find_package(spirv_cross_c_shared QUIET)
  if(NOT spirv_cross_c_shared_FOUND)
    # Static spirv-cross: spirv_cross_c imports the spirv-cross-c target which
    # references siblings (glsl/hlsl/msl/cpp/reflect/core). Each ships its own
    # cmake config; we have to load all so the imported targets resolve.
    foreach(_spvc_comp core glsl hlsl msl cpp reflect c)
      find_package(spirv_cross_${_spvc_comp} REQUIRED)
    endforeach()
  endif()
endif()

if(LINUX)
  find_package(UDEV REQUIRED)
endif()

if(NOT FFMPEG_FOUND)
  set(FFMPEG_INCLUDE_DIRS "${CMAKE_SOURCE_DIR}/dep/ffmpeg/include")
endif()

include("${CMAKE_SOURCE_DIR}/CMakeModules/GooseAndroidDepsAliases.cmake")
PATCHEND
mkdir -p 'cmake'
# Add: cmake/FindPNG.cmake
cat > 'cmake/FindPNG.cmake' <<'PATCHEND'
# FindPNG.cmake — pkg-config wrapper for GooseStation libretro builds
# DuckStation expects PNG::PNG target

find_package(PkgConfig REQUIRED)
pkg_check_modules(PC_PNG REQUIRED IMPORTED_TARGET libpng)

add_library(PNG::PNG INTERFACE IMPORTED)
set_target_properties(PNG::PNG PROPERTIES
    INTERFACE_INCLUDE_DIRECTORIES "${PC_PNG_INCLUDE_DIRS}"
    INTERFACE_LINK_LIBRARIES "${PC_PNG_LIBRARIES}"
    INTERFACE_LINK_DIRECTORIES "${PC_PNG_LIBRARY_DIRS}"
)
mark_as_advanced(PC_PNG_INCLUDE_DIRS PC_PNG_LIBRARIES)
PATCHEND
mkdir -p 'cmake'
# Add: cmake/FindShaderc.cmake
cat > 'cmake/FindShaderc.cmake' <<'PATCHEND'
# Findshaderc.cmake — pkg-config wrapper for GooseStation libretro builds
# DuckStation expects Shaderc::shaderc_shared target

find_package(PkgConfig REQUIRED)
pkg_check_modules(PC_shaderc REQUIRED IMPORTED_TARGET shaderc)

find_library(shaderc_LIBRARY NAMES shaderc_shared
             HINTS ${PC_shaderc_LIBRARY_DIRS})

add_library(Shaderc::shaderc_shared UNKNOWN IMPORTED)
set_target_properties(Shaderc::shaderc_shared PROPERTIES
    IMPORTED_LOCATION "${shaderc_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${PC_shaderc_INCLUDE_DIRS}"
    INTERFACE_COMPILE_DEFINITIONS "SHADERC_SHAREDLIB"
)
mark_as_advanced(shaderc_LIBRARY)
PATCHEND
mkdir -p 'cmake'
# Add: cmake/FindWebP.cmake
cat > 'cmake/FindWebP.cmake' <<'PATCHEND'
# FindWebP.cmake — pkg-config wrapper for GooseStation libretro builds
# DuckStation expects WebP::webp target

find_package(PkgConfig REQUIRED)
pkg_check_modules(PC_WebP REQUIRED IMPORTED_TARGET libwebp)

find_library(WebP_LIBRARY NAMES webp
             HINTS ${PC_WebP_LIBRARY_DIRS})
find_library(SharpYuv_LIBRARY NAMES sharpyuv
             HINTS ${PC_WebP_LIBRARY_DIRS})

add_library(WebP::webp UNKNOWN IMPORTED)
set_target_properties(WebP::webp PROPERTIES
    IMPORTED_LOCATION "${WebP_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${PC_WebP_INCLUDE_DIRS}"
)
if(SharpYuv_LIBRARY)
    set_target_properties(WebP::webp PROPERTIES
        INTERFACE_LINK_LIBRARIES "${SharpYuv_LIBRARY}"
    )
endif()
mark_as_advanced(WebP_LIBRARY SharpYuv_LIBRARY)
PATCHEND
mkdir -p 'cmake'
# Add: cmake/Findcpuinfo.cmake
cat > 'cmake/Findcpuinfo.cmake' <<'PATCHEND'
# Findcpuinfo.cmake — pkg-config wrapper for GooseStation libretro builds
# DuckStation expects cpuinfo::cpuinfo target

find_package(PkgConfig REQUIRED)
pkg_check_modules(PC_cpuinfo REQUIRED IMPORTED_TARGET libcpuinfo)

find_library(cpuinfo_LIBRARY NAMES cpuinfo
             HINTS ${PC_cpuinfo_LIBRARY_DIRS})

add_library(cpuinfo::cpuinfo UNKNOWN IMPORTED)
set_target_properties(cpuinfo::cpuinfo PROPERTIES
    IMPORTED_LOCATION "${cpuinfo_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${PC_cpuinfo_INCLUDE_DIRS}"
)
mark_as_advanced(cpuinfo_LIBRARY)
PATCHEND
mkdir -p 'cmake'
# Add: cmake/Findlibjpeg-turbo.cmake
cat > 'cmake/Findlibjpeg-turbo.cmake' <<'PATCHEND'
# Findlibjpeg-turbo.cmake — pkg-config wrapper for GooseStation libretro builds
# DuckStation expects libjpeg-turbo::jpeg target

find_package(PkgConfig REQUIRED)
pkg_check_modules(PC_libjpeg REQUIRED IMPORTED_TARGET libjpeg)

find_library(libjpeg_LIBRARY NAMES jpeg
             HINTS ${PC_libjpeg_LIBRARY_DIRS})

add_library(libjpeg-turbo::jpeg UNKNOWN IMPORTED)
set_target_properties(libjpeg-turbo::jpeg PROPERTIES
    IMPORTED_LOCATION "${libjpeg_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${PC_libjpeg_INCLUDE_DIRS}"
)
mark_as_advanced(libjpeg_LIBRARY)
PATCHEND
mkdir -p 'cmake'
# Add: cmake/Findspirv_cross_c_shared.cmake
cat > 'cmake/Findspirv_cross_c_shared.cmake' <<'PATCHEND'
# Findspirv_cross_c_shared.cmake — pkg-config wrapper for GooseStation libretro builds.
# DuckStation expects the spirv-cross-c-shared target (note hyphens). When the
# shared library isn't installed (e.g. our mingw deps build static-only),
# report not-found and let GooseStationDependencies.cmake fall back to the
# per-component static spirv_cross_* configs.

find_package(PkgConfig QUIET)
if(NOT PKG_CONFIG_FOUND)
  set(spirv_cross_c_shared_FOUND FALSE)
  return()
endif()

pkg_check_modules(PC_spirv_cross QUIET IMPORTED_TARGET spirv-cross-c-shared)
if(NOT PC_spirv_cross_FOUND)
  set(spirv_cross_c_shared_FOUND FALSE)
  return()
endif()

find_library(spirv_cross_LIBRARY NAMES spirv-cross-c-shared
             HINTS ${PC_spirv_cross_LIBRARY_DIRS})
if(NOT spirv_cross_LIBRARY)
  set(spirv_cross_c_shared_FOUND FALSE)
  return()
endif()

add_library(spirv-cross-c-shared UNKNOWN IMPORTED)
set_target_properties(spirv-cross-c-shared PROPERTIES
    IMPORTED_LOCATION "${spirv_cross_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${PC_spirv_cross_INCLUDE_DIRS}"
)
set(spirv_cross_c_shared_FOUND TRUE)
mark_as_advanced(spirv_cross_LIBRARY)
PATCHEND
mkdir -p 'cmake'
# Add: cmake/Findzstd.cmake
cat > 'cmake/Findzstd.cmake' <<'PATCHEND'
# Findzstd.cmake — pkg-config wrapper for GooseStation libretro builds
# DuckStation expects zstd::libzstd_shared target

find_package(PkgConfig REQUIRED)
pkg_check_modules(PC_zstd REQUIRED IMPORTED_TARGET libzstd)

find_library(zstd_LIBRARY NAMES zstd
             HINTS ${PC_zstd_LIBRARY_DIRS})

add_library(zstd::libzstd_shared UNKNOWN IMPORTED)
set_target_properties(zstd::libzstd_shared PROPERTIES
    IMPORTED_LOCATION "${zstd_LIBRARY}"
    INTERFACE_INCLUDE_DIRECTORIES "${PC_zstd_INCLUDE_DIRS}"
)
mark_as_advanced(zstd_LIBRARY)
PATCHEND
mkdir -p 'cmake/lib/cmake/PNG'
# Add: cmake/lib/cmake/PNG/PNGConfig.cmake
cat > 'cmake/lib/cmake/PNG/PNGConfig.cmake' <<'PATCHEND'
get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
include("${CMAKE_CURRENT_LIST_DIR}/../../../FindPNG.cmake")
PATCHEND
mkdir -p 'cmake/lib/cmake/Shaderc'
# Add: cmake/lib/cmake/Shaderc/ShadercConfig.cmake
cat > 'cmake/lib/cmake/Shaderc/ShadercConfig.cmake' <<'PATCHEND'
get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
include("${CMAKE_CURRENT_LIST_DIR}/../../../Findshaderc.cmake")
PATCHEND
mkdir -p 'cmake/lib/cmake/WebP'
# Add: cmake/lib/cmake/WebP/WebPConfig.cmake
cat > 'cmake/lib/cmake/WebP/WebPConfig.cmake' <<'PATCHEND'
get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
include("${CMAKE_CURRENT_LIST_DIR}/../../../FindWebP.cmake")
PATCHEND
mkdir -p 'cmake/lib/cmake/cpuinfo'
# Add: cmake/lib/cmake/cpuinfo/cpuinfoConfig.cmake
cat > 'cmake/lib/cmake/cpuinfo/cpuinfoConfig.cmake' <<'PATCHEND'
get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
include("${CMAKE_CURRENT_LIST_DIR}/../../../Findcpuinfo.cmake")
PATCHEND
mkdir -p 'cmake/lib/cmake/spirv_cross_c_shared'
# Add: cmake/lib/cmake/spirv_cross_c_shared/spirv_cross_c_sharedConfig.cmake
cat > 'cmake/lib/cmake/spirv_cross_c_shared/spirv_cross_c_sharedConfig.cmake' <<'PATCHEND'
get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../.." ABSOLUTE)
include("${CMAKE_CURRENT_LIST_DIR}/../../../Findspirv_cross_c_shared.cmake")
PATCHEND
mkdir -p 'cmake/lib/cmake/zstd'
# Add: cmake/lib/cmake/zstd/zstdConfig.cmake
cat > 'cmake/lib/cmake/zstd/zstdConfig.cmake' <<'PATCHEND'
get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../" ABSOLUTE)
include("${CMAKE_CURRENT_LIST_DIR}/../../../Findzstd.cmake")
PATCHEND
# Modify: dep/CMakeLists.txt
ed -s 'dep/CMakeLists.txt' <<'PATCHEND'
21,22s/^/  /
22a
endif()
.
20a
if(NOT BUILD_LIBRETRO)
.
wq
PATCHEND
# Add: goosestation_libretro.info
cat > 'goosestation_libretro.info' <<'PATCHEND'
# Software Information
display_name = "Sony - PlayStation (GooseStation)"
authors = "stenzek"
supported_extensions = "exe|psexe|cue|bin|img|iso|chd|pbp|ecm|mds|psf|m3u"
corename = "GooseStation"
categories = "Emulator"
license = "CC-BY-NC-ND-4.0"
permissions = ""

# Hardware Information
manufacturer = "Sony"
systemname = "PlayStation"
systemid = "playstation"

# Libretro Features
database = "Sony - PlayStation"
display_version = "0.1"
supports_no_game = "false"
hw_render = "true"
required_hw_api = "OpenGL Core >= 3.3 | Vulkan >= 1.0"
is_experimental = "true"
savestate = "true"
savestate_features = "serialized"
input_descriptors = "true"
disk_control = "true"

# BIOS / Firmware
firmware_count = 7
firmware0_desc = "psxonpsp660.bin (PSP PS1 BIOS)"
firmware0_path = "psxonpsp660.bin"
firmware0_opt = "true"
firmware1_desc = "scph5500.bin (PS1 JP BIOS)"
firmware1_path = "scph5500.bin"
firmware1_opt = "true"
firmware2_desc = "scph5501.bin (PS1 US BIOS)"
firmware2_path = "scph5501.bin"
firmware2_opt = "true"
firmware3_desc = "scph5502.bin (PS1 EU BIOS)"
firmware3_path = "scph5502.bin"
firmware3_opt = "true"
firmware4_desc = "ps1_rom.bin (PS3 PS1 BIOS)"
firmware4_path = "ps1_rom.bin"
firmware4_opt = "true"
firmware5_desc = "PSX-XBOO.ROM (no$psx bios)"
firmware5_path = "PSX-XBOO.ROM"
firmware5_opt = "true"
firmware6_desc = "PSX-XBOO.ROM-512K (no$psx bios 512K)"
firmware6_path = "PSX-XBOO.ROM-512K"
firmware6_opt = "true"

notes = "(!) psxonpsp660.bin (md5): c53ca5908936d412331790f4426c6c33|(!) scph5500.bin (md5): 8dd7d5296a650fac7319bce665a6a53c|(!) scph5501.bin (md5): 490f666e1afb15b7362b406ed1cea246|(!) scph5502.bin (md5): 32736f17079d0b2b7024407c39bd3050|(!) ps1_rom.bin (md5): 81bbe60ba7a3d1cea1d48c14cbcc647b|(!) PSX-XBOO.ROM (md5): 6d2d7d64d5a6a9dfe86b514f10046313|(!) PSX-XBOO.ROM-512K (md5): fa20b6f2cf54b6825209d6b40ec91c15"

description = "GooseStation is a Sony PlayStation libretro core based on goosified DuckStation. A BIOS ROM image is required."
PATCHEND
# Modify: src/CMakeLists.txt
ed -s 'src/CMakeLists.txt' <<'PATCHEND'
5s/^/  /
7,9s/^/  /
11,13s/^/  /
13a
  endif()
.
4a

if(BUILD_LIBRETRO)
  # Propagate __LIBRETRO__ to all targets so #ifdef guards work in core/util code
  target_compile_definitions(common PUBLIC "__LIBRETRO__=1")
  target_compile_definitions(core PUBLIC "__LIBRETRO__=1")
  target_compile_definitions(util PUBLIC "__LIBRETRO__=1")

  if(NOT MSVC)
    target_compile_options(core PRIVATE -ffunction-sections -fdata-sections)
    target_compile_options(util PRIVATE -ffunction-sections -fdata-sections)
    target_compile_options(scmversion PRIVATE -ffunction-sections -fdata-sections)
  endif()

  add_subdirectory(goosestation-libretro)

  if(NOT MSVC)
    target_link_options(goosestation_libretro PRIVATE -Wl,--gc-sections -Wl,--as-needed)
  endif()
else()
.
wq
PATCHEND
# Modify: src/common/CMakeLists.txt
ed -s 'src/common/CMakeLists.txt' <<'PATCHEND'
88s/^/  /
93,95s/^  //
97,98s/^  //
115s/^/  /
115a
  endif()
.
114a
  if(NOT BUILD_LIBRETRO)
.
99d
96d
95a
elseif(MSVC AND (CPU_ARCH_ARM32 OR CPU_ARCH_ARM64))
.
91,92d
90a
if(WIN32 AND CPU_ARCH_X64)
.
88a
  else()
    # mingw: equivalents of OneCore.lib for VirtualAlloc2/PathCchCanonicalizeEx etc.
    target_link_libraries(common PRIVATE pathcch onecore)
  endif()
.
87a
  if(MSVC)
    target_sources(common PRIVATE
      thirdparty/StackWalker.cpp
      thirdparty/StackWalker.h
    )
.
84,85d
wq
PATCHEND
# Modify: src/common/align.h
ed -s 'src/common/align.h' <<'PATCHEND'
110d
109a
#ifdef _WIN32
.
95d
94a
#ifdef _WIN32
.
12d
11a
#ifdef _WIN32
.
wq
PATCHEND
# Modify: src/common/assert.cpp
ed -s 'src/common/assert.cpp' <<'PATCHEND'
149d
148a
#endif // !defined(__APPLE__) && (!defined(__ANDROID__) || defined(__LIBRETRO__))
.
4d
3a
#if !defined(__APPLE__) && (!defined(__ANDROID__) || defined(__LIBRETRO__))
.
wq
PATCHEND
# Modify: src/common/crash_handler.cpp
ed -s 'src/common/crash_handler.cpp' <<'PATCHEND'
494d
472d
471a
#elif (!defined(__ANDROID__) || defined(__LIBRETRO__))
.
470a
#endif
.
283a
#if defined(__LIBRETRO__)
bool CrashHandler::Install(CleanupHandler) { return false; }
void CrashHandler::SetWriteDirectory(std::string_view) {}
void CrashHandler::WriteDumpForCaller(std::string_view) {}
void CrashHandler::CrashSignalHandler(int, siginfo_t*, void*) {}
#else // !__LIBRETRO__
.
282d
281a
#elif !defined(__APPLE__) && (!defined(__ANDROID__) || defined(__LIBRETRO__))
.
17d
16a
#include <dbghelp.h>
.
13d
12a
#if defined(_WIN32) && !defined(_MSC_VER)

bool CrashHandler::Install(CleanupHandler) { return false; }
void CrashHandler::SetWriteDirectory(std::string_view) {}
void CrashHandler::WriteDumpForCaller(std::string_view) {}

#elif defined(_WIN32)
.
wq
PATCHEND
# Modify: src/common/fastjmp.h
ed -s 'src/common/fastjmp.h' <<'PATCHEND'
14a
#elif defined(_WIN32) && defined(__GNUC__) && defined(__x86_64__)
  static constexpr std::size_t BUF_SIZE = 512;
.
13d
12a
#if defined(_WIN32) && !defined(__GNUC__) && defined(_M_AMD64)
.
wq
PATCHEND
# Modify: src/common/fifo_queue.h
ed -s 'src/common/fifo_queue.h' <<'PATCHEND'
244d
243a
#ifdef _WIN32
.
222d
221a
#ifdef _WIN32
.
11d
10a
#ifdef _WIN32
.
wq
PATCHEND
# Modify: src/common/file_system.cpp
ed -s 'src/common/file_system.cpp' <<'PATCHEND'
2483d
2482a
#elif (!defined(__ANDROID__) || defined(__LIBRETRO__))
.
1093d
1092a
#endif // __ANDROID__ && !__LIBRETRO__
.
268d
267a
#if !defined(__ANDROID__) || defined(__LIBRETRO__)
.
wq
PATCHEND
# Modify: src/common/heap_array.h
ed -s 'src/common/heap_array.h' <<'PATCHEND'
483d
482a
#ifdef _WIN32
.
453d
452a
#ifdef _WIN32
.
130d
129a
#ifdef _WIN32
.
108d
107a
#ifdef _WIN32
.
wq
PATCHEND
# Modify: src/common/memmap.cpp
ed -s 'src/common/memmap.cpp' <<'PATCHEND'
744a
#endif
.
743a
#if !defined(__ANDROID__)
.
718,719d
692d
691a
#if defined(__ANDROID__) && defined(__LIBRETRO__)
  // Android libretro: use memfd_create via syscall (shm_open not available in Bionic)
  const int fd = android_memfd_create(is_anonymous ? "" : name, 0);
  if (fd < 0)
  {
    Error::SetErrno(error, "memfd_create() failed: ", errno);
    return nullptr;
  }
#elif defined(__linux__) || defined(__FreeBSD__)
.
687d
686a
#if !defined(__ANDROID__) || defined(__LIBRETRO__)

#if defined(__ANDROID__) && defined(__LIBRETRO__)
#include <sys/syscall.h>
static int android_memfd_create(const char* name, unsigned int flags)
{
  return static_cast<int>(syscall(__NR_memfd_create, name, flags));
}
#endif
.
142a
  }
.
140,141d
139a
  HMODULE mod = nullptr;
  if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                          reinterpret_cast<LPCWSTR>(&GetBaseAddress), &mod))
  {
.
18d
17a
#include <psapi.h>
.
wq
PATCHEND
# Modify: src/common/threading.cpp
ed -s 'src/common/threading.cpp' <<'PATCHEND'
639a
#elif defined(_WIN32)
  // mingw: no SEH, no-op.
  (void)name;
.
wq
PATCHEND
# Modify: src/common/time_helpers.h
ed -s 'src/common/time_helpers.h' <<'PATCHEND'
15d
14a
#ifdef _WIN32
.
wq
PATCHEND
# Modify: src/core/CMakeLists.txt
ed -s 'src/core/CMakeLists.txt' <<'PATCHEND'
154s/^/  /
209,221d
154a
endif()
.
153a
if(BUILD_LIBRETRO)
  target_sources(core PRIVATE hotkeys_stub.cpp)
  target_link_libraries(core PRIVATE xxhash rapidyaml cpuinfo::cpuinfo speex_resampler_headers)
else()
  target_sources(core PRIVATE hotkeys.cpp)
.
152a
target_include_directories(core PRIVATE "${PROJECT_SOURCE_DIR}/dep/imgui/include")
.
125,126d
117,118d
109,110d
98,99d
84,85d
82d
43,56d
2,4d
wq
PATCHEND
# Modify: src/core/achievements.h
ed -s 'src/core/achievements.h' <<'PATCHEND'
228a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "achievements_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/core'
# Add: src/core/achievements_libretro.h
cat > 'src/core/achievements_libretro.h' <<'PATCHEND'
// Stub achievements for libretro builds — owned by GooseStation.
#pragma once

#include "common/types.h"
#include <functional>
#include <mutex>
#include <string>
#include <string_view>

class CDImage;
class Settings;
class StateWrapper;

namespace Achievements {

inline bool IsHardcoreModeActive() { return false; }
inline bool IsActive() { return false; }
inline void Initialize() {}
inline void Shutdown() {}
inline void IdleUpdate() {}
inline void UpdateSettings(const Settings&) {}
inline void FrameUpdate() {}
inline void OnSystemStarting(CDImage*, bool) {}
inline void OnSystemReset() {}
inline void OnSystemDestroyed() {}
inline void GameChanged(CDImage*) {}
inline void DisableHardcoreMode(bool, bool = false) {}
inline u32 GetGameID() { return 0; }
inline bool HasRichPresence() { return false; }
inline std::string GetRichPresenceString() { return {}; }
inline std::string GetGameIconURL() { return {}; }
inline u32 GetPauseThrottleFrames() { return 0; }
inline bool DoState(StateWrapper&) { return true; }

inline std::unique_lock<std::mutex> GetLock() { return {}; }

using ConfirmHardcoreModeDisableCallback = std::function<void(bool)>;
inline void ConfirmHardcoreModeDisableAsync(std::string_view, ConfirmHardcoreModeDisableCallback cb) { if (cb) cb(true); }

enum class LoginRequestReason : u8
{
  UserInitiated,
  TokenInvalid,
};

} // namespace Achievements

namespace Host {
inline void OnAchievementsLoginRequested(Achievements::LoginRequestReason reason) {}
inline void OnAchievementsLoginSuccess(const char* display_name, u32 points, u32 sc_points, u32 unread_messages) {}
inline void OnAchievementsActiveChanged(bool active) {}
inline void OnAchievementsHardcoreModeChanged(bool enabled) {}
} // namespace Host
PATCHEND
# Modify: src/core/bios.cpp
ed -s 'src/core/bios.cpp' <<'PATCHEND'
212s/^/  /
470d
469a
    if (fd.Size != BIOS_SIZE && fd.Size != BIOS_SIZE_HALF && fd.Size != BIOS_SIZE_PS2 && fd.Size != BIOS_SIZE_PS3)
.
409d
408a
    if (fd.Size != BIOS_SIZE && fd.Size != BIOS_SIZE_HALF && fd.Size != BIOS_SIZE_PS2 && fd.Size != BIOS_SIZE_PS3)
.
212a
    std::memcpy(ret->data.data() + BIOS_SIZE_HALF, ret->data.data(), BIOS_SIZE_HALF);
  }
  else
  {
    ret->data.resize(BIOS_SIZE);
  }
.
211a
  if (ret->data.size() == BIOS_SIZE_HALF)
  {
    // Half-size BIOS (256KB) - mirror to fill 512KB, matching real hardware behavior.
.
204d
203a
  if (!data.has_value() || data->size() < BIOS_SIZE_HALF)
.
194d
193a
  if (size != BIOS_SIZE && size != BIOS_SIZE_HALF && size != BIOS_SIZE_PS2 && size != BIOS_SIZE_PS3)
.
138a
  {"PSX-XBOO (nocash PSX BIOS)", ConsoleRegion::Auto, false, ImageInfo::FastBootPatch::Unsupported, 200, MakeHashFromString("fa20b6f2cf54b6825209d6b40ec91c15")},
  {"PSX-XBOO (nocash PSX BIOS, 256K)", ConsoleRegion::Auto, false, ImageInfo::FastBootPatch::Unsupported, 200, MakeHashFromString("6d2d7d64d5a6a9dfe86b514f10046313")},
.
wq
PATCHEND
# Modify: src/core/bios.h
ed -s 'src/core/bios.h' <<'PATCHEND'
24a
  BIOS_SIZE_HALF = 0x40000,
.
wq
PATCHEND
# Modify: src/core/bus.cpp
ed -s 'src/core/bus.cpp' <<'PATCHEND'
53,54d
52a
__declspec(dllexport) uintptr_t RAM;
__declspec(dllexport) u32 RAM_SIZE, RAM_MASK;
.
wq
PATCHEND
# Modify: src/core/cdrom.cpp
ed -s 'src/core/cdrom.cpp' <<'PATCHEND'
4361a

#endif
.
4093a
#ifdef __LIBRETRO__
  return;
#else

.
1032d
1031a
  ProgressCallback callback;
.
38a
#endif
.
37a
#ifndef __LIBRETRO__
.
8d
7a

#include "common/progress_callback.h"
.
wq
PATCHEND
# Modify: src/core/cheats.cpp
ed -s 'src/core/cheats.cpp' <<'PATCHEND'
156a
#else
  ALWAYS_INLINE bool IsOpen() const { return false; }
  bool Open(bool) { return false; }
  std::optional<std::string> ReadFile(const char*) const { return std::nullopt; }
#endif
.
103a
#ifndef __LIBRETRO__
.
25a
#endif
.
24a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/core/core.cpp
ed -s 'src/core/core.cpp' <<'PATCHEND'
527d
526a
#if defined(__ANDROID__) && !defined(__LIBRETRO__)
.
313a
#endif
.
312a
#ifndef __LIBRETRO__
.
225d
224a
#if !defined(__ANDROID__) || defined(__LIBRETRO__)
.
107d
106a
#if !defined(__ANDROID__) || defined(__LIBRETRO__)
.
48d
47a
#if !defined(__ANDROID__) || defined(__LIBRETRO__)
.
31d
30a
#include <shlobj.h>
.
wq
PATCHEND
# Modify: src/core/core_private.h
ed -s 'src/core/core_private.h' <<'PATCHEND'
48d
47a
#if !defined(__ANDROID__) || defined(__LIBRETRO__)
.
15d
14a
#if !defined(__ANDROID__) || defined(__LIBRETRO__)
.
wq
PATCHEND
# Modify: src/core/cpu_core.cpp
ed -s 'src/core/cpu_core.cpp' <<'PATCHEND'
435a
#endif
.
426d
423d
420,421d
417a
#ifndef __LIBRETRO__
.
12a
#endif
.
11a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/core/dma.cpp
ed -s 'src/core/dma.cpp' <<'PATCHEND'
1031a

#endif
.
966a
#ifdef __LIBRETRO__
  return;
#else

.
11a
#endif
.
10a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/core/fullscreenui.h
ed -s 'src/core/fullscreenui.h' <<'PATCHEND'
118a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "fullscreenui_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/core'
# Add: src/core/fullscreenui_libretro.h
cat > 'src/core/fullscreenui_libretro.h' <<'PATCHEND'
// Stub fullscreenui for libretro builds — owned by GooseStation.
#pragma once

#include "common/types.h"

class GPUTexture;
class GPUPipeline;
struct GPUSettings;

namespace FullscreenUI {

inline void Initialize() {}
inline bool IsInitialized() { return false; }
inline bool HasActiveWindow() { return false; }
inline void CheckForConfigChanges(const GPUSettings&) {}
inline void OnSystemStarting() {}
inline void OnSystemPaused() {}
inline void OnSystemResumed() {}
inline void OnSystemDestroyed() {}
inline void Shutdown() {}
inline void DestroyGPUResources() {}
inline void Render() {}
inline void RenderOverlays() {}
inline void DrawAchievementsOverlays() {}
inline void UploadAsyncTextures() {}
inline float GetBackgroundAlpha() { return 0.0f; }
inline bool IsTransitionActive() { return false; }
inline GPUTexture* GetTransitionRenderTexture() { return nullptr; }
inline GPUTexture* GetBlurRenderTexture() { return nullptr; }
inline GPUPipeline* GetPresentCopyPipeline() { return nullptr; }
inline void RenderTransitionBlend(GPUTexture*, float) {}
inline void RenderBlur(GPUTexture*, float) {}

} // namespace FullscreenUI

namespace Host {
inline void RequestExitApplication(bool allow_confirm) {}
inline void RequestExitBigPicture() {}
inline const char* GetDefaultFullscreenUITheme() { return ""; }
} // namespace Host
PATCHEND
# Modify: src/core/game_database.h
ed -s 'src/core/game_database.h' <<'PATCHEND'
244a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "game_database_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/core'
# Add: src/core/game_database_libretro.h
cat > 'src/core/game_database_libretro.h' <<'PATCHEND'
// Stub game_database for libretro builds — owned by GooseStation.
#pragma once

#include "types.h"

#include <bitset>
#include <optional>
#include <string_view>
#include <vector>

namespace GameDatabase {

enum class Trait : u32
{
  ForceInterpreter,
  ForceSoftwareRenderer,
  ForceSoftwareRendererForReadbacks,
  ForceRoundUpscaledTextureCoordinates,
  ForceShaderBlending,
  ForceFullTrueColor,
  ForceDeinterlacing,
  ForceFullBoot,
  DisableAutoAnalogMode,
  DisableMultitap,
  DisableFastForwardMemoryCardAccess,
  DisableCDROMReadSpeedup,
  DisableCDROMSeekSpeedup,
  DisableCDROMSpeedupOnMDEC,
  DisableTrueColor,
  DisableFullTrueColor,
  DisableUpscaling,
  DisableTextureFiltering,
  DisableSpriteTextureFiltering,
  DisableScaledDithering,
  DisableScaledInterlacing,
  DisableAllBordersCrop,
  DisableWidescreen,
  DisablePGXP,
  DisablePGXPCulling,
  DisablePGXPTextureCorrection,
  DisablePGXPColorCorrection,
  DisablePGXPDepthBuffer,
  DisablePGXPOn2DPolygons,
  ForcePGXPVertexCache,
  ForcePGXPCPUMode,
  ForceRecompilerICache,
  ForceCDROMSubQSkew,
  IsLibCryptProtected,

  MaxCount
};

struct DiscSetEntry
{
  std::string_view title;
  std::vector<std::string_view> serials;
  std::string_view GetFirstSerial() const { return serials.empty() ? std::string_view{} : serials.front(); }
  std::string_view GetSaveTitle() const { return title; }
  std::string_view GetDisplayTitle(bool = false) const { return title; }
};

struct Entry
{
  std::string_view serial;
  std::string_view title;
  const DiscSetEntry* disc_set = nullptr;
  u16 supported_controllers = 0;
  std::bitset<static_cast<size_t>(Trait::MaxCount)> traits{};

  bool HasTrait(Trait trait) const { return traits.test(static_cast<size_t>(trait)); }
  std::string_view GetSaveTitle() const { return serial; }
  std::string_view GetDisplayTitle(bool = false) const { return title; }
  bool IsFirstDiscInSet() const { return true; }
  void ApplySettings(class Settings&, bool) const {}
};

inline const Entry* GetEntryForSerial(std::string_view) { return nullptr; }
inline const Entry* GetEntryForGameDetails(const std::string&, u64) { return nullptr; }

} // namespace GameDatabase
PATCHEND
# Modify: src/core/game_list.h
ed -s 'src/core/game_list.h' <<'PATCHEND'
202a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "game_list_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/core'
# Add: src/core/game_list_libretro.h
cat > 'src/core/game_list_libretro.h' <<'PATCHEND'
// Stub game_list for libretro builds — owned by GooseStation.
#pragma once

#include "types.h"
#include "game_database.h"

#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <string_view>

class CDImage;

namespace GameList {

enum class EntryType : u8
{
  Disc,
  PSExe,
  Playlist,
  PSF,
  Count,
};

struct Entry
{
  EntryType type = EntryType::Disc;
  DiscRegion region = DiscRegion::Other;
  std::string path;
  std::string serial;
  std::string title;
  u64 hash = 0;
  bool has_custom_title = false;
  bool has_custom_serial = false;
  bool is_runtime_populated = false;
  u32 achievements_game_id = 0;
  const struct GameDatabase::Entry* dbentry = nullptr;
};

inline std::unique_lock<std::mutex> GetLock() { return {}; }
inline const Entry* GetEntryForPath(const std::string& ) { return nullptr; }
inline const Entry* GetEntryBySerial(std::string_view) { return nullptr; }
inline std::optional<DiscRegion> GetCustomRegionForPath(const std::string&) { return std::nullopt; }
inline bool ShouldShowLocalizedTitles() { return false; }
inline bool CanEditGameSettingsForPath(const std::string&, const std::string& = {}) { return false; }
inline void AddPlayedTimeForSerial(const std::string&, std::time_t, std::time_t = 0) {}
inline std::string GetCoverImagePathForEntry(const Entry*) { return {}; }
inline std::string GetGameIconPath(std::string_view, std::string_view, std::string_view, u32 = 0) { return {}; }
inline std::string GetAchievementGameBadgePath(u32) { return {}; }

} // namespace GameList

namespace Host {
inline void RefreshGameListAsync(bool invalidate_cache) {}
inline void CancelGameListRefresh() {}
inline void OnGameListEntriesChanged(std::span<const u32> changed_indices) {}
} // namespace Host
PATCHEND
# Modify: src/core/gdb_server.h
ed -s 'src/core/gdb_server.h' <<'PATCHEND'
14a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "gdb_server_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/core'
# Add: src/core/gdb_server_libretro.h
cat > 'src/core/gdb_server_libretro.h' <<'PATCHEND'
// Stub gdb_server.h for libretro builds — no GDB debugging support.
#pragma once

#include "common/types.h"

namespace GDBServer {
inline void Initialize(u16 = 0) {}
inline void Shutdown() {}
inline void OnSystemPaused() {}
inline void OnSystemResumed() {}
} // namespace GDBServer
PATCHEND
# Modify: src/core/gpu.cpp
ed -s 'src/core/gpu.cpp' <<'PATCHEND'
2241a

#endif
.
2189a
#ifdef __LIBRETRO__
  return;
#else

.
43a
#endif
.
42a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/core/gpu.h
ed -s 'src/core/gpu.h' <<'PATCHEND'
162a

#ifdef __LIBRETRO__
  /// Returns true if the display is in 24-bit color depth mode (used for FMVs).
  ALWAYS_INLINE bool IsDisplayAreaColorDepth24() const { return m_GPUSTAT.display_area_color_depth_24; }

  /// Returns the display address start X coordinate in VRAM (for 24-bit source offset).
  ALWAYS_INLINE u16 GetDisplayAddressStartX() const { return m_crtc_state.regs.X; }
#endif
.
wq
PATCHEND
# Modify: src/core/gpu_backend.cpp
ed -s 'src/core/gpu_backend.cpp' <<'PATCHEND'
595a
#endif
.
581a
#ifdef __LIBRETRO__
    ReleaseQueuedFrame();
#else
.
128a
#endif
.
125a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/core/gpu_backend.h
ed -s 'src/core/gpu_backend.h' <<'PATCHEND'
188a
#endif
.
186a
#ifdef __LIBRETRO__
inline void FrameDoneOnVideoThread(GPUBackend*, u32) {}
#else
.
78a
#endif
.
77a
#ifdef __LIBRETRO__
  virtual void UpdatePostProcessingSettings(bool force_reload) {}
#else
.
wq
PATCHEND
# Modify: src/core/gpu_hw.cpp
ed -s 'src/core/gpu_hw.cpp' <<'PATCHEND'
4443a
#endif
.
4420a
#ifndef __LIBRETRO__
.
4417a
#endif
.
4404a
#ifndef __LIBRETRO__
.
4184a
#endif
.
4170a
#ifndef __LIBRETRO__
.
4155a
#endif

.
4153a
#ifdef __LIBRETRO__
    const ExtractUniforms uniforms = {reinterpret_start_x, scaled_vram_offset_y, skip_x,
                                      static_cast<u32>(line_skip ? 2 : 1)};
#else
.
4152a
#endif
.
4150a
#ifdef __LIBRETRO__
      u32 skip_x;
      u32 line_skip;
#else
.
4115a
#endif
.
4111a
#ifdef __LIBRETRO__
    GPUTexture* depth_source = nullptr;
#else
.
4081a
#ifdef __LIBRETRO__
    if (!m_vram_dirty_draw_rect.eq(INVALID_RECT) || !m_vram_dirty_write_rect.eq(INVALID_RECT))
      UpdateVRAMReadTexture(!m_vram_dirty_draw_rect.eq(INVALID_RECT), !m_vram_dirty_write_rect.eq(INVALID_RECT));
#endif

.
4080a
#endif
.
4079a
#ifdef __LIBRETRO__
           true)
#else
.
4068d
4067a
    VideoPresenter::SetDisplayDisabled();
.
3962a
#ifdef __LIBRETRO__
  SetVRAMRenderTarget();
  g_gpu_device->SetViewport(m_vram_texture->GetRect());
#endif

.
3668a

#ifdef __LIBRETRO__
      SetVRAMRenderTarget();
    g_gpu_device->SetViewport(m_vram_texture->GetRect());
#endif
.
3543a
#ifdef __LIBRETRO__
  SetVRAMRenderTarget();
  g_gpu_device->SetViewport(m_vram_texture->GetRect());
#endif

.
3388a
#ifdef __LIBRETRO__
  SetVRAMRenderTarget();
  g_gpu_device->SetViewport(m_vram_texture->GetRect());
#endif

.
2182a
#endif
.
2177a
#ifdef __LIBRETRO__
  if (texture_mode != static_cast<u8>(BatchTextureMode::Disabled))
  {
    g_gpu_device->SetTextureSampler(0, (m_use_texture_cache && texture) ? texture->texture : m_vram_read_texture.get(),
                                    g_gpu_device->GetNearestSampler());
  }
#else
.
2074a
#endif
.
2073a
#ifdef __LIBRETRO__
    if (false)
#else
.
343a
#endif
.
342a
#ifndef __LIBRETRO__
.
228,231d
227a
      VERBOSE_LOG("Compiling shaders: {} of {} pipelines", m_progress, m_total);
.
220d
219a
      Error::SetStringView(error, "Startup was cancelled.");
.
37a
#endif
.
36a
#ifndef __LIBRETRO__
.
15d
8d
wq
PATCHEND
# Modify: src/core/gpu_hw.h
ed -s 'src/core/gpu_hw.h' <<'PATCHEND'
371a
#endif
.
370a
#ifndef __LIBRETRO__
.
269a
#endif
.
268a
#ifndef __LIBRETRO__
.
20a
#endif
.
17a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/core/gpu_hw_shadergen.cpp
ed -s 'src/core/gpu_hw_shadergen.cpp' <<'PATCHEND'
1786,1788d
1785a
)";
#ifdef __LIBRETRO__
  ss << "  uint2 icoords = uint2(uint(v_pos.x) + u_skip_x, uint(v_pos.y) * u_line_skip);\n";
#else
  ss << "  float2 v_pos_floored = floor(v_pos.xy);\n";
  ss << "  uint2 icoords = uint2(v_pos_floored.x + u_skip_x, v_pos_floored.y * u_line_skip);\n";
#endif
  ss << R"(  int2 wrapped_coords = int2((icoords + u_vram_offset) % VRAM_SIZE);
.
1728a
#endif
.
1727a
#ifdef __LIBRETRO__
  DeclareUniformBuffer(ss, {"uint2 u_vram_offset", "uint u_skip_x", "uint u_line_skip"}, true);
#else
.
wq
PATCHEND
truncate -s -1 'src/core/gpu_hw_shadergen.cpp'
# Modify: src/core/gpu_hw_texture_cache.cpp
ed -s 'src/core/gpu_hw_texture_cache.cpp' <<'PATCHEND'
3465,3468d
3464a
    VERBOSE_LOG("Preloading replacement textures: {} of {}", num_textures_loaded, total_textures);                     \
.
12d
5d
wq
PATCHEND
truncate -s -1 'src/core/gpu_hw_texture_cache.cpp'
# Modify: src/core/gpu_sw.cpp
ed -s 'src/core/gpu_sw.cpp' <<'PATCHEND'
399d
398a
      VideoPresenter::SetDisplayDisabled();
.
392a
#ifdef __LIBRETRO__
  // Libretro reads directly from g_vram — skip GPU texture upload.
  return;
#endif
.
52a
#endif
.
51d
38a
#ifdef __LIBRETRO__
  // In libretro, frames are pushed directly from VRAM — no GPU device needed for display.
  m_16bit_display_format = GPUTextureFormat::RGBA8;
#else
.
wq
PATCHEND
# Modify: src/core/gte.cpp
ed -s 'src/core/gte.cpp' <<'PATCHEND'
1796a
#endif
}
.
1662a
#ifdef __LIBRETRO__
  return;
#else
.
19a
#endif
.
18a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/core/host.h
ed -s 'src/core/host.h' <<'PATCHEND'
65a
#endif
.
48a
#ifdef __LIBRETRO__
inline void OpenURL(std::string_view) {}
inline std::string GetClipboardText() { return {}; }
inline bool CopyTextToClipboard(std::string_view) { return false; }
inline std::span<const std::pair<const char*, const char*>> GetAvailableLanguageList() { return {}; }
inline const char* GetLanguageName(std::string_view) { return ""; }
inline bool ChangeLanguage(const char*) { return false; }
#else
.
16a

inline void AddOSDMessage(OSDMessageType, std::string) {}
inline void AddKeyedOSDMessage(OSDMessageType, std::string, std::string) {}
inline void AddIconOSDMessage(OSDMessageType, std::string, const char*, std::string) {}
inline void AddIconOSDMessage(OSDMessageType, std::string, const char*, std::string, std::string) {}
inline void AddIconOSDMessage(OSDMessageType, std::string, std::string, std::string, std::string) {}
inline void RemoveKeyedOSDMessage(std::string) {}
inline void ClearOSDMessages() {}
.
15a
enum class OSDMessageType : u8
{
  Error,
  Warning,
  Info,
  Quick,
  Persistent,

  MaxCount
};

.
11a
#include <string>
.
wq
PATCHEND
mkdir -p 'src/core'
# Add: src/core/hotkeys_stub.cpp
cat > 'src/core/hotkeys_stub.cpp' <<'PATCHEND'
// GooseStation: hotkey stubs for libretro builds.

#include "settings.h"
#include "util/input_manager.h"

#include <array>

void Settings::SetDefaultHotkeyConfig(SettingsInterface& si)
{
  si.ClearSection("Hotkeys");
}

namespace Core {

std::span<const HotkeyInfo> GetHotkeyList()
{
  static constexpr std::array<HotkeyInfo, 0> s_hotkeys = {};
  return s_hotkeys;
}

} // namespace Core
PATCHEND
# Modify: src/core/imgui_overlays.h
ed -s 'src/core/imgui_overlays.h' <<'PATCHEND'
50a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "imgui_overlays_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/core'
# Add: src/core/imgui_overlays_libretro.h
cat > 'src/core/imgui_overlays_libretro.h' <<'PATCHEND'
// Stub imgui_overlays for libretro builds — owned by GooseStation.
#pragma once

#include "util/imgui_manager.h"

class SettingsInterface;
class GPUBackend;

namespace ImGuiManager {
inline void RenderTextOverlays(const GPUBackend*) {}
inline bool IsSPUDebugWindowEnabled() { return false; }
inline void RenderDebugWindows() {}
inline void DestroyAllDebugWindows() {}
inline void RenderOverlayWindows() {}
inline void DestroyOverlayTextures() {}
} // namespace ImGuiManager

namespace SaveStateSelectorUI {
inline constexpr float DEFAULT_OPEN_TIME = 7.5f;
inline bool IsOpen() { return false; }
inline void Open(float = DEFAULT_OPEN_TIME) {}
inline void RefreshList() {}
inline void Clear() {}
inline void ClearList() {}
inline void Close() {}
inline void SelectNextSlot(bool) {}
inline void SelectPreviousSlot(bool) {}
inline s32 GetCurrentSlot() { return 0; }
inline bool IsCurrentSlotGlobal() { return false; }
inline void LoadCurrentSlot() {}
inline void SaveCurrentSlot() {}
} // namespace SaveStateSelectorUI
PATCHEND
# Modify: src/core/mdec.cpp
ed -s 'src/core/mdec.cpp' <<'PATCHEND'
1191a

#endif
.
1162a
#ifdef __LIBRETRO__
  return;
#else

.
19a
#endif
.
18a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/core/pcdrv.h
ed -s 'src/core/pcdrv.h' <<'PATCHEND'
18a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "pcdrv_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/core'
# Add: src/core/pcdrv_libretro.h
cat > 'src/core/pcdrv_libretro.h' <<'PATCHEND'
// Stub pcdrv for libretro builds — owned by GooseStation.
#pragma once

namespace PCDrv {
inline void Initialize() {}
inline void Shutdown() {}
inline void Reset() {}
} // namespace PCDrv
PATCHEND
# Modify: src/core/pch.h
ed -s 'src/core/pch.h' <<'PATCHEND'
6a
#include "host.h"
#include "util/translation.h"
.
wq
PATCHEND
# Modify: src/core/performance_counters.cpp
ed -s 'src/core/performance_counters.cpp' <<'PATCHEND'
243s/^/  /
242a
  if (g_gpu_device)
.
222d
221a
  if (g_gpu_device && g_gpu_device->IsGPUTimingEnabled())
.
wq
PATCHEND
# Modify: src/core/psf_loader.h
ed -s 'src/core/psf_loader.h' <<'PATCHEND'
61a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "psf_loader_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/core'
# Add: src/core/psf_loader_libretro.h
cat > 'src/core/psf_loader_libretro.h' <<'PATCHEND'
// Stub psf_loader for libretro builds — owned by GooseStation.
#pragma once

#include "types.h"

#include <string>

class Error;

namespace PSFLoader {

class File
{
public:
  bool Load(const char*, Error*) { return false; }
  DiscRegion GetRegion() const { return DiscRegion::Other; }
};

inline bool Load(const std::string&, Error*) { return false; }

} // namespace PSFLoader
PATCHEND
# Modify: src/core/settings.cpp
ed -s 'src/core/settings.cpp' <<'PATCHEND'
628d
627a
#if defined(__ANDROID__) && !defined(__LIBRETRO__)
.
156d
150,154d
9d
wq
PATCHEND
# Modify: src/core/sound_effect_manager.h
ed -s 'src/core/sound_effect_manager.h' <<'PATCHEND'
34a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "sound_effect_manager_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/core'
# Add: src/core/sound_effect_manager_libretro.h
cat > 'src/core/sound_effect_manager_libretro.h' <<'PATCHEND'
// Stub sound_effect_manager for libretro builds — owned by GooseStation.
#pragma once

namespace SoundEffectManager {
inline bool IsInitialized() { return false; }
inline void Initialize() {}
inline void EnsureInitialized() {}
inline void Shutdown() {}
inline void UpdateSettings() {}
inline void PlayGateSound() {}
inline void StopGateSound() {}
} // namespace SoundEffectManager
PATCHEND
# Modify: src/core/spu.cpp
ed -s 'src/core/spu.cpp' <<'PATCHEND'
2865a

#endif
.
2563a
#ifdef __LIBRETRO__
  return;
#else

.
29a
#endif
.
28a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/core/system.cpp
ed -s 'src/core/system.cpp' <<'PATCHEND'
5862a
#endif
.
5861a
#endif
.
5842a
#ifndef __LIBRETRO__
.
5838a
#endif
.
5821a
#ifndef __LIBRETRO__
.
5817a
#endif
.
5759a
#ifdef __LIBRETRO__
  return false;
#else
.
5754a
#endif
.
5720a
#ifdef __LIBRETRO__
  return false;
#else
.
5689a
#ifndef __LIBRETRO__
.
2405d
2404a
    ((is_duplicate_frame || (s_state.throttler_enabled && !s_state.optimal_frame_pacing &&
                             current_time > s_state.next_frame_time &&
.
2048a
#endif
.
2045a
#ifndef __LIBRETRO__
.
1721a

#ifdef __LIBRETRO__
  // Only the state change is needed — the full pause/resume machinery is harmful per-frame.
  return;
#endif

.
1632a
#endif
.
1554a
#ifdef __LIBRETRO__
  return nullptr;
#else
.
819a
#endif
.
815a
#ifndef __LIBRETRO__
.
540d
539a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
186a

#ifdef __LIBRETRO__
static bool StartMediaCapture(std::string path, bool capture_video, bool capture_audio, u32 video_width,
                              u32 video_height)
{
  return false;
}

static void StopMediaCapture(std::unique_ptr<MediaCapture> cap)
{
}
#endif
.
104a
#endif
.
100a
#ifndef __LIBRETRO__
.
97d
96a
#include <objbase.h>
.
82a
#endif
.
81a
#ifndef __LIBRETRO__
.
26d
wq
PATCHEND
# Modify: src/core/system.h
ed -s 'src/core/system.h' <<'PATCHEND'
438a
#endif
.
430a
#ifdef __LIBRETRO__
inline std::string GetNewMediaCapturePath(const std::string_view title, const std::string_view container)
{
  return {};
}

/// Current media capture (if active).
inline MediaCapture* GetMediaCapture()
{
  return nullptr;
}

/// Media capture (video and/or audio). If no path is provided, one will be generated automatically.
inline bool StartMediaCapture(std::string path = {})
{
  return false;
}

inline void StopMediaCapture()
{
}
#else
.
235a
#endif
.
234a
#ifdef __LIBRETRO__
inline const GameDatabase::Entry* GetGameDatabaseEntry()
{
  return nullptr;
}
#else
.
wq
PATCHEND
# Modify: src/core/timers.cpp
ed -s 'src/core/timers.cpp' <<'PATCHEND'
583a

#endif
.
525a
#ifdef __LIBRETRO__
  return;
#else

.
16a
#endif
.
15a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/core/video_presenter.cpp
ed -s 'src/core/video_presenter.cpp' <<'PATCHEND'
1753s/^  //
1793,1795s/^  //
1797,1804s/^  //
1816a
#endif
.
1806,1811d
1796d
1784,1792d
1777d
1776a
  if (!display)
    return;
.
1758,1772d
1746,1752d
1708,1743d
1707a
#ifndef __LIBRETRO__
.
1606a
#endif
.
1601,1603d
1487a
#ifdef __LIBRETRO__
  return true;
#else
.
1199a
#endif
.
1175a
#ifndef __LIBRETRO__
.
1035,1146d
733,794d
677,712d
593d
581d
571d
570a
}

void VideoPresenter::SetDisplayDisabled()
{
  // Just clear - HW renderers will clear to black via glClear/VkCmdClear
  // This is simpler and avoids potential texture lifetime issues
  s_locals.display_texture = nullptr;
  s_locals.display_texture_rect = GSVector4i::zero();
.
242,243d
219,220d
212,213d
178,182d
174a
bool VideoPresenter::HasDisplayTexture()
{
  return s_locals.display_texture != nullptr;
}

.
169a
const GSVector4i& VideoPresenter::GetVideoActiveRect()
{
  return s_locals.video_active_rect;
}

.
154d
116d
75,76d
64,69d
12d
7,8d
wq
PATCHEND
# Modify: src/core/video_presenter.h
ed -s 'src/core/video_presenter.h' <<'PATCHEND'
99a
#endif
.
97a
#ifdef __LIBRETRO__
inline void FrameDoneOnVideoThread(u32) {}
#else
.
62a
#endif
.
61a
#ifdef __LIBRETRO__
inline void SendDisplayToMediaCapture(MediaCapture* cap)
{
}
#else
.
46a
void SetDisplayDisabled();
.
31a
const GSVector4i& GetVideoActiveRect();
.
wq
PATCHEND
# Modify: src/core/video_thread.cpp
ed -s 'src/core/video_thread.cpp' <<'PATCHEND'
1121,1122s/^/  /
1124,1130s/^/  /
1135s/^  //
1496,1500d
1292,1293d
1225,1237d
1132,1134d
1130a
    }
    else
    {
      Error error;
      if (!s_state.gpu_backend->UpdateSettings(old_settings, &error)) [[unlikely]]
      {
        ReportFatalErrorAndShutdown(fmt::format("Failed to update settings: {}", error.GetDescription()));
        return;
      }
    }
.
1120a
    if (g_gpu_device)
    {
.
1111,1118d
1042d
1041a
  if (g_gpu_device && g_gpu_device->HasMainSwapChain())
.
1022,1024d
1000a
  } // end non-libretro-sw path
.
916a
#ifdef __LIBRETRO__
  // In libretro with software renderer, skip GPU device creation entirely.
  // Frames are pushed directly from VRAM via the libretro video callback.
  // Creating a GPU device (OpenGL/Vulkan) would conflict with RetroArch's own context.
  if (cmd->renderer.has_value() && cmd->renderer.value() == GPURenderer::Software)
  {
    s_state.gpu_backend = GPUBackend::CreateSoftwareBackend();
    Error local_error;
    if (s_state.gpu_backend->Initialize(cmd->upload_vram, &local_error))
    {
      *cmd->out_result = VideoThreadReconfigureCommand::Result::Success;
      *cmd->out_created_renderer = GPURenderer::Software;
    }
    else
    {
      ERROR_LOG("Failed to create software renderer: {}", local_error.GetDescription());
      s_state.gpu_backend.reset();
      *cmd->out_result = VideoThreadReconfigureCommand::Result::Failed;
      *cmd->out_created_renderer = GPURenderer::Count;
      if (cmd->error_ptr)
        *cmd->error_ptr = std::move(local_error);
    }
  }
  else
#endif
  {
.
830,833d
784,793d
756a
#endif
.
746a
#ifndef __LIBRETRO__
.
745a
#endif
.
727a
#ifndef __LIBRETRO__
.
616a
#endif
.
588a
#ifndef __LIBRETRO__
.
36a
#endif
.
35a
#ifndef __LIBRETRO__
.
23d
21d
11d
6d
wq
PATCHEND
# Modify: src/core/video_thread.h
ed -s 'src/core/video_thread.h' <<'PATCHEND'
135a
#endif
.
130a
#ifdef __LIBRETRO__
inline void OnVideoThreadRunIdleChanged(bool) {}
inline bool SetScreensaverInhibit(bool, Error*) { return true; }
#else
.
48a
#endif
.
45a
#ifdef __LIBRETRO__
inline bool StartFullscreenUI(bool fullscreen, Error* error)
{
  return false;
}

inline bool IsFullscreenUIRequested()
{
  return false;
}

inline void StopFullscreenUI()
{
}
#else
.
wq
PATCHEND
mkdir -p 'src/goosestation-libretro'
# Add: src/goosestation-libretro/CMakeLists.txt
cat > 'src/goosestation-libretro/CMakeLists.txt' <<'PATCHEND'
add_library(goosestation_libretro SHARED
  main.cpp
)

set_target_properties(goosestation_libretro PROPERTIES
  OUTPUT_NAME "goosestation_libretro"
  PREFIX ""
  C_VISIBILITY_PRESET hidden
  CXX_VISIBILITY_PRESET hidden
)

# LIBRETRO_HEADERS_DIR: path containing libretro.h, libretro_vulkan.h, etc.
# Defaults to current source dir for local dev; ebuild overrides to packaging/libretro/.
if(NOT DEFINED LIBRETRO_HEADERS_DIR)
  set(LIBRETRO_HEADERS_DIR "${CMAKE_CURRENT_SOURCE_DIR}")
endif()

target_include_directories(goosestation_libretro PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/.."
  "${CMAKE_CURRENT_SOURCE_DIR}"
  "${LIBRETRO_HEADERS_DIR}"
)

target_link_libraries(goosestation_libretro PRIVATE core common scmversion glad)
target_compile_definitions(goosestation_libretro PRIVATE "__LIBRETRO__=1")

# Position-independent code for shared library
set_target_properties(goosestation_libretro PROPERTIES POSITION_INDEPENDENT_CODE ON)

# Hide all symbols except retro_* to avoid collisions with libvulkan etc.
# PE/COFF doesn't use version scripts; on Windows RETRO_API uses dllexport.
if(NOT WIN32)
  target_link_options(goosestation_libretro PRIVATE
    "LINKER:--version-script=${CMAKE_CURRENT_SOURCE_DIR}/link.T"
    "LINKER:--no-undefined"
  )
endif()

# mingw: bake gcc/c++/pthread runtimes into the DLL so it doesn't need
# libgcc_s_seh-1.dll / libstdc++-6.dll / libwinpthread-1.dll alongside.
if(WIN32 AND NOT MSVC)
  target_link_options(goosestation_libretro PRIVATE
    -static-libgcc -static-libstdc++
    "LINKER:-Bstatic,--whole-archive,-lwinpthread,--no-whole-archive,-Bdynamic"
  )
endif()

# No resources needed — libretro cores are self-contained .so files.
# Game database, shaders, fonts, etc. are all handled by RetroArch.
PATCHEND
mkdir -p 'src/goosestation-libretro'
# Add: src/goosestation-libretro/libretro.h
cat > 'src/goosestation-libretro/libretro.h' <<'PATCHEND'
/*!
 * libretro.h is a simple API that allows for the creation of games and emulators.
 *
 * @file libretro.h
 * @version 1
 * @author libretro
 * @copyright Copyright (C) 2010-2024 The RetroArch team
 *
 * @paragraph LICENSE
 * The following license statement only applies to this libretro API header (libretro.h).
 *
 * Copyright (C) 2010-2024 The RetroArch team
 *
 * Permission is hereby granted, free of charge,
 * to any person obtaining a copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software,
 * and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#ifndef LIBRETRO_H__
#define LIBRETRO_H__

#include <stdint.h>
#include <stddef.h>
#include <limits.h>

#ifdef __cplusplus
extern "C" {
#endif

#ifndef __cplusplus
#if defined(_MSC_VER) && _MSC_VER < 1800 && !defined(SN_TARGET_PS3)
/* Hack applied for MSVC when compiling in C89 mode
 * as it isn't C99-compliant. */
#define bool unsigned char
#define true 1
#define false 0
#else
#include <stdbool.h>
#endif
#endif

#ifndef RETRO_CALLCONV
#  if defined(__GNUC__) && defined(__i386__) && !defined(__x86_64__)
#    define RETRO_CALLCONV __attribute__((cdecl))
#  elif defined(_MSC_VER) && defined(_M_X86) && !defined(_M_X64)
#    define RETRO_CALLCONV __cdecl
#  else
#    define RETRO_CALLCONV /* all other platforms only have one calling convention each */
#  endif
#endif

#ifndef RETRO_API
#  if defined(_WIN32) || defined(__CYGWIN__) || defined(__MINGW32__)
#    ifdef RETRO_IMPORT_SYMBOLS
#      ifdef __GNUC__
#        define RETRO_API RETRO_CALLCONV __attribute__((__dllimport__))
#      else
#        define RETRO_API RETRO_CALLCONV __declspec(dllimport)
#      endif
#    else
#      ifdef __GNUC__
#        define RETRO_API RETRO_CALLCONV __attribute__((__dllexport__))
#      else
#        define RETRO_API RETRO_CALLCONV __declspec(dllexport)
#      endif
#    endif
#  else
#      if defined(__GNUC__) && __GNUC__ >= 4
#        define RETRO_API RETRO_CALLCONV __attribute__((__visibility__("default")))
#      else
#        define RETRO_API RETRO_CALLCONV
#      endif
#  endif
#endif

/**
 * The major version of the libretro API and ABI.
 * Cores may support multiple versions,
 * or they may reject cores with unsupported versions.
 * It is only incremented for incompatible API/ABI changes;
 * this generally implies a function was removed or changed,
 * or that a \c struct had fields removed or changed.
 * @note A design goal of libretro is to avoid having to increase this value at all costs.
 * This is why there are APIs that are "extended" or "V2".
 */
#define RETRO_API_VERSION         1

/**
 * @defgroup RETRO_DEVICE Input Devices
 * @brief Libretro's fundamental device abstractions.
 *
 * Libretro's input system consists of abstractions over standard device types,
 * such as a joypad (with or without analog), mouse, keyboard, light gun, or an abstract pointer.
 * Instead of managing input devices themselves,
 * cores need only to map their own concept of a controller to libretro's abstractions.
 * This makes it possible for frontends to map the abstract types to a real input device
 * without having to worry about the correct use of arbitrary (real) controller layouts.
 * @{
 */

#define RETRO_DEVICE_TYPE_SHIFT         8
#define RETRO_DEVICE_MASK               ((1 << RETRO_DEVICE_TYPE_SHIFT) - 1)

/**
 * Defines an ID for a subclass of a known device type.
 *
 * To define a subclass ID, use this macro like so:
 * @code{c}
 * #define RETRO_DEVICE_SUPER_SCOPE RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_LIGHTGUN, 1)
 * #define RETRO_DEVICE_JUSTIFIER RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_LIGHTGUN, 2)
 * @endcode
 *
 * Correct use of this macro allows a frontend to select a suitable physical device
 * to map to the emulated device.
 *
 * @note Cores must use the base ID when polling for input,
 * and frontends must only accept the base ID for this purpose.
 * Polling for input using subclass IDs is reserved for future definition.
 *
 * @param base One of the \ref RETRO_DEVICE "base device types".
 * @param id A unique ID, with respect to \c base.
 * Must be a non-negative integer.
 * @return A unique subclass ID.
 * @see retro_controller_description
 * @see retro_set_controller_port_device
 */
#define RETRO_DEVICE_SUBCLASS(base, id) (((id + 1) << RETRO_DEVICE_TYPE_SHIFT) | base)

/**
 * @defgroup RETRO_DEVICE Input Device Classes
 * @{
 */

/**
 * Indicates no input.
 *
 * When provided as the \c device argument to \c retro_input_state_t,
 * all other arguments are ignored and zero is returned.
 *
 * @see retro_input_state_t
 */
#define RETRO_DEVICE_NONE         0

/**
 * An abstraction around a game controller, known as a "RetroPad".
 *
 * The RetroPad is modelled after a SNES controller,
 * but with additional L2/R2/L3/R3 buttons
 * (similar to a PlayStation controller).
 *
 * When provided as the \c device argument to \c retro_input_state_t,
 * the \c id argument denotes the button (including D-Pad directions) to query.
 * The result of said query will be 1 if the button is down, 0 if not.
 *
 * There is one exception; if \c RETRO_DEVICE_ID_JOYPAD_MASK is queried
 * (and the frontend supports this query),
 * the result will be a bitmask of all pressed buttons.
 *
 * @see retro_input_state_t
 * @see RETRO_DEVICE_ANALOG
 * @see RETRO_DEVICE_ID_JOYPAD
 * @see RETRO_DEVICE_ID_JOYPAD_MASK
 * @see RETRO_ENVIRONMENT_GET_INPUT_BITMASKS
 */
#define RETRO_DEVICE_JOYPAD       1

/**
 * An abstraction around a mouse, similar to the SNES Mouse but with more buttons.
 *
 * When provided as the \c device argument to \c retro_input_state_t,
 * the \c id argument denotes the button or axis to query.
 * For buttons, the result of said query
 * will be 1 if the button is down or 0 if not.
 * For mouse wheel axes, the result
 * will be 1 if the wheel was rotated in that direction and 0 if not.
 * For the mouse pointer axis, the result will be thee mouse's movement
 * relative to the last poll.
 * The core is responsible for tracking the mouse's position,
 * and the frontend is responsible for preventing interference
 * by the real hardware pointer (if applicable).
 *
 * @note This should only be used for cores that emulate mouse input,
 * such as for home computers
 * or consoles with mouse attachments.
 * Cores that emulate light guns should use \c RETRO_DEVICE_LIGHTGUN,
 * and cores that emulate touch screens should use \c RETRO_DEVICE_POINTER.
 *
 * @see RETRO_DEVICE_POINTER
 * @see RETRO_DEVICE_LIGHTGUN
 */
#define RETRO_DEVICE_MOUSE        2

/**
 * An abstraction around a keyboard.
 *
 * When provided as the \c device argument to \c retro_input_state_t,
 * the \c id argument denotes the key to poll.
 *
 * @note This should only be used for cores that emulate keyboard input,
 * such as for home computers
 * or consoles with keyboard attachments.
 * Cores that emulate gamepads should use \c RETRO_DEVICE_JOYPAD or \c RETRO_DEVICE_ANALOG,
 * and leave keyboard compatibility to the frontend.
 *
 * @see RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK
 * @see retro_key
 */
#define RETRO_DEVICE_KEYBOARD     3

/**
 * An abstraction around a light gun, similar to the PlayStation's Guncon.
 *
 * When provided as the \c device argument to \c retro_input_state_t,
 * the \c id argument denotes one of several possible inputs.
 *
 * The gun's coordinates are reported in screen space (similar to the pointer)
 * in the range of [-0x8000, 0x7fff].
 * Zero is the center of the game's screen
 * and -0x8000 represents out-of-bounds.
 * The trigger and various auxiliary buttons are also reported.
 *
 * @note A forced off-screen shot can be requested for auto-reloading
 * function in some games.
 *
 * @see RETRO_DEVICE_POINTER
 */
#define RETRO_DEVICE_LIGHTGUN     4

/**
 * An extension of the RetroPad that supports analog input.
 *
 * The analog RetroPad provides two virtual analog sticks (similar to DualShock controllers)
 * and allows any button to be treated as analog (similar to Xbox shoulder triggers).
 *
 * When provided as the \c device argument to \c retro_input_state_t,
 * the \c id argument denotes an analog axis or an analog button.
 *
 * Analog axes are reported in the range of [-0x8000, 0x7fff],
 * with the X axis being positive towards the right
 * and the Y axis being positive towards the bottom.
 *
 * Analog buttons are reported in the range of [0, 0x7fff],
 * where 0 is unpressed and 0x7fff is fully pressed.
 *
 * @note Cores should only use this type if they need analog input.
 * Otherwise, \c RETRO_DEVICE_JOYPAD should be used.
 * @see RETRO_DEVICE_JOYPAD
 */
#define RETRO_DEVICE_ANALOG       5

/**
 * Input Device: Pointer.
 *
 * Abstracts the concept of a pointing mechanism, e.g. touch.
 * This allows libretro to query in absolute coordinates where on the
 * screen a mouse (or something similar) is being placed.
 * For a touch centric device, coordinates reported are the coordinates
 * of the press.
 *
 * Coordinates in X and Y are reported as:
 * [-0x7fff, 0x7fff]: -0x7fff corresponds to the far left/top of the screen,
 * and 0x7fff corresponds to the far right/bottom of the screen.
 * The "screen" is here defined as area that is passed to the frontend and
 * later displayed on the monitor. If the pointer is outside this screen,
 * such as in the black surrounding areas when actual display is larger,
 * edge position is reported. An explicit edge detection is also provided,
 * that will return 1 if the pointer is near the screen edge or actually outside it.
 *
 * The frontend is free to scale/resize this screen as it sees fit, however,
 * (X, Y) = (-0x7fff, -0x7fff) will correspond to the top-left pixel of the
 * game image, etc.
 *
 * To check if the pointer coordinates are valid (e.g. a touch display
 * actually being touched), \c RETRO_DEVICE_ID_POINTER_PRESSED returns 1 or 0.
 *
 * If using a mouse on a desktop, \c RETRO_DEVICE_ID_POINTER_PRESSED will
 * usually correspond to the left mouse button, but this is a frontend decision.
 * \c RETRO_DEVICE_ID_POINTER_PRESSED will only return 1 if the pointer is
 * inside the game screen.
 *
 * For multi-touch, the index variable can be used to successively query
 * more presses.
 * If index = 0 returns true for \c _PRESSED, coordinates can be extracted
 * with \c _X, \c _Y for index = 0. One can then query \c _PRESSED, \c _X, \c _Y with
 * index = 1, and so on.
 * Eventually \c _PRESSED will return false for an index. No further presses
 * are registered at this point.
 *
 * @see RETRO_DEVICE_MOUSE
 * @see RETRO_DEVICE_ID_POINTER_X
 * @see RETRO_DEVICE_ID_POINTER_Y
 * @see RETRO_DEVICE_ID_POINTER_PRESSED
 */
#define RETRO_DEVICE_POINTER      6

/** @} */

/** @defgroup RETRO_DEVICE_ID_JOYPAD RetroPad Input
 * @brief Digital buttons for the RetroPad.
 *
 * Button placement is comparable to that of a SNES controller,
 * combined with the shoulder buttons of a PlayStation controller.
 * These values can also be used for the \c id field of \c RETRO_DEVICE_INDEX_ANALOG_BUTTON
 * to represent analog buttons (usually shoulder triggers).
 * @{
 */

/** The equivalent of the SNES controller's south face button. */
#define RETRO_DEVICE_ID_JOYPAD_B        0

/** The equivalent of the SNES controller's west face button. */
#define RETRO_DEVICE_ID_JOYPAD_Y        1

/** The equivalent of the SNES controller's left-center button. */
#define RETRO_DEVICE_ID_JOYPAD_SELECT   2

/** The equivalent of the SNES controller's right-center button. */
#define RETRO_DEVICE_ID_JOYPAD_START    3

/** Up on the RetroPad's D-pad. */
#define RETRO_DEVICE_ID_JOYPAD_UP       4

/** Down on the RetroPad's D-pad. */
#define RETRO_DEVICE_ID_JOYPAD_DOWN     5

/** Left on the RetroPad's D-pad. */
#define RETRO_DEVICE_ID_JOYPAD_LEFT     6

/** Right on the RetroPad's D-pad. */
#define RETRO_DEVICE_ID_JOYPAD_RIGHT    7

/** The equivalent of the SNES controller's east face button. */
#define RETRO_DEVICE_ID_JOYPAD_A        8

/** The equivalent of the SNES controller's north face button. */
#define RETRO_DEVICE_ID_JOYPAD_X        9

/** The equivalent of the SNES controller's left shoulder button. */
#define RETRO_DEVICE_ID_JOYPAD_L       10

/** The equivalent of the SNES controller's right shoulder button. */
#define RETRO_DEVICE_ID_JOYPAD_R       11

/** The equivalent of the PlayStation's rear left shoulder button. */
#define RETRO_DEVICE_ID_JOYPAD_L2      12

/** The equivalent of the PlayStation's rear right shoulder button. */
#define RETRO_DEVICE_ID_JOYPAD_R2      13

/**
 * The equivalent of the PlayStation's left analog stick button,
 * although the actual button need not be in this position.
 */
#define RETRO_DEVICE_ID_JOYPAD_L3      14

/**
 * The equivalent of the PlayStation's right analog stick button,
 * although the actual button need not be in this position.
 */
#define RETRO_DEVICE_ID_JOYPAD_R3      15

/**
 * Represents a bitmask that describes the state of all \c RETRO_DEVICE_ID_JOYPAD button constants,
 * rather than the state of a single button.
 *
 * @see RETRO_ENVIRONMENT_GET_INPUT_BITMASKS
 * @see RETRO_DEVICE_JOYPAD
 */
#define RETRO_DEVICE_ID_JOYPAD_MASK    256

/** @} */

/** @defgroup RETRO_DEVICE_ID_ANALOG Analog RetroPad Input
 * @{
 */

/* Index / Id values for ANALOG device. */
#define RETRO_DEVICE_INDEX_ANALOG_LEFT       0
#define RETRO_DEVICE_INDEX_ANALOG_RIGHT      1
#define RETRO_DEVICE_INDEX_ANALOG_BUTTON     2
#define RETRO_DEVICE_ID_ANALOG_X             0
#define RETRO_DEVICE_ID_ANALOG_Y             1

/** @} */

/* Id values for MOUSE. */
#define RETRO_DEVICE_ID_MOUSE_X                0
#define RETRO_DEVICE_ID_MOUSE_Y                1
#define RETRO_DEVICE_ID_MOUSE_LEFT             2
#define RETRO_DEVICE_ID_MOUSE_RIGHT            3
#define RETRO_DEVICE_ID_MOUSE_WHEELUP          4
#define RETRO_DEVICE_ID_MOUSE_WHEELDOWN        5
#define RETRO_DEVICE_ID_MOUSE_MIDDLE           6
#define RETRO_DEVICE_ID_MOUSE_HORIZ_WHEELUP    7
#define RETRO_DEVICE_ID_MOUSE_HORIZ_WHEELDOWN  8
#define RETRO_DEVICE_ID_MOUSE_BUTTON_4         9
#define RETRO_DEVICE_ID_MOUSE_BUTTON_5         10

/* Id values for LIGHTGUN. */
#define RETRO_DEVICE_ID_LIGHTGUN_SCREEN_X        13 /*Absolute Position*/
#define RETRO_DEVICE_ID_LIGHTGUN_SCREEN_Y        14 /*Absolute Position*/
/** Indicates if lightgun points off the screen or near the edge */
#define RETRO_DEVICE_ID_LIGHTGUN_IS_OFFSCREEN    15 /*Status Check*/
#define RETRO_DEVICE_ID_LIGHTGUN_TRIGGER          2
#define RETRO_DEVICE_ID_LIGHTGUN_RELOAD          16 /*Forced off-screen shot*/
#define RETRO_DEVICE_ID_LIGHTGUN_AUX_A            3
#define RETRO_DEVICE_ID_LIGHTGUN_AUX_B            4
#define RETRO_DEVICE_ID_LIGHTGUN_START            6
#define RETRO_DEVICE_ID_LIGHTGUN_SELECT           7
#define RETRO_DEVICE_ID_LIGHTGUN_AUX_C            8
#define RETRO_DEVICE_ID_LIGHTGUN_DPAD_UP          9
#define RETRO_DEVICE_ID_LIGHTGUN_DPAD_DOWN       10
#define RETRO_DEVICE_ID_LIGHTGUN_DPAD_LEFT       11
#define RETRO_DEVICE_ID_LIGHTGUN_DPAD_RIGHT      12
/* deprecated */
#define RETRO_DEVICE_ID_LIGHTGUN_X                0 /*Relative Position*/
#define RETRO_DEVICE_ID_LIGHTGUN_Y                1 /*Relative Position*/
#define RETRO_DEVICE_ID_LIGHTGUN_CURSOR           3 /*Use Aux:A instead*/
#define RETRO_DEVICE_ID_LIGHTGUN_TURBO            4 /*Use Aux:B instead*/
#define RETRO_DEVICE_ID_LIGHTGUN_PAUSE            5 /*Use Start instead*/

/* Id values for POINTER. */
#define RETRO_DEVICE_ID_POINTER_X             0
#define RETRO_DEVICE_ID_POINTER_Y             1
#define RETRO_DEVICE_ID_POINTER_PRESSED       2
#define RETRO_DEVICE_ID_POINTER_COUNT         3
/** Indicates if pointer is off the screen or near the edge */
#define RETRO_DEVICE_ID_POINTER_IS_OFFSCREEN 15
/** @} */

/* Returned from retro_get_region(). */
#define RETRO_REGION_NTSC  0
#define RETRO_REGION_PAL   1

/**
 * Identifiers for supported languages.
 * @see RETRO_ENVIRONMENT_GET_LANGUAGE
 */
enum retro_language
{
   RETRO_LANGUAGE_ENGLISH             = 0,
   RETRO_LANGUAGE_JAPANESE            = 1,
   RETRO_LANGUAGE_FRENCH              = 2,
   RETRO_LANGUAGE_SPANISH             = 3,
   RETRO_LANGUAGE_GERMAN              = 4,
   RETRO_LANGUAGE_ITALIAN             = 5,
   RETRO_LANGUAGE_DUTCH               = 6,
   RETRO_LANGUAGE_PORTUGUESE_BRAZIL   = 7,
   RETRO_LANGUAGE_PORTUGUESE_PORTUGAL = 8,
   RETRO_LANGUAGE_RUSSIAN             = 9,
   RETRO_LANGUAGE_KOREAN              = 10,
   RETRO_LANGUAGE_CHINESE_TRADITIONAL = 11,
   RETRO_LANGUAGE_CHINESE_SIMPLIFIED  = 12,
   RETRO_LANGUAGE_ESPERANTO           = 13,
   RETRO_LANGUAGE_POLISH              = 14,
   RETRO_LANGUAGE_VIETNAMESE          = 15,
   RETRO_LANGUAGE_ARABIC              = 16,
   RETRO_LANGUAGE_GREEK               = 17,
   RETRO_LANGUAGE_TURKISH             = 18,
   RETRO_LANGUAGE_SLOVAK              = 19,
   RETRO_LANGUAGE_PERSIAN             = 20,
   RETRO_LANGUAGE_HEBREW              = 21,
   RETRO_LANGUAGE_ASTURIAN            = 22,
   RETRO_LANGUAGE_FINNISH             = 23,
   RETRO_LANGUAGE_INDONESIAN          = 24,
   RETRO_LANGUAGE_SWEDISH             = 25,
   RETRO_LANGUAGE_UKRAINIAN           = 26,
   RETRO_LANGUAGE_CZECH               = 27,
   RETRO_LANGUAGE_CATALAN_VALENCIA    = 28,
   RETRO_LANGUAGE_CATALAN             = 29,
   RETRO_LANGUAGE_BRITISH_ENGLISH     = 30,
   RETRO_LANGUAGE_HUNGARIAN           = 31,
   RETRO_LANGUAGE_BELARUSIAN          = 32,
   RETRO_LANGUAGE_GALICIAN            = 33,
   RETRO_LANGUAGE_NORWEGIAN           = 34,
   RETRO_LANGUAGE_IRISH               = 35,
   RETRO_LANGUAGE_LAST,

   /** Defined to ensure that <tt>sizeof(retro_language) == sizeof(int)</tt>. Do not use. */
   RETRO_LANGUAGE_DUMMY          = INT_MAX
};

/** @defgroup RETRO_MEMORY Memory Types
 * @{
 */

/* Passed to retro_get_memory_data/size().
 * If the memory type doesn't apply to the
 * implementation NULL/0 can be returned.
 */
#define RETRO_MEMORY_MASK        0xff

/* Regular save RAM. This RAM is usually found on a game cartridge,
 * backed up by a battery.
 * If save game data is too complex for a single memory buffer,
 * the SAVE_DIRECTORY (preferably) or SYSTEM_DIRECTORY environment
 * callback can be used. */
#define RETRO_MEMORY_SAVE_RAM    0

/* Some games have a built-in clock to keep track of time.
 * This memory is usually just a couple of bytes to keep track of time.
 */
#define RETRO_MEMORY_RTC         1

/* System ram lets a frontend peek into a game systems main RAM. */
#define RETRO_MEMORY_SYSTEM_RAM  2

/* Video ram lets a frontend peek into a game systems video RAM (VRAM). */
#define RETRO_MEMORY_VIDEO_RAM   3

/* ROM lets a frontend peek into a game systems ROM. */
#define RETRO_MEMORY_ROM   4

/** @} */

/* Keysyms used for ID in input state callback when polling RETRO_KEYBOARD. */
enum retro_key
{
   RETROK_UNKNOWN        = 0,
   RETROK_FIRST          = 0,
   RETROK_BACKSPACE      = 8,
   RETROK_TAB            = 9,
   RETROK_CLEAR          = 12,
   RETROK_RETURN         = 13,
   RETROK_PAUSE          = 19,
   RETROK_ESCAPE         = 27,
   RETROK_SPACE          = 32,
   RETROK_EXCLAIM        = 33,
   RETROK_QUOTEDBL       = 34,
   RETROK_HASH           = 35,
   RETROK_DOLLAR         = 36,
   RETROK_AMPERSAND      = 38,
   RETROK_QUOTE          = 39,
   RETROK_LEFTPAREN      = 40,
   RETROK_RIGHTPAREN     = 41,
   RETROK_ASTERISK       = 42,
   RETROK_PLUS           = 43,
   RETROK_COMMA          = 44,
   RETROK_MINUS          = 45,
   RETROK_PERIOD         = 46,
   RETROK_SLASH          = 47,
   RETROK_0              = 48,
   RETROK_1              = 49,
   RETROK_2              = 50,
   RETROK_3              = 51,
   RETROK_4              = 52,
   RETROK_5              = 53,
   RETROK_6              = 54,
   RETROK_7              = 55,
   RETROK_8              = 56,
   RETROK_9              = 57,
   RETROK_COLON          = 58,
   RETROK_SEMICOLON      = 59,
   RETROK_LESS           = 60,
   RETROK_EQUALS         = 61,
   RETROK_GREATER        = 62,
   RETROK_QUESTION       = 63,
   RETROK_AT             = 64,
   RETROK_LEFTBRACKET    = 91,
   RETROK_BACKSLASH      = 92,
   RETROK_RIGHTBRACKET   = 93,
   RETROK_CARET          = 94,
   RETROK_UNDERSCORE     = 95,
   RETROK_BACKQUOTE      = 96,
   RETROK_a              = 97,
   RETROK_b              = 98,
   RETROK_c              = 99,
   RETROK_d              = 100,
   RETROK_e              = 101,
   RETROK_f              = 102,
   RETROK_g              = 103,
   RETROK_h              = 104,
   RETROK_i              = 105,
   RETROK_j              = 106,
   RETROK_k              = 107,
   RETROK_l              = 108,
   RETROK_m              = 109,
   RETROK_n              = 110,
   RETROK_o              = 111,
   RETROK_p              = 112,
   RETROK_q              = 113,
   RETROK_r              = 114,
   RETROK_s              = 115,
   RETROK_t              = 116,
   RETROK_u              = 117,
   RETROK_v              = 118,
   RETROK_w              = 119,
   RETROK_x              = 120,
   RETROK_y              = 121,
   RETROK_z              = 122,
   RETROK_LEFTBRACE      = 123,
   RETROK_BAR            = 124,
   RETROK_RIGHTBRACE     = 125,
   RETROK_TILDE          = 126,
   RETROK_DELETE         = 127,

   RETROK_KP0            = 256,
   RETROK_KP1            = 257,
   RETROK_KP2            = 258,
   RETROK_KP3            = 259,
   RETROK_KP4            = 260,
   RETROK_KP5            = 261,
   RETROK_KP6            = 262,
   RETROK_KP7            = 263,
   RETROK_KP8            = 264,
   RETROK_KP9            = 265,
   RETROK_KP_PERIOD      = 266,
   RETROK_KP_DIVIDE      = 267,
   RETROK_KP_MULTIPLY    = 268,
   RETROK_KP_MINUS       = 269,
   RETROK_KP_PLUS        = 270,
   RETROK_KP_ENTER       = 271,
   RETROK_KP_EQUALS      = 272,

   RETROK_UP             = 273,
   RETROK_DOWN           = 274,
   RETROK_RIGHT          = 275,
   RETROK_LEFT           = 276,
   RETROK_INSERT         = 277,
   RETROK_HOME           = 278,
   RETROK_END            = 279,
   RETROK_PAGEUP         = 280,
   RETROK_PAGEDOWN       = 281,

   RETROK_F1             = 282,
   RETROK_F2             = 283,
   RETROK_F3             = 284,
   RETROK_F4             = 285,
   RETROK_F5             = 286,
   RETROK_F6             = 287,
   RETROK_F7             = 288,
   RETROK_F8             = 289,
   RETROK_F9             = 290,
   RETROK_F10            = 291,
   RETROK_F11            = 292,
   RETROK_F12            = 293,
   RETROK_F13            = 294,
   RETROK_F14            = 295,
   RETROK_F15            = 296,

   RETROK_NUMLOCK        = 300,
   RETROK_CAPSLOCK       = 301,
   RETROK_SCROLLOCK      = 302,
   RETROK_RSHIFT         = 303,
   RETROK_LSHIFT         = 304,
   RETROK_RCTRL          = 305,
   RETROK_LCTRL          = 306,
   RETROK_RALT           = 307,
   RETROK_LALT           = 308,
   RETROK_RMETA          = 309,
   RETROK_LMETA          = 310,
   RETROK_LSUPER         = 311,
   RETROK_RSUPER         = 312,
   RETROK_MODE           = 313,
   RETROK_COMPOSE        = 314,

   RETROK_HELP           = 315,
   RETROK_PRINT          = 316,
   RETROK_SYSREQ         = 317,
   RETROK_BREAK          = 318,
   RETROK_MENU           = 319,
   RETROK_POWER          = 320,
   RETROK_EURO           = 321,
   RETROK_UNDO           = 322,
   RETROK_OEM_102        = 323,

   RETROK_BROWSER_BACK      = 324,
   RETROK_BROWSER_FORWARD   = 325,
   RETROK_BROWSER_REFRESH   = 326,
   RETROK_BROWSER_STOP      = 327,
   RETROK_BROWSER_SEARCH    = 328,
   RETROK_BROWSER_FAVORITES = 329,
   RETROK_BROWSER_HOME      = 330,
   RETROK_VOLUME_MUTE       = 331,
   RETROK_VOLUME_DOWN       = 332,
   RETROK_VOLUME_UP         = 333,
   RETROK_MEDIA_NEXT        = 334,
   RETROK_MEDIA_PREV        = 335,
   RETROK_MEDIA_STOP        = 336,
   RETROK_MEDIA_PLAY_PAUSE  = 337,
   RETROK_LAUNCH_MAIL       = 338,
   RETROK_LAUNCH_MEDIA      = 339,
   RETROK_LAUNCH_APP1       = 340,
   RETROK_LAUNCH_APP2       = 341,

   RETROK_LAST,

   RETROK_DUMMY          = INT_MAX /* Ensure sizeof(enum) == sizeof(int) */
};

enum retro_mod
{
   RETROKMOD_NONE       = 0x0000,

   RETROKMOD_SHIFT      = 0x01,
   RETROKMOD_CTRL       = 0x02,
   RETROKMOD_ALT        = 0x04,
   RETROKMOD_META       = 0x08,

   RETROKMOD_NUMLOCK    = 0x10,
   RETROKMOD_CAPSLOCK   = 0x20,
   RETROKMOD_SCROLLOCK  = 0x40,

   RETROKMOD_DUMMY = INT_MAX /* Ensure sizeof(enum) == sizeof(int) */
};

/**
 * @defgroup RETRO_ENVIRONMENT Environment Callbacks
 * @{
 */

/**
 * This bit indicates that the associated environment call is experimental,
 * and may be changed or removed in the future.
 * Frontends should mask out this bit before handling the environment call.
 */
#define RETRO_ENVIRONMENT_EXPERIMENTAL 0x10000

/** Frontend-internal environment callbacks should include this bit. */
#define RETRO_ENVIRONMENT_PRIVATE 0x20000

/* Environment commands. */
/**
 * Requests the frontend to set the screen rotation.
 *
 * @param[in] data <tt>const unsigned*</tt>.
 * Valid values are 0, 1, 2, and 3.
 * These numbers respectively set the screen rotation to 0, 90, 180, and 270 degrees counter-clockwise.
 * @returns \c true if the screen rotation was set successfully.
 */
#define RETRO_ENVIRONMENT_SET_ROTATION  1

/**
 * Queries whether the core should use overscan or not.
 *
 * @param[out] data <tt>bool*</tt>.
 * Set to \c true if the core should use overscan,
 * \c false if it should be cropped away.
 * @returns \c true if the environment call is available.
 * Does \em not indicate whether overscan should be used.
 * @deprecated As of 2019 this callback is considered deprecated in favor of
 * using core options to manage overscan in a more nuanced, core-specific way.
 */
#define RETRO_ENVIRONMENT_GET_OVERSCAN  2

/**
 * Queries whether the frontend supports frame duping,
 * in the form of passing \c NULL to the video frame callback.
 *
 * @param[out] data <tt>bool*</tt>.
 * Set to \c true if the frontend supports frame duping.
 * @returns \c true if the environment call is available.
 * @see retro_video_refresh_t
 */
#define RETRO_ENVIRONMENT_GET_CAN_DUPE  3

/*
 * Environ 4, 5 are no longer supported (GET_VARIABLE / SET_VARIABLES),
 * and reserved to avoid possible ABI clash.
 */

/**
 * @brief Displays a user-facing message for a short time.
 *
 * Use this callback to convey important status messages,
 * such as errors or the result of long-running operations.
 * For trivial messages or logging, use \c RETRO_ENVIRONMENT_GET_LOG_INTERFACE or \c stderr.
 *
 * \code{.c}
 * void set_message_example(void)
 * {
 *    struct retro_message msg;
 *    msg.frames = 60 * 5; // 5 seconds
 *    msg.msg = "Hello world!";
 *
 *    environ_cb(RETRO_ENVIRONMENT_SET_MESSAGE, &msg);
 * }
 * \endcode
 *
 * @deprecated Prefer using \c RETRO_ENVIRONMENT_SET_MESSAGE_EXT for new code,
 * as it offers more features.
 * Only use this environment call for compatibility with older cores or frontends.
 *
 * @param[in] data <tt>const struct retro_message*</tt>.
 * Details about the message to show to the user.
 * Behavior is undefined if <tt>NULL</tt>.
 * @returns \c true if the environment call is available.
 * @see retro_message
 * @see RETRO_ENVIRONMENT_GET_LOG_INTERFACE
 * @see RETRO_ENVIRONMENT_SET_MESSAGE_EXT
 * @see RETRO_ENVIRONMENT_SET_MESSAGE
 * @see RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION
 * @note The frontend must make its own copy of the message and the underlying string.
 */
#define RETRO_ENVIRONMENT_SET_MESSAGE   6

/**
 * Requests the frontend to shutdown the core.
 * Should only be used if the core can exit on its own,
 * such as from a menu item in a game
 * or an emulated power-off in an emulator.
 *
 * @param data Ignored.
 * @returns \c true if the environment call is available.
 */
#define RETRO_ENVIRONMENT_SHUTDOWN      7

/**
 * Gives a hint to the frontend of how demanding this core is on the system.
 * For example, reporting a level of 2 means that
 * this implementation should run decently on frontends
 * of level 2 and above.
 *
 * It can be used by the frontend to potentially warn
 * about too demanding implementations.
 *
 * The levels are "floating".
 *
 * This function can be called on a per-game basis,
 * as a core may have different demands for different games or settings.
 * If called, it should be called in <tt>retro_load_game()</tt>.
 * @param[in] data <tt>const unsigned*</tt>.
*/
#define RETRO_ENVIRONMENT_SET_PERFORMANCE_LEVEL 8

/**
 * Returns the path to the frontend's system directory,
 * which can be used to store system-specific configuration
 * such as BIOS files or cached data.
 *
 * @param[out] data <tt>const char**</tt>.
 * Pointer to the \c char* in which the system directory will be saved.
 * The string is managed by the frontend and must not be modified or freed by the core.
 * May be \c NULL if no system directory is defined,
 * in which case the core should find an alternative directory.
 * @return \c true if the environment call is available,
 * even if the value returned in \c data is <tt>NULL</tt>.
 * @note Historically, some cores would use this folder for save data such as memory cards or SRAM.
 * This is now discouraged in favor of \c RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY.
 * @see RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY
 */
#define RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY 9

/**
 * Sets the internal pixel format used by the frontend for rendering.
 * The default pixel format is \c RETRO_PIXEL_FORMAT_0RGB1555 for compatibility reasons,
 * although it's considered deprecated and shouldn't be used by new code.
 *
 * @param[in] data <tt>const enum retro_pixel_format *</tt>.
 * Pointer to the pixel format to use.
 * @returns \c true if the pixel format was set successfully,
 * \c false if it's not supported or this callback is unavailable.
 * @note This function should be called inside \c retro_load_game()
 * or <tt>retro_get_system_av_info()</tt>.
 * @see retro_pixel_format
 */
#define RETRO_ENVIRONMENT_SET_PIXEL_FORMAT 10

/**
 * Sets an array of input descriptors for the frontend
 * to present to the user for configuring the core's controls.
 *
 * This function can be called at any time,
 * preferably early in the core's life cycle.
 * Ideally, no later than \c retro_load_game().
 *
 * @param[in] data <tt>const struct retro_input_descriptor *</tt>.
 * An array of input descriptors terminated by one whose
 * \c retro_input_descriptor::description field is set to \c NULL.
 * Behavior is undefined if \c NULL.
 * @return \c true if the environment call is recognized.
 * @see retro_input_descriptor
 */
#define RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS 11

/**
 * Sets a callback function used to notify the core about keyboard events.
 * This should only be used for cores that specifically need keyboard input,
 * such as for home computer emulators or games with text entry.
 *
 * @param[in] data <tt>const struct retro_keyboard_callback *</tt>.
 * Pointer to the callback function.
 * Behavior is undefined if <tt>NULL</tt>.
 * @return \c true if the environment call is recognized.
 * @see retro_keyboard_callback
 * @see retro_key
 */
#define RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK 12

/**
 * Sets an interface that the frontend can use to insert and remove disks
 * from the emulated console's disk drive.
 * Can be used for optical disks, floppy disks, or any other game storage medium
 * that can be swapped at runtime.
 *
 * This is intended for multi-disk games that expect the player
 * to manually swap disks at certain points in the game.
 *
 * @deprecated Prefer using \c RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE
 * over this environment call, as it supports additional features.
 * Only use this callback to maintain compatibility
 * with older cores or frontends.
 *
 * @param[in] data <tt>const struct retro_disk_control_callback *</tt>.
 * Pointer to the callback functions to use.
 * May be \c NULL, in which case the existing disk callback is deregistered.
 * @return \c true if this environment call is available,
 * even if \c data is \c NULL.
 * @see retro_disk_control_callback
 * @see RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE
 */
#define RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE 13

/**
 * Requests that a frontend enable a particular hardware rendering API.
 *
 * If successful, the frontend will create a context (and other related resources)
 * that the core can use for rendering.
 * The framebuffer will be at least as large as
 * the maximum dimensions provided in <tt>retro_get_system_av_info</tt>.
 *
 * @param[in, out] data <tt>struct retro_hw_render_callback *</tt>.
 * Pointer to the hardware render callback struct.
 * Used to define callbacks for the hardware-rendering life cycle,
 * as well as to request a particular rendering API.
 * @return \c true if the environment call is recognized
 * and the requested rendering API is supported.
 * \c false if \c data is \c NULL
 * or the frontend can't provide the requested rendering API.
 * @see retro_hw_render_callback
 * @see retro_video_refresh_t
 * @see RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER
 * @note Should be called in <tt>retro_load_game()</tt>.
 * @note If HW rendering is used, pass only \c RETRO_HW_FRAME_BUFFER_VALID or
 * \c NULL to <tt>retro_video_refresh_t</tt>.
 */
#define RETRO_ENVIRONMENT_SET_HW_RENDER 14

/**
 * Retrieves a core option's value from the frontend.
 * \c retro_variable::key should be set to an option key
 * that was previously set in \c RETRO_ENVIRONMENT_SET_VARIABLES
 * (or a similar environment call).
 *
 * @param[in,out] data <tt>struct retro_variable *</tt>.
 * Pointer to a single \c retro_variable struct.
 * See the documentation for \c retro_variable for details
 * on which fields are set by the frontend or core.
 * May be \c NULL.
 * @returns \c true if the environment call is available,
 * even if \c data is \c NULL or the key it specifies is not found.
 * @note Passing \c NULL in to \c data can be useful to
 * test for support of this environment call without looking up any variables.
 * @see retro_variable
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 * @see RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE
 */
#define RETRO_ENVIRONMENT_GET_VARIABLE 15

/**
 * Notifies the frontend of the core's available options.
 *
 * The core may check these options later using \c RETRO_ENVIRONMENT_GET_VARIABLE.
 * The frontend may also present these options to the user
 * in its own configuration UI.
 *
 * This should be called the first time as early as possible,
 * ideally in \c retro_set_environment.
 * The core may later call this function again
 * to communicate updated options to the frontend,
 * but the number of core options must not change.
 *
 * Here's an example that sets two options.
 *
 * @code
 * void set_variables_example(void)
 * {
 *    struct retro_variable options[] = {
 *        { "foo_speedhack", "Speed hack; false|true" }, // false by default
 *        { "foo_displayscale", "Display scale factor; 1|2|3|4" }, // 1 by default
 *        { NULL, NULL },
 *    };
 *
 *    environ_cb(RETRO_ENVIRONMENT_SET_VARIABLES, &options);
 * }
 * @endcode
 *
 * The possible values will generally be displayed and stored as-is by the frontend.
 *
 * @deprecated Prefer using \c RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 for new code,
 * as it offers more features such as categories and translation.
 * Only use this environment call to maintain compatibility
 * with older frontends or cores.
 * @note Keep the available options (and their possible values) as low as possible;
 * it should be feasible to cycle through them without a keyboard.
 * @param[in] data <tt>const struct retro_variable *</tt>.
 * Pointer to an array of \c retro_variable structs that define available core options,
 * terminated by a <tt>{ NULL, NULL }</tt> element.
 * The frontend must maintain its own copy of this array.
 *
 * @returns \c true if the environment call is available,
 * even if \c data is <tt>NULL</tt>.
 * @see retro_variable
 * @see RETRO_ENVIRONMENT_GET_VARIABLE
 * @see RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 */
#define RETRO_ENVIRONMENT_SET_VARIABLES 16

/**
 * Queries whether at least one core option was updated by the frontend
 * since the last call to \ref RETRO_ENVIRONMENT_GET_VARIABLE.
 * This typically means that the user opened the core options menu and made some changes.
 *
 * Cores usually call this each frame before the core's main emulation logic.
 * Specific options can then be queried with \ref RETRO_ENVIRONMENT_GET_VARIABLE.
 *
 * @param[out] data <tt>bool *</tt>.
 * Set to \c true if at least one core option was updated
 * since the last call to \ref RETRO_ENVIRONMENT_GET_VARIABLE.
 * Behavior is undefined if this pointer is \c NULL.
 * @returns \c true if the environment call is available.
 * @see RETRO_ENVIRONMENT_GET_VARIABLE
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 */
#define RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE 17

/**
 * Notifies the frontend that this core can run without loading any content,
 * such as when emulating a console that has built-in software.
 * When a core is loaded without content,
 * \c retro_load_game receives an argument of <tt>NULL</tt>.
 * This should be called within \c retro_set_environment() only.
 *
 * @param[in] data <tt>const bool *</tt>.
 * Pointer to a single \c bool that indicates whether this frontend can run without content.
 * Can point to a value of \c false but this isn't necessary,
 * as contentless support is opt-in.
 * The behavior is undefined if \c data is <tt>NULL</tt>.
 * @returns \c true if the environment call is available.
 * @see retro_load_game
 */
#define RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME 18

/**
 * Retrieves the absolute path from which this core was loaded.
 * Useful when loading assets from paths relative to the core,
 * as is sometimes the case when using <tt>RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME</tt>.
 *
 * @param[out] data <tt>const char **</tt>.
 * Pointer to a string in which the core's path will be saved.
 * The string is managed by the frontend and must not be modified or freed by the core.
 * May be \c NULL if the core is statically linked to the frontend
 * or if the core's path otherwise cannot be determined.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * @returns \c true if the environment call is available.
 */
#define RETRO_ENVIRONMENT_GET_LIBRETRO_PATH 19

/* Environment call 20 was an obsolete version of SET_AUDIO_CALLBACK.
 * It was not used by any known core at the time, and was removed from the API.
 * The number 20 is reserved to prevent ABI clashes.
 */

/**
 * Sets a callback that notifies the core of how much time has passed
 * since the last iteration of <tt>retro_run</tt>.
 * If the frontend is not running the core in real time
 * (e.g. it's frame-stepping or running in slow motion),
 * then the reference value will be provided to the callback instead.
 *
 * @param[in] data <tt>const struct retro_frame_time_callback *</tt>.
 * Pointer to a single \c retro_frame_time_callback struct.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * @returns \c true if the environment call is available.
 * @note Frontends may disable this environment call in certain situations.
 * It will return \c false in those cases.
 * @see retro_frame_time_callback
 */
#define RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK 21

/**
 * Registers a set of functions that the frontend can use
 * to tell the core it's ready for audio output.
 *
 * It is intended for games that feature asynchronous audio.
 * It should not be used for emulators unless their audio is asynchronous.
 *
 *
 * The callback only notifies about writability; the libretro core still
 * has to call the normal audio callbacks
 * to write audio. The audio callbacks must be called from within the
 * notification callback.
 * The amount of audio data to write is up to the core.
 * Generally, the audio callback will be called continuously in a loop.
 *
 * A frontend may disable this callback in certain situations.
 * The core must be able to render audio with the "normal" interface.
 *
 * @param[in] data <tt>const struct retro_audio_callback *</tt>.
 * Pointer to a set of functions that the frontend will call to notify the core
 * when it's ready to receive audio data.
 * May be \c NULL, in which case the frontend will return
 * whether this environment callback is available.
 * @return \c true if this environment call is available,
 * even if \c data is \c NULL.
 * @warning The provided callbacks can be invoked from any thread,
 * so their implementations \em must be thread-safe.
 * @note If a core uses this callback,
 * it should also use <tt>RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK</tt>.
 * @see retro_audio_callback
 * @see retro_audio_sample_t
 * @see retro_audio_sample_batch_t
 * @see RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK
 */
#define RETRO_ENVIRONMENT_SET_AUDIO_CALLBACK 22

/**
 * Gets an interface that a core can use to access a controller's rumble motors.
 *
 * The interface supports two independently-controlled motors,
 * one strong and one weak.
 *
 * Should be called from either \c retro_init() or \c retro_load_game(),
 * but not from \c retro_set_environment().
 *
 * @param[out] data <tt>struct retro_rumble_interface *</tt>.
 * Pointer to the interface struct.
 * Behavior is undefined if \c NULL.
 * @returns \c true if the environment call is available,
 * even if the current device doesn't support vibration.
 * @see retro_rumble_interface
 * @defgroup GET_RUMBLE_INTERFACE Rumble Interface
 */
#define RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE 23

/**
 * Returns the frontend's supported input device types.
 *
 * The supported device types are returned as a bitmask,
 * with each value of \ref RETRO_DEVICE corresponding to a bit.
 *
 * Should only be called in \c retro_run().
 *
 * @code
 * #define REQUIRED_DEVICES ((1 << RETRO_DEVICE_JOYPAD) | (1 << RETRO_DEVICE_ANALOG))
 * void get_input_device_capabilities_example(void)
 * {
 *    uint64_t capabilities;
 *    environ_cb(RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES, &capabilities);
 *    if ((capabilities & REQUIRED_DEVICES) == REQUIRED_DEVICES)
 *      printf("Joypad and analog device types are supported");
 * }
 * @endcode
 *
 * @param[out] data <tt>uint64_t *</tt>.
 * Pointer to a bitmask of supported input device types.
 * If the frontend supports a particular \c RETRO_DEVICE_* type,
 * then the bit <tt>(1 << RETRO_DEVICE_*)</tt> will be set.
 *
 * Each bit represents a \c RETRO_DEVICE constant,
 * e.g. bit 1 represents \c RETRO_DEVICE_JOYPAD,
 * bit 2 represents \c RETRO_DEVICE_MOUSE, and so on.
 *
 * Bits that do not correspond to known device types will be set to zero
 * and are reserved for future use.
 *
 * Behavior is undefined if \c NULL.
 * @returns \c true if the environment call is available.
 * @note If the frontend supports multiple input drivers,
 * availability of this environment call (and the reported capabilities)
 * may depend on the active driver.
 * @see RETRO_DEVICE
 */
#define RETRO_ENVIRONMENT_GET_INPUT_DEVICE_CAPABILITIES 24

/**
 * Returns an interface that the core can use to access and configure available sensors,
 * such as an accelerometer or gyroscope.
 *
 * @param[out] data <tt>struct retro_sensor_interface *</tt>.
 * Pointer to the sensor interface that the frontend will populate.
 * Behavior is undefined if is \c NULL.
 * @returns \c true if the environment call is available,
 * even if the device doesn't have any supported sensors.
 * @see retro_sensor_interface
 * @see retro_sensor_action
 * @see RETRO_SENSOR
 * @addtogroup RETRO_SENSOR
 */
#define RETRO_ENVIRONMENT_GET_SENSOR_INTERFACE (25 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Gets an interface to the device's video camera.
 *
 * The frontend delivers new video frames via a user-defined callback
 * that runs in the same thread as \c retro_run().
 * Should be called in \c retro_load_game().
 *
 * @param[in,out] data <tt>struct retro_camera_callback *</tt>.
 * Pointer to the camera driver interface.
 * Some fields in the struct must be filled in by the core,
 * others are provided by the frontend.
 * Behavior is undefined if \c NULL.
 * @returns \c true if this environment call is available,
 * even if an actual camera isn't.
 * @note This API only supports one video camera at a time.
 * If the device provides multiple cameras (e.g. inner/outer cameras on a phone),
 * the frontend will choose one to use.
 * @see retro_camera_callback
 * @see RETRO_ENVIRONMENT_SET_HW_RENDER
 */
#define RETRO_ENVIRONMENT_GET_CAMERA_INTERFACE (26 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Gets an interface that the core can use for cross-platform logging.
 * Certain platforms don't have a console or <tt>stderr</tt>,
 * or they have their own preferred logging methods.
 * The frontend itself may also display log output.
 *
 * @attention This should not be used for information that the player must immediately see,
 * such as major errors or warnings.
 * In most cases, this is best for information that will help you (the developer)
 * identify problems when debugging or providing support.
 * Unless a core or frontend is intended for advanced users,
 * the player might not check (or even know about) their logs.
 *
 * @param[out] data <tt>struct retro_log_callback *</tt>.
 * Pointer to the callback where the function pointer will be saved.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * @returns \c true if the environment call is available.
 * @see retro_log_callback
 * @note Cores can fall back to \c stderr if this interface is not available.
 */
#define RETRO_ENVIRONMENT_GET_LOG_INTERFACE 27

/**
 * Returns an interface that the core can use for profiling code
 * and to access performance-related information.
 *
 * This callback supports performance counters, a high-resolution timer,
 * and listing available CPU features (mostly SIMD instructions).
 *
 * @param[out] data <tt>struct retro_perf_callback *</tt>.
 * Pointer to the callback interface.
 * Behavior is undefined if \c NULL.
 * @returns \c true if the environment call is available.
 * @see retro_perf_callback
 */
#define RETRO_ENVIRONMENT_GET_PERF_INTERFACE 28

/**
 * Returns an interface that the core can use to retrieve the device's location,
 * including its current latitude and longitude.
 *
 * @param[out] data <tt>struct retro_location_callback *</tt>.
 * Pointer to the callback interface.
 * Behavior is undefined if \c NULL.
 * @return \c true if the environment call is available,
 * even if there's no location information available.
 * @see retro_location_callback
 */
#define RETRO_ENVIRONMENT_GET_LOCATION_INTERFACE 29

/**
 * @deprecated An obsolete alias to \c RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY kept for compatibility.
 * @see RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY
 **/
#define RETRO_ENVIRONMENT_GET_CONTENT_DIRECTORY 30

/**
 * Returns the frontend's "core assets" directory,
 * which can be used to store assets that the core needs
 * such as art assets or level data.
 *
 * @param[out] data <tt>const char **</tt>.
 * Pointer to a string in which the core assets directory will be saved.
 * This string is managed by the frontend and must not be modified or freed by the core.
 * May be \c NULL if no core assets directory is defined,
 * in which case the core should find an alternative directory.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * @returns \c true if the environment call is available,
 * even if the value returned in \c data is <tt>NULL</tt>.
 */
#define RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY 30

/**
 * Returns the frontend's save data directory, if available.
 * This directory should be used to store game-specific save data,
 * including memory card images.
 *
 * Although libretro provides an interface for cores to expose SRAM to the frontend,
 * not all cores can support it correctly.
 * In this case, cores should use this environment callback
 * to save their game data to disk manually.
 *
 * Cores that use this environment callback
 * should flush their save data to disk periodically and when unloading.
 *
 * @param[out] data <tt>const char **</tt>.
 * Pointer to the string in which the save data directory will be saved.
 * This string is managed by the frontend and must not be modified or freed by the core.
 * May return \c NULL if no save data directory is defined.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * @returns \c true if the environment call is available,
 * even if the value returned in \c data is <tt>NULL</tt>.
 * @note Early libretro cores used \c RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY for save data.
 * This is still supported for backwards compatibility,
 * but new cores should use this environment call instead.
 * \c RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY should be used for game-agnostic data
 * such as BIOS files or core-specific configuration.
 * @note The returned directory may or may not be the same
 * as the one used for \c retro_get_memory_data.
 *
 * @see retro_get_memory_data
 * @see RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY
 */
#define RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY 31

/**
 * Sets new video and audio parameters for the core.
 * This can only be called from within <tt>retro_run</tt>.
 *
 * This environment call may entail a full reinitialization of the frontend's audio/video drivers,
 * hence it should \em only be used if the core needs to make drastic changes
 * to audio/video parameters.
 *
 * This environment call should \em not be used when:
 * <ul>
 * <li>Changing the emulated system's internal resolution,
 * within the limits defined by the existing values of \c max_width and \c max_height.
 * Use \c RETRO_ENVIRONMENT_SET_GEOMETRY instead,
 * and adjust \c retro_get_system_av_info to account for
 * supported scale factors and screen layouts
 * when computing \c max_width and \c max_height.
 * Only use this environment call if \c max_width or \c max_height needs to increase.
 * <li>Adjusting the screen's aspect ratio,
 * e.g. when changing the layout of the screen(s).
 * Use \c RETRO_ENVIRONMENT_SET_GEOMETRY or \c RETRO_ENVIRONMENT_SET_ROTATION instead.
 * </ul>
 *
 * The frontend will reinitialize its audio and video drivers within this callback;
 * after that happens, audio and video callbacks will target the newly-initialized driver,
 * even within the same \c retro_run call.
 *
 * This callback makes it possible to support configurable resolutions
 * while avoiding the need to compute the "worst case" values of \c max_width and \c max_height.
 *
 * @param[in] data <tt>const struct retro_system_av_info *</tt>.
 * Pointer to the new video and audio parameters that the frontend should adopt.
 * @returns \c true if the environment call is available
 * and the new av_info struct was accepted.
 * \c false if the environment call is unavailable or \c data is <tt>NULL</tt>.
 * @see retro_system_av_info
 * @see RETRO_ENVIRONMENT_SET_GEOMETRY
 */
#define RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO 32

/**
 * Provides an interface that a frontend can use
 * to get function pointers from the core.
 *
 * This allows cores to define their own extensions to the libretro API,
 * or to expose implementations of a frontend's libretro extensions.
 *
 * @param[in] data <tt>const struct retro_get_proc_address_interface *</tt>.
 * Pointer to the interface that the frontend can use to get function pointers from the core.
 * The frontend must maintain its own copy of this interface.
 * @returns \c true if the environment call is available
 * and the returned interface was accepted.
 * @note The provided interface may be called at any time,
 * even before this environment call returns.
 * @note Extensions should be prefixed with the name of the frontend or core that defines them.
 * For example, a frontend named "foo" that defines a debugging extension
 * should expect the core to define functions prefixed with "foo_debug_".
 * @warning If a core wants to use this environment call,
 * it \em must do so from within \c retro_set_environment().
 * @see retro_get_proc_address_interface
 */
#define RETRO_ENVIRONMENT_SET_PROC_ADDRESS_CALLBACK 33

/**
 * Registers a core's ability to handle "subsystems",
 * which are secondary platforms that augment a core's primary emulated hardware.
 *
 * A core doesn't need to emulate a secondary platform
 * in order to use it as a subsystem;
 * as long as it can load a secondary file for some practical use,
 * then this environment call is most likely suitable.
 *
 * Possible use cases of a subsystem include:
 *
 * \li Installing software onto an emulated console's internal storage,
 * such as the Nintendo DSi.
 * \li Emulating accessories that are used to support another console's games,
 * such as the Super Game Boy or the N64 Transfer Pak.
 * \li Inserting a secondary ROM into a console
 * that features multiple cartridge ports,
 * such as the Nintendo DS's Slot-2.
 * \li Loading a save data file created and used by another core.
 *
 * Cores should \em not use subsystems for:
 *
 * \li Emulators that support multiple "primary" platforms,
 * such as a Game Boy/Game Boy Advance core
 * or a Sega Genesis/Sega CD/32X core.
 * Use \c retro_system_content_info_override, \c retro_system_info,
 * and/or runtime detection instead.
 * \li Selecting different memory card images.
 * Use dynamically-populated core options instead.
 * \li Different variants of a single console,
 * such the Game Boy vs. the Game Boy Color.
 * Use core options or runtime detection instead.
 * \li Games that span multiple disks.
 * Use \c RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE
 * and m3u-formatted playlists instead.
 * \li Console system files (BIOS, firmware, etc.).
 * Use \c RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY
 * and a common naming convention instead.
 *
 * When the frontend loads a game via a subsystem,
 * it must call \c retro_load_game_special() instead of \c retro_load_game().
 *
 * @param[in] data <tt>const struct retro_subsystem_info *</tt>.
 * Pointer to an array of subsystem descriptors,
 * terminated by a zeroed-out \c retro_subsystem_info struct.
 * The frontend should maintain its own copy
 * of this array and the strings within it.
 * Behavior is undefined if \c NULL.
 * @returns \c true if this environment call is available.
 * @note This environment call \em must be called from within \c retro_set_environment(),
 * as frontends may need the registered information before loading a game.
 * @see retro_subsystem_info
 * @see retro_load_game_special
 */
#define RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO 34

/**
 * Declares one or more types of controllers supported by this core.
 * The frontend may then allow the player to select one of these controllers in its menu.
 *
 * Many consoles had controllers that came in different versions,
 * were extensible with peripherals,
 * or could be held in multiple ways;
 * this environment call can be used to represent these differences
 * and adjust the core's behavior to match.
 *
 * Possible use cases include:
 *
 * \li Supporting different classes of a single controller that supported their own sets of games.
 *     For example, the SNES had two different lightguns (the Super Scope and the Justifier)
 *     whose games were incompatible with each other.
 * \li Representing a platform's alternative controllers.
 *     For example, several platforms had music/rhythm games that included controllers
 *     shaped like musical instruments.
 * \li Representing variants of a standard controller with additional inputs.
 *     For example, numerous consoles in the 90's introduced 6-button controllers for fighting games,
 *     steering wheels for racing games,
 *     or analog sticks for 3D platformers.
 * \li Representing add-ons for consoles or standard controllers.
 *     For example, the 3DS had a Circle Pad Pro attachment that added a second analog stick.
 * \li Selecting different configurations for a single controller.
 *     For example, the Wii Remote could be held sideways like a traditional game pad
 *     or in one hand like a wand.
 * \li Providing multiple ways to simulate the experience of using a particular controller.
 *     For example, the Game Boy Advance featured several games
 *     with motion or light sensors in their cartridges;
 *     a core could provide controller configurations
 *     that allow emulating the sensors with either analog axes
 *     or with their host device's sensors.
 *
 * Should be called in retro_load_game.
 * The frontend must maintain its own copy of the provided array,
 * including all strings and subobjects.
 * A core may exclude certain controllers for known incompatible games.
 *
 * When the frontend changes the active device for a particular port,
 * it must call \c retro_set_controller_port_device() with that port's index
 * and one of the IDs defined in its retro_controller_info::types field.
 *
 * Input ports are generally associated with different players
 * (and the frontend's UI may reflect this with "Player 1" labels),
 * but this is not required.
 * Some games use multiple controllers for a single player,
 * or some cores may use port indexes to represent an emulated console's
 * alternative input peripherals.
 *
 * @param[in] data <tt>const struct retro_controller_info *</tt>.
 * Pointer to an array of controller types defined by this core,
 * terminated by a zeroed-out \c retro_controller_info.
 * Each element of this array represents a controller port on the emulated device.
 * Behavior is undefined if \c NULL.
 * @returns \c true if this environment call is available.
 * @see retro_controller_info
 * @see retro_set_controller_port_device
 * @see RETRO_DEVICE_SUBCLASS
 */
#define RETRO_ENVIRONMENT_SET_CONTROLLER_INFO 35

/**
 * Notifies the frontend of the address spaces used by the core's emulated hardware,
 * and of the memory maps within these spaces.
 * This can be used by the frontend to provide cheats, achievements, or debugging capabilities.
 * Should only be used by emulators, as it makes little sense for game engines.
 *
 * @note Cores should also expose these address spaces
 * through retro_get_memory_data and \c retro_get_memory_size if applicable;
 * this environment call is not intended to replace those two functions,
 * as the emulated hardware may feature memory regions outside of its own address space
 * that are nevertheless useful for the frontend.
 *
 * @param[in] data <tt>const struct retro_memory_map *</tt>.
 * Pointer to a single memory-map listing.
 * The frontend must maintain its own copy of this object and its contents,
 * including strings and nested objects.
 * Behavior is undefined if \c NULL.
 * @returns \c true if this environment call is available.
 * @see retro_memory_map
 * @see retro_get_memory_data
 * @see retro_memory_descriptor
 */
#define RETRO_ENVIRONMENT_SET_MEMORY_MAPS (36 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Resizes the viewport without reinitializing the video driver.
 *
 * Similar to \c RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO,
 * but any changes that would require video reinitialization will not be performed.
 * Can only be called from within \c retro_run().
 *
 * This environment call allows a core to revise the size of the viewport at will,
 * which can be useful for emulated platforms that support dynamic resolution changes
 * or for cores that support multiple screen layouts.
 *
 * A frontend must guarantee that this environment call completes in
 * constant time.
 *
 * @param[in] data <tt>const struct retro_game_geometry *</tt>.
 * Pointer to the new video parameters that the frontend should adopt.
 * \c retro_game_geometry::max_width and \c retro_game_geometry::max_height
 * will be ignored.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * @return \c true if the environment call is available.
 * @see RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO
 */
#define RETRO_ENVIRONMENT_SET_GEOMETRY 37

/**
 * Returns the name of the user, if possible.
 * This callback is suitable for cores that offer personalization,
 * such as online facilities or user profiles on the emulated system.
 * @param[out] data <tt>const char **</tt>.
 * Pointer to the user name string.
 * May be \c NULL, in which case the core should use a default name.
 * The returned pointer is owned by the frontend and must not be modified or freed by the core.
 * Behavior is undefined if \c NULL.
 * @returns \c true if the environment call is available,
 * even if the frontend couldn't provide a name.
 */
#define RETRO_ENVIRONMENT_GET_USERNAME 38

/**
 * Returns the frontend's configured language.
 * It can be used to localize the core's UI,
 * or to customize the emulated firmware if applicable.
 *
 * @param[out] data <tt>retro_language *</tt>.
 * Pointer to the language identifier.
 * Behavior is undefined if \c NULL.
 * @returns \c true if the environment call is available.
 * @note The returned language may not be the same as the operating system's language.
 * Cores should fall back to the operating system's language (or to English)
 * if the environment call is unavailable or the returned language is unsupported.
 * @see retro_language
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL
 */
#define RETRO_ENVIRONMENT_GET_LANGUAGE 39

/**
 * Returns a frontend-managed framebuffer
 * that the core may render directly into
 *
 * This environment call is provided as an optimization
 * for cores that use software rendering
 * (i.e. that don't use \refitem RETRO_ENVIRONMENT_SET_HW_RENDER "a graphics hardware API");
 * specifically, the intended use case is to allow a core
 * to render directly into frontend-managed video memory,
 * avoiding the bandwidth use that copying a whole framebuffer from core to video memory entails.
 *
 * Must be called every frame if used,
 * as this may return a different framebuffer each frame
 * (e.g. for swap chains).
 * However, a core may render to a different buffer even if this call succeeds.
 *
 * @param[in,out] data <tt>struct retro_framebuffer *</tt>.
 * Pointer to a frontend's frame buffer and accompanying data.
 * Some fields are set by the core, others are set by the frontend.
 * Only guaranteed to be valid for the duration of the current \c retro_run call,
 * and must not be used afterwards.
 * Behavior is undefined if \c NULL.
 * @return \c true if the environment call was recognized
 * and the framebuffer was successfully returned.
 * @see retro_framebuffer
 */
#define RETRO_ENVIRONMENT_GET_CURRENT_SOFTWARE_FRAMEBUFFER (40 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Returns an interface for accessing the data of specific rendering APIs.
 * Not all hardware rendering APIs support or need this.
 *
 * The details of these interfaces are specific to each rendering API.
 *
 * @note \c retro_hw_render_callback::context_reset must be called by the frontend
 * before this environment call can be used.
 * Additionally, the contents of the returned interface are invalidated
 * after \c retro_hw_render_callback::context_destroyed has been called.
 * @param[out] data <tt>const struct retro_hw_render_interface **</tt>.
 * The render interface for the currently-enabled hardware rendering API, if any.
 * The frontend will store a pointer to the interface at the address provided here.
 * The returned interface is owned by the frontend and must not be modified or freed by the core.
 * Behavior is undefined if \c NULL.
 * @return \c true if this environment call is available,
 * the active graphics API has a libretro rendering interface,
 * and the frontend is able to return said interface.
 * \c false otherwise.
 * @see RETRO_ENVIRONMENT_SET_HW_RENDER
 * @see retro_hw_render_interface
 * @note Since not every libretro-supported hardware rendering API
 * has a \c retro_hw_render_interface implementation,
 * a result of \c false is not necessarily an error.
 */
#define RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE (41 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Explicitly notifies the frontend of whether this core supports achievements.
 * The core must expose its emulated address space via
 * \c retro_get_memory_data or \c RETRO_ENVIRONMENT_GET_MEMORY_MAPS.
 * Must be called before the first call to <tt>retro_run</tt>.
 *
 * If \ref retro_get_memory_data returns a valid address
 * but this environment call is not used,
 * the frontend (at its discretion) may or may not opt in the core to its achievements support.
 * whether this core is opted in to the frontend's achievement support
 * is left to the frontend's discretion.
 * @param[in] data <tt>const bool *</tt>.
 * Pointer to a single \c bool that indicates whether this core supports achievements.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * @returns \c true if the environment call is available.
 * @see RETRO_ENVIRONMENT_SET_MEMORY_MAPS
 * @see retro_get_memory_data
 */
#define RETRO_ENVIRONMENT_SET_SUPPORT_ACHIEVEMENTS (42 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Defines an interface that the frontend can use
 * to ask the core for the parameters it needs for a hardware rendering context.
 * The exact semantics depend on \ref RETRO_ENVIRONMENT_SET_HW_RENDER "the active rendering API".
 * Will be used some time after \c RETRO_ENVIRONMENT_SET_HW_RENDER is called,
 * but before \c retro_hw_render_callback::context_reset is called.
 *
 * @param[in] data <tt>const struct retro_hw_render_context_negotiation_interface *</tt>.
 * Pointer to the context negotiation interface.
 * Will be populated by the frontend.
 * Behavior is undefined if \c NULL.
 * @return \c true if this environment call is supported,
 * even if the current graphics API doesn't use
 * a context negotiation interface (in which case the argument is ignored).
 * @see retro_hw_render_context_negotiation_interface
 * @see RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT
 * @see RETRO_ENVIRONMENT_SET_HW_RENDER
 */
#define RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE (43 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Notifies the frontend of any quirks associated with serialization.
 *
 * Should be set in either \c retro_init or \c retro_load_game, but not both.
 * @param[in, out] data <tt>uint64_t *</tt>.
 * Pointer to the core's serialization quirks.
 * The frontend will set the flags of the quirks it supports
 * and clear the flags of those it doesn't.
 * Behavior is undefined if \c NULL.
 * @return \c true if this environment call is supported.
 * @see retro_serialize
 * @see retro_unserialize
 * @see RETRO_SERIALIZATION_QUIRK
 */
#define RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS 44

/**
 * The frontend will try to use a "shared" context when setting up a hardware context.
 * Mostly applicable to OpenGL.
 *
 * In order for this to have any effect,
 * the core must call \c RETRO_ENVIRONMENT_SET_HW_RENDER at some point
 * if it hasn't already.
 *
 * @param data Ignored.
 * @returns \c true if the environment call is available
 * and the frontend supports shared hardware contexts.
 */
#define RETRO_ENVIRONMENT_SET_HW_SHARED_CONTEXT (44 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Returns an interface that the core can use to access the file system.
 * Should be called as early as possible.
 *
 * @param[in,out] data <tt>struct retro_vfs_interface_info *</tt>.
 * Information about the desired VFS interface,
 * as well as the interface itself.
 * Behavior is undefined if \c NULL.
 * @return \c true if this environment call is available
 * and the frontend can provide a VFS interface of the requested version or newer.
 * @see retro_vfs_interface_info
 * @see file_path
 * @see retro_dirent
 * @see file_stream
 */
#define RETRO_ENVIRONMENT_GET_VFS_INTERFACE (45 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Returns an interface that the core can use
 * to set the state of any accessible device LEDs.
 *
 * @param[out] data <tt>struct retro_led_interface *</tt>.
 * Pointer to the LED interface that the frontend will populate.
 * May be \c NULL, in which case the frontend will only return
 * whether this environment callback is available.
 * @returns \c true if the environment call is available,
 * even if \c data is \c NULL
 * or no LEDs are accessible.
 * @see retro_led_interface
 */
#define RETRO_ENVIRONMENT_GET_LED_INTERFACE (46 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Returns hints about certain steps that the core may skip for this frame.
 *
 * A frontend may not need a core to generate audio or video in certain situations;
 * this environment call sets a bitmask that indicates
 * which steps the core may skip for this frame.
 *
 * This can be used to increase performance for some frontend features.
 *
 * @note Emulation accuracy should not be compromised;
 * for example, if a core emulates a platform that supports display capture
 * (i.e. looking at its own VRAM), then it should perform its rendering as normal
 * unless it can prove that the emulated game is not using display capture.
 *
 * @param[out] data <tt>retro_av_enable_flags *</tt>.
 * Pointer to the bitmask of steps that the frontend will skip.
 * Other bits are set to zero and are reserved for future use.
 * If \c NULL, the frontend will only return whether this environment callback is available.
 * @returns \c true if the environment call is available,
 * regardless of the value output to \c data.
 * If \c false, the core should assume that the frontend will not skip any steps.
 * @see retro_av_enable_flags
 */
#define RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE (47 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Gets an interface that the core can use for raw MIDI I/O.
 *
 * @param[out] data <tt>struct retro_midi_interface *</tt>.
 * Pointer to the MIDI interface.
 * May be \c NULL.
 * @return \c true if the environment call is available,
 * even if \c data is \c NULL.
 * @see retro_midi_interface
 */
#define RETRO_ENVIRONMENT_GET_MIDI_INTERFACE (48 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Asks the frontend if it's currently in fast-forward mode.
 * @param[out] data <tt>bool *</tt>.
 * Set to \c true if the frontend is currently fast-forwarding its main loop.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * @returns \c true if this environment call is available,
 * regardless of the value returned in \c data.
 *
 * @see RETRO_ENVIRONMENT_SET_FASTFORWARDING_OVERRIDE
 */
#define RETRO_ENVIRONMENT_GET_FASTFORWARDING (49 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Returns the refresh rate the frontend is targeting, in Hz.
 * The intended use case is for the core to use the result to select an ideal refresh rate.
 *
 * @param[out] data <tt>float *</tt>.
 * Pointer to the \c float in which the frontend will store its target refresh rate.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * @return \c true if this environment call is available,
 * regardless of the value returned in \c data.
*/
#define RETRO_ENVIRONMENT_GET_TARGET_REFRESH_RATE (50 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Returns whether the frontend can return the state of all buttons at once as a bitmask,
 * rather than requiring a series of individual calls to \c retro_input_state_t.
 *
 * If this callback returns \c true,
 * you can get the state of all buttons by passing \c RETRO_DEVICE_ID_JOYPAD_MASK
 * as the \c id parameter to \c retro_input_state_t.
 * Bit #N represents the RETRO_DEVICE_ID_JOYPAD constant of value N,
 * e.g. <tt>(1 << RETRO_DEVICE_ID_JOYPAD_A)</tt> represents the A button.
 *
 * @param data Ignored.
 * @returns \c true if the frontend can report the complete digital joypad state as a bitmask.
 * @see retro_input_state_t
 * @see RETRO_DEVICE_JOYPAD
 * @see RETRO_DEVICE_ID_JOYPAD_MASK
 */
#define RETRO_ENVIRONMENT_GET_INPUT_BITMASKS (51 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Returns the version of the core options API supported by the frontend.
 *
 * Over the years, libretro has used several interfaces
 * for allowing cores to define customizable options.
 * \ref SET_CORE_OPTIONS_V2 "Version 2 of the interface"
 * is currently preferred due to its extra features,
 * but cores and frontends should strive to support
 * versions \ref RETRO_ENVIRONMENT_SET_CORE_OPTIONS "1"
 * and \ref RETRO_ENVIRONMENT_SET_VARIABLES "0" as well.
 * This environment call provides the information that cores need for that purpose.
 *
 * If this environment call returns \c false,
 * then the core should assume version 0 of the core options API.
 *
 * @param[out] data <tt>unsigned *</tt>.
 * Pointer to the integer that will store the frontend's
 * supported core options API version.
 * Behavior is undefined if \c NULL.
 * @returns \c true if the environment call is available,
 * \c false otherwise.
 * @see RETRO_ENVIRONMENT_SET_VARIABLES
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 */
#define RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION 52

/**
 * @copybrief RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 *
 * @deprecated This environment call has been superseded
 * by RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2,
 * which supports categorizing options into groups.
 * This environment call should only be used to maintain compatibility
 * with older cores and frontends.
 *
 * This environment call is intended to replace \c RETRO_ENVIRONMENT_SET_VARIABLES,
 * and should only be called if \c RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION
 * returns an API version of at least 1.
 *
 * This should be called the first time as early as possible,
 * ideally in \c retro_set_environment (but \c retro_load_game is acceptable).
 * It may then be called again later to update
 * the core's options and their associated values,
 * as long as the number of options doesn't change
 * from the number given in the first call.
 *
 * The core can retrieve option values at any time with \c RETRO_ENVIRONMENT_GET_VARIABLE.
 * If a saved value for a core option doesn't match the option definition's values,
 * the frontend may treat it as incorrect and revert to the default.
 *
 * Core options and their values are usually defined in a large static array,
 * but they may be generated at runtime based on the loaded game or system state.
 * Here are some use cases for that:
 *
 * @li Selecting a particular file from one of the
 *     \ref RETRO_ENVIRONMENT_GET_ASSET_DIRECTORY "frontend's"
 *     \ref RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY "content"
 *     \ref RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY "directories",
 *     such as a memory card image or figurine data file.
 * @li Excluding options that are not relevant to the current game,
 *     for cores that define a large number of possible options.
 * @li Choosing a default value at runtime for a specific game,
 *     such as a BIOS file whose region matches that of the loaded content.
 *
 * @note A guiding principle of libretro's API design is that
 * all common interactions (gameplay, menu navigation, etc.)
 * should be possible without a keyboard.
 * This implies that cores should keep the number of options and values
 * as low as possible.
 *
 * Example entry:
 * @code
 * {
 *     "foo_option",
 *     "Speed hack coprocessor X",
 *     "Provides increased performance at the expense of reduced accuracy",
 *     {
 *         { "false",    NULL },
 *         { "true",     NULL },
 *         { "unstable", "Turbo (Unstable)" },
 *         { NULL, NULL },
 *     },
 *     "false"
 * }
 * @endcode
 *
 * @param[in] data <tt>const struct retro_core_option_definition *</tt>.
 * Pointer to one or more core option definitions,
 * terminated by a \ref retro_core_option_definition whose values are all zero.
 * May be \c NULL, in which case the frontend will remove all existing core options.
 * The frontend must maintain its own copy of this object,
 * including all strings and subobjects.
 * @return \c true if this environment call is available.
 *
 * @see retro_core_option_definition
 * @see RETRO_ENVIRONMENT_GET_VARIABLE
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL
 */
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS 53

/**
 * A variant of \ref RETRO_ENVIRONMENT_SET_CORE_OPTIONS
 * that supports internationalization.
 *
 * @deprecated This environment call has been superseded
 * by \ref RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL,
 * which supports categorizing options into groups
 * (plus translating the groups themselves).
 * Only use this environment call to maintain compatibility
 * with older cores and frontends.
 *
 * This should be called instead of \c RETRO_ENVIRONMENT_SET_CORE_OPTIONS
 * if the core provides translations for its options.
 * General use is largely the same,
 * but see \ref retro_core_options_intl for some important details.
 *
 * @param[in] data <tt>const struct retro_core_options_intl *</tt>.
 * Pointer to a core's option values and their translations.
 * @see retro_core_options_intl
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS
 */
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL 54

/**
 * Notifies the frontend that it should show or hide the named core option.
 *
 * Some core options aren't relevant in all scenarios,
 * such as a submenu for hardware rendering flags
 * when the software renderer is configured.
 * This environment call asks the frontend to stop (or start)
 * showing the named core option to the player.
 * This is only a hint, not a requirement;
 * the frontend may ignore this environment call.
 * By default, all core options are visible.
 *
 * @note This environment call must \em only affect a core option's visibility,
 * not its functionality or availability.
 * \ref RETRO_ENVIRONMENT_GET_VARIABLE "Getting an invisible core option"
 * must behave normally.
 *
 * @param[in] data <tt>const struct retro_core_option_display *</tt>.
 * Pointer to a descriptor for the option that the frontend should show or hide.
 * May be \c NULL, in which case the frontend will only return
 * whether this environment callback is available.
 * @return \c true if this environment call is available,
 * even if \c data is \c NULL
 * or the specified option doesn't exist.
 * @see retro_core_option_display
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK
 */
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY 55

/**
 * Returns the frontend's preferred hardware rendering API.
 * Cores should use this information to decide which API to use with \c RETRO_ENVIRONMENT_SET_HW_RENDER.
 * @param[out] data <tt>retro_hw_context_type *</tt>.
 * Pointer to the hardware context type.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * This value will be set even if the environment call returns <tt>false</tt>,
 * unless the frontend doesn't implement it.
 * @returns \c true if the environment call is available
 * and the frontend is able to use a hardware rendering API besides the one returned.
 * If \c false is returned and the core cannot use the preferred rendering API,
 * then it should exit or fall back to software rendering.
 * @note The returned value does not indicate which API is currently in use.
 * For example, the frontend may return \c RETRO_HW_CONTEXT_OPENGL
 * while a Direct3D context from a previous session is active;
 * this would signal that the frontend's current preference is for OpenGL,
 * possibly because the user changed their frontend's video driver while a game is running.
 * @see retro_hw_context_type
 * @see RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE
 * @see RETRO_ENVIRONMENT_SET_HW_RENDER
 */
#define RETRO_ENVIRONMENT_GET_PREFERRED_HW_RENDER 56

/**
 * Returns the minimum version of the disk control interface supported by the frontend.
 *
 * If this environment call returns \c false or \c data is 0 or greater,
 * then cores may use disk control callbacks
 * with \c RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE.
 * If the reported version is 1 or greater,
 * then cores should use \c RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE instead.
 *
 * @param[out] data <tt>unsigned *</tt>.
 * Pointer to the unsigned integer that the frontend's supported disk control interface version will be stored in.
 * Behavior is undefined if \c NULL.
 * @return \c true if this environment call is available.
 * @see RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE
 */
#define RETRO_ENVIRONMENT_GET_DISK_CONTROL_INTERFACE_VERSION 57

/**
 * @copybrief RETRO_ENVIRONMENT_SET_DISK_CONTROL_INTERFACE
 *
 * This is intended for multi-disk games that expect the player
 * to manually swap disks at certain points in the game.
 * This version of the disk control interface provides
 * more information about disk images.
 * Should be called in \c retro_init.
 *
 * @param[in] data <tt>const struct retro_disk_control_ext_callback *</tt>.
 * Pointer to the callback functions to use.
 * May be \c NULL, in which case the existing disk callback is deregistered.
 * @return \c true if this environment call is available,
 * even if \c data is \c NULL.
 * @see retro_disk_control_ext_callback
 */
#define RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE 58

/**
 * Returns the version of the message interface supported by the frontend.
 *
 * A version of 0 indicates that the frontend
 * only supports the legacy \c RETRO_ENVIRONMENT_SET_MESSAGE interface.
 * A version of 1 indicates that the frontend
 * supports \c RETRO_ENVIRONMENT_SET_MESSAGE_EXT as well.
 * If this environment call returns \c false,
 * the core should behave as if it had returned 0.
 *
 * @param[out] data <tt>unsigned *</tt>.
 * Pointer to the result returned by the frontend.
 * Behavior is undefined if \c NULL.
 * @return \c true if this environment call is available.
 * @see RETRO_ENVIRONMENT_SET_MESSAGE_EXT
 * @see RETRO_ENVIRONMENT_SET_MESSAGE
 */
#define RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION 59

/**
 * Displays a user-facing message for a short time.
 *
 * Use this callback to convey important status messages,
 * such as errors or the result of long-running operations.
 * For trivial messages or logging, use \c RETRO_ENVIRONMENT_GET_LOG_INTERFACE or \c stderr.
 *
 * This environment call supersedes \c RETRO_ENVIRONMENT_SET_MESSAGE,
 * as it provides many more ways to customize
 * how a message is presented to the player.
 * However, a frontend that supports this environment call
 * must still support \c RETRO_ENVIRONMENT_SET_MESSAGE.
 *
 * @param[in] data <tt>const struct retro_message_ext *</tt>.
 * Pointer to the message to display to the player.
 * Behavior is undefined if \c NULL.
 * @returns \c true if this environment call is available.
 * @see retro_message_ext
 * @see RETRO_ENVIRONMENT_GET_MESSAGE_INTERFACE_VERSION
 */
#define RETRO_ENVIRONMENT_SET_MESSAGE_EXT 60

/**
 * Returns the number of active input devices currently provided by the frontend.
 *
 * This may change between frames,
 * but will remain constant for the duration of each frame.
 *
 * If this callback returns \c true,
 * a core need not poll any input device
 * with an index greater than or equal to the returned value.
 *
 * If callback returns \c false,
 * the number of active input devices is unknown.
 * In this case, all input devices should be considered active.
 *
 * @param[out] data <tt>unsigned *</tt>.
 * Pointer to the result returned by the frontend.
 * Behavior is undefined if \c NULL.
 * @return \c true if this environment call is available.
 */
#define RETRO_ENVIRONMENT_GET_INPUT_MAX_USERS 61

/**
 * Registers a callback that the frontend can use to notify the core
 * of the audio output buffer's occupancy.
 * Can be used by a core to attempt frame-skipping to avoid buffer under-runs
 * (i.e. "crackling" sounds).
 *
 * @param[in] data <tt>const struct retro_audio_buffer_status_callback *</tt>.
 * Pointer to the the buffer status callback,
 * or \c NULL to unregister any existing callback.
 * @return \c true if this environment call is available,
 * even if \c data is \c NULL.
 *
 * @see retro_audio_buffer_status_callback
 */
#define RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK 62

/**
 * Requests a minimum frontend audio latency in milliseconds.
 *
 * This is a hint; the frontend may assign a different audio latency
 * to accommodate hardware limits,
 * although it should try to honor requests up to 512ms.
 *
 * This callback has no effect if the requested latency
 * is less than the frontend's current audio latency.
 * If value is zero or \c data is \c NULL,
 * the frontend should set its default audio latency.
 *
 * May be used by a core to increase audio latency and
 * reduce the risk of buffer under-runs (crackling)
 * when performing 'intensive' operations.
 *
 * A core using RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK
 * to implement audio-buffer-based frame skipping can get good results
 * by setting the audio latency to a high (typically 6x or 8x)
 * integer multiple of the expected frame time.
 *
 * This can only be called from within \c retro_run().
 *
 * @warning This environment call may require the frontend to reinitialize its audio system.
 * This environment call should be used sparingly.
 * If the driver is reinitialized,
 * \ref retro_audio_callback_t "all audio callbacks" will be updated
 * to target the newly-initialized driver.
 *
 * @param[in] data <tt>const unsigned *</tt>.
 * Minimum audio latency, in milliseconds.
 * @return \c true if this environment call is available,
 * even if \c data is \c NULL.
 *
 * @see RETRO_ENVIRONMENT_SET_AUDIO_BUFFER_STATUS_CALLBACK
 */
#define RETRO_ENVIRONMENT_SET_MINIMUM_AUDIO_LATENCY 63

/**
 * Allows the core to tell the frontend when it should enable fast-forwarding,
 * rather than relying solely on the frontend and user interaction.
 *
 * Possible use cases include:
 *
 * \li Temporarily disabling a core's fastforward support
 *     while investigating a related bug.
 * \li Disabling fastforward during netplay sessions,
 *     or when using an emulated console's network features.
 * \li Automatically speeding up the game when in a loading screen
 *     that cannot be shortened with high-level emulation.
 *
 * @param[in] data <tt>const struct retro_fastforwarding_override *</tt>.
 * Pointer to the parameters that decide when and how
 * the frontend is allowed to enable fast-forward mode.
 * May be \c NULL, in which case the frontend will return \c true
 * without updating the fastforward state,
 * which can be used to detect support for this environment call.
 * @return \c true if this environment call is available,
 * even if \c data is \c NULL.
 *
 * @see retro_fastforwarding_override
 * @see RETRO_ENVIRONMENT_GET_FASTFORWARDING
 */
#define RETRO_ENVIRONMENT_SET_FASTFORWARDING_OVERRIDE 64

#define RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE 65
                                           /* const struct retro_system_content_info_override * --
                                            * Allows an implementation to override 'global' content
                                            * info parameters reported by retro_get_system_info().
                                            * Overrides also affect subsystem content info parameters
                                            * set via RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO.
                                            * This function must be called inside retro_set_environment().
                                            * If callback returns false, content info overrides
                                            * are unsupported by the frontend, and will be ignored.
                                            * If callback returns true, extended game info may be
                                            * retrieved by calling RETRO_ENVIRONMENT_GET_GAME_INFO_EXT
                                            * in retro_load_game() or retro_load_game_special().
                                            *
                                            * 'data' points to an array of retro_system_content_info_override
                                            * structs terminated by a { NULL, false, false } element.
                                            * If 'data' is NULL, no changes will be made to the frontend;
                                            * a core may therefore pass NULL in order to test whether
                                            * the RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE and
                                            * RETRO_ENVIRONMENT_GET_GAME_INFO_EXT callbacks are supported
                                            * by the frontend.
                                            *
                                            * For struct member descriptions, see the definition of
                                            * struct retro_system_content_info_override.
                                            *
                                            * Example:
                                            *
                                            * - struct retro_system_info:
                                            * {
                                            *    "My Core",                      // library_name
                                            *    "v1.0",                         // library_version
                                            *    "m3u|md|cue|iso|chd|sms|gg|sg", // valid_extensions
                                            *    true,                           // need_fullpath
                                            *    false                           // block_extract
                                            * }
                                            *
                                            * - Array of struct retro_system_content_info_override:
                                            * {
                                            *    {
                                            *       "md|sms|gg", // extensions
                                            *       false,       // need_fullpath
                                            *       true         // persistent_data
                                            *    },
                                            *    {
                                            *       "sg",        // extensions
                                            *       false,       // need_fullpath
                                            *       false        // persistent_data
                                            *    },
                                            *    { NULL, false, false }
                                            * }
                                            *
                                            * Result:
                                            * - Files of type m3u, cue, iso, chd will not be
                                            *   loaded by the frontend. Frontend will pass a
                                            *   valid path to the core, and core will handle
                                            *   loading internally
                                            * - Files of type md, sms, gg will be loaded by
                                            *   the frontend. A valid memory buffer will be
                                            *   passed to the core. This memory buffer will
                                            *   remain valid until retro_deinit() returns
                                            * - Files of type sg will be loaded by the frontend.
                                            *   A valid memory buffer will be passed to the core.
                                            *   This memory buffer will remain valid until
                                            *   retro_load_game() (or retro_load_game_special())
                                            *   returns
                                            *
                                            * NOTE: If an extension is listed multiple times in
                                            * an array of retro_system_content_info_override
                                            * structs, only the first instance will be registered
                                            */

#define RETRO_ENVIRONMENT_GET_GAME_INFO_EXT 66
                                           /* const struct retro_game_info_ext ** --
                                            * Allows an implementation to fetch extended game
                                            * information, providing additional content path
                                            * and memory buffer status details.
                                            * This function may only be called inside
                                            * retro_load_game() or retro_load_game_special().
                                            * If callback returns false, extended game information
                                            * is unsupported by the frontend. In this case, only
                                            * regular retro_game_info will be available.
                                            * RETRO_ENVIRONMENT_GET_GAME_INFO_EXT is guaranteed
                                            * to return true if RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE
                                            * returns true.
                                            *
                                            * 'data' points to an array of retro_game_info_ext structs.
                                            *
                                            * For struct member descriptions, see the definition of
                                            * struct retro_game_info_ext.
                                            *
                                            * - If function is called inside retro_load_game(),
                                            *   the retro_game_info_ext array is guaranteed to
                                            *   have a size of 1 - i.e. the returned pointer may
                                            *   be used to access directly the members of the
                                            *   first retro_game_info_ext struct, for example:
                                            *
                                            *      struct retro_game_info_ext *game_info_ext;
                                            *      if (environ_cb(RETRO_ENVIRONMENT_GET_GAME_INFO_EXT, &game_info_ext))
                                            *         printf("Content Directory: %s\n", game_info_ext->dir);
                                            *
                                            * - If the function is called inside retro_load_game_special(),
                                            *   the retro_game_info_ext array is guaranteed to have a
                                            *   size equal to the num_info argument passed to
                                            *   retro_load_game_special()
                                            */

/**
 * Defines a set of core options that can be shown and configured by the frontend,
 * so that the player may customize their gameplay experience to their liking.
 *
 * @note This environment call is intended to replace
 * \c RETRO_ENVIRONMENT_SET_VARIABLES and \c RETRO_ENVIRONMENT_SET_CORE_OPTIONS,
 * and should only be called if \c RETRO_ENVIRONMENT_GET_CORE_OPTIONS_VERSION
 * returns an API version of at least 2.
 *
 * This should be called the first time as early as possible,
 * ideally in \c retro_set_environment (but \c retro_load_game is acceptable).
 * It may then be called again later to update
 * the core's options and their associated values,
 * as long as the number of options doesn't change
 * from the number given in the first call.
 *
 * The core can retrieve option values at any time with \c RETRO_ENVIRONMENT_GET_VARIABLE.
 * If a saved value for a core option doesn't match the option definition's values,
 * the frontend may treat it as incorrect and revert to the default.
 *
 * Core options and their values are usually defined in a large static array,
 * but they may be generated at runtime based on the loaded game or system state.
 * Here are some use cases for that:
 *
 * @li Selecting a particular file from one of the
 *     \ref RETRO_ENVIRONMENT_GET_ASSET_DIRECTORY "frontend's"
 *     \ref RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY "content"
 *     \ref RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY "directories",
 *     such as a memory card image or figurine data file.
 * @li Excluding options that are not relevant to the current game,
 *     for cores that define a large number of possible options.
 * @li Choosing a default value at runtime for a specific game,
 *     such as a BIOS file whose region matches that of the loaded content.
 *
 * @note A guiding principle of libretro's API design is that
 * all common interactions (gameplay, menu navigation, etc.)
 * should be possible without a keyboard.
 * This implies that cores should keep the number of options and values
 * as low as possible.
 *
 * @param[in] data <tt>const struct retro_core_options_v2 *</tt>.
 * Pointer to a core's options and their associated categories.
 * May be \c NULL, in which case the frontend will remove all existing core options.
 * The frontend must maintain its own copy of this object,
 * including all strings and subobjects.
 * @return \c true if this environment call is available
 * and the frontend supports categories.
 * Note that this environment call is guaranteed to successfully register
 * the provided core options,
 * so the return value does not indicate success or failure.
 *
 * @see retro_core_options_v2
 * @see retro_core_option_v2_category
 * @see retro_core_option_v2_definition
 * @see RETRO_ENVIRONMENT_GET_VARIABLE
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL
 */
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 67

/**
 * A variant of \ref RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 * that supports internationalization.
 *
 * This should be called instead of \c RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 * if the core provides translations for its options.
 * General use is largely the same,
 * but see \ref retro_core_options_v2_intl for some important details.
 *
 * @param[in] data <tt>const struct retro_core_options_v2_intl *</tt>.
 * Pointer to a core's option values and categories,
 * plus a translation for each option and category.
 * @see retro_core_options_v2_intl
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 */
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL 68

/**
 * Registers a callback that the frontend can use
 * to notify the core that at least one core option
 * should be made hidden or visible.
 * Allows a frontend to signal that a core must update
 * the visibility of any dynamically hidden core options,
 * and enables the frontend to detect visibility changes.
 * Used by the frontend to update the menu display status
 * of core options without requiring a call of retro_run().
 * Must be called in retro_set_environment().
 *
 * @param[in] data <tt>const struct retro_core_options_update_display_callback *</tt>.
 * The callback that the frontend should use.
 * May be \c NULL, in which case the frontend will unset any existing callback.
 * Can be used to query visibility support.
 * @return \c true if this environment call is available,
 * even if \c data is \c NULL.
 * @see retro_core_options_update_display_callback
 */
#define RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK 69

/**
 * Forcibly sets a core option's value.
 *
 * After changing a core option value with this callback,
 * it will be reflected in the frontend
 * and \ref RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE will return \c true.
 * \ref retro_variable::key must match
 * a \ref RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 "previously-set core option",
 * and \ref retro_variable::value must match one of its defined values.
 *
 * Possible use cases include:
 *
 * @li Allowing the player to set certain core options
 *     without entering the frontend's option menu,
 *     using an in-core hotkey.
 * @li Adjusting invalid combinations of settings.
 * @li Migrating settings from older releases of a core.
 *
 * @param[in] data <tt>const struct retro_variable *</tt>.
 * Pointer to a single option that the core is changing.
 * May be \c NULL, in which case the frontend will return \c true
 * to indicate that this environment call is available.
 * @return \c true if this environment call is available
 * and the option named by \c key was successfully
 * set to the given \c value.
 * \c false if the \c key or \c value fields are \c NULL, empty,
 * or don't match a previously set option.
 *
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 * @see RETRO_ENVIRONMENT_GET_VARIABLE
 * @see RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE
 */
#define RETRO_ENVIRONMENT_SET_VARIABLE 70

#define RETRO_ENVIRONMENT_GET_THROTTLE_STATE (71 | RETRO_ENVIRONMENT_EXPERIMENTAL)
                                           /* struct retro_throttle_state * --
                                            * Allows an implementation to get details on the actual rate
                                            * the frontend is attempting to call retro_run().
                                            */

/**
 * Returns information about how the frontend will use savestates.
 *
 * @param[out] data <tt>retro_savestate_context *</tt>.
 * Pointer to the current savestate context.
 * May be \c NULL, in which case the environment call
 * will return \c true to indicate its availability.
 * @returns \c true if the environment call is available,
 * even if \c data is \c NULL.
 * @see retro_savestate_context
 */
#define RETRO_ENVIRONMENT_GET_SAVESTATE_CONTEXT (72 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Before calling \c SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE, will query which interface is supported.
 *
 * Frontend looks at \c retro_hw_render_interface_type and returns the maximum supported
 * context negotiation interface version. If the \c retro_hw_render_interface_type is not
 * supported or recognized by the frontend, a version of 0 must be returned in
 * \c retro_hw_render_interface's \c interface_version and \c true is returned by frontend.
 *
 * If this environment call returns true with a \c interface_version greater than 0,
 * a core can always use a negotiation interface version larger than what the frontend returns,
 * but only earlier versions of the interface will be used by the frontend.
 *
 * A frontend must not reject a negotiation interface version that is larger than what the
 * frontend supports. Instead, the frontend will use the older entry points that it recognizes.
 * If this is incompatible with a particular core's requirements, it can error out early.
 *
 * @note Regarding backwards compatibility, this environment call was introduced after Vulkan v1
 * context negotiation. If this environment call is not supported by frontend, i.e. the environment
 * call returns \c false , only Vulkan v1 context negotiation is supported (if Vulkan HW rendering
 * is supported at all). If a core uses Vulkan negotiation interface with version > 1, negotiation
 * may fail unexpectedly. All future updates to the context negotiation interface implies that
 * frontend must support this environment call to query support.
 *
 * @param[out] data <tt>struct retro_hw_render_context_negotiation_interface *</tt>.
 * @return \c true if the environment call is available.
 * @see SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE
 * @see retro_hw_render_interface_type
 * @see retro_hw_render_context_negotiation_interface
 */
#define RETRO_ENVIRONMENT_GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT (73 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Asks the frontend whether JIT compilation can be used.
 * Primarily used by iOS and tvOS.
 * @param[out] data <tt>bool *</tt>.
 * Set to \c true if the frontend has verified that JIT compilation is possible.
 * @return \c true if the environment call is available.
 */
#define RETRO_ENVIRONMENT_GET_JIT_CAPABLE 74

/**
 * Returns an interface that the core can use to receive microphone input.
 *
 * @param[out] data <tt>retro_microphone_interface *</tt>.
 * Pointer to the microphone interface.
 * @return \true if microphone support is available,
 * even if no microphones are plugged in.
 * \c false if microphone support is disabled unavailable,
 * or if \c data is \c NULL.
 * @see retro_microphone_interface
 */
#define RETRO_ENVIRONMENT_GET_MICROPHONE_INTERFACE (75 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/* Environment 76 was an obsolete version of RETRO_ENVIRONMENT_SET_NETPACKET_INTERFACE.
* It was not used by any known core at the time, and was removed from the API. */

/**
 * Returns the device's current power state as reported by the frontend.
 *
 * This is useful for emulating the battery level in handheld consoles,
 * or for reducing power consumption when on battery power.
 *
 * @note This environment call describes the power state for the entire device,
 * not for individual peripherals like controllers.
 *
 * @param[out] data <struct retro_device_power *>.
 * Indicates whether the frontend can provide this information, even if the parameter
 * is \c NULL. If the frontend does not support this functionality, then the provided
 * argument will remain unchanged.
 * @return \c true if the environment call is available.
 * @see retro_device_power
 */
#define RETRO_ENVIRONMENT_GET_DEVICE_POWER (77 | RETRO_ENVIRONMENT_EXPERIMENTAL)

#define RETRO_ENVIRONMENT_SET_NETPACKET_INTERFACE 78
                                           /* const struct retro_netpacket_callback * --
                                            * When set, a core gains control over network packets sent and
                                            * received during a multiplayer session. This can be used to
                                            * emulate multiplayer games that were originally played on two
                                            * or more separate consoles or computers connected together.
                                            *
                                            * The frontend will take care of connecting players together,
                                            * and the core only needs to send the actual data as needed for
                                            * the emulation, while handshake and connection management happen
                                            * in the background.
                                            *
                                            * When two or more players are connected and this interface has
                                            * been set, time manipulation features (such as pausing, slow motion,
                                            * fast forward, rewinding, save state loading, etc.) are disabled to
                                            * avoid interrupting communication.
                                            *
                                            * Should be set in either retro_init or retro_load_game, but not both.
                                            *
                                            * When not set, a frontend may use state serialization-based
                                            * multiplayer, where a deterministic core supporting multiple
                                            * input devices does not need to take any action on its own.
                                            */

/**
 * Returns the device's current power state as reported by the frontend.
 * This is useful for emulating the battery level in handheld consoles,
 * or for reducing power consumption when on battery power.
 *
 * The return value indicates whether the frontend can provide this information,
 * even if the parameter is \c NULL.
 *
 * If the frontend does not support this functionality,
 * then the provided argument will remain unchanged.
 * @param[out] data <tt>retro_device_power *</tt>.
 * Pointer to the information that the frontend returns about its power state.
 * May be \c NULL.
 * @return \c true if the environment call is available,
 * even if \c data is \c NULL.
 * @see retro_device_power
 * @note This environment call describes the power state for the entire device,
 * not for individual peripherals like controllers.
*/
#define RETRO_ENVIRONMENT_GET_DEVICE_POWER (77 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Returns the "playlist" directory of the frontend.
 *
 * This directory can be used to store core generated playlists, in case
 * this internal functionality is available (e.g. internal core game detection
 * engine).
 *
 * @param[out] data <tt>const char **</tt>.
 * May be \c NULL. If so, no such directory is defined, and it's up to the
 * implementation to find a suitable directory.
 * @return \c true if the environment call is available.
 */
#define RETRO_ENVIRONMENT_GET_PLAYLIST_DIRECTORY 79

/**
 * Returns the "file browser" start directory of the frontend.
 *
 * This directory can serve as a start directory for the core in case it
 * provides an internal way of loading content.
 *
 * @param[out] data <tt>const char **</tt>.
 * May be \c NULL. If so, no such directory is defined, and it's up to the
 * implementation to find a suitable directory.
 * @return \c true if the environment call is available.
 */
#define RETRO_ENVIRONMENT_GET_FILE_BROWSER_START_DIRECTORY 80

/**
 * Returns the audio sample rate the frontend is targeting, in Hz.
 * The intended use case is for the core to use the result to select an ideal sample rate.
 *
 * @param[out] data <tt>unsigned *</tt>.
 * Pointer to the \c unsigned integer in which the frontend will store its target sample rate.
 * Behavior is undefined if \c data is <tt>NULL</tt>.
 * @return \c true if this environment call is available,
 * regardless of the value returned in \c data.
*/
#define RETRO_ENVIRONMENT_GET_TARGET_SAMPLE_RATE (81 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**
 * Returns the local player's netplay client index when using frontend-managed
 * multiplayer/rollback netplay.
 *
 * @param[out] data <tt>unsigned *</tt>.
 * Pointer to an unsigned integer where the frontend stores the local client index.
 * 0 indicates host. Values > 0 indicate connected clients.
 * @return \\c true if the environment call is available and value was written,
 * \\c false otherwise.
*/
#define RETRO_ENVIRONMENT_GET_NETPLAY_CLIENT_INDEX (82 | RETRO_ENVIRONMENT_EXPERIMENTAL)

/**@}*/

/**
 * @defgroup GET_VFS_INTERFACE File System Interface
 * @brief File system functionality.
 *
 * @section File Paths
 * File paths passed to all libretro filesystem APIs shall be well formed UNIX-style,
 * using "/" (unquoted forward slash) as the directory separator
 * regardless of the platform's native separator.
 *
 * Paths shall also include at least one forward slash
 * (e.g. use "./game.bin" instead of "game.bin").
 *
 * Other than the directory separator, cores shall not make assumptions about path format.
 * The following paths are all valid:
 * @li \c C:/path/game.bin
 * @li \c http://example.com/game.bin
 * @li \c #game/game.bin
 * @li \c ./game.bin
 *
 * Cores may replace the basename or remove path components from the end, and/or add new components;
 * however, cores shall not append "./", "../" or multiple consecutive forward slashes ("//") to paths they request from the front end.
 *
 * The frontend is encouraged to do the best it can when given an ill-formed path,
 * but it is allowed to give up.
 *
 * Frontends are encouraged, but not required, to support native file system paths
 * (including replacing the directory separator, if applicable).
 *
 * Cores are allowed to try using them, but must remain functional if the frontend rejects such requests.
 *
 * Cores are encouraged to use the libretro-common filestream functions for file I/O,
 * as they seamlessly integrate with VFS,
 * deal with directory separator replacement as appropriate
 * and provide platform-specific fallbacks
 * in cases where front ends do not provide their own VFS interface.
 *
 * @see RETRO_ENVIRONMENT_GET_VFS_INTERFACE
 * @see retro_vfs_interface_info
 * @see file_path
 * @see retro_dirent
 * @see file_stream
 *
 * @{
 */

/**
 * Opaque file handle.
 * @since VFS API v1
 */
struct retro_vfs_file_handle;

/**
 * Opaque directory handle.
 * @since VFS API v3
 */
struct retro_vfs_dir_handle;

/** @defgroup RETRO_VFS_FILE_ACCESS File Access Flags
 * File access flags.
 * @since VFS API v1
 * @{
 */

/** Opens a file for read-only access. */
#define RETRO_VFS_FILE_ACCESS_READ            (1 << 0)

/**
 * Opens a file for write-only access.
 * Any existing file at this path will be discarded and overwritten
 * unless \c RETRO_VFS_FILE_ACCESS_UPDATE_EXISTING is also specified.
 */
#define RETRO_VFS_FILE_ACCESS_WRITE           (1 << 1)

/**
 * Opens a file for reading and writing.
 * Any existing file at this path will be discarded and overwritten
 * unless \c RETRO_VFS_FILE_ACCESS_UPDATE_EXISTING is also specified.
 */
#define RETRO_VFS_FILE_ACCESS_READ_WRITE      (RETRO_VFS_FILE_ACCESS_READ | RETRO_VFS_FILE_ACCESS_WRITE)

/**
 * Opens a file without discarding its existing contents.
 * Only meaningful if \c RETRO_VFS_FILE_ACCESS_WRITE is specified.
 */
#define RETRO_VFS_FILE_ACCESS_UPDATE_EXISTING (1 << 2) /* Prevents discarding content of existing files opened for writing */

/** @} */

/** @defgroup RETRO_VFS_FILE_ACCESS_HINT File Access Hints
 *
 * Hints to the frontend for how a file will be accessed.
 * The VFS implementation may use these to optimize performance,
 * react to external interference (such as concurrent writes),
 * or it may ignore them entirely.
 *
 * Hint flags do not change the behavior of each VFS function
 * unless otherwise noted.
 * @{
 */

/** No particular hints are given. */
#define RETRO_VFS_FILE_ACCESS_HINT_NONE              (0)

/**
 * Indicates that the file will be accessed frequently.
 *
 * The frontend should cache it or map it into memory.
 */
#define RETRO_VFS_FILE_ACCESS_HINT_FREQUENT_ACCESS   (1 << 0)

/** @} */

/** @defgroup RETRO_VFS_SEEK_POSITION File Seek Positions
 * File access flags and hints.
 * @{
 */

/**
 * Indicates a seek relative to the start of the file.
 */
#define RETRO_VFS_SEEK_POSITION_START    0

/**
 * Indicates a seek relative to the current stream position.
 */
#define RETRO_VFS_SEEK_POSITION_CURRENT  1

/**
 * Indicates a seek relative to the end of the file.
 * @note The offset passed to \c retro_vfs_seek_t should be negative.
 */
#define RETRO_VFS_SEEK_POSITION_END      2

/** @} */

/** @defgroup RETRO_VFS_STAT File Status Flags
 * File stat flags.
 * @see retro_vfs_stat_t
 * @since VFS API v3
 * @{
 */

/** Indicates that the given path refers to a valid file. */
#define RETRO_VFS_STAT_IS_VALID               (1 << 0)

/** Indicates that the given path refers to a directory. */
#define RETRO_VFS_STAT_IS_DIRECTORY           (1 << 1)

/**
 * Indicates that the given path refers to a character special file,
 * such as \c /dev/null.
 */
#define RETRO_VFS_STAT_IS_CHARACTER_SPECIAL   (1 << 2)

/** @} */

/**
 * Returns the path that was used to open this file.
 *
 * @param stream The opened file handle to get the path of.
 * Behavior is undefined if \c NULL or closed.
 * @return The path that was used to open \c stream.
 * The string is owned by \c stream and must not be modified.
 * @since VFS API v1
 * @see filestream_get_path
 */
typedef const char *(RETRO_CALLCONV *retro_vfs_get_path_t)(struct retro_vfs_file_handle *stream);

/**
 * Open a file for reading or writing.
 *
 * @param path The path to open.
 * @param mode A bitwise combination of \c RETRO_VFS_FILE_ACCESS flags.
 * At a minimum, one of \c RETRO_VFS_FILE_ACCESS_READ or \c RETRO_VFS_FILE_ACCESS_WRITE must be specified.
 * @param hints A bitwise combination of \c RETRO_VFS_FILE_ACCESS_HINT flags.
 * @return A handle to the opened file,
 * or \c NULL upon failure.
 * Note that this will return \c NULL if \c path names a directory.
 * The returned file handle must be closed with \c retro_vfs_close_t.
 * @since VFS API v1
 * @see File Paths
 * @see RETRO_VFS_FILE_ACCESS
 * @see RETRO_VFS_FILE_ACCESS_HINT
 * @see retro_vfs_close_t
 * @see filestream_open
 */
typedef struct retro_vfs_file_handle *(RETRO_CALLCONV *retro_vfs_open_t)(const char *path, unsigned mode, unsigned hints);

/**
 * Close the file and release its resources.
 * All files returned by \c retro_vfs_open_t must be closed with this function.
 *
 * @param stream The file handle to close.
 * Behavior is undefined if already closed.
 * Upon completion of this function, \c stream is no longer valid
 * (even if it returns failure).
 * @return 0 on success, -1 on failure or if \c stream is \c NULL.
 * @see retro_vfs_open_t
 * @see filestream_close
 * @since VFS API v1
 */
typedef int (RETRO_CALLCONV *retro_vfs_close_t)(struct retro_vfs_file_handle *stream);

/**
 * Return the size of the file in bytes.
 *
 * @param stream The file to query the size of.
 * @return Size of the file in bytes, or -1 if there was an error.
 * @see filestream_get_size
 * @since VFS API v1
 */
typedef int64_t (RETRO_CALLCONV *retro_vfs_size_t)(struct retro_vfs_file_handle *stream);

/**
 * Set the file's length.
 *
 * @param stream The file whose length will be adjusted.
 * @param length The new length of the file, in bytes.
 * If shorter than the original length, the extra bytes will be discarded.
 * If longer, the file's padding is unspecified (and likely platform-dependent).
 * @return 0 on success,
 * -1 on failure.
 * @see filestream_truncate
 * @since VFS API v2
 */
typedef int64_t (RETRO_CALLCONV *retro_vfs_truncate_t)(struct retro_vfs_file_handle *stream, int64_t length);

/**
 * Gets the given file's current read/write position.
 * This position is advanced with each call to \c retro_vfs_read_t or \c retro_vfs_write_t.
 *
 * @param stream The file to query the position of.
 * @return The current stream position in bytes
 * or -1 if there was an error.
 * @see filestream_tell
 * @since VFS API v1
 */
typedef int64_t (RETRO_CALLCONV *retro_vfs_tell_t)(struct retro_vfs_file_handle *stream);

/**
 * Sets the given file handle's current read/write position.
 *
 * @param stream The file to set the position of.
 * @param offset The new position, in bytes.
 * @param seek_position The position to seek from.
 * @return The new position,
 * or -1 if there was an error.
 * @since VFS API v1
 * @see File Seek Positions
 * @see filestream_seek
 */
typedef int64_t (RETRO_CALLCONV *retro_vfs_seek_t)(struct retro_vfs_file_handle *stream, int64_t offset, int seek_position);

/**
 * Read data from a file, if it was opened for reading.
 *
 * @param stream The file to read from.
 * @param s The buffer to read into.
 * @param len The number of bytes to read.
 * The buffer pointed to by \c s must be this large.
 * @return The number of bytes read,
 * or -1 if there was an error.
 * @since VFS API v1
 * @see filestream_read
 */
typedef int64_t (RETRO_CALLCONV *retro_vfs_read_t)(struct retro_vfs_file_handle *stream, void *s, uint64_t len);

/**
 * Write data to a file, if it was opened for writing.
 *
 * @param stream The file handle to write to.
 * @param s The buffer to write from.
 * @param len The number of bytes to write.
 * The buffer pointed to by \c s must be this large.
 * @return The number of bytes written,
 * or -1 if there was an error.
 * @since VFS API v1
 * @see filestream_write
 */
typedef int64_t (RETRO_CALLCONV *retro_vfs_write_t)(struct retro_vfs_file_handle *stream, const void *s, uint64_t len);

/**
 * Flush pending writes to the file, if applicable.
 *
 * This does not mean that the changes will be immediately persisted to disk;
 * that may be scheduled for later, depending on the platform.
 *
 * @param stream The file handle to flush.
 * @return 0 on success, -1 on failure.
 * @since VFS API v1
 * @see filestream_flush
 */
typedef int (RETRO_CALLCONV *retro_vfs_flush_t)(struct retro_vfs_file_handle *stream);

/**
 * Deletes the file at the given path.
 *
 * @param path The path to the file that will be deleted.
 * @return 0 on success, -1 on failure.
 * @see filestream_delete
 * @since VFS API v1
 */
typedef int (RETRO_CALLCONV *retro_vfs_remove_t)(const char *path);

/**
 * Rename the specified file.
 *
 * @param old_path Path to an existing file.
 * @param new_path The destination path.
 * Must not name an existing file.
 * @return 0 on success, -1 on failure
 * @see filestream_rename
 * @since VFS API v1
 */
typedef int (RETRO_CALLCONV *retro_vfs_rename_t)(const char *old_path, const char *new_path);

/**
 * Gets information about the given file.
 *
 * @param path The path to the file to query.
 * @param[out] size The reported size of the file in bytes.
 * May be \c NULL, in which case this value is ignored.
 * @return A bitmask of \c RETRO_VFS_STAT flags,
 * or 0 if \c path doesn't refer to a valid file.
 * @see path_stat
 * @see path_get_size
 * @see RETRO_VFS_STAT
 * @since VFS API v3
 */
typedef int (RETRO_CALLCONV *retro_vfs_stat_t)(const char *path, int32_t *size);

/**
 * Creates a directory at the given path.
 *
 * @param dir The desired location of the new directory.
 * @return 0 if the directory was created,
 * -2 if the directory already exists,
 * or -1 if some other error occurred.
 * @see path_mkdir
 * @since VFS API v3
 */
typedef int (RETRO_CALLCONV *retro_vfs_mkdir_t)(const char *dir);

/**
 * Opens a handle to a directory so its contents can be inspected.
 *
 * @param dir The path to the directory to open.
 * Must be an existing directory.
 * @param include_hidden Whether to include hidden files in the directory listing.
 * The exact semantics of this flag will depend on the platform.
 * @return A handle to the opened directory,
 * or \c NULL if there was an error.
 * @see retro_opendir
 * @since VFS API v3
 */
typedef struct retro_vfs_dir_handle *(RETRO_CALLCONV *retro_vfs_opendir_t)(const char *dir, bool include_hidden);

/**
 * Gets the next dirent ("directory entry")
 * within the given directory.
 *
 * @param[in,out] dirstream The directory to read from.
 * Updated to point to the next file, directory, or other path.
 * @return \c true when the next dirent was retrieved,
 * \c false if there are no more dirents to read.
 * @note This API iterates over all files and directories within \c dirstream.
 * Remember to check what the type of the current dirent is.
 * @note This function does not recurse,
 * i.e. it does not return the contents of subdirectories.
 * @note This may include "." and ".." on Unix-like platforms.
 * @see retro_readdir
 * @see retro_vfs_dirent_is_dir_t
 * @since VFS API v3
 */
typedef bool (RETRO_CALLCONV *retro_vfs_readdir_t)(struct retro_vfs_dir_handle *dirstream);

/**
 * Gets the filename of the current dirent.
 *
 * The returned string pointer is valid
 * until the next call to \c retro_vfs_readdir_t or \c retro_vfs_closedir_t.
 *
 * @param dirstream The directory to read from.
 * @return The current dirent's name,
 * or \c NULL if there was an error.
 * @note This function only returns the file's \em name,
 * not a complete path to it.
 * @see retro_dirent_get_name
 * @since VFS API v3
 */
typedef const char *(RETRO_CALLCONV *retro_vfs_dirent_get_name_t)(struct retro_vfs_dir_handle *dirstream);

/**
 * Checks whether the current dirent names a directory.
 *
 * @param dirstream The directory to read from.
 * @return \c true if \c dirstream's current dirent points to a directory,
 * \c false if not or if there was an error.
 * @see retro_dirent_is_dir
 * @since VFS API v3
 */
typedef bool (RETRO_CALLCONV *retro_vfs_dirent_is_dir_t)(struct retro_vfs_dir_handle *dirstream);

/**
 * Closes the given directory and release its resources.
 *
 * Must be called on any \c retro_vfs_dir_handle returned by \c retro_vfs_open_t.
 *
 * @param dirstream The directory to close.
 * When this function returns (even failure),
 * \c dirstream will no longer be valid and must not be used.
 * @return 0 on success, -1 on failure.
 * @see retro_closedir
 * @since VFS API v3
 */
typedef int (RETRO_CALLCONV *retro_vfs_closedir_t)(struct retro_vfs_dir_handle *dirstream);

/**
 * File system interface exposed by the frontend.
 *
 * @see dirent_vfs_init
 * @see filestream_vfs_init
 * @see path_vfs_init
 * @see RETRO_ENVIRONMENT_GET_VFS_INTERFACE
 */
struct retro_vfs_interface
{
   /* VFS API v1 */
   /** @copydoc retro_vfs_get_path_t */
	retro_vfs_get_path_t get_path;

   /** @copydoc retro_vfs_open_t */
	retro_vfs_open_t open;

   /** @copydoc retro_vfs_close_t */
	retro_vfs_close_t close;

   /** @copydoc retro_vfs_size_t */
	retro_vfs_size_t size;

   /** @copydoc retro_vfs_tell_t */
	retro_vfs_tell_t tell;

   /** @copydoc retro_vfs_seek_t */
	retro_vfs_seek_t seek;

   /** @copydoc retro_vfs_read_t */
	retro_vfs_read_t read;

   /** @copydoc retro_vfs_write_t */
	retro_vfs_write_t write;

   /** @copydoc retro_vfs_flush_t */
	retro_vfs_flush_t flush;

   /** @copydoc retro_vfs_remove_t */
	retro_vfs_remove_t remove;

   /** @copydoc retro_vfs_rename_t */
	retro_vfs_rename_t rename;
   /* VFS API v2 */

   /** @copydoc retro_vfs_truncate_t */
   retro_vfs_truncate_t truncate;
   /* VFS API v3 */

   /** @copydoc retro_vfs_stat_t */
   retro_vfs_stat_t stat;

   /** @copydoc retro_vfs_mkdir_t */
   retro_vfs_mkdir_t mkdir;

   /** @copydoc retro_vfs_opendir_t */
   retro_vfs_opendir_t opendir;

   /** @copydoc retro_vfs_readdir_t */
   retro_vfs_readdir_t readdir;

   /** @copydoc retro_vfs_dirent_get_name_t */
   retro_vfs_dirent_get_name_t dirent_get_name;

   /** @copydoc retro_vfs_dirent_is_dir_t */
   retro_vfs_dirent_is_dir_t dirent_is_dir;

   /** @copydoc retro_vfs_closedir_t */
   retro_vfs_closedir_t closedir;
};

/**
 * Represents a request by the core for the frontend's file system interface,
 * as well as the interface itself returned by the frontend.
 *
 * You do not need to use these functions directly;
 * you may pass this struct to \c dirent_vfs_init,
 * \c filestream_vfs_init, or \c path_vfs_init
 * so that you can use the wrappers provided by these modules.
 *
 * @see dirent_vfs_init
 * @see filestream_vfs_init
 * @see path_vfs_init
 * @see RETRO_ENVIRONMENT_GET_VFS_INTERFACE
 */
struct retro_vfs_interface_info
{
   /**
    * The minimum version of the VFS API that the core requires.
    * libretro-common's wrapper API initializers will check this value as well.
    *
    * Set to the core's desired VFS version when requesting an interface,
    * and set by the frontend to indicate its actual API version.
    *
    * If the core asks for a newer VFS API version than the frontend supports,
    * the frontend must return \c false within the \c RETRO_ENVIRONMENT_GET_VFS_INTERFACE call.
    * @since VFS API v1
    */
   uint32_t required_interface_version;

   /**
    * Set by the frontend.
    * The frontend will set this to the VFS interface it provides.
    *
    * The interface is owned by the frontend
    * and must not be modified or freed by the core.
    * @since VFS API v1 */
   struct retro_vfs_interface *iface;
};

/** @} */

/** @defgroup GET_HW_RENDER_INTERFACE Hardware Rendering Interface
 * @{
 */

/**
 * Describes the hardware rendering API supported by
 * a particular subtype of \c retro_hw_render_interface.
 *
 * Not every rendering API supported by libretro has its own interface,
 * or even needs one.
 *
 * @see RETRO_ENVIRONMENT_SET_HW_RENDER
 * @see RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE
 */
enum retro_hw_render_interface_type
{
   /**
    * Indicates a \c retro_hw_render_interface for Vulkan.
    * @see retro_hw_render_interface_vulkan
    */
   RETRO_HW_RENDER_INTERFACE_VULKAN     = 0,

   /** Indicates a \c retro_hw_render_interface for Direct3D 9. */
   RETRO_HW_RENDER_INTERFACE_D3D9       = 1,

   /** Indicates a \c retro_hw_render_interface for Direct3D 10. */
   RETRO_HW_RENDER_INTERFACE_D3D10      = 2,

   /**
    * Indicates a \c retro_hw_render_interface for Direct3D 11.
    * @see retro_hw_render_interface_d3d11
    */
   RETRO_HW_RENDER_INTERFACE_D3D11      = 3,

   /**
    * Indicates a \c retro_hw_render_interface for Direct3D 12.
    * @see retro_hw_render_interface_d3d12
    */
   RETRO_HW_RENDER_INTERFACE_D3D12      = 4,

   /**
    * Indicates a \c retro_hw_render_interface for
    * the PlayStation's 2 PSKit API.
    * @see retro_hw_render_interface_gskit_ps2
    */
   RETRO_HW_RENDER_INTERFACE_GSKIT_PS2  = 5,

   /** @private Defined to ensure <tt>sizeof(retro_hw_render_interface_type) == sizeof(int)</tt>.
    * Do not use. */
   RETRO_HW_RENDER_INTERFACE_DUMMY      = INT_MAX
};

/**
 * Base render interface type.
 * All \c retro_hw_render_interface implementations
 * will start with these two fields set to particular values.
 *
 * @see retro_hw_render_interface_type
 * @see RETRO_ENVIRONMENT_SET_HW_RENDER
 * @see RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE
 */
struct retro_hw_render_interface
{
   /**
    * Denotes the particular rendering API that this interface is for.
    * Each interface requires this field to be set to a particular value.
    * Use it to cast this interface to the appropriate pointer.
    */
   enum retro_hw_render_interface_type interface_type;

   /**
    * The version of this rendering interface.
    * @note This is not related to the version of the API itself.
    */
   unsigned interface_version;
};

/** @} */

/**
 * @defgroup GET_LED_INTERFACE LED Interface
 * @{
 */

/** @copydoc retro_led_interface::set_led_state */
typedef void (RETRO_CALLCONV *retro_set_led_state_t)(int led, int state);

/**
 * Interface that the core can use to set the state of available LEDs.
 * @see RETRO_ENVIRONMENT_GET_LED_INTERFACE
 */
struct retro_led_interface
{
   /**
    * Sets the state of an LED.
    *
    * @param led The LED to set the state of.
    * @param state The state to set the LED to.
    * \c true to enable, \c false to disable.
    */
   retro_set_led_state_t set_led_state;
};

/** @} */

/** @defgroup GET_AUDIO_VIDEO_ENABLE Skipped A/V Steps
 * @{
 */

/**
 * Flags that define A/V steps that the core may skip for this frame.
 *
 * @see RETRO_ENVIRONMENT_GET_AUDIO_VIDEO_ENABLE
 */
enum retro_av_enable_flags
{
   /**
    * If set, the core should render video output with \c retro_video_refresh_t as normal.
    *
    * Otherwise, the frontend will discard any video data received this frame,
    * including frames presented via hardware acceleration.
    * \c retro_video_refresh_t will do nothing.
    *
    * @note After running the frame, the video output of the next frame
    * should be no different than if video was enabled,
    * and saving and loading state should have no issues.
    * This implies that the emulated console's graphics pipeline state
    * should not be affected by this flag.
    *
    * @note If emulating a platform that supports display capture
    * (i.e. reading its own VRAM),
    * the core may not be able to completely skip rendering,
    * as the VRAM is part of the graphics pipeline's state.
    */
   RETRO_AV_ENABLE_VIDEO = (1 << 0),

   /**
    * If set, the core should render audio output
    * with \c retro_audio_sample_t or \c retro_audio_sample_batch_t as normal.
    *
    * Otherwise, the frontend will discard any audio data received this frame.
    * The core should skip audio rendering if possible.
    *
    * @note After running the frame, the audio output of the next frame
    * should be no different than if audio was enabled,
    * and saving and loading state should have no issues.
    * This implies that the emulated console's audio pipeline state
    * should not be affected by this flag.
    */
   RETRO_AV_ENABLE_AUDIO = (1 << 1),

   /**
    * If set, indicates that any savestates taken this frame
    * are guaranteed to be created by the same binary that will load them,
    * and will not be written to or read from the disk.
    *
    * The core may use these guarantees to:
    *
    * @li Assume that loading state will succeed.
    * @li Update its memory buffers in-place if possible.
    * @li Skip clearing memory.
    * @li Skip resetting the system.
    * @li Skip validation steps.
    *
    * @deprecated Use \c RETRO_ENVIRONMENT_GET_SAVESTATE_CONTEXT instead,
    * except for compatibility purposes.
    */
   RETRO_AV_ENABLE_FAST_SAVESTATES = (1 << 2),

   /**
    * If set, indicates that the frontend will never need audio from the core.
    * Used by a frontend for implementing runahead via a secondary core instance.
    *
    * The core may stop synthesizing audio if it can do so
    * without compromising emulation accuracy.
    *
    * Audio output for the next frame does not matter,
    * and the frontend will never need an accurate audio state in the future.
    *
    * State will never be saved while this flag is set.
    */
   RETRO_AV_ENABLE_HARD_DISABLE_AUDIO = (1 << 3),

   /**
    * @private Defined to ensure <tt>sizeof(retro_av_enable_flags) == sizeof(int)</tt>.
    * Do not use.
    */
   RETRO_AV_ENABLE_DUMMY = INT_MAX
};

/** @} */

/**
 * @defgroup GET_MIDI_INTERFACE MIDI Interface
 * @{
 */

/** @copydoc retro_midi_interface::input_enabled */
typedef bool (RETRO_CALLCONV *retro_midi_input_enabled_t)(void);

/** @copydoc retro_midi_interface::output_enabled */
typedef bool (RETRO_CALLCONV *retro_midi_output_enabled_t)(void);

/** @copydoc retro_midi_interface::read */
typedef bool (RETRO_CALLCONV *retro_midi_read_t)(uint8_t *byte);

/** @copydoc retro_midi_interface::write */
typedef bool (RETRO_CALLCONV *retro_midi_write_t)(uint8_t byte, uint32_t delta_time);

/** @copydoc retro_midi_interface::flush */
typedef bool (RETRO_CALLCONV *retro_midi_flush_t)(void);

/**
 * Interface that the core can use for raw MIDI I/O.
 */
struct retro_midi_interface
{
   /**
    * Retrieves the current state of MIDI input.
    *
    * @return \c true if MIDI input is enabled.
    */
   retro_midi_input_enabled_t input_enabled;

   /**
    * Retrieves the current state of MIDI output.
    * @return \c true if MIDI output is enabled.
    */
   retro_midi_output_enabled_t output_enabled;

   /**
    * Reads a byte from the MIDI input stream.
    *
    * @param[out] byte The byte received from the input stream.
    * @return \c true if a byte was read,
    * \c false if MIDI input is disabled or \c byte is \c NULL.
    */
   retro_midi_read_t read;

   /**
    * Writes a byte to the output stream.
    *
    * @param byte The byte to write to the output stream.
    * @param delta_time Time since the previous write, in microseconds.
    * @return \c true if c\ byte was written, false otherwise.
    */
   retro_midi_write_t write;

   /**
    * Flushes previously-written data.
    *
    * @return \c true if successful.
    */
   retro_midi_flush_t flush;
};

/** @} */

/** @defgroup SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE Render Context Negotiation
 * @{
 */

/**
 * Describes the hardware rendering API used by
 * a particular subtype of \c retro_hw_render_context_negotiation_interface.
 *
 * Not every rendering API supported by libretro has a context negotiation interface,
 * or even needs one.
 *
 * @see RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE
 * @see RETRO_ENVIRONMENT_SET_HW_RENDER
 * @see RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE
 */
enum retro_hw_render_context_negotiation_interface_type
{
   /**
    * Denotes a context negotiation interface for Vulkan.
    * @see retro_hw_render_context_negotiation_interface_vulkan
    */
   RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN = 0,

   /**
    * @private Defined to ensure <tt>sizeof(retro_hw_render_context_negotiation_interface_type) == sizeof(int)</tt>.
    * Do not use.
    */
   RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_DUMMY = INT_MAX
};

/**
 * Base context negotiation interface type.
 * All \c retro_hw_render_context_negotiation_interface implementations
 * will start with these two fields set to particular values.
 *
 * @see retro_hw_render_interface_type
 * @see RETRO_ENVIRONMENT_SET_HW_RENDER
 * @see RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE
 * @see RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE
 */
struct retro_hw_render_context_negotiation_interface
{
   /**
    * Denotes the particular rendering API that this interface is for.
    * Each interface requires this field to be set to a particular value.
    * Use it to cast this interface to the appropriate pointer.
    */
   enum retro_hw_render_context_negotiation_interface_type interface_type;

   /**
    * The version of this negotiation interface.
    * @note This is not related to the version of the API itself.
    */
   unsigned interface_version;
};

/** @} */

/** @defgroup RETRO_SERIALIZATION_QUIRK Serialization Quirks
 * @{
 */

/**
 * Indicates that serialized state is incomplete in some way.
 *
 * Set if serialization is usable for the common case of saving and loading game state,
 * but should not be relied upon for frame-sensitive frontend features
 * such as netplay or rerecording.
 */
#define RETRO_SERIALIZATION_QUIRK_INCOMPLETE (1 << 0)

/**
 * Indicates that core must spend some time initializing before serialization can be done.
 *
 * \c retro_serialize(), \c retro_unserialize(), and \c retro_serialize_size() will initially fail.
 */
#define RETRO_SERIALIZATION_QUIRK_MUST_INITIALIZE (1 << 1)

/** Set by the core to indicate that serialization size may change within a session. */
#define RETRO_SERIALIZATION_QUIRK_CORE_VARIABLE_SIZE (1 << 2)

/** Set by the frontend to acknowledge that it supports variable-sized states. */
#define RETRO_SERIALIZATION_QUIRK_FRONT_VARIABLE_SIZE (1 << 3)

/** Serialized state can only be loaded during the same session. */
#define RETRO_SERIALIZATION_QUIRK_SINGLE_SESSION (1 << 4)

/**
 * Serialized state cannot be loaded on an architecture
 * with a different endianness from the one it was saved on.
 */
#define RETRO_SERIALIZATION_QUIRK_ENDIAN_DEPENDENT (1 << 5)

/**
 * Serialized state cannot be loaded on a different platform
 * from the one it was saved on for reasons other than endianness,
 * such as word size dependence.
 */
#define RETRO_SERIALIZATION_QUIRK_PLATFORM_DEPENDENT (1 << 6)

/** @} */

/** @defgroup SET_MEMORY_MAPS Memory Descriptors
 * @{
 */

/** @defgroup RETRO_MEMDESC Memory Descriptor Flags
 * Information about how the emulated hardware uses this portion of its address space.
 * @{
 */

/**
 * Indicates that this memory area won't be modified
 * once \c retro_load_game has returned.
 */
#define RETRO_MEMDESC_CONST      (1 << 0)

/**
 * Indicates a memory area with big-endian byte ordering,
 * as opposed to the default of little-endian.
 */
#define RETRO_MEMDESC_BIGENDIAN  (1 << 1)

/**
 * Indicates a memory area that is used for the emulated system's main RAM.
 */
#define RETRO_MEMDESC_SYSTEM_RAM (1 << 2)

/**
 * Indicates a memory area that is used for the emulated system's save RAM,
 * usually found on a game cartridge as battery-backed RAM or flash memory.
 */
#define RETRO_MEMDESC_SAVE_RAM   (1 << 3)

/**
 * Indicates a memory area that is used for the emulated system's video RAM,
 * usually found on a console's GPU (or local equivalent).
 */
#define RETRO_MEMDESC_VIDEO_RAM  (1 << 4)

/**
 * Indicates a memory area that requires all accesses
 * to be aligned to 2 bytes or their own size
 * (whichever is smaller).
 */
#define RETRO_MEMDESC_ALIGN_2    (1 << 16)

/**
 * Indicates a memory area that requires all accesses
 * to be aligned to 4 bytes or their own size
 * (whichever is smaller).
 */
#define RETRO_MEMDESC_ALIGN_4    (2 << 16)

/**
 * Indicates a memory area that requires all accesses
 * to be aligned to 8 bytes or their own size
 * (whichever is smaller).
 */
#define RETRO_MEMDESC_ALIGN_8    (3 << 16)

/**
 * Indicates a memory area that requires all accesses
 * to be at least 2 bytes long.
 */
#define RETRO_MEMDESC_MINSIZE_2  (1 << 24)

/**
 * Indicates a memory area that requires all accesses
 * to be at least 4 bytes long.
 */
#define RETRO_MEMDESC_MINSIZE_4  (2 << 24)

/**
 * Indicates a memory area that requires all accesses
 * to be at least 8 bytes long.
 */
#define RETRO_MEMDESC_MINSIZE_8  (3 << 24)

/** @} */

/**
 * A mapping from a region of the emulated console's address space
 * to the host's address space.
 *
 * Can be used to map an address in the console's address space
 * to the host's address space, like so:
 *
 * @code
 * void* emu_to_host(void* addr, struct retro_memory_descriptor* descriptor)
 * {
 *     return descriptor->ptr + (addr & ~descriptor->disconnect) - descriptor->start;
 * }
 * @endcode
 *
 * @see RETRO_ENVIRONMENT_SET_MEMORY_MAPS
 */
struct retro_memory_descriptor
{
   /**
    * A bitwise \c OR of one or more \ref RETRO_MEMDESC "flags"
    * that describe how the emulated system uses this descriptor's address range.
    *
    * @note If \c ptr is \c NULL,
    * then no flags should be set.
    * @see RETRO_MEMDESC
    */
   uint64_t flags;

   /**
    * Pointer to the start of this memory region's buffer
    * within the \em host's address space.
    * The address listed here must be valid for the duration of the session;
    * it must not be freed or modified by the frontend
    * and it must not be moved by the core.
    *
    * May be \c NULL to indicate a lack of accessible memory
    * at the emulated address given in \c start.
    *
    * @note Overlapping descriptors that include the same byte
    * must have the same \c ptr value.
    */
   void *ptr;

   /**
    * The offset of this memory region,
    * relative to the address given by \c ptr.
    *
    * @note It is recommended to use this field for address calculations
    * instead of performing arithmetic on \c ptr.
    */
   size_t offset;

   /**
    * The starting address of this memory region
    * <em>within the emulated hardware's address space</em>.
    *
    * @note Not represented as a pointer
    * because it's unlikely to be valid on the host device.
    */
   size_t start;

   /**
    * A bitmask that specifies which bits of an address must match
    * the bits of the \ref start address.
    *
    * Combines with \c disconnect to map an address to a memory block.
    *
    * If multiple memory descriptors can claim a particular byte,
    * the first one defined in the \ref retro_memory_descriptor array applies.
    * A bit which is set in \c start must also be set in this.
    *
    * Can be zero, in which case \c start and \c len represent
    * the complete mapping for this region of memory
    * (i.e. each byte is mapped exactly once).
    * In this case, \c len must be a power of two.
    */
   size_t select;

   /**
    * A bitmask of bits that are \em not used for addressing.
    *
    * Any set bits are assumed to be disconnected from
    * the emulated memory chip's address pins,
    * and are therefore ignored when memory-mapping.
    */
   size_t disconnect;

   /**
    * The length of this memory region, in bytes.
    *
    * If applying \ref start and \ref disconnect to an address
    * results in a value higher than this,
    * the highest bit of the address is cleared.
    *
    * If the address is still too high, the next highest bit is cleared.
    * Can be zero, in which case it's assumed to be
    * bounded only by \ref select and \ref disconnect.
    */
   size_t len;

   /**
    * A short name for this address space.
    *
    * Names must meet the following requirements:
    *
    * \li Characters must be in the set <tt>[a-zA-Z0-9_-]</tt>.
    * \li No more than 8 characters, plus a \c NULL terminator.
    * \li Names are case-sensitive, but lowercase characters are discouraged.
    * \li A name must not be the same as another name plus a character in the set \c [A-F0-9]
    *     (i.e. if an address space named "RAM" exists,
    *     then the names "RAM0", "RAM1", ..., "RAMF" are forbidden).
    *     This is to allow addresses to be named by each descriptor unambiguously,
    *     even if the areas overlap.
    * \li May be \c NULL or empty (both are considered equivalent).
    *
    * Here are some examples of pairs of address space names:
    *
    * \li \em blank + \em blank: valid (multiple things may be mapped in the same namespace)
    * \li \c Sp + \c Sp: valid (multiple things may be mapped in the same namespace)
    * \li \c SRAM + \c VRAM: valid (neither is a prefix of the other)
    * \li \c V + \em blank: valid (\c V is not in \c [A-F0-9])
    * \li \c a + \em blank: valid but discouraged (\c a is not in \c [A-F0-9])
    * \li \c a + \c A: valid but discouraged (neither is a prefix of the other)
    * \li \c AR + \em blank: valid (\c R is not in \c [A-F0-9])
    * \li \c ARB + \em blank: valid (there's no \c AR namespace,
    *     so the \c B doesn't cause ambiguity).
    * \li \em blank + \c B: invalid, because it's ambiguous which address space \c B1234 would refer to.
    *
    * The length of the address space's name can't be used to disambugiate,
    * as extra information may be appended to it without a separator.
    */
   const char *addrspace;

   /* TODO: When finalizing this one, add a description field, which should be
    * "WRAM" or something roughly equally long. */

   /* TODO: When finalizing this one, replace 'select' with 'limit', which tells
    * which bits can vary and still refer to the same address (limit = ~select).
    * TODO: limit? range? vary? something else? */

   /* TODO: When finalizing this one, if 'len' is above what 'select' (or
    * 'limit') allows, it's bankswitched. Bankswitched data must have both 'len'
    * and 'select' != 0, and the mappings don't tell how the system switches the
    * banks. */

   /* TODO: When finalizing this one, fix the 'len' bit removal order.
    * For len=0x1800, pointer 0x1C00 should go to 0x1400, not 0x0C00.
    * Algorithm: Take bits highest to lowest, but if it goes above len, clear
    * the most recent addition and continue on the next bit.
    * TODO: Can the above be optimized? Is "remove the lowest bit set in both
    * pointer and 'len'" equivalent? */

   /* TODO: Some emulators (MAME?) emulate big endian systems by only accessing
    * the emulated memory in 32-bit chunks, native endian. But that's nothing
    * compared to Darek Mihocka <http://www.emulators.com/docs/nx07_vm101.htm>
    * (section Emulation 103 - Nearly Free Byte Reversal) - he flips the ENTIRE
    * RAM backwards! I'll want to represent both of those, via some flags.
    *
    * I suspect MAME either didn't think of that idea, or don't want the #ifdef.
    * Not sure which, nor do I really care. */

   /* TODO: Some of those flags are unused and/or don't really make sense. Clean
    * them up. */
};

/**
 * A list of regions within the emulated console's address space.
 *
 * The frontend may use the largest value of
 * \ref retro_memory_descriptor::start + \ref retro_memory_descriptor::select
 * in a certain namespace to infer the overall size of the address space.
 * If the address space is larger than that,
 * the last mapping in \ref descriptors should have \ref retro_memory_descriptor::ptr set to \c NULL
 * and \ref retro_memory_descriptor::select should have all bits used in the address space set to 1.
 *
 * Here's an example set of descriptors for the SNES.
 *
 * @code{.c}
 * struct retro_memory_map snes_descriptors = retro_memory_map
 * {
 *    .descriptors = (struct retro_memory_descriptor[])
 *    {
 *       // WRAM; must usually be mapped before the ROM,
 *       // as some SNES ROM mappers try to claim 0x7E0000
 *       { .addrspace="WRAM", .start=0x7E0000, .len=0x20000 },
 *
 *       // SPC700 RAM
 *       { .addrspace="SPC700", .len=0x10000 },
 *
 *       // WRAM mirrors
 *       { .addrspace="WRAM", .start=0x000000, .select=0xC0E000, .len=0x2000 },
 *       { .addrspace="WRAM", .start=0x800000, .select=0xC0E000, .len=0x2000 },
 *
 *       // WRAM mirror, alternate equivalent descriptor
 *       // (Various similar constructions can be created by combining parts of the above two.)
 *       { .addrspace="WRAM", .select=0x40E000, .disconnect=~0x1FFF },
 *
 *       // LoROM (512KB, mirrored a couple of times)
 *       { .addrspace="LoROM", .start=0x008000, .select=0x408000, .disconnect=0x8000, .len=512*1024, .flags=RETRO_MEMDESC_CONST },
 *       { .addrspace="LoROM", .start=0x400000, .select=0x400000, .disconnect=0x8000, .len=512*1024, .flags=RETRO_MEMDESC_CONST },
 *
 *       // HiROM (4MB)
 *       { .addrspace="HiROM", .start=0x400000, .select=0x400000, .len=4*1024*1024, .flags=RETRO_MEMDESC_CONST },
 *       { .addrspace="HiROM", .start=0x008000, .select=0x408000, .len=4*1024*1024, .offset=0x8000, .flags=RETRO_MEMDESC_CONST },
 *
 *       // ExHiROM (8MB)
 *       { .addrspace="ExHiROM", .start=0xC00000, .select=0xC00000, .len=4*1024*1024, .offset=0, .flags=RETRO_MEMDESC_CONST },
 *       { .addrspace="ExHiROM", .start=0x400000, .select=0xC00000, .len=4*1024*1024, .offset=4*1024*1024, .flags=RETRO_MEMDESC_CONST },
 *       { .addrspace="ExHiROM", .start=0x808000, .select=0xC08000, .len=4*1024*1024, .offset=0x8000, .flags=RETRO_MEMDESC_CONST },
 *       { .addrspace="ExHiROM", .start=0x008000, .select=0xC08000, .len=4*1024*1024, .offset=4*1024*1024+0x8000, .flags=RETRO_MEMDESC_CONST },
 *
 *       // Clarifying the full size of the address space
 *       { .select=0xFFFFFF, .ptr=NULL },
 *    },
 *    .num_descriptors = 14,
 * };
 * @endcode
 *
 * @see RETRO_ENVIRONMENT_SET_MEMORY_MAPS
 */
struct retro_memory_map
{
   /**
    * Pointer to an array of memory descriptors,
    * each of which describes part of the emulated console's address space.
    */
   const struct retro_memory_descriptor *descriptors;

   /** The number of descriptors in \c descriptors. */
   unsigned num_descriptors;
};

/** @} */

/** @defgroup SET_CONTROLLER_INFO Controller Info
 * @{
 */

/**
 * Details about a controller (or controller configuration)
 * supported by one of a core's emulated input ports.
 *
 * @see RETRO_ENVIRONMENT_SET_CONTROLLER_INFO
 */
struct retro_controller_description
{
   /**
    * A human-readable label for the controller or configuration
    * represented by this device type.
    * Most likely the device's original brand name.
    */
   const char *desc;

   /**
    * A unique identifier that will be passed to \c retro_set_controller_port_device()'s \c device parameter.
    * May be the ID of one of \ref RETRO_DEVICE "the generic controller types",
    * or a subclass ID defined with \c RETRO_DEVICE_SUBCLASS.
    *
    * @see RETRO_DEVICE_SUBCLASS
    */
   unsigned id;
};

/**
 * Lists the types of controllers supported by
 * one of core's emulated input ports.
 *
 * @see RETRO_ENVIRONMENT_SET_CONTROLLER_INFO
 */
struct retro_controller_info
{

   /**
    * A pointer to an array of device types supported by this controller port.
    *
    * @note Ports that support the same devices
    * may share the same underlying array.
    */
   const struct retro_controller_description *types;

   /** The number of elements in \c types. */
   unsigned num_types;
};

/** @} */

/** @defgroup SET_SUBSYSTEM_INFO Subsystems
 * @{
 */

/**
 * Information about a type of memory associated with a subsystem.
 * Usually used for SRAM (save RAM).
 *
 * @see RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO
 * @see retro_get_memory_data
 * @see retro_get_memory_size
 */
struct retro_subsystem_memory_info
{
   /**
    * The file extension the frontend should use
    * to save this memory region to disk, e.g. "srm" or "sav".
    */
   const char *extension;

   /**
    * A constant that identifies this type of memory.
    * Should be at least 0x100 (256) to avoid conflict
    * with the standard libretro memory types,
    * unless a subsystem uses the main platform's memory region.
    * @see RETRO_MEMORY
    */
   unsigned type;
};

/**
 * Information about a type of ROM that a subsystem may use.
 * Subsystems may use one or more ROMs at once,
 * possibly of different types.
 *
 * @see RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO
 * @see retro_subsystem_info
 */
struct retro_subsystem_rom_info
{
   /**
    * Human-readable description of what the content represents,
    * e.g. "Game Boy ROM".
    */
   const char *desc;

   /** @copydoc retro_system_info::valid_extensions */
   const char *valid_extensions;

   /** @copydoc retro_system_info::need_fullpath */
   bool need_fullpath;

   /** @copydoc retro_system_info::block_extract */
   bool block_extract;

   /**
    * Indicates whether this particular subsystem ROM is required.
    * If \c true and the user doesn't provide a ROM,
    * the frontend should not load the core.
    * If \c false and the user doesn't provide a ROM,
    * the frontend should pass a zeroed-out \c retro_game_info
    * to the corresponding entry in \c retro_load_game_special().
    */
   bool required;

   /**
    * Pointer to an array of memory descriptors that this subsystem ROM type uses.
    * Useful for secondary cartridges that have their own save data.
    * May be \c NULL, in which case this subsystem ROM's memory is not persisted by the frontend
    * and \c num_memory should be zero.
    */
   const struct retro_subsystem_memory_info *memory;

   /** The number of elements in the array pointed to by \c memory. */
   unsigned num_memory;
};

/**
 * Information about a secondary platform that a core supports.
 * @see RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO
 */
struct retro_subsystem_info
{
   /**
    * A human-readable description of the subsystem type,
    * usually the brand name of the original platform
    * (e.g. "Super Game Boy").
    */
   const char *desc;

   /**
    * A short machine-friendly identifier for the subsystem,
    * usually an abbreviation of the platform name.
    * For example, a Super Game Boy subsystem for a SNES core
    * might use an identifier of "sgb".
    * This identifier can be used for command-line interfaces,
    * configuration, or other purposes.
    * Must use lower-case alphabetical characters only (i.e. from a-z).
    */
   const char *ident;

   /**
    * The list of ROM types that this subsystem may use.
    *
    * The first entry is considered to be the "most significant" content,
    * for the purposes of the frontend's categorization.
    * E.g. with Super GameBoy, the first content should be the GameBoy ROM,
    * as it is the most "significant" content to a user.
    *
    * If a frontend creates new files based on the content used (e.g. for savestates),
    * it should derive the filenames from the name of the first ROM in this list.
    *
    * @note \c roms can have a single element,
    * but this is usually a sign that the core should broaden its
    * primary system info instead.
    *
    * @see \c retro_system_info
    */
   const struct retro_subsystem_rom_info *roms;

   /** The length of the array given in \c roms. */
   unsigned num_roms;

   /** A unique identifier passed to retro_load_game_special(). */
   unsigned id;
};

/** @} */

/** @defgroup SET_PROC_ADDRESS_CALLBACK Core Function Pointers
 * @{ */

/**
 * The function pointer type that \c retro_get_proc_address_t returns.
 *
 * Despite the signature shown here, the original function may include any parameters and return type
 * that respects the calling convention and C ABI.
 *
 * The frontend is expected to cast the function pointer to the correct type.
 */
typedef void (RETRO_CALLCONV *retro_proc_address_t)(void);

/**
 * Get a symbol from a libretro core.
 *
 * Cores should only return symbols that serve as libretro extensions.
 * Frontends should not use this to obtain symbols to standard libretro entry points;
 * instead, they should link to the core statically or use \c dlsym (or local equivalent).
 *
 * The symbol name must be equal to the function name.
 * e.g. if <tt>void retro_foo(void);</tt> exists, the symbol in the compiled library must be called \c retro_foo.
 * The returned function pointer must be cast to the corresponding type.
 *
 * @param \c sym The name of the symbol to look up.
 * @return Pointer to the exposed function with the name given in \c sym,
 * or \c NULL if one couldn't be found.
 * @note The frontend is expected to know the returned pointer's type in advance
 * so that it can be cast correctly.
 * @note The core doesn't need to expose every possible function through this interface.
 * It's enough to only expose the ones that it expects the frontend to use.
 * @note The functions exposed through this interface
 * don't need to be publicly exposed in the compiled library
 * (e.g. via \c __declspec(dllexport)).
 * @see RETRO_ENVIRONMENT_SET_PROC_ADDRESS_CALLBACK
 */
typedef retro_proc_address_t (RETRO_CALLCONV *retro_get_proc_address_t)(const char *sym);

/**
 * An interface that the frontend can use to get function pointers from the core.
 *
 * @note The returned function pointer will be invalidated once the core is unloaded.
 * How and when that happens is up to the frontend.
 *
 * @see retro_get_proc_address_t
 * @see RETRO_ENVIRONMENT_SET_PROC_ADDRESS_CALLBACK
 */
struct retro_get_proc_address_interface
{
   /** Set by the core. */
   retro_get_proc_address_t get_proc_address;
};

/** @} */

/** @defgroup GET_LOG_INTERFACE Logging
 * @{
 */

/**
 * The severity of a given message.
 * The frontend may log messages differently depending on the level.
 * It may also ignore log messages of a certain level.
 * @see retro_log_callback
 */
enum retro_log_level
{
   /** The logged message is most likely not interesting to the user. */
   RETRO_LOG_DEBUG = 0,

   /** Information about the core operating normally. */
   RETRO_LOG_INFO,

   /** Indicates a potential problem, possibly one that the core can recover from. */
   RETRO_LOG_WARN,

   /** Indicates a degraded experience, if not failure. */
   RETRO_LOG_ERROR,

   /** Defined to ensure that sizeof(enum retro_log_level) == sizeof(int). Do not use. */
   RETRO_LOG_DUMMY = INT_MAX
};

/**
 * Logs a message to the frontend.
 *
 * @param level The log level of the message.
 * @param fmt The format string to log.
 * Same format as \c printf.
 * Behavior is undefined if this is \c NULL.
 * @param ... Zero or more arguments used by the format string.
 * Behavior is undefined if these don't match the ones expected by \c fmt.
 * @see retro_log_level
 * @see retro_log_callback
 * @see RETRO_ENVIRONMENT_GET_LOG_INTERFACE
 * @see printf
 */
typedef void (RETRO_CALLCONV *retro_log_printf_t)(enum retro_log_level level,
      const char *fmt, ...);

/**
 * Details about how to make log messages.
 *
 * @see retro_log_printf_t
 * @see RETRO_ENVIRONMENT_GET_LOG_INTERFACE
 */
struct retro_log_callback
{
   /**
    * Called when logging a message.
    *
    * @note Set by the frontend.
    */
   retro_log_printf_t log;
};

/** @} */

/** @defgroup GET_PERF_INTERFACE Performance Interface
 * @{
 */

/** @defgroup RETRO_SIMD CPU Features
 * @{
 */

/**
 * Indicates CPU support for the SSE instruction set.
 *
 * @see https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#ssetechs=SSE
 */
#define RETRO_SIMD_SSE      (1 << 0)

/**
 * Indicates CPU support for the SSE2 instruction set.
 *
 * @see https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#ssetechs=SSE2
 */
#define RETRO_SIMD_SSE2     (1 << 1)

/** Indicates CPU support for the AltiVec (aka VMX or Velocity Engine) instruction set. */
#define RETRO_SIMD_VMX      (1 << 2)

/** Indicates CPU support for the VMX128 instruction set. Xbox 360 only. */
#define RETRO_SIMD_VMX128   (1 << 3)

/**
 * Indicates CPU support for the AVX instruction set.
 *
 * @see https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#avxnewtechs=AVX
 */
#define RETRO_SIMD_AVX      (1 << 4)

/**
 * Indicates CPU support for the NEON instruction set.
 * @see https://developer.arm.com/architectures/instruction-sets/intrinsics/#f:@navigationhierarchiessimdisa=[Neon]
 */
#define RETRO_SIMD_NEON     (1 << 5)

/**
 * Indicates CPU support for the SSE3 instruction set.
 *
 * @see https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#ssetechs=SSE3
 */
#define RETRO_SIMD_SSE3     (1 << 6)

/**
 * Indicates CPU support for the SSSE3 instruction set.
 *
 * @see https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#ssetechs=SSSE3
 */
#define RETRO_SIMD_SSSE3    (1 << 7)

/**
 * Indicates CPU support for the MMX instruction set.
 * @see https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#techs=MMX
 */
#define RETRO_SIMD_MMX      (1 << 8)

/** Indicates CPU support for the MMXEXT instruction set. */
#define RETRO_SIMD_MMXEXT   (1 << 9)

/**
 * Indicates CPU support for the SSE4 instruction set.
 *
 * @see https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#ssetechs=SSE4_1
 */
#define RETRO_SIMD_SSE4     (1 << 10)

/**
 * Indicates CPU support for the SSE4.2 instruction set.
 *
 * @see https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#ssetechs=SSE4_2
 */
#define RETRO_SIMD_SSE42    (1 << 11)

/**
 * Indicates CPU support for the AVX2 instruction set.
 *
 * @see https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#avxnewtechs=AVX2
 */
#define RETRO_SIMD_AVX2     (1 << 12)

/** Indicates CPU support for the VFPU instruction set. PS2 and PSP only.
 *
 * @see https://pspdev.github.io/vfpu-docs
 */
#define RETRO_SIMD_VFPU     (1 << 13)

/**
 * Indicates CPU support for Gekko SIMD extensions. GameCube only.
 */
#define RETRO_SIMD_PS       (1 << 14)

/**
 * Indicates CPU support for AES instructions.
 *
 * @see https://www.intel.com/content/www/us/en/docs/intrinsics-guide/index.html#aestechs=AES&othertechs=AES
 */
#define RETRO_SIMD_AES      (1 << 15)

/**
 * Indicates CPU support for the VFPv3 instruction set.
 */
#define RETRO_SIMD_VFPV3    (1 << 16)

/**
 * Indicates CPU support for the VFPv4 instruction set.
 */
#define RETRO_SIMD_VFPV4    (1 << 17)

/** Indicates CPU support for the POPCNT instruction. */
#define RETRO_SIMD_POPCNT   (1 << 18)

/** Indicates CPU support for the MOVBE instruction. */
#define RETRO_SIMD_MOVBE    (1 << 19)

/** Indicates CPU support for the CMOV instruction. */
#define RETRO_SIMD_CMOV     (1 << 20)

/** Indicates CPU support for the ASIMD instruction set. */
#define RETRO_SIMD_ASIMD    (1 << 21)

/** @} */

/**
 * An abstract unit of ticks.
 *
 * Usually nanoseconds or CPU cycles,
 * but it depends on the platform and the frontend.
 */
typedef uint64_t retro_perf_tick_t;

/** Time in microseconds. */
typedef int64_t retro_time_t;

/**
 * A performance counter.
 *
 * Use this to measure the execution time of a region of code.
 * @see retro_perf_callback
 */
struct retro_perf_counter
{
   /**
    * A human-readable identifier for the counter.
    *
    * May be displayed by the frontend.
    * Behavior is undefined if this is \c NULL.
    */
   const char *ident;

   /**
    * The time of the most recent call to \c retro_perf_callback::perf_start
    * on this performance counter.
    *
    * @see retro_perf_start_t
    */
   retro_perf_tick_t start;

   /**
    * The total time spent within this performance counter's measured code,
    * i.e. between calls to \c retro_perf_callback::perf_start and \c retro_perf_callback::perf_stop.
    *
    * Updated after each call to \c retro_perf_callback::perf_stop.
    * @see retro_perf_stop_t
    */
   retro_perf_tick_t total;

   /**
    * The number of times this performance counter has been started.
    *
    * Updated after each call to \c retro_perf_callback::perf_start.
    * @see retro_perf_start_t
    */
   retro_perf_tick_t call_cnt;

   /**
    * \c true if this performance counter has been registered by the frontend.
    * Must be initialized to \c false by the core before registering it.
    * @see retro_perf_register_t
    */
   bool registered;
};

/**
 * @returns The current system time in microseconds.
 * @note Accuracy may vary by platform.
 * The frontend should use the most accurate timer possible.
 * @see RETRO_ENVIRONMENT_GET_PERF_INTERFACE
 */
typedef retro_time_t (RETRO_CALLCONV *retro_perf_get_time_usec_t)(void);

/**
 * @returns The number of ticks since some unspecified epoch.
 * The exact meaning of a "tick" depends on the platform,
 * but it usually refers to nanoseconds or CPU cycles.
 * @see RETRO_ENVIRONMENT_GET_PERF_INTERFACE
 */
typedef retro_perf_tick_t (RETRO_CALLCONV *retro_perf_get_counter_t)(void);

/**
 * Returns a bitmask of detected CPU features.
 *
 * Use this for runtime dispatching of CPU-specific code.
 *
 * @returns A bitmask of detected CPU features.
 * @see RETRO_ENVIRONMENT_GET_PERF_INTERFACE
 * @see RETRO_SIMD
 */
typedef uint64_t (RETRO_CALLCONV *retro_get_cpu_features_t)(void);

/**
 * Asks the frontend to log or display the state of performance counters.
 * How this is done depends on the frontend.
 * Performance counters can be reviewed manually as well.
 *
 * @see RETRO_ENVIRONMENT_GET_PERF_INTERFACE
 * @see retro_perf_counter
 */
typedef void (RETRO_CALLCONV *retro_perf_log_t)(void);

/**
 * Registers a new performance counter.
 *
 * If \c counter has already been registered beforehand,
 * this function does nothing.
 *
 * @param counter The counter to register.
 * \c counter::ident must be set to a unique identifier,
 * and all other values in \c counter must be set to zero or \c false.
 * Behavior is undefined if \c NULL.
 * @post If \c counter is successfully registered,
 * then \c counter::registered will be set to \c true.
 * Otherwise, it will be set to \c false.
 * Registration may fail if the frontend's maximum number of counters (if any) has been reached.
 * @note The counter is owned by the core and must not be freed by the frontend.
 * The frontend must also clean up any references to a core's performance counters
 * before unloading it, otherwise undefined behavior may occur.
 * @see retro_perf_start_t
 * @see retro_perf_stop_t
 */
typedef void (RETRO_CALLCONV *retro_perf_register_t)(struct retro_perf_counter *counter);

/**
 * Starts a registered performance counter.
 *
 * Call this just before the code you want to measure.
 *
 * @param counter The counter to start.
 * Behavior is undefined if \c NULL.
 * @see retro_perf_stop_t
 */
typedef void (RETRO_CALLCONV *retro_perf_start_t)(struct retro_perf_counter *counter);

/**
 * Stops a registered performance counter.
 *
 * Call this just after the code you want to measure.
 *
 * @param counter The counter to stop.
 * Behavior is undefined if \c NULL.
 * @see retro_perf_start_t
 * @see retro_perf_stop_t
 */
typedef void (RETRO_CALLCONV *retro_perf_stop_t)(struct retro_perf_counter *counter);

/**
 * An interface that the core can use to get performance information.
 *
 * Here's a usage example:
 *
 * @code{.c}
 * #ifdef PROFILING
 * // Wrapper macros to simplify using performance counters.
 * // Optional; tailor these to your project's needs.
 * #define RETRO_PERFORMANCE_INIT(perf_cb, name) static struct retro_perf_counter name = {#name}; if (!name.registered) perf_cb.perf_register(&(name))
 * #define RETRO_PERFORMANCE_START(perf_cb, name) perf_cb.perf_start(&(name))
 * #define RETRO_PERFORMANCE_STOP(perf_cb, name) perf_cb.perf_stop(&(name))
 * #else
 * // Exclude the performance counters if profiling is disabled.
 * #define RETRO_PERFORMANCE_INIT(perf_cb, name) ((void)0)
 * #define RETRO_PERFORMANCE_START(perf_cb, name) ((void)0)
 * #define RETRO_PERFORMANCE_STOP(perf_cb, name) ((void)0)
 * #endif
 *
 * // Defined somewhere else in the core.
 * extern struct retro_perf_callback perf_cb;
 *
 * void retro_run(void)
 * {
 *    RETRO_PERFORMANCE_INIT(cb, interesting);
 *    RETRO_PERFORMANCE_START(cb, interesting);
 *    interesting_work();
 *    RETRO_PERFORMANCE_STOP(cb, interesting);
 *
 *    RETRO_PERFORMANCE_INIT(cb, maybe_slow);
 *    RETRO_PERFORMANCE_START(cb, maybe_slow);
 *    more_interesting_work();
 *    RETRO_PERFORMANCE_STOP(cb, maybe_slow);
 * }
 *
 * void retro_deinit(void)
 * {
 *    // Asks the frontend to log the results of all performance counters.
 *    perf_cb.perf_log();
 * }
 * @endcode
 *
 * All functions are set by the frontend.
 *
 * @see RETRO_ENVIRONMENT_GET_PERF_INTERFACE
 */
struct retro_perf_callback
{
   /** @copydoc retro_perf_get_time_usec_t */
   retro_perf_get_time_usec_t    get_time_usec;

   /** @copydoc retro_perf_get_counter_t */
   retro_get_cpu_features_t      get_cpu_features;

   /** @copydoc retro_perf_get_counter_t */
   retro_perf_get_counter_t      get_perf_counter;

   /** @copydoc retro_perf_register_t */
   retro_perf_register_t         perf_register;

   /** @copydoc retro_perf_start_t */
   retro_perf_start_t            perf_start;

   /** @copydoc retro_perf_stop_t */
   retro_perf_stop_t             perf_stop;

   /** @copydoc retro_perf_log_t */
   retro_perf_log_t              perf_log;
};

/** @} */

/**
 * @defgroup RETRO_SENSOR Sensor Interface
 * @{
 */

/**
 * Defines actions that can be performed on sensors.
 * @note Cores should only enable sensors while they're actively being used;
 * depending on the frontend and platform,
 * enabling these sensors may impact battery life.
 *
 * @see RETRO_ENVIRONMENT_GET_SENSOR_INTERFACE
 * @see retro_sensor_interface
 * @see retro_set_sensor_state_t
 */
enum retro_sensor_action
{
   /** Enables accelerometer input, if one exists. */
   RETRO_SENSOR_ACCELEROMETER_ENABLE = 0,

   /** Disables accelerometer input, if one exists. */
   RETRO_SENSOR_ACCELEROMETER_DISABLE,

   /** Enables gyroscope input, if one exists. */
   RETRO_SENSOR_GYROSCOPE_ENABLE,

   /** Disables gyroscope input, if one exists. */
   RETRO_SENSOR_GYROSCOPE_DISABLE,

   /** Enables ambient light input, if a luminance sensor exists. */
   RETRO_SENSOR_ILLUMINANCE_ENABLE,

   /** Disables ambient light input, if a luminance sensor exists. */
   RETRO_SENSOR_ILLUMINANCE_DISABLE,

   /** @private Defined to ensure <tt>sizeof(enum retro_sensor_action) == sizeof(int)</tt>. Do not use. */
   RETRO_SENSOR_DUMMY = INT_MAX
};

/** @defgroup RETRO_SENSOR_ID Sensor Value IDs
 * @{
 */
/* Id values for SENSOR types. */

/**
 * Returns the device's acceleration along its local X axis, in g (standard gravity, 9.80665 m/s^2).
 * Includes the effect of gravity;
 * a device at rest on a table will have values close to 0, 0, 1.
 *
 * Positive values mean that the device is accelerating to the right,
 * assuming the user is looking at it head-on.
 */
#define RETRO_SENSOR_ACCELEROMETER_X 0

/**
 * Returns the device's acceleration along its local Y axis, in g (standard gravity, 9.80665 m/s^2).
 * Includes the effect of gravity.
 *
 * Positive values mean that the device is accelerating upwards,
 * assuming the user is looking at it head-on.
 */
#define RETRO_SENSOR_ACCELEROMETER_Y 1

/**
 * Returns the device's acceleration along its local Z axis, in g (standard gravity, 9.80665 m/s^2).
 * Includes the effect of gravity.
 *
 * Positive values indicate forward acceleration towards the user,
 * assuming the user is looking at the device head-on.
 */
#define RETRO_SENSOR_ACCELEROMETER_Z 2

/**
 * Returns the angular velocity of the device around its local X axis, in radians per second.
 *
 * Positive values indicate counter-clockwise rotation.
 *
 * @note A radian is about 57 degrees, and a full 360-degree rotation is 2*pi radians.
 * @see https://developer.android.com/reference/android/hardware/SensorEvent#sensor.type_gyroscope
 * for guidance on using this value to derive a device's orientation.
 */
#define RETRO_SENSOR_GYROSCOPE_X 3

/**
 * Returns the angular velocity of the device around its local Z axis, in radians per second.
 *
 * Positive values indicate counter-clockwise rotation.
 *
 * @note A radian is about 57 degrees, and a full 360-degree rotation is 2*pi radians.
 * @see https://developer.android.com/reference/android/hardware/SensorEvent#sensor.type_gyroscope
 * for guidance on using this value to derive a device's orientation.
 */
#define RETRO_SENSOR_GYROSCOPE_Y 4

/**
 * Returns the angular velocity of the device around its local Z axis, in radians per second.
 *
 * Positive values indicate counter-clockwise rotation.
 *
 * @note A radian is about 57 degrees, and a full 360-degree rotation is 2*pi radians.
 * @see https://developer.android.com/reference/android/hardware/SensorEvent#sensor.type_gyroscope
 * for guidance on using this value to derive a device's orientation.
 */
#define RETRO_SENSOR_GYROSCOPE_Z 5

/**
 * Returns the ambient illuminance (light intensity) of the device's environment, in lux.
 *
 * @see https://en.wikipedia.org/wiki/Lux for a table of common lux values.
 */
#define RETRO_SENSOR_ILLUMINANCE 6
/** @} */

/**
 * Adjusts the state of a sensor.
 *
 * @param port The device port of the controller that owns the sensor given in \c action.
 * @param action The action to perform on the sensor.
 * Different devices support different sensors.
 * @param rate The rate at which the underlying sensor should be updated, in Hz.
 * This should be treated as a hint,
 * as some device sensors may not support the requested rate
 * (if it's configurable at all).
 * @returns \c true if the sensor state was successfully adjusted, \c false otherwise.
 * @note If one of the \c RETRO_SENSOR_*_ENABLE actions fails,
 * this likely means that the given sensor is not available
 * on the provided \c port.
 * @see retro_sensor_action
 */
typedef bool (RETRO_CALLCONV *retro_set_sensor_state_t)(unsigned port,
      enum retro_sensor_action action, unsigned rate);

/**
 * Retrieves the current value reported by sensor.
 * @param port The device port of the controller that owns the sensor given in \c id.
 * @param id The sensor value to query.
 * @returns The current sensor value.
 * Exact semantics depend on the value given in \c id,
 * but will return 0 for invalid arguments.
 *
 * @see RETRO_SENSOR_ID
 */
typedef float (RETRO_CALLCONV *retro_sensor_get_input_t)(unsigned port, unsigned id);

/**
 * An interface that cores can use to access device sensors.
 *
 * All function pointers are set by the frontend.
 */
struct retro_sensor_interface
{
   /** @copydoc retro_set_sensor_state_t */
   retro_set_sensor_state_t set_sensor_state;

   /** @copydoc retro_sensor_get_input_t */
   retro_sensor_get_input_t get_sensor_input;
};

/** @} */

/** @defgroup GET_CAMERA_INTERFACE Camera Interface
 * @{
 */

/**
 * Denotes the type of buffer in which the camera will store its input.
 *
 * Different camera drivers may support different buffer types.
 *
 * @see RETRO_ENVIRONMENT_GET_CAMERA_INTERFACE
 * @see retro_camera_callback
 */
enum retro_camera_buffer
{
   /**
    * Indicates that camera frames should be delivered to the core as an OpenGL texture.
    *
    * Requires that the core is using an OpenGL context via \c RETRO_ENVIRONMENT_SET_HW_RENDER.
    *
    * @see retro_camera_frame_opengl_texture_t
    */
   RETRO_CAMERA_BUFFER_OPENGL_TEXTURE = 0,

   /**
    * Indicates that camera frames should be delivered to the core as a raw buffer in memory.
    *
    * @see retro_camera_frame_raw_framebuffer_t
    */
   RETRO_CAMERA_BUFFER_RAW_FRAMEBUFFER,

   /**
    * @private Defined to ensure <tt>sizeof(enum retro_camera_buffer) == sizeof(int)</tt>.
    * Do not use.
    */
   RETRO_CAMERA_BUFFER_DUMMY = INT_MAX
};

/**
 * Starts an initialized camera.
 * The camera is disabled by default,
 * and must be enabled with this function before being used.
 *
 * Set by the frontend.
 *
 * @returns \c true if the camera was successfully started, \c false otherwise.
 * Failure may occur if no actual camera is available,
 * or if the frontend doesn't have permission to access it.
 * @note Must be called in \c retro_run().
 * @see retro_camera_callback
 */
typedef bool (RETRO_CALLCONV *retro_camera_start_t)(void);

/**
 * Stops the running camera.
 *
 * Set by the frontend.
 *
 * @note Must be called in \c retro_run().
 * @warning The frontend may close the camera on its own when unloading the core,
 * but this behavior is not guaranteed.
 * Cores should clean up the camera before exiting.
 * @see retro_camera_callback
 */
typedef void (RETRO_CALLCONV *retro_camera_stop_t)(void);

/**
 * Called by the frontend to report the state of the camera driver.
 *
 * @see retro_camera_callback
 */
typedef void (RETRO_CALLCONV *retro_camera_lifetime_status_t)(void);

/**
 * Called by the frontend to report a new camera frame,
 * delivered as a raw buffer in memory.
 *
 * Set by the core.
 *
 * @param buffer Pointer to the camera's most recent video frame.
 * Each pixel is in XRGB8888 format.
 * The first pixel represents the top-left corner of the image
 * (i.e. the Y axis goes downward).
 * @param width The width of the frame given in \c buffer, in pixels.
 * @param height The height of the frame given in \c buffer, in pixels.
 * @param pitch The width of the frame given in \c buffer, in bytes.
 * @warning \c buffer may be invalidated when this function returns,
 * so the core should make its own copy of \c buffer if necessary.
 * @see RETRO_CAMERA_BUFFER_RAW_FRAMEBUFFER
 */
typedef void (RETRO_CALLCONV *retro_camera_frame_raw_framebuffer_t)(const uint32_t *buffer,
      unsigned width, unsigned height, size_t pitch);

/**
 * Called by the frontend to report a new camera frame,
 * delivered as an OpenGL texture.
 *
 * @param texture_id The ID of the OpenGL texture that represents the camera's most recent frame.
 * Owned by the frontend, and must not be modified by the core.
 * @param texture_target The type of the texture given in \c texture_id.
 * Usually either \c GL_TEXTURE_2D or \c GL_TEXTURE_RECTANGLE,
 * but other types are allowed.
 * @param affine A pointer to a 3x3 column-major affine matrix
 * that can be used to transform pixel coordinates to texture coordinates.
 * After transformation, the bottom-left corner should have coordinates of <tt>(0, 0)</tt>
 * and the top-right corner should have coordinates of <tt>(1, 1)</tt>
 * (or <tt>(width, height)</tt> for \c GL_TEXTURE_RECTANGLE).
 *
 * @note GL-specific typedefs (e.g. \c GLfloat and \c GLuint) are avoided here
 * so that the API doesn't rely on gl.h.
 * @warning \c texture_id and \c affine may be invalidated when this function returns,
 * so the core should make its own copy of them if necessary.
 */
typedef void (RETRO_CALLCONV *retro_camera_frame_opengl_texture_t)(unsigned texture_id,
      unsigned texture_target, const float *affine);

/**
 * An interface that the core can use to access a device's camera.
 *
 * @see RETRO_ENVIRONMENT_GET_CAMERA_INTERFACE
 */
struct retro_camera_callback
{
   /**
    * Requested camera capabilities,
    * given as a bitmask of \c retro_camera_buffer values.
    * Set by the core.
    *
    * Here's a usage example:
    * @code
    * // Requesting support for camera data delivered as both an OpenGL texture and a pixel buffer:
    * struct retro_camera_callback callback;
    * callback.caps = (1 << RETRO_CAMERA_BUFFER_OPENGL_TEXTURE) | (1 << RETRO_CAMERA_BUFFER_RAW_FRAMEBUFFER);
    * @endcode
    */
   uint64_t caps;

   /**
    * The desired width of the camera frame, in pixels.
    * This is only a hint; the frontend may provide a different size.
    * Set by the core.
    * Use zero to let the frontend decide.
    */
   unsigned width;

   /**
    * The desired height of the camera frame, in pixels.
    * This is only a hint; the frontend may provide a different size.
     * Set by the core.
    * Use zero to let the frontend decide.
    */
   unsigned height;

   /**
    * @copydoc retro_camera_start_t
    * @see retro_camera_callback
    */
   retro_camera_start_t start;

   /**
    * @copydoc retro_camera_stop_t
    * @see retro_camera_callback
    */
   retro_camera_stop_t stop;

   /**
    * @copydoc retro_camera_frame_raw_framebuffer_t
    * @note If \c NULL, this function will not be called.
    */
   retro_camera_frame_raw_framebuffer_t frame_raw_framebuffer;

   /**
    * @copydoc retro_camera_frame_opengl_texture_t
    * @note If \c NULL, this function will not be called.
    */
   retro_camera_frame_opengl_texture_t frame_opengl_texture;

   /**
    * Core-defined callback invoked by the frontend right after the camera driver is initialized
    * (\em not when calling \c start).
    * May be \c NULL, in which case this function is skipped.
    */
   retro_camera_lifetime_status_t initialized;

   /**
    * Core-defined callback invoked by the frontend
    * right before the video camera driver is deinitialized
    * (\em not when calling \c stop).
    * May be \c NULL, in which case this function is skipped.
    */
   retro_camera_lifetime_status_t deinitialized;
};

/** @} */

/** @defgroup GET_LOCATION_INTERFACE Location Interface
 * @{
 */

/** @copydoc retro_location_callback::set_interval */
typedef void (RETRO_CALLCONV *retro_location_set_interval_t)(unsigned interval_ms,
      unsigned interval_distance);

/** @copydoc retro_location_callback::start */
typedef bool (RETRO_CALLCONV *retro_location_start_t)(void);

/** @copydoc retro_location_callback::stop */
typedef void (RETRO_CALLCONV *retro_location_stop_t)(void);

/** @copydoc retro_location_callback::get_position */
typedef bool (RETRO_CALLCONV *retro_location_get_position_t)(double *lat, double *lon,
      double *horiz_accuracy, double *vert_accuracy);

/** Function type that reports the status of the location service. */
typedef void (RETRO_CALLCONV *retro_location_lifetime_status_t)(void);

/**
 * An interface that the core can use to access a device's location.
 *
 * @note It is the frontend's responsibility to request the necessary permissions
 * from the operating system.
 * @see RETRO_ENVIRONMENT_GET_LOCATION_INTERFACE
 */
struct retro_location_callback
{
   /**
    * Starts listening the device's location service.
    *
    * The frontend will report changes to the device's location
    * at the interval defined by \c set_interval.
    * Set by the frontend.
    *
    * @return true if location services were successfully started, false otherwise.
    * Note that this will return \c false if location services are disabled
    * or the frontend doesn't have permission to use them.
    * @note The device's location service may or may not have been enabled
    * before the core calls this function.
    */
   retro_location_start_t         start;

   /**
    * Stop listening to the device's location service.
    *
    * Set by the frontend.
    *
    * @note The location service itself may or may not
    * be turned off by this function,
    * depending on the platform and the frontend.
    * @post The core will stop receiving location service updates.
    */
   retro_location_stop_t          stop;

   /**
    * Returns the device's current coordinates.
    *
    * Set by the frontend.
    *
    * @param[out] lat Pointer to latitude, in degrees.
    * Will be set to 0 if no change has occurred since the last call.
    * Behavior is undefined if \c NULL.
    * @param[out] lon Pointer to longitude, in degrees.
    * Will be set to 0 if no change has occurred since the last call.
    * Behavior is undefined if \c NULL.
    * @param[out] horiz_accuracy Pointer to horizontal accuracy.
    * Will be set to 0 if no change has occurred since the last call.
    * Behavior is undefined if \c NULL.
    * @param[out] vert_accuracy Pointer to vertical accuracy.
    * Will be set to 0 if no change has occurred since the last call.
    * Behavior is undefined if \c NULL.
    */
   retro_location_get_position_t  get_position;

   /**
    * Sets the rate at which the location service should report updates.
    *
    * This is only a hint; the actual rate may differ.
    * Sets the interval of time and/or distance at which to update/poll
    * location-based data.
    *
    * Some platforms may only support one of the two parameters;
    * cores should provide both to ensure compatibility.
    *
    * Set by the frontend.
    *
    * @param interval_ms The desired period of time between location updates, in milliseconds.
    * @param interval_distance The desired distance between location updates, in meters.
    */
   retro_location_set_interval_t  set_interval;

   /** Called when the location service is initialized. Set by the core. Optional. */
   retro_location_lifetime_status_t initialized;

   /** Called when the location service is deinitialized. Set by the core. Optional. */
   retro_location_lifetime_status_t deinitialized;
};

/** @} */

/** @addtogroup GET_RUMBLE_INTERFACE
 * @{ */

/**
 * The type of rumble motor in a controller.
 *
 * Both motors can be controlled independently,
 * and the strong motor does not override the weak motor.
 * @see RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE
 */
enum retro_rumble_effect
{
   RETRO_RUMBLE_STRONG = 0,
   RETRO_RUMBLE_WEAK = 1,

   /** @private Defined to ensure <tt>sizeof(enum retro_rumble_effect) == sizeof(int)</tt>. Do not use. */
   RETRO_RUMBLE_DUMMY = INT_MAX
};

/**
 * Requests a rumble state change for a controller.
 * Set by the frontend.
 *
 * @param port The controller port to set the rumble state for.
 * @param effect The rumble motor to set the strength of.
 * @param strength The desired intensity of the rumble motor, ranging from \c 0 to \c 0xffff (inclusive).
 * @return \c true if the requested rumble state was honored.
 * If the controller doesn't support rumble, will return \c false.
 * @note Calling this before the first \c retro_run() may return \c false.
 * @see RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE
 */
typedef bool (RETRO_CALLCONV *retro_set_rumble_state_t)(unsigned port,
      enum retro_rumble_effect effect, uint16_t strength);

/**
 * An interface that the core can use to set the rumble state of a controller.
 * @see RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE
 */
struct retro_rumble_interface
{
   /** @copydoc retro_set_rumble_state_t */
   retro_set_rumble_state_t set_rumble_state;
};

/** @} */

/**
 * Called by the frontend to request audio samples.
 * The core should render audio within this function
 * using the callback provided by \c retro_set_audio_sample or \c retro_set_audio_sample_batch.
 *
 * @warning This function may be called by any thread,
 * therefore it must be thread-safe.
 * @see RETRO_ENVIRONMENT_SET_AUDIO_CALLBACK
 * @see retro_audio_callback
 * @see retro_audio_sample_batch_t
 * @see retro_audio_sample_t
 */
typedef void (RETRO_CALLCONV *retro_audio_callback_t)(void);

/**
 * Called by the frontend to notify the core that it should pause or resume audio rendering.
 * The initial state of the audio driver after registering this callback is \c false (inactive).
 *
 * @param enabled \c true if the frontend's audio driver is active.
 * If so, the registered audio callback will be called regularly.
 * If not, the audio callback will not be invoked until the next time
 * the frontend calls this function with \c true.
 * @warning This function may be called by any thread,
 * therefore it must be thread-safe.
 * @note Even if no audio samples are rendered,
 * the core should continue to update its emulated platform's audio engine if necessary.
 * @see RETRO_ENVIRONMENT_SET_AUDIO_CALLBACK
 * @see retro_audio_callback
 * @see retro_audio_callback_t
 */
typedef void (RETRO_CALLCONV *retro_audio_set_state_callback_t)(bool enabled);

/**
 * An interface that the frontend uses to request audio samples from the core.
 * @note To unregister a callback, pass a \c retro_audio_callback_t
 * with both fields set to <tt>NULL</tt>.
 * @see RETRO_ENVIRONMENT_SET_AUDIO_CALLBACK
 */
struct retro_audio_callback
{
   /** @see retro_audio_callback_t */
   retro_audio_callback_t callback;

   /** @see retro_audio_set_state_callback_t */
   retro_audio_set_state_callback_t set_state;
};

typedef int64_t retro_usec_t;

/**
 * Called right before each iteration of \c retro_run
 * if registered via <tt>RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK</tt>.
 *
 * @param usec Time since the last call to <tt>retro_run</tt>, in microseconds.
 * If the frontend is manipulating the frame time
 * (e.g. via fast-forward or slow motion),
 * this value will be the reference value initially provided to the environment call.
 * @see RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK
 * @see retro_frame_time_callback
 */
typedef void (RETRO_CALLCONV *retro_frame_time_callback_t)(retro_usec_t usec);

/**
 * @see RETRO_ENVIRONMENT_SET_FRAME_TIME_CALLBACK
 */
struct retro_frame_time_callback
{
   /**
    * Called to notify the core of the current frame time.
    * If <tt>NULL</tt>, the frontend will clear its registered callback.
    */
   retro_frame_time_callback_t callback;

   /**
    * The ideal duration of one frame, in microseconds.
    * Compute it as <tt>1000000 / fps</tt>.
    * The frontend will resolve rounding to ensure that framestepping, etc is exact.
    */
   retro_usec_t reference;
};

/** @defgroup SET_AUDIO_BUFFER_STATUS_CALLBACK Audio Buffer Occupancy
 * @{
 */

/**
 * Notifies a libretro core of how full the frontend's audio buffer is.
 * Set by the core, called by the frontend.
 * It will be called right before \c retro_run() every frame.
 *
 * @param active \c true if the frontend's audio buffer is currently in use,
 * \c false if audio is disabled in the frontend.
 * @param occupancy A value between 0 and 100 (inclusive),
 * corresponding to the frontend's audio buffer occupancy percentage.
 * @param underrun_likely \c true if the frontend expects an audio buffer underrun
 * during the next frame, which indicates that a core should attempt frame-skipping.
 */
typedef void (RETRO_CALLCONV *retro_audio_buffer_status_callback_t)(
      bool active, unsigned occupancy, bool underrun_likely);

/**
 * A callback to register with the frontend to receive audio buffer occupancy information.
 */
struct retro_audio_buffer_status_callback
{
   /** @copydoc retro_audio_buffer_status_callback_t */
   retro_audio_buffer_status_callback_t callback;
};

/** @} */

/* Pass this to retro_video_refresh_t if rendering to hardware.
 * Passing NULL to retro_video_refresh_t is still a frame dupe as normal.
 * */
#define RETRO_HW_FRAME_BUFFER_VALID ((void*)-1)

/* Invalidates the current HW context.
 * Any GL state is lost, and must not be deinitialized explicitly.
 * If explicit deinitialization is desired by the libretro core,
 * it should implement context_destroy callback.
 * If called, all GPU resources must be reinitialized.
 * Usually called when frontend reinits video driver.
 * Also called first time video driver is initialized,
 * allowing libretro core to initialize resources.
 */
typedef void (RETRO_CALLCONV *retro_hw_context_reset_t)(void);

/* Gets current framebuffer which is to be rendered to.
 * Could change every frame potentially.
 */
typedef uintptr_t (RETRO_CALLCONV *retro_hw_get_current_framebuffer_t)(void);

/* Get a symbol from HW context. */
typedef retro_proc_address_t (RETRO_CALLCONV *retro_hw_get_proc_address_t)(const char *sym);

enum retro_hw_context_type
{
   RETRO_HW_CONTEXT_NONE             = 0,
   /* OpenGL 2.x. Driver can choose to use latest compatibility context. */
   RETRO_HW_CONTEXT_OPENGL           = 1,
   /* OpenGL ES 2.0. */
   RETRO_HW_CONTEXT_OPENGLES2        = 2,
   /* Modern desktop core GL context. Use version_major/
    * version_minor fields to set GL version. */
   RETRO_HW_CONTEXT_OPENGL_CORE      = 3,
   /* OpenGL ES 3.0 */
   RETRO_HW_CONTEXT_OPENGLES3        = 4,
   /* OpenGL ES 3.1+. Set version_major/version_minor. For GLES2 and GLES3,
    * use the corresponding enums directly. */
   RETRO_HW_CONTEXT_OPENGLES_VERSION = 5,

   /* Vulkan, see RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE. */
   RETRO_HW_CONTEXT_VULKAN           = 6,

   /* Direct3D11, see RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE */
   RETRO_HW_CONTEXT_D3D11            = 7,

   /* Direct3D10, see RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE */
   RETRO_HW_CONTEXT_D3D10            = 8,

   /* Direct3D12, see RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE */
   RETRO_HW_CONTEXT_D3D12            = 9,

   /* Direct3D9, see RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE */
   RETRO_HW_CONTEXT_D3D9             = 10,

   /** Dummy value to ensure sizeof(enum retro_hw_context_type) == sizeof(int). Do not use. */
   RETRO_HW_CONTEXT_DUMMY = INT_MAX
};

struct retro_hw_render_callback
{
   /* Which API to use. Set by libretro core. */
   enum retro_hw_context_type context_type;

   /* Called when a context has been created or when it has been reset.
    * An OpenGL context is only valid after context_reset() has been called.
    *
    * When context_reset is called, OpenGL resources in the libretro
    * implementation are guaranteed to be invalid.
    *
    * It is possible that context_reset is called multiple times during an
    * application lifecycle.
    * If context_reset is called without any notification (context_destroy),
    * the OpenGL context was lost and resources should just be recreated
    * without any attempt to "free" old resources.
    */
   retro_hw_context_reset_t context_reset;

   /* Set by frontend.
    * TODO: This is rather obsolete. The frontend should not
    * be providing preallocated framebuffers. */
   retro_hw_get_current_framebuffer_t get_current_framebuffer;

   /* Set by frontend.
    * Can return all relevant functions, including glClear on Windows. */
   retro_hw_get_proc_address_t get_proc_address;

   /* Set if render buffers should have depth component attached.
    * TODO: Obsolete. */
   bool depth;

   /* Set if stencil buffers should be attached.
    * TODO: Obsolete. */
   bool stencil;

   /* If depth and stencil are true, a packed 24/8 buffer will be added.
    * Only attaching stencil is invalid and will be ignored. */

   /* Use conventional bottom-left origin convention. If false,
    * standard libretro top-left origin semantics are used.
    * TODO: Move to GL specific interface. */
   bool bottom_left_origin;

   /* Major version number for core GL context or GLES 3.1+. */
   unsigned version_major;

   /* Minor version number for core GL context or GLES 3.1+. */
   unsigned version_minor;

   /* If this is true, the frontend will go very far to avoid
    * resetting context in scenarios like toggling fullscreen, etc.
    * TODO: Obsolete? Maybe frontend should just always assume this ...
    */
   bool cache_context;

   /* The reset callback might still be called in extreme situations
    * such as if the context is lost beyond recovery.
    *
    * For optimal stability, set this to false, and allow context to be
    * reset at any time.
    */

   /* A callback to be called before the context is destroyed in a
    * controlled way by the frontend. */
   retro_hw_context_reset_t context_destroy;

   /* OpenGL resources can be deinitialized cleanly at this step.
    * context_destroy can be set to NULL, in which resources will
    * just be destroyed without any notification.
    *
    * Even when context_destroy is non-NULL, it is possible that
    * context_reset is called without any destroy notification.
    * This happens if context is lost by external factors (such as
    * notified by GL_ARB_robustness).
    *
    * In this case, the context is assumed to be already dead,
    * and the libretro implementation must not try to free any OpenGL
    * resources in the subsequent context_reset.
    */

   /* Creates a debug context. */
   bool debug_context;
};

/* Callback type passed in RETRO_ENVIRONMENT_SET_KEYBOARD_CALLBACK.
 * Called by the frontend in response to keyboard events.
 * down is set if the key is being pressed, or false if it is being released.
 * keycode is the RETROK value of the char.
 * character is the text character of the pressed key. (UTF-32).
 * key_modifiers is a set of RETROKMOD values or'ed together.
 *
 * The pressed/keycode state can be independent of the character.
 * It is also possible that multiple characters are generated from a
 * single keypress.
 * Keycode events should be treated separately from character events.
 * However, when possible, the frontend should try to synchronize these.
 * If only a character is posted, keycode should be RETROK_UNKNOWN.
 *
 * Similarly if only a keycode event is generated with no corresponding
 * character, character should be 0.
 */
typedef void (RETRO_CALLCONV *retro_keyboard_event_t)(bool down, unsigned keycode,
      uint32_t character, uint16_t key_modifiers);

struct retro_keyboard_callback
{
   retro_keyboard_event_t callback;
};

/** @defgroup SET_DISK_CONTROL_INTERFACE Disk Control
 *
 * Callbacks for inserting and removing disks from the emulated console at runtime.
 * Should be provided by cores that support doing so.
 * Cores should automate this process if possible,
 * but some cases require the player's manual input.
 *
 * The steps for swapping disk images are generally as follows:
 *
 * \li Eject the emulated console's disk drive with \c set_eject_state(true).
 * \li Insert the new disk image with \c set_image_index(index).
 * \li Close the virtual disk tray with \c set_eject_state(false).
 *
 * @{
 */

/**
 * Called by the frontend to open or close the emulated console's virtual disk tray.
 *
 * The frontend may only set the disk image index
 * while the emulated tray is opened.
 *
 * If the emulated console's disk tray is already in the state given by \c ejected,
 * then this function should return \c true without doing anything.
 * The core should return \c false if it couldn't change the disk tray's state;
 * this may happen if the console itself limits when the disk tray can be open or closed
 * (e.g. to wait for the disc to stop spinning).
 *
 * @param ejected \c true if the virtual disk tray should be "ejected",
 * \c false if it should be "closed".
 * @return \c true if the virtual disk tray's state has been set to the given state,
 * false if there was an error.
 * @see retro_get_eject_state_t
 */
typedef bool (RETRO_CALLCONV *retro_set_eject_state_t)(bool ejected);

/**
 * Gets the current ejected state of the disk drive.
 * The initial state is closed, i.e. \c false.
 *
 * @return \c true if the virtual disk tray is "ejected",
 * i.e. it's open and a disk can be inserted.
 * @see retro_set_eject_state_t
 */
typedef bool (RETRO_CALLCONV *retro_get_eject_state_t)(void);

/**
 * Gets the index of the current disk image,
 * as determined by however the frontend orders disk images
 * (such as m3u-formatted playlists or special directories).
 *
 * @return The index of the current disk image
 * (starting with 0 for the first disk),
 * or a value greater than or equal to \c get_num_images() if no disk is inserted.
 * @see retro_get_num_images_t
 */
typedef unsigned (RETRO_CALLCONV *retro_get_image_index_t)(void);

/**
 * Inserts the disk image at the given index into the emulated console's drive.
 * Can only be called while the disk tray is ejected
 * (i.e. \c retro_get_eject_state_t returns \c true).
 *
 * If the emulated disk tray is ejected
 * and already contains the disk image named by \c index,
 * then this function should do nothing and return \c true.
 *
 * @param index The index of the disk image to insert,
 * starting from 0 for the first disk.
 * A value greater than or equal to \c get_num_images()
 * represents the frontend removing the disk without inserting a new one.
 * @return \c true if the disk image was successfully set.
 * \c false if the disk tray isn't ejected or there was another error
 * inserting a new disk image.
 */
typedef bool (RETRO_CALLCONV *retro_set_image_index_t)(unsigned index);

/**
 * @return The number of disk images which are available to use.
 * These are most likely defined in a playlist file.
 */
typedef unsigned (RETRO_CALLCONV *retro_get_num_images_t)(void);

struct retro_game_info;

/**
 * Replaces the disk image at the given index with a new disk.
 *
 * Replaces the disk image associated with index.
 * Arguments to pass in info have same requirements as retro_load_game().
 * Virtual disk tray must be ejected when calling this.
 *
 * Passing \c NULL to this function indicates
 * that the frontend has removed this disk image from its internal list.
 * As a result, calls to this function can change the number of available disk indexes.
 *
 * For example, calling <tt>replace_image_index(1, NULL)</tt>
 * will remove the disk image at index 1,
 * and the disk image at index 2 (if any)
 * will be moved to the newly-available index 1.
 *
 * @param index The index of the disk image to replace.
 * @param info Details about the new disk image,
 * or \c NULL if the disk image at the given index should be discarded.
 * The semantics of each field are the same as in \c retro_load_game.
 * @return \c true if the disk image was successfully replaced
 * or removed from the playlist,
 * \c false if the tray is not ejected
 * or if there was an error.
 */
typedef bool (RETRO_CALLCONV *retro_replace_image_index_t)(unsigned index,
      const struct retro_game_info *info);

/**
 * Adds a new index to the core's internal disk list.
 * This will increment the return value from \c get_num_images() by 1.
 * This image index cannot be used until a disk image has been set
 * with \c replace_image_index.
 *
 * @return \c true if the core has added space for a new disk image
 * and is ready to receive one.
 */
typedef bool (RETRO_CALLCONV *retro_add_image_index_t)(void);

/**
 * Sets the disk image that will be inserted into the emulated disk drive
 * before \c retro_load_game is called.
 *
 * \c retro_load_game does not provide a way to ensure
 * that a particular disk image in a playlist is inserted into the console;
 * this function makes up for that.
 * Frontends should call it immediately before \c retro_load_game,
 * and the core should use the arguments
 * to validate the disk image in \c retro_load_game.
 *
 * When content is loaded, the core should verify that the
 * disk specified by \c index can be found at \c path.
 * This is to guard against auto-selecting the wrong image
 * if (for example) the user should modify an existing M3U playlist.
 * We have to let the core handle this because
 * \c set_initial_image() must be called before loading content,
 * i.e. the frontend cannot access image paths in advance
 * and thus cannot perform the error check itself.
 * If \c index is invalid (i.e. <tt>index >= get_num_images()</tt>)
 * or the disk image doesn't match the value given in \c path,
 * the core should ignore the arguments
 * and insert the disk at index 0 into the virtual disk tray.
 *
 * @warning If \c RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE is called within \c retro_load_game,
 * then this function may not be executed.
 * Set the disk control interface in \c retro_init if possible.
 *
 * @param index The index of the disk image within the playlist to set.
 * @param path The path of the disk image to set as the first.
 * The core should not load this path immediately;
 * instead, it should use it within \c retro_load_game
 * to verify that the correct disk image was loaded.
 * @return \c true if the initial disk index was set,
 * \c false if the arguments are invalid
 * or the core doesn't support this function.
 */
typedef bool (RETRO_CALLCONV *retro_set_initial_image_t)(unsigned index, const char *path);

/**
 * Returns the path of the disk image at the given index
 * on the host's file system.
 *
 * @param index The index of the disk image to get the path of.
 * @param s A buffer to store the path in.
 * @param len The size of \c s, in bytes.
 * @return \c true if the disk image's location was successfully
 * queried and copied into \c s,
 * \c false if the index is invalid
 * or the core couldn't locate the disk image.
 */
typedef bool (RETRO_CALLCONV *retro_get_image_path_t)(unsigned index, char *s, size_t len);

/**
 * Returns a friendly label for the given disk image.
 *
 * In the simplest case, this may be the disk image's file name
 * with the extension omitted.
 * For cores or games with more complex content requirements,
 * the label can be used to provide information to help the player
 * select a disk image to insert;
 * for example, a core may label different kinds of disks
 * (save data, level disk, installation disk, bonus content, etc.).
 * with names that correspond to in-game prompts,
 * so that the frontend can provide better guidance to the player.
 *
 * @param index The index of the disk image to return a label for.
 * @param s A buffer to store the resulting label in.
 * @param len The length of \c s, in bytes.
 * @return \c true if the disk image at \c index is valid
 * and a label was copied into \c s.
 */
typedef bool (RETRO_CALLCONV *retro_get_image_label_t)(unsigned index, char *s, size_t len);

/**
 * An interface that the frontend can use to exchange disks
 * within the emulated console's disk drive.
 *
 * All function pointers are required.
 *
 * @deprecated This struct is superseded by \ref retro_disk_control_ext_callback.
 * Only use this one to maintain compatibility
 * with older cores and frontends.
 *
 * @see RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE
 * @see retro_disk_control_ext_callback
 */
struct retro_disk_control_callback
{
   /** @copydoc retro_set_eject_state_t */
   retro_set_eject_state_t set_eject_state;

   /** @copydoc retro_get_eject_state_t */
   retro_get_eject_state_t get_eject_state;

   /** @copydoc retro_get_image_index_t */
   retro_get_image_index_t get_image_index;

   /** @copydoc retro_set_image_index_t */
   retro_set_image_index_t set_image_index;

   /** @copydoc retro_get_num_images_t */
   retro_get_num_images_t  get_num_images;

   /** @copydoc retro_replace_image_index_t */
   retro_replace_image_index_t replace_image_index;

   /** @copydoc retro_add_image_index_t */
   retro_add_image_index_t add_image_index;
};

/**
 * @copybrief retro_disk_control_callback
 *
 * All function pointers are required unless otherwise noted.
 *
 * @see RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE
 */
struct retro_disk_control_ext_callback
{
   /** @copydoc retro_set_eject_state_t */
   retro_set_eject_state_t set_eject_state;

   /** @copydoc retro_get_eject_state_t */
   retro_get_eject_state_t get_eject_state;

   /** @copydoc retro_get_image_index_t */
   retro_get_image_index_t get_image_index;

   /** @copydoc retro_set_image_index_t */
   retro_set_image_index_t set_image_index;

   /** @copydoc retro_get_num_images_t */
   retro_get_num_images_t  get_num_images;

   /** @copydoc retro_replace_image_index_t */
   retro_replace_image_index_t replace_image_index;

   /** @copydoc retro_add_image_index_t */
   retro_add_image_index_t add_image_index;

   /** @copydoc retro_set_initial_image_t
    *
    * Optional; not called if \c NULL.
    *
    * @note The frontend will only try to record/restore the last-used disk index
    * if both \c set_initial_image and \c get_image_path are implemented.
    */
   retro_set_initial_image_t set_initial_image;

   /**
    * @copydoc retro_get_image_path_t
    *
    * Optional; not called if \c NULL.
    */
   retro_get_image_path_t get_image_path;

   /**
    * @copydoc retro_get_image_label_t
    *
    * Optional; not called if \c NULL.
    */
   retro_get_image_label_t get_image_label;
};

/** @} */

/* Definitions for RETRO_ENVIRONMENT_SET_NETPACKET_INTERFACE.
 * A core can set it if sending and receiving custom network packets
 * during a multiplayer session is desired.
 */

/* Netpacket flags for retro_netpacket_send_t */
#define RETRO_NETPACKET_UNRELIABLE  0        /* Packet to be sent unreliable, depending on network quality it might not arrive. */
#define RETRO_NETPACKET_RELIABLE    (1 << 0) /* Reliable packets are guaranteed to arrive at the target in the order they were sent. */
#define RETRO_NETPACKET_UNSEQUENCED (1 << 1) /* Packet will not be sequenced with other packets and may arrive out of order. Cannot be set on reliable packets. */
#define RETRO_NETPACKET_FLUSH_HINT  (1 << 2) /* Request the packet and any previously buffered ones to be sent immediately */

/* Broadcast client_id for retro_netpacket_send_t */
#define RETRO_NETPACKET_BROADCAST 0xFFFF

/* Used by the core to send a packet to one or all connected players.
 * A single packet sent via this interface can contain up to 64 KB of data.
 *
 * The client_id RETRO_NETPACKET_BROADCAST sends the packet as a broadcast to
 * all connected players. This is supported from the host as well as clients.
*  Otherwise, the argument indicates the player to send the packet to.
 *
 * A frontend must support sending reliable packets (RETRO_NETPACKET_RELIABLE).
 * Unreliable packets might not be supported by the frontend, but the flags can
 * still be specified. Reliable transmission will be used instead.
 *
 * Calling this with the flag RETRO_NETPACKET_FLUSH_HINT will send off the
 * packet and any previously buffered ones immediately and without blocking.
 * To only flush previously queued packets, buf or len can be passed as NULL/0.
 *
 * This function is not guaranteed to be thread-safe and must be called during
 * retro_run or any of the netpacket callbacks passed with this interface.
 */
typedef void (RETRO_CALLCONV *retro_netpacket_send_t)(int flags, const void* buf, size_t len, uint16_t client_id);

/* Optionally read any incoming packets without waiting for the end of the
 * frame. While polling, retro_netpacket_receive_t and retro_netpacket_stop_t
 * can be called. The core can perform this in a loop to do a blocking read,
 * i.e., wait for incoming data, but needs to handle stop getting called and
 * also give up after a short while to avoid freezing on a connection problem.
 * It is a good idea to manually flush outgoing packets before calling this.
 *
 * This function is not guaranteed to be thread-safe and must be called during
 * retro_run or any of the netpacket callbacks passed with this interface.
 */
typedef void (RETRO_CALLCONV *retro_netpacket_poll_receive_t)(void);

/* Called by the frontend to signify that a multiplayer session has started.
 * If client_id is 0 the local player is the host of the session and at this
 * point no other player has connected yet.
 *
 * If client_id is > 0 the local player is a client connected to a host and
 * at this point is already fully connected to the host.
 *
 * The core must store the function pointer send_fn and use it whenever it
 * wants to send a packet. Optionally poll_receive_fn can be stored and used
 * when regular receiving between frames is not enough. These function pointers
 * remain valid until the frontend calls retro_netpacket_stop_t.
 */
typedef void (RETRO_CALLCONV *retro_netpacket_start_t)(uint16_t client_id, retro_netpacket_send_t send_fn, retro_netpacket_poll_receive_t poll_receive_fn);

/* Called by the frontend when a new packet arrives which has been sent from
 * another player with retro_netpacket_send_t. The client_id argument indicates
 * who has sent the packet.
 */
typedef void (RETRO_CALLCONV *retro_netpacket_receive_t)(const void* buf, size_t len, uint16_t client_id);

/* Called by the frontend when the multiplayer session has ended.
 * Once this gets called the function pointers passed to
 * retro_netpacket_start_t will not be valid anymore.
 */
typedef void (RETRO_CALLCONV *retro_netpacket_stop_t)(void);

/* Called by the frontend every frame (between calls to retro_run while
 * updating the state of the multiplayer session.
 * This is a good place for the core to call retro_netpacket_send_t from.
 */
typedef void (RETRO_CALLCONV *retro_netpacket_poll_t)(void);

/* Called by the frontend when a new player connects to the hosted session.
 * This is only called on the host side, not for clients connected to the host.
 * If this function returns false, the newly connected player gets dropped.
 * This can be used for example to limit the number of players.
 */
typedef bool (RETRO_CALLCONV *retro_netpacket_connected_t)(uint16_t client_id);

/* Called by the frontend when a player leaves or disconnects from the hosted session.
 * This is only called on the host side, not for clients connected to the host.
 */
typedef void (RETRO_CALLCONV *retro_netpacket_disconnected_t)(uint16_t client_id);

/**
 * A callback interface for giving a core the ability to send and receive custom
 * network packets during a multiplayer session between two or more instances
 * of a libretro frontend.
 *
 * Normally during connection handshake the frontend will compare library_version
 * used by both parties and show a warning if there is a difference. When the core
 * supplies protocol_version, the frontend will check against this instead.
 *
 * @see RETRO_ENVIRONMENT_SET_NETPACKET_INTERFACE
 */
struct retro_netpacket_callback
{
   retro_netpacket_start_t        start;
   retro_netpacket_receive_t      receive;
   retro_netpacket_stop_t         stop;         /* Optional - may be NULL */
   retro_netpacket_poll_t         poll;         /* Optional - may be NULL */
   retro_netpacket_connected_t    connected;    /* Optional - may be NULL */
   retro_netpacket_disconnected_t disconnected; /* Optional - may be NULL */
   const char* protocol_version; /* Optional - if not NULL will be used instead of core version to decide if communication is compatible */
};

/**
 * The pixel format used for rendering.
 * @see RETRO_ENVIRONMENT_SET_PIXEL_FORMAT
 */
enum retro_pixel_format
{
   /**
    * 0RGB1555, native endian.
    * Used as the default if \c RETRO_ENVIRONMENT_SET_PIXEL_FORMAT is not called.
    * The most significant bit must be set to 0.
    * @deprecated This format remains supported to maintain compatibility.
    * New code should use <tt>RETRO_PIXEL_FORMAT_RGB565</tt> instead.
    * @see RETRO_PIXEL_FORMAT_RGB565
    */
   RETRO_PIXEL_FORMAT_0RGB1555 = 0,

   /**
    * XRGB8888, native endian.
    * The most significant byte (the <tt>X</tt>) is ignored.
    */
   RETRO_PIXEL_FORMAT_XRGB8888 = 1,

   /**
    * RGB565, native endian.
    * This format is recommended if 16-bit pixels are desired,
    * as it is available on a variety of devices and APIs.
    */
   RETRO_PIXEL_FORMAT_RGB565   = 2,

   /** Defined to ensure that <tt>sizeof(retro_pixel_format) == sizeof(int)</tt>. Do not use. */
   RETRO_PIXEL_FORMAT_UNKNOWN  = INT_MAX
};

/** @defgroup GET_SAVESTATE_CONTEXT Savestate Context
 * @{
 */

/**
 * Details about how the frontend will use savestates.
 *
 * @see RETRO_ENVIRONMENT_GET_SAVESTATE_CONTEXT
 * @see retro_serialize
 */
enum retro_savestate_context
{
   /**
    * Standard savestate written to disk.
    * May be loaded at any time,
    * even in a separate session or on another device.
    *
    * Should not contain any pointers to code or data.
    */
   RETRO_SAVESTATE_CONTEXT_NORMAL                 = 0,

   /**
    * The savestate is guaranteed to be loaded
    * within the same session, address space, and binary.
    * Will not be written to disk or sent over the network;
    * therefore, internal pointers to code or data are acceptable.
    * May still be loaded or saved at any time.
    *
    * @note This context generally implies the use of runahead or rewinding,
    * which may work by taking savestates multiple times per second.
    * Savestate code that runs in this context should be fast.
    */
   RETRO_SAVESTATE_CONTEXT_RUNAHEAD_SAME_INSTANCE = 1,

   /**
    * The savestate is guaranteed to be loaded
    * in the same session and by the same binary,
    * but possibly by a different address space
    * (e.g. for "second instance" runahead)
    *
    * Will not be written to disk or sent over the network,
    * but may be loaded in a different address space.
    * Therefore, the savestate <em>must not</em> contain pointers.
    */
   RETRO_SAVESTATE_CONTEXT_RUNAHEAD_SAME_BINARY   = 2,

   /**
    * The savestate will not be written to disk,
    * but no other guarantees are made.
    * The savestate will almost certainly be loaded
    * by a separate binary, device, and address space.
    *
    * This context is intended for use with frontends that support rollback netplay.
    * Serialized state should omit any data that would unnecessarily increase bandwidth usage.
    * Must not contain pointers, and integers must be saved in big-endian format.
    * @see retro_endianness.h
    * @see network_stream
    */
   RETRO_SAVESTATE_CONTEXT_ROLLBACK_NETPLAY       = 3,

   /**
    * @private Defined to ensure <tt>sizeof(retro_savestate_context) == sizeof(int)</tt>.
    * Do not use.
    */
   RETRO_SAVESTATE_CONTEXT_UNKNOWN                = INT_MAX
};

/** @} */

/** @defgroup SET_MESSAGE User-Visible Messages
 *
 * @{
 */

/**
 * Defines a message that the frontend will display to the user,
 * as determined by <tt>RETRO_ENVIRONMENT_SET_MESSAGE</tt>.
 *
 * @deprecated This struct is superseded by \ref retro_message_ext,
 * which provides more control over how a message is presented.
 * Only use it for compatibility with older cores and frontends.
 *
 * @see RETRO_ENVIRONMENT_SET_MESSAGE
 * @see retro_message_ext
 */
struct retro_message
{
   /**
    * Null-terminated message to be displayed.
    * If \c NULL or empty, the message will be ignored.
    */
   const char *msg;

   /** Duration to display \c msg in frames. */
   unsigned    frames;
};

/**
 * The method that the frontend will use to display a message to the player.
 * @see retro_message_ext
 */
enum retro_message_target
{
   /**
    * Indicates that the frontend should display the given message
    * using all other targets defined by \c retro_message_target at once.
    */
   RETRO_MESSAGE_TARGET_ALL = 0,

   /**
    * Indicates that the frontend should display the given message
    * using the frontend's on-screen display, if available.
    *
    * @attention If the frontend allows players to customize or disable notifications,
    * then they may not see messages sent to this target.
    */
   RETRO_MESSAGE_TARGET_OSD,

   /**
    * Indicates that the frontend should log the message
    * via its usual logging mechanism, if available.
    *
    * This is not intended to be a substitute for \c RETRO_ENVIRONMENT_SET_LOG_INTERFACE.
    * It is intended for the common use case of
    * logging a player-facing message.
    *
    * This target should not be used for messages
    * of type \c RETRO_MESSAGE_TYPE_STATUS or \c RETRO_MESSAGE_TYPE_PROGRESS,
    * as it may add unnecessary noise to a log file.
    *
    * @see RETRO_ENVIRONMENT_SET_LOG_INTERFACE
    */
   RETRO_MESSAGE_TARGET_LOG
};

/**
 * A broad category for the type of message that the frontend will display.
 *
 * Each message type has its own use case,
 * therefore the frontend should present each one differently.
 *
 * @note This is a hint that the frontend may ignore.
 * The frontend should fall back to \c RETRO_MESSAGE_TYPE_NOTIFICATION
 * for message types that it doesn't support.
 */
enum retro_message_type
{
   /**
    * A standard on-screen message.
    *
    * Suitable for a variety of use cases,
    * such as messages about errors
    * or other important events.
    *
    * Frontends that display their own messages
    * should display this type of core-generated message the same way.
    */
   RETRO_MESSAGE_TYPE_NOTIFICATION = 0,

   /**
    * An on-screen message that should be visually distinct
    * from \c RETRO_MESSAGE_TYPE_NOTIFICATION messages.
    *
    * The exact meaning of "visually distinct" is left to the frontend,
    * but this usually implies that the frontend shows the message
    * in a way that it doesn't typically use for its own notices.
    */
   RETRO_MESSAGE_TYPE_NOTIFICATION_ALT,

   /**
    * Indicates a frequently-updated status display,
    * rather than a standard notification.
    * Status messages are intended to be displayed permanently while a core is running
    * in a way that doesn't suggest user action is required.
    *
    * Here are some possible use cases for status messages:
    *
    * @li An internal framerate counter.
    * @li Debugging information.
    *     Remember to let the player disable it in the core options.
    * @li Core-specific state, such as when a microphone is active.
    *
    * The status message is displayed for the given duration,
    * unless another status message of equal or greater priority is shown.
    */
   RETRO_MESSAGE_TYPE_STATUS,

   /**
    * Denotes a message that reports the progress
    * of a long-running asynchronous task,
    * such as when a core loads large files from disk or the network.
    *
    * The frontend should display messages of this type as a progress bar
    * (or a progress spinner for indefinite tasks),
    * where \c retro_message_ext::msg is the progress bar's title
    * and \c retro_message_ext::progress sets the progress bar's length.
    *
    * This message type shouldn't be used for tasks that are expected to complete quickly.
    */
   RETRO_MESSAGE_TYPE_PROGRESS
};

/**
 * A core-provided message that the frontend will display to the player.
 *
 * @note The frontend is encouraged store these messages in a queue.
 * However, it should not empty the queue of core-submitted messages upon exit;
 * if a core exits with an error, it may want to use this API
 * to show an error message to the player.
 *
 * The frontend should maintain its own copy of the submitted message
 * and all subobjects, including strings.
 *
 * @see RETRO_ENVIRONMENT_SET_MESSAGE_EXT
 */
struct retro_message_ext
{
   /**
    * The \c NULL-terminated text of a message to show to the player.
    * Must not be \c NULL.
    *
    * @note The frontend must honor newlines in this string
    * when rendering text to \c RETRO_MESSAGE_TARGET_OSD.
    */
   const char *msg;

   /**
    * The duration that \c msg will be displayed on-screen, in milliseconds.
    *
    * Ignored for \c RETRO_MESSAGE_TARGET_LOG.
    */
   unsigned duration;

   /**
    * The relative importance of this message
    * when targeting \c RETRO_MESSAGE_TARGET_OSD.
    * Higher values indicate higher priority.
    *
    * The frontend should use this to prioritize messages
    * when it can't show all active messages at once,
    * or to remove messages from its queue if it's full.
    *
    * The relative display order of messages with the same priority
    * is left to the frontend's discretion,
    * although we suggest breaking ties
    * in favor of the most recently-submitted message.
    *
    * Frontends may handle deprioritized messages at their discretion;
    * such messages may have their \c duration altered,
    * be hidden without being delayed,
    * or even be discarded entirely.
    *
    * @note In the reference frontend (RetroArch),
    * the same priority values are used for frontend-generated notifications,
    * which are typically between 0 and 3 depending upon importance.
    *
    * Ignored for \c RETRO_MESSAGE_TARGET_LOG.
    */
   unsigned priority;

   /**
    * The severity level of this message.
    *
    * The frontend may use this to filter or customize messages
    * depending on the player's preferences.
    * Here are some ideas:
    *
    * @li Use this to prioritize errors and warnings
    *     over higher-ranking info and debug messages.
    * @li Render warnings or errors with extra visual feedback,
    *     e.g. with brighter colors or accompanying sound effects.
    *
    * @see RETRO_ENVIRONMENT_SET_LOG_INTERFACE
    */
   enum retro_log_level level;

   /**
    * The intended destination of this message.
    *
    * @see retro_message_target
    */
   enum retro_message_target target;

   /**
    * The intended semantics of this message.
    *
    * Ignored for \c RETRO_MESSAGE_TARGET_LOG.
    *
    * @see retro_message_type
    */
   enum retro_message_type type;

   /**
    * The progress of an asynchronous task.
    *
    * A value between 0 and 100 (inclusive) indicates the task's percentage,
    * and a value of -1 indicates a task of unknown completion.
    *
    * @note Since message type is a hint, a frontend may ignore progress values.
    * Where relevant, a core should include progress percentage within the message string,
    * such that the message intent remains clear when displayed
    * as a standard frontend-generated notification.
    *
    * Ignored for \c RETRO_MESSAGE_TARGET_LOG and for
    * message types other than \c RETRO_MESSAGE_TYPE_PROGRESS.
    */
   int8_t progress;
};

/** @} */

/* Describes how the libretro implementation maps a libretro input bind
 * to its internal input system through a human readable string.
 * This string can be used to better let a user configure input. */
struct retro_input_descriptor
{
   /* Associates given parameters with a description. */
   unsigned port;
   unsigned device;
   unsigned index;
   unsigned id;

   /* Human readable description for parameters.
    * The pointer must remain valid until
    * retro_unload_game() is called. */
   const char *description;
};

/**
 * Contains basic information about the core.
 *
 * @see retro_get_system_info
 * @warning All pointers are owned by the core
 * and must remain valid throughout its lifetime.
 */
struct retro_system_info
{
   /**
    * Descriptive name of the library.
    *
    * @note Should not contain any version numbers, etc.
    */
   const char *library_name;

   /**
    * Descriptive version of the core.
    */
   const char *library_version;

   /**
    * A pipe-delimited string list of file extensions that this core can load, e.g. "bin|rom|iso".
    * Typically used by a frontend for filtering or core selection.
    */
   const char *valid_extensions;

   /* Libretro cores that need to have direct access to their content
    * files, including cores which use the path of the content files to
    * determine the paths of other files, should set need_fullpath to true.
    *
    * Cores should strive for setting need_fullpath to false,
    * as it allows the frontend to perform patching, etc.
    *
    * If need_fullpath is true and retro_load_game() is called:
    *    - retro_game_info::path is guaranteed to have a valid path
    *    - retro_game_info::data and retro_game_info::size are invalid
    *
    * If need_fullpath is false and retro_load_game() is called:
    *    - retro_game_info::path may be NULL
    *    - retro_game_info::data and retro_game_info::size are guaranteed
    *      to be valid
    *
    * See also:
    *    - RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY
    *    - RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY
    */
   bool        need_fullpath;

   /* If true, the frontend is not allowed to extract any archives before
    * loading the real content.
    * Necessary for certain libretro implementations that load games
    * from zipped archives. */
   bool        block_extract;
};

/* Defines overrides which modify frontend handling of
 * specific content file types.
 * An array of retro_system_content_info_override is
 * passed to RETRO_ENVIRONMENT_SET_CONTENT_INFO_OVERRIDE
 * NOTE: In the following descriptions, references to
 *       retro_load_game() may be replaced with
 *       retro_load_game_special() */
struct retro_system_content_info_override
{
   /* A list of file extensions for which the override
    * should apply, delimited by a 'pipe' character
    * (e.g. "md|sms|gg")
    * Permitted file extensions are limited to those
    * included in retro_system_info::valid_extensions
    * and/or retro_subsystem_rom_info::valid_extensions */
   const char *extensions;

   /* Overrides the need_fullpath value set in
    * retro_system_info and/or retro_subsystem_rom_info.
    * To reiterate:
    *
    * If need_fullpath is true and retro_load_game() is called:
    *    - retro_game_info::path is guaranteed to contain a valid
    *      path to an existent file
    *    - retro_game_info::data and retro_game_info::size are invalid
    *
    * If need_fullpath is false and retro_load_game() is called:
    *    - retro_game_info::path may be NULL
    *    - retro_game_info::data and retro_game_info::size are guaranteed
    *      to be valid
    *
    * In addition:
    *
    * If need_fullpath is true and retro_load_game() is called:
    *    - retro_game_info_ext::full_path is guaranteed to contain a valid
    *      path to an existent file
    *    - retro_game_info_ext::archive_path may be NULL
    *    - retro_game_info_ext::archive_file may be NULL
    *    - retro_game_info_ext::dir is guaranteed to contain a valid path
    *      to the directory in which the content file exists
    *    - retro_game_info_ext::name is guaranteed to contain the
    *      basename of the content file, without extension
    *    - retro_game_info_ext::ext is guaranteed to contain the
    *      extension of the content file in lower case format
    *    - retro_game_info_ext::data and retro_game_info_ext::size
    *      are invalid
    *
    * If need_fullpath is false and retro_load_game() is called:
    *    - If retro_game_info_ext::file_in_archive is false:
    *       - retro_game_info_ext::full_path is guaranteed to contain
    *         a valid path to an existent file
    *       - retro_game_info_ext::archive_path may be NULL
    *       - retro_game_info_ext::archive_file may be NULL
    *       - retro_game_info_ext::dir is guaranteed to contain a
    *         valid path to the directory in which the content file exists
    *       - retro_game_info_ext::name is guaranteed to contain the
    *         basename of the content file, without extension
    *       - retro_game_info_ext::ext is guaranteed to contain the
    *         extension of the content file in lower case format
    *    - If retro_game_info_ext::file_in_archive is true:
    *       - retro_game_info_ext::full_path may be NULL
    *       - retro_game_info_ext::archive_path is guaranteed to
    *         contain a valid path to an existent compressed file
    *         inside which the content file is located
    *       - retro_game_info_ext::archive_file is guaranteed to
    *         contain a valid path to an existent content file
    *         inside the compressed file referred to by
    *         retro_game_info_ext::archive_path
    *            e.g. for a compressed file '/path/to/foo.zip'
    *            containing 'bar.sfc'
    *             > retro_game_info_ext::archive_path will be '/path/to/foo.zip'
    *             > retro_game_info_ext::archive_file will be 'bar.sfc'
    *       - retro_game_info_ext::dir is guaranteed to contain a
    *         valid path to the directory in which the compressed file
    *         (containing the content file) exists
    *       - retro_game_info_ext::name is guaranteed to contain
    *         EITHER
    *         1) the basename of the compressed file (containing
    *            the content file), without extension
    *         OR
    *         2) the basename of the content file inside the
    *            compressed file, without extension
    *         In either case, a core should consider 'name' to
    *         be the canonical name/ID of the the content file
    *       - retro_game_info_ext::ext is guaranteed to contain the
    *         extension of the content file inside the compressed file,
    *         in lower case format
    *    - retro_game_info_ext::data and retro_game_info_ext::size are
    *      guaranteed to be valid */
   bool need_fullpath;

   /* If need_fullpath is false, specifies whether the content
    * data buffer available in retro_load_game() is 'persistent'
    *
    * If persistent_data is false and retro_load_game() is called:
    *    - retro_game_info::data and retro_game_info::size
    *      are valid only until retro_load_game() returns
    *    - retro_game_info_ext::data and retro_game_info_ext::size
    *      are valid only until retro_load_game() returns
    *
    * If persistent_data is true and retro_load_game() is called:
    *    - retro_game_info::data and retro_game_info::size
    *      are valid until retro_deinit() returns
    *    - retro_game_info_ext::data and retro_game_info_ext::size
    *      are valid until retro_deinit() returns */
   bool persistent_data;
};

/* Similar to retro_game_info, but provides extended
 * information about the source content file and
 * game memory buffer status.
 * And array of retro_game_info_ext is returned by
 * RETRO_ENVIRONMENT_GET_GAME_INFO_EXT
 * NOTE: In the following descriptions, references to
 *       retro_load_game() may be replaced with
 *       retro_load_game_special() */
struct retro_game_info_ext
{
   /* - If file_in_archive is false, contains a valid
    *   path to an existent content file (UTF-8 encoded)
    * - If file_in_archive is true, may be NULL */
   const char *full_path;

   /* - If file_in_archive is false, may be NULL
    * - If file_in_archive is true, contains a valid path
    *   to an existent compressed file inside which the
    *   content file is located (UTF-8 encoded) */
   const char *archive_path;

   /* - If file_in_archive is false, may be NULL
    * - If file_in_archive is true, contain a valid path
    *   to an existent content file inside the compressed
    *   file referred to by archive_path (UTF-8 encoded)
    *      e.g. for a compressed file '/path/to/foo.zip'
    *      containing 'bar.sfc'
    *      > archive_path will be '/path/to/foo.zip'
    *      > archive_file will be 'bar.sfc' */
   const char *archive_file;

   /* - If file_in_archive is false, contains a valid path
    *   to the directory in which the content file exists
    *   (UTF-8 encoded)
    * - If file_in_archive is true, contains a valid path
    *   to the directory in which the compressed file
    *   (containing the content file) exists (UTF-8 encoded) */
   const char *dir;

   /* Contains the canonical name/ID of the content file
    * (UTF-8 encoded). Intended for use when identifying
    * 'complementary' content named after the loaded file -
    * i.e. companion data of a different format (a CD image
    * required by a ROM), texture packs, internally handled
    * save files, etc.
    * - If file_in_archive is false, contains the basename
    *   of the content file, without extension
    * - If file_in_archive is true, then string is
    *   implementation specific. A frontend may choose to
    *   set a name value of:
    *   EITHER
    *   1) the basename of the compressed file (containing
    *      the content file), without extension
    *   OR
    *   2) the basename of the content file inside the
    *      compressed file, without extension
    *   RetroArch sets the 'name' value according to (1).
    *   A frontend that supports routine loading of
    *   content from archives containing multiple unrelated
    *   content files may set the 'name' value according
    *   to (2). */
   const char *name;

   /* - If file_in_archive is false, contains the extension
    *   of the content file in lower case format
    * - If file_in_archive is true, contains the extension
    *   of the content file inside the compressed file,
    *   in lower case format */
   const char *ext;

   /* String of implementation specific meta-data. */
   const char *meta;

   /* Memory buffer of loaded game content. Will be NULL:
    * IF
    * - retro_system_info::need_fullpath is true and
    *   retro_system_content_info_override::need_fullpath
    *   is unset
    * OR
    * - retro_system_content_info_override::need_fullpath
    *   is true */
   const void *data;

   /* Size of game content memory buffer, in bytes */
   size_t size;

   /* True if loaded content file is inside a compressed
    * archive */
   bool file_in_archive;

   /* - If data is NULL, value is unset/ignored
    * - If data is non-NULL:
    *   - If persistent_data is false, data and size are
    *     valid only until retro_load_game() returns
    *   - If persistent_data is true, data and size are
    *     are valid until retro_deinit() returns */
   bool persistent_data;
};

/**
 * Parameters describing the size and shape of the video frame.
 * @see retro_system_av_info
 * @see RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO
 * @see RETRO_ENVIRONMENT_SET_GEOMETRY
 * @see retro_get_system_av_info
 */
struct retro_game_geometry
{
   /**
    * Nominal video width of game, in pixels.
    * This will typically be the emulated platform's native video width
    * (or its smallest, if the original hardware supports multiple resolutions).
    */
   unsigned base_width;

   /**
    * Nominal video height of game, in pixels.
    * This will typically be the emulated platform's native video height
    * (or its smallest, if the original hardware supports multiple resolutions).
    */
   unsigned base_height;

   /**
    * Maximum possible width of the game screen, in pixels.
    * This will typically be the emulated platform's maximum video width.
    * For cores that emulate platforms with multiple screens (such as the Nintendo DS),
    * this should assume the core's widest possible screen layout (e.g. side-by-side).
    * For cores that support upscaling the resolution,
    * this should assume the highest supported scale factor is active.
    */
   unsigned max_width;

   /**
    * Maximum possible height of the game screen, in pixels.
    * This will typically be the emulated platform's maximum video height.
    * For cores that emulate platforms with multiple screens (such as the Nintendo DS),
    * this should assume the core's tallest possible screen layout (e.g. vertical).
    * For cores that support upscaling the resolution,
    * this should assume the highest supported scale factor is active.
    */
   unsigned max_height;    /* Maximum possible height of game. */

   /**
    * Nominal aspect ratio of game.
    * If zero or less,
    * an aspect ratio of <tt>base_width / base_height</tt> is assumed.
    *
    * @note A frontend may ignore this setting.
    */
   float    aspect_ratio;
};

/**
 * Parameters describing the timing of the video and audio.
 * @see retro_system_av_info
 * @see RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO
 * @see retro_get_system_av_info
 */
struct retro_system_timing
{
   /** Video output refresh rate, in frames per second. */
   double fps;

   /** The audio output sample rate, in Hz. */
   double sample_rate;
};

/**
 * Configures how the core's audio and video should be updated.
 * @see RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO
 * @see retro_get_system_av_info
 */
struct retro_system_av_info
{
   /** Parameters describing the size and shape of the video frame. */
   struct retro_game_geometry geometry;

   /** Parameters describing the timing of the video and audio. */
   struct retro_system_timing timing;
};

/** @defgroup SET_CORE_OPTIONS Core Options
 *  @{
 */

/**
 * Represents \ref RETRO_ENVIRONMENT_GET_VARIABLE "a core option query".
 *
 * @note In \ref RETRO_ENVIRONMENT_SET_VARIABLES
 * (which is a deprecated API),
 * this \c struct serves as an option definition.
 *
 * @see RETRO_ENVIRONMENT_GET_VARIABLE
 */
struct retro_variable
{
   /**
    * A unique key identifying this option.
    *
    * Should be a key for an option that was previously defined
    * with \ref RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 or similar.
    *
    * Should be prefixed with the core's name
    * to minimize the risk of collisions with another core's options,
    * as frontends are not required to use a namespacing scheme for storing options.
    * For example, a core named "foo" might define an option named "foo_option".
    *
    * @note In \ref RETRO_ENVIRONMENT_SET_VARIABLES
    * (which is a deprecated API),
    * this field is used to define an option
    * named by this key.
    */
   const char *key;

   /**
    * Value to be obtained.
    *
    * Set by the frontend to \c NULL if
    * the option named by \ref key does not exist.
    *
    * @note In \ref RETRO_ENVIRONMENT_SET_VARIABLES
    * (which is a deprecated API),
    * this field is set by the core to define the possible values
    * for an option named by \ref key.
    * When used this way, it must be formatted as follows:
    * @li The text before the first ';' is the option's human-readable title.
    * @li A single space follows the ';'.
    * @li The rest of the string is a '|'-delimited list of possible values,
    * with the first one being the default.
    */
   const char *value;
};

/**
 * An argument that's used to show or hide a core option in the frontend.
 *
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY
 */
struct retro_core_option_display
{
   /**
    * The key for a core option that was defined with \ref RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2,
    * \ref RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL,
    * or their legacy equivalents.
    */
   const char *key;

   /**
    * Whether the option named by \c key
    * should be displayed to the player in the frontend's core options menu.
    *
    * @note This value is a hint, \em not a requirement;
    * the frontend is free to ignore this field.
    */
   bool visible;
};

/**
 * The maximum number of choices that can be defined for a given core option.
 *
 * This limit was chosen as a compromise between
 * a core's flexibility and a streamlined user experience.
 *
 * @note A guiding principle of libretro's API design is that
 * all common interactions (gameplay, menu navigation, etc.)
 * should be possible without a keyboard.
 *
 * If you need more than 128 choices for a core option,
 * consider simplifying your option structure.
 * Here are some ideas:
 *
 * \li If a core option represents a numeric value,
 *     consider reducing the option's granularity
 *     (e.g. define time limits in increments of 5 seconds instead of 1 second).
 *     Providing a fixed set of values based on experimentation
 *     is also a good idea.
 * \li If a core option represents a dynamically-built list of files,
 *     consider leaving out files that won't be useful.
 *     For example, if a core allows the player to choose a specific BIOS file,
 *     it can omit files of the wrong length or without a valid header.
 *
 * @see retro_core_option_definition
 * @see retro_core_option_v2_definition
 */
#define RETRO_NUM_CORE_OPTION_VALUES_MAX 128

/**
 * A descriptor for a particular choice within a core option.
 *
 * @note All option values are represented as strings.
 * If you need to represent any other type,
 * parse the string in \ref value.
 *
 * @see retro_core_option_v2_category
 */
struct retro_core_option_value
{
   /**
    * The option value that the frontend will serialize.
    *
    * Must not be \c NULL or empty.
    * No other hard limits are placed on this value's contents,
    * but here are some suggestions:
    *
    * \li If the value represents a number,
    *     don't include any non-digit characters (units, separators, etc.).
    *     Instead, include that information in \c label.
    *     This will simplify parsing.
    * \li If the value represents a file path,
    *     store it as a relative path with respect to one of the common libretro directories
    *     (e.g. \ref RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY "the system directory"
    *     or \ref RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY "the save directory"),
    *     and use forward slashes (\c "/") as directory separators.
    *     This will simplify cloud storage if supported by the frontend,
    *     as the same file may be used on multiple devices.
    */
   const char *value;

   /**
    * Human-readable name for \c value that the frontend should show to players.
    *
    * May be \c NULL, in which case the frontend
    * should display \c value itself.
    *
    * Here are some guidelines for writing a good label:
    *
    * \li Make the option labels obvious
    *     so that they don't need to be explained in the description.
    * \li Keep labels short, and don't use unnecessary words.
    *     For example, "OpenGL" is a better label than "OpenGL Mode".
    * \li If the option represents a number,
    *     consider adding units, separators, or other punctuation
    *     into the label itself.
    *     For example, "5 seconds" is a better label than "5".
    * \li If the option represents a number, use intuitive units
    *     that don't take a lot of digits to express.
    *     For example, prefer "1 minute" over "60 seconds" or "60,000 milliseconds".
    */
   const char *label;
};

/**
 * @copybrief retro_core_option_v2_definition
 *
 * @deprecated Use \ref retro_core_option_v2_definition instead,
 * as it supports categorizing options into groups.
 * Only use this \c struct to support older frontends or cores.
 *
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL
 */
struct retro_core_option_definition
{
   /** @copydoc retro_core_option_v2_definition::key */
   const char *key;

   /** @copydoc retro_core_option_v2_definition::desc */
   const char *desc;

   /** @copydoc retro_core_option_v2_definition::info */
   const char *info;

   /** @copydoc retro_core_option_v2_definition::values */
   struct retro_core_option_value values[RETRO_NUM_CORE_OPTION_VALUES_MAX];

   /** @copydoc retro_core_option_v2_definition::default_value */
   const char *default_value;
};

#ifdef __PS3__
#undef local
#endif

/**
 * A variant of \ref retro_core_options that supports internationalization.
 *
 * @deprecated Use \ref retro_core_options_v2_intl instead,
 * as it supports categorizing options into groups.
 * Only use this \c struct to support older frontends or cores.
 *
 * @see retro_core_options
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_INTL
 * @see RETRO_ENVIRONMENT_GET_LANGUAGE
 * @see retro_language
 */
struct retro_core_options_intl
{
   /** @copydoc retro_core_options_v2_intl::us */
   struct retro_core_option_definition *us;

   /** @copydoc retro_core_options_v2_intl::local */
   struct retro_core_option_definition *local;
};

/**
 * A descriptor for a group of related core options.
 *
 * Here's an example category:
 *
 * @code
 * {
 *     "cpu",
 *     "CPU Emulation",
 *     "Settings for CPU quirks."
 * }
 * @endcode
 *
 * @see retro_core_options_v2
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL
 */
struct retro_core_option_v2_category
{
   /**
    * A string that uniquely identifies this category within the core's options.
    * Any \c retro_core_option_v2_definition whose \c category_key matches this
    * is considered to be within this category.
    * Different cores may use the same category keys,
    * so namespacing them is not necessary.
    * Valid characters are <tt>[a-zA-Z0-9_-]</tt>.
    *
    * Frontends should use this category to organize core options,
    * but may customize this category's presentation in other ways.
    * For example, a frontend may use common keys like "audio" or "gfx"
    * to select an appropriate icon in its UI.
    *
    * Required; must not be \c NULL.
    */
   const char *key;

   /**
    * A brief human-readable name for this category,
    * intended for the frontend to display to the player.
    * This should be a name that's concise and descriptive, such as "Audio" or "Video".
    *
    * Required; must not be \c NULL.
    */
   const char *desc;

   /**
    * A human-readable description for this category,
    * intended for the frontend to display to the player
    * as secondary help text (e.g. a sublabel or a tooltip).
    * Optional; may be \c NULL or an empty string.
    */
   const char *info;
};

/**
 * A descriptor for a particular core option and the values it may take.
 *
 * Supports categorizing options into groups,
 * so as not to overwhelm the player.
 *
 * @see retro_core_option_v2_category
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL
 */
struct retro_core_option_v2_definition
{
   /**
    * A unique identifier for this option that cores may use
    * \ref RETRO_ENVIRONMENT_GET_VARIABLE "to query its value from the frontend".
    * Must be unique within this core.
    *
    * Should be unique globally;
    * the recommended method for doing so
    * is to prefix each option with the core's name.
    * For example, an option that controls the resolution for a core named "foo"
    * should be named \c "foo_resolution".
    *
    * Valid key characters are in the set <tt>[a-zA-Z0-9_-]</tt>.
    */
   const char *key;

   /**
    * A human-readable name for this option,
    * intended to be displayed by frontends that don't support
    * categorizing core options.
    *
    * Required; must not be \c NULL or empty.
    */
   const char *desc;

   /**
    * A human-readable name for this option,
    * intended to be displayed by frontends that support
    * categorizing core options.
    *
    * This version may be slightly more concise than \ref desc,
    * as it can rely on the structure of the options menu.
    * For example, "Interface" is a good \c desc_categorized,
    * as it can be displayed as a sublabel for a "Network" category.
    * For \c desc, "Network Interface" would be more suitable.
    *
    * Optional; if this field or \c category_key is empty or \c NULL,
    * \c desc will be used instead.
    */
   const char *desc_categorized;

   /**
    * A human-readable description of this option and its effects,
    * intended to be displayed by frontends that don't support
    * categorizing core options.
    *
    * @details Intended to be displayed as secondary help text,
    * such as a tooltip or a sublabel.
    *
    * Here are some suggestions for writing a good description:
    *
    * \li Avoid technical jargon unless this option is meant for advanced users.
    *     If unavoidable, suggest one of the default options for those unsure.
    * \li Don't repeat the option name in the description;
    *     instead, describe what the option name means.
    * \li If an option requires a core restart or game reset to take effect,
    *     be sure to say so.
    * \li Try to make the option labels obvious
    *     so that they don't need to be explained in the description.
    *
    * Optional; may be \c NULL.
    */
   const char *info;

   /**
    * @brief A human-readable description of this option and its effects,
    * intended to be displayed by frontends that support
    * categorizing core options.
    *
    * This version is provided to accommodate descriptions
    * that reference other options by name,
    * as options may have different user-facing names
    * depending on whether the frontend supports categorization.
    *
    * @copydetails info
    *
    * If empty or \c NULL, \c info will be used instead.
    * Will be ignored if \c category_key is empty or \c NULL.
    */
   const char *info_categorized;

   /**
    * The key of the category that this option belongs to.
    *
    * Optional; if equal to \ref retro_core_option_v2_category::key "a defined category",
    * then this option shall be displayed by the frontend
    * next to other options in this same category,
    * assuming it supports doing so.
    * Option categories are intended to be displayed in a submenu,
    * but this isn't a hard requirement.
    *
    * If \c NULL, empty, or not equal to a defined category,
    * then this option is considered uncategorized
    * and the frontend shall display it outside of any category
    * (most likely at a top-level menu).
    *
    * @see retro_core_option_v2_category
    */
   const char *category_key;

   /**
    * One or more possible values for this option,
    * up to the limit of \ref RETRO_NUM_CORE_OPTION_VALUES_MAX.
    *
    * Terminated by a \c { NULL, NULL } element,
    * although frontends should work even if all elements are used.
    */
   struct retro_core_option_value values[RETRO_NUM_CORE_OPTION_VALUES_MAX];

   /**
    * The default value for this core option.
    * Used if it hasn't been set, e.g. for new cores.
    * Must equal one of the \ref value members in the \c values array,
    * or else this option will be ignored.
    */
   const char *default_value;
};

/**
 * A set of core option descriptors and the categories that group them,
 * suitable for enabling a core to be customized.
 *
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2
 */
struct retro_core_options_v2
{
   /**
    * An array of \ref retro_core_option_v2_category "option categories",
    * terminated by a zeroed-out category \c struct.
    *
    * Will be ignored if the frontend doesn't support core option categories.
    *
    * If \c NULL or ignored, all options will be treated as uncategorized.
    * This most likely means that a frontend will display them at a top-level menu
    * without any kind of hierarchy or grouping.
    */
   struct retro_core_option_v2_category *categories;

   /**
    * An array of \ref retro_core_option_v2_definition "core option descriptors",
    * terminated by a zeroed-out definition \c struct.
    *
    * Required; must not be \c NULL.
    */
   struct retro_core_option_v2_definition *definitions;
};

/**
 * A variant of \ref retro_core_options_v2 that supports internationalization.
 *
 * @see retro_core_options_v2
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL
 * @see RETRO_ENVIRONMENT_GET_LANGUAGE
 * @see retro_language
 */
struct retro_core_options_v2_intl
{
   /**
    * Pointer to a core options set
    * whose text is written in American English.
    *
    * This may be passed to \c RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2 as-is
    * if not using \c RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2_INTL.
    *
    * Required; must not be \c NULL.
    */
   struct retro_core_options_v2 *us;

   /**
    * Pointer to a core options set
    * whose text is written in one of libretro's \ref retro_language "supported languages",
    * most likely the one returned by \ref RETRO_ENVIRONMENT_GET_LANGUAGE.
    *
    * Structure is the same, but usage is slightly different:
    *
    * \li All text (except for keys and option values)
    *     should be written in whichever language
    *     is returned by \c RETRO_ENVIRONMENT_GET_LANGUAGE.
    * \li All fields besides keys and option values may be \c NULL,
    *     in which case the corresponding string in \c us
    *     is used instead.
    * \li All \ref retro_core_option_v2_definition::default_value "default option values"
    *     are taken from \c us.
    *     The defaults in this field are ignored.
    *
    * May be \c NULL, in which case \c us is used instead.
    */
   struct retro_core_options_v2 *local;
};

/**
 * Called by the frontend to determine if any core option's visibility has changed.
 *
 * Each time a frontend sets a core option,
 * it should call this function to see if
 * any core option should be made visible or invisible.
 *
 * May also be called after \ref retro_load_game "loading a game",
 * to determine what the initial visibility of each option should be.
 *
 * Within this function, the core must update the visibility
 * of any dynamically-hidden options
 * using \ref RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY.
 *
 * @note All core options are visible by default,
 * even during this function's first call.
 *
 * @return \c true if any core option's visibility was adjusted
 * since the last call to this function.
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY
 * @see retro_core_option_display
 */
typedef bool (RETRO_CALLCONV *retro_core_options_update_display_callback_t)(void);

/**
 * Callback registered by the core for the frontend to use
 * when setting the visibility of each core option.
 *
 * @see RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY
 * @see retro_core_option_display
 */
struct retro_core_options_update_display_callback
{
   /**
    * @copydoc retro_core_options_update_display_callback_t
    *
    * Set by the core.
    */
   retro_core_options_update_display_callback_t callback;
};

/** @} */

struct retro_game_info
{
   const char *path;       /* Path to game, UTF-8 encoded.
                            * Sometimes used as a reference for building other paths.
                            * May be NULL if game was loaded from stdin or similar,
                            * but in this case some cores will be unable to load `data`.
                            * So, it is preferable to fabricate something here instead
                            * of passing NULL, which will help more cores to succeed.
                            * retro_system_info::need_fullpath requires
                            * that this path is valid. */
   const void *data;       /* Memory buffer of loaded game. Will be NULL
                            * if need_fullpath was set. */
   size_t      size;       /* Size of memory buffer. */
   const char *meta;       /* String of implementation specific meta-data. */
};

/** @defgroup GET_CURRENT_SOFTWARE_FRAMEBUFFER Frontend-Owned Framebuffers
 * @{
 */

/** @defgroup RETRO_MEMORY_ACCESS Framebuffer Memory Access Types
 * @{
 */

/** Indicates that core will write to the framebuffer returned by the frontend. */
#define RETRO_MEMORY_ACCESS_WRITE (1 << 0)

/** Indicates that the core will read from the framebuffer returned by the frontend. */
#define RETRO_MEMORY_ACCESS_READ (1 << 1)

/** @} */

/** @defgroup RETRO_MEMORY_TYPE Framebuffer Memory Types
 * @{
 */

/**
 * Indicates that the returned framebuffer's memory is cached.
 * If not set, random access to the buffer may be very slow.
 */
#define RETRO_MEMORY_TYPE_CACHED (1 << 0)

/** @} */

/**
 * A frame buffer owned by the frontend that a core may use for rendering.
 *
 * @see GET_CURRENT_SOFTWARE_FRAMEBUFFER
 * @see retro_video_refresh_t
 */
struct retro_framebuffer
{
   /**
    * Pointer to the beginning of the framebuffer provided by the frontend.
    * The initial contents of this buffer are unspecified,
    * as is the means used to map the memory;
    * this may be defined in software,
    * or it may be GPU memory mapped to RAM.
    *
    * If the framebuffer is used,
    * this pointer must be passed to \c retro_video_refresh_t as-is.
    * It is undefined behavior to pass an offset to this pointer.
    *
    * @warning This pointer is only guaranteed to be valid
    * for the duration of the same \c retro_run iteration
    * \ref GET_CURRENT_SOFTWARE_FRAMEBUFFER "that requested the framebuffer".
    * Reuse of this pointer is undefined.
    */
   void *data;

   /**
    * The width of the framebuffer given in \c data, in pixels.
    * Set by the core.
    *
    * @warning If the framebuffer is used,
    * this value must be passed to \c retro_video_refresh_t as-is.
    * It is undefined behavior to try to render \c data with any other width.
    */
   unsigned width;

   /**
    * The height of the framebuffer given in \c data, in pixels.
    * Set by the core.
    *
    * @warning If the framebuffer is used,
    * this value must be passed to \c retro_video_refresh_t as-is.
    * It is undefined behavior to try to render \c data with any other height.
    */
   unsigned height;

   /**
    * The distance between the start of one scanline and the beginning of the next, in bytes.
    * In practice this is usually equal to \c width times the pixel size,
    * but that's not guaranteed.
    * Sometimes called the "stride".
    *
    * @setby{frontend}
    * @warning If the framebuffer is used,
    * this value must be passed to \c retro_video_refresh_t as-is.
    * It is undefined to try to render \c data with any other pitch.
    */
   size_t pitch;

   /**
    * The pixel format of the returned framebuffer.
    * May be different than the format specified by the core in \c RETRO_ENVIRONMENT_SET_PIXEL_FORMAT,
    * e.g. due to conversions.
    * Set by the frontend.
    *
    * @see RETRO_ENVIRONMENT_SET_PIXEL_FORMAT
    */
   enum retro_pixel_format format;

   /**
    * One or more \ref RETRO_MEMORY_ACCESS "memory access flags"
    * that specify how the core will access the memory in \c data.
    *
    * @setby{core}
    */
   unsigned access_flags;

   /**
    * Zero or more \ref RETRO_MEMORY_TYPE "memory type flags"
    * that describe how the framebuffer's memory has been mapped.
    *
    * @setby{frontend}
    */
   unsigned memory_flags;
};

/** @} */

/** @defgroup SET_FASTFORWARDING_OVERRIDE Fast-Forward Override
 * @{
 */

/**
 * Parameters that govern when and how the core takes control
 * of fast-forwarding mode.
 */
struct retro_fastforwarding_override
{
   /**
    * The factor by which the core will be sped up
    * when \c fastforward is \c true.
    * This value is used as follows:
    *
    * @li A value greater than 1.0 will run the core at
    *     the specified multiple of normal speed.
    *     For example, a value of 5.0
    *     combined with a normal target rate of 60 FPS
    *     will result in a target rate of 300 FPS.
    *     The actual rate may be lower if the host's hardware can't keep up.
    * @li A value of 1.0 will run the core at normal speed.
    * @li A value between 0.0 (inclusive) and 1.0 (exclusive)
    *     will run the core as fast as the host system can manage.
    * @li A negative value will let the frontend choose a factor.
    * @li An infinite value or \c NaN results in undefined behavior.
    *
    * @attention Setting this value to less than 1.0 will \em not
    * slow down the core.
    */
   float ratio;

   /**
    * If \c true, the frontend should activate fast-forwarding
    * until this field is set to \c false or the core is unloaded.
    */
   bool fastforward;

   /**
    * If \c true, the frontend should display an on-screen notification or icon
    * while \c fastforward is \c true (where supported).
    * Otherwise, the frontend should not display any such notification.
    */
   bool notification;

   /**
    * If \c true, the core has exclusive control
    * over enabling and disabling fast-forwarding
    * via the \c fastforward field.
    * The frontend will not be able to start or stop fast-forwarding
    * until this field is set to \c false or the core is unloaded.
    */
   bool inhibit_toggle;
};

/** @} */

/**
 * During normal operation.
 *
 * @note Rate will be equal to the core's internal FPS.
 */
#define RETRO_THROTTLE_NONE              0

/**
 * While paused or stepping single frames.
 *
 * @note Rate will be 0.
 */
#define RETRO_THROTTLE_FRAME_STEPPING    1

/**
 * During fast forwarding.
 *
 * @note Rate will be 0 if not specifically limited to a maximum speed.
 */
#define RETRO_THROTTLE_FAST_FORWARD      2

/**
 * During slow motion.
 *
 * @note Rate will be less than the core's internal FPS.
 */
#define RETRO_THROTTLE_SLOW_MOTION       3

/**
 * While rewinding recorded save states.
 *
 * @note Rate can vary depending on the rewind speed or be 0 if the frontend
 * is not aiming for a specific rate.
 */
#define RETRO_THROTTLE_REWINDING         4

/**
 * While vsync is active in the video driver, and the target refresh rate is lower than the core's internal FPS.
 *
 * @note Rate is the target refresh rate.
 */
#define RETRO_THROTTLE_VSYNC             5

/**
 * When the frontend does not throttle in any way.
 *
 * @note Rate will be 0. An example could be if no vsync or audio output is active.
 */
#define RETRO_THROTTLE_UNBLOCKED         6

/**
 * Details about the actual rate an implementation is calling \c retro_run() at.
 *
 * @see RETRO_ENVIRONMENT_GET_THROTTLE_STATE
 */
struct retro_throttle_state
{
   /**
    * The current throttling mode.
    *
    * @note Should be one of the \c RETRO_THROTTLE_* values.
    * @see RETRO_THROTTLE_NONE
    * @see RETRO_THROTTLE_FRAME_STEPPING
    * @see RETRO_THROTTLE_FAST_FORWARD
    * @see RETRO_THROTTLE_SLOW_MOTION
    * @see RETRO_THROTTLE_REWINDING
    * @see RETRO_THROTTLE_VSYNC
    * @see RETRO_THROTTLE_UNBLOCKED
    */
   unsigned mode;

   /**
    * How many times per second the frontend aims to call retro_run.
    *
    * @note Depending on the mode, it can be 0 if there is no known fixed rate.
    * This won't be accurate if the total processing time of the core and
    * the frontend is longer than what is available for one frame.
    */
   float rate;
};

/** @defgroup GET_MICROPHONE_INTERFACE Microphone Interface
 * @{
 */

/**
 * Opaque handle to a microphone that's been opened for use.
 * The underlying object is accessed or created with \c retro_microphone_interface_t.
 */
typedef struct retro_microphone retro_microphone_t;

/**
 * Parameters for configuring a microphone.
 * Some of these might not be honored,
 * depending on the available hardware and driver configuration.
 */
typedef struct retro_microphone_params
{
   /**
    * The desired sample rate of the microphone's input, in Hz.
    * The microphone's input will be resampled,
    * so cores can ask for whichever frequency they need.
    *
    * If zero, some reasonable default will be provided by the frontend
    * (usually from its config file).
    *
    * @see retro_get_mic_rate_t
    */
   unsigned rate;
} retro_microphone_params_t;

/**
 * @copydoc retro_microphone_interface::open_mic
 */
typedef retro_microphone_t *(RETRO_CALLCONV *retro_open_mic_t)(const retro_microphone_params_t *params);

/**
 * @copydoc retro_microphone_interface::close_mic
 */
typedef void (RETRO_CALLCONV *retro_close_mic_t)(retro_microphone_t *microphone);

/**
 * @copydoc retro_microphone_interface::get_params
 */
typedef bool (RETRO_CALLCONV *retro_get_mic_params_t)(const retro_microphone_t *microphone, retro_microphone_params_t *params);

/**
 * @copydoc retro_microphone_interface::set_mic_state
 */
typedef bool (RETRO_CALLCONV *retro_set_mic_state_t)(retro_microphone_t *microphone, bool state);

/**
 * @copydoc retro_microphone_interface::get_mic_state
 */
typedef bool (RETRO_CALLCONV *retro_get_mic_state_t)(const retro_microphone_t *microphone);

/**
 * @copydoc retro_microphone_interface::read_mic
 */
typedef int (RETRO_CALLCONV *retro_read_mic_t)(retro_microphone_t *microphone, int16_t* samples, size_t num_samples);

/**
 * The current version of the microphone interface.
 * Will be incremented whenever \c retro_microphone_interface or \c retro_microphone_params_t
 * receive new fields.
 *
 * Frontends using cores built against older mic interface versions
 * should not access fields introduced in newer versions.
 */
#define RETRO_MICROPHONE_INTERFACE_VERSION 1

/**
 * An interface for querying the microphone and accessing data read from it.
 *
 * @see RETRO_ENVIRONMENT_GET_MICROPHONE_INTERFACE
 */
struct retro_microphone_interface
{
   /**
    * The version of this microphone interface.
    * Set by the core to request a particular version,
    * and set by the frontend to indicate the returned version.
    * 0 indicates that the interface is invalid or uninitialized.
    */
   unsigned interface_version;

   /**
    * Initializes a new microphone.
    * Assuming that microphone support is enabled and provided by the frontend,
    * cores may call this function whenever necessary.
    * A microphone could be opened throughout a core's lifetime,
    * or it could wait until a microphone is plugged in to the emulated device.
    *
    * The returned handle will be valid until it's freed,
    * even if the audio driver is reinitialized.
    *
    * This function is not guaranteed to be thread-safe.
    *
    * @param[in] args Parameters used to create the microphone.
    * May be \c NULL, in which case the default value of each parameter will be used.
    *
    * @returns Pointer to the newly-opened microphone,
    * or \c NULL if one couldn't be opened.
    * This likely means that no microphone is plugged in and recognized,
    * or the maximum number of supported microphones has been reached.
    *
    * @note Microphones are \em inactive by default;
    * to begin capturing audio, call \c set_mic_state.
    * @see retro_microphone_params_t
    */
   retro_open_mic_t open_mic;

   /**
    * Closes a microphone that was initialized with \c open_mic.
    * Calling this function will stop all microphone activity
    * and free up the resources that it allocated.
    * Afterwards, the handle is invalid and must not be used.
    *
    * A frontend may close opened microphones when unloading content,
    * but this behavior is not guaranteed.
    * Cores should close their microphones when exiting, just to be safe.
    *
    * @param microphone Pointer to the microphone that was allocated by \c open_mic.
    * If \c NULL, this function does nothing.
    *
    * @note The handle might be reused if another microphone is opened later.
    */
   retro_close_mic_t close_mic;

   /**
    * Returns the configured parameters of this microphone.
    * These may differ from what was requested depending on
    * the driver and device configuration.
    *
    * Cores should check these values before they start fetching samples.
    *
    * Will not change after the mic was opened.
    *
    * @param[in] microphone Opaque handle to the microphone
    * whose parameters will be retrieved.
    * @param[out] params The parameters object that the
    * microphone's parameters will be copied to.
    *
    * @return \c true if the parameters were retrieved,
    * \c false if there was an error.
    */
   retro_get_mic_params_t get_params;

   /**
    * Enables or disables the given microphone.
    * Microphones are disabled by default
    * and must be explicitly enabled before they can be used.
    * Disabled microphones will not process incoming audio samples,
    * and will therefore have minimal impact on overall performance.
    * Cores may enable microphones throughout their lifetime,
    * or only for periods where they're needed.
    *
    * Cores that accept microphone input should be able to operate without it;
    * we suggest substituting silence in this case.
    *
    * @param microphone Opaque handle to the microphone
    * whose state will be adjusted.
    * This will have been provided by \c open_mic.
    * @param state \c true if the microphone should receive audio input,
    * \c false if it should be idle.
    * @returns \c true if the microphone's state was successfully set,
    * \c false if \c microphone is invalid
    * or if there was an error.
    */
   retro_set_mic_state_t set_mic_state;

   /**
    * Queries the active state of a microphone at the given index.
    * Will return whether the microphone is enabled,
    * even if the driver is paused.
    *
    * @param microphone Opaque handle to the microphone
    * whose state will be queried.
    * @return \c true if the provided \c microphone is valid and active,
    * \c false if not or if there was an error.
    */
   retro_get_mic_state_t get_mic_state;

   /**
    * Retrieves the input processed by the microphone since the last call.
    * \em Must be called every frame unless \c microphone is disabled,
    * similar to how \c retro_audio_sample_batch_t works.
    *
    * @param[in] microphone Opaque handle to the microphone
    * whose recent input will be retrieved.
    * @param[out] samples The buffer that will be used to store the microphone's data.
    * Microphone input is in mono (i.e. one number per sample).
    * Should be large enough to accommodate the expected number of samples per frame;
    * for example, a 44.1kHz sample rate at 60 FPS would require space for 735 samples.
    * @param[in] num_samples The size of the data buffer in samples (\em not bytes).
    * Microphone input is in mono, so a "frame" and a "sample" are equivalent in length here.
    *
    * @return The number of samples that were copied into \c samples.
    * If \c microphone is pending driver initialization,
    * this function will copy silence of the requested length into \c samples.
    *
    * Will return -1 if the microphone is disabled,
    * the audio driver is paused,
    * or there was an error.
    */
   retro_read_mic_t read_mic;
};

/** @} */

/** @defgroup GET_DEVICE_POWER Device Power
 * @{
 */

/**
 * Describes how a device is being powered.
 * @see RETRO_ENVIRONMENT_GET_DEVICE_POWER
 */
enum retro_power_state
{
   /**
    * Indicates that the frontend cannot report its power state at this time,
    * most likely due to a lack of support.
    *
    * \c RETRO_ENVIRONMENT_GET_DEVICE_POWER will not return this value;
    * instead, the environment callback will return \c false.
    */
   RETRO_POWERSTATE_UNKNOWN = 0,

   /**
    * Indicates that the device is running on its battery.
    * Usually applies to portable devices such as handhelds, laptops, and smartphones.
    */
   RETRO_POWERSTATE_DISCHARGING,

   /**
    * Indicates that the device's battery is currently charging.
    */
   RETRO_POWERSTATE_CHARGING,

   /**
    * Indicates that the device is connected to a power source
    * and that its battery has finished charging.
    */
   RETRO_POWERSTATE_CHARGED,

   /**
    * Indicates that the device is connected to a power source
    * and that it does not have a battery.
    * This usually suggests a desktop computer or a non-portable game console.
    */
   RETRO_POWERSTATE_PLUGGED_IN
};

/**
 * Indicates that an estimate is not available for the battery level or time remaining,
 * even if the actual power state is known.
 */
#define RETRO_POWERSTATE_NO_ESTIMATE (-1)

/**
 * Describes the power state of the device running the frontend.
 * @see RETRO_ENVIRONMENT_GET_DEVICE_POWER
 */
struct retro_device_power
{
   /**
    * The current state of the frontend's power usage.
    */
   enum retro_power_state state;

   /**
    * A rough estimate of the amount of time remaining (in seconds)
    * before the device powers off.
    * This value depends on a variety of factors,
    * so it is not guaranteed to be accurate.
    *
    * Will be set to \c RETRO_POWERSTATE_NO_ESTIMATE if \c state does not equal \c RETRO_POWERSTATE_DISCHARGING.
    * May still be set to \c RETRO_POWERSTATE_NO_ESTIMATE if the frontend is unable to provide an estimate.
    */
   int seconds;

   /**
    * The approximate percentage of battery charge,
    * ranging from 0 to 100 (inclusive).
    * The device may power off before this reaches 0.
    *
    * The user might have configured their device
    * to stop charging before the battery is full,
    * so do not assume that this will be 100 in the \c RETRO_POWERSTATE_CHARGED state.
    */
   int8_t percent;
};

/** @} */

/**
 * @defgroup Callbacks
 * @{
 */

/**
 * Environment callback to give implementations a way of performing uncommon tasks.
 *
 * @note Extensible.
 *
 * @param cmd The command to run.
 * @param data A pointer to the data associated with the command.
 *
 * @return Varies by callback,
 * but will always return \c false if the command is not recognized.
 *
 * @see RETRO_ENVIRONMENT_SET_ROTATION
 * @see retro_set_environment()
 */
typedef bool (RETRO_CALLCONV *retro_environment_t)(unsigned cmd, void *data);

/**
 * Render a frame.
 *
 * @note For performance reasons, it is highly recommended to have a frame
 * that is packed in memory, i.e. pitch == width * byte_per_pixel.
 * Certain graphic APIs, such as OpenGL ES, do not like textures
 * that are not packed in memory.
 *
 * @param data A pointer to the frame buffer data with a pixel format of 15-bit \c 0RGB1555 native endian, unless changed with \c RETRO_ENVIRONMENT_SET_PIXEL_FORMAT.
 * @param width The width of the frame buffer, in pixels.
 * @param height The height frame buffer, in pixels.
 * @param pitch The width of the frame buffer, in bytes.
 *
 * @see retro_set_video_refresh()
 * @see RETRO_ENVIRONMENT_SET_PIXEL_FORMAT
 * @see retro_pixel_format
 */
typedef void (RETRO_CALLCONV *retro_video_refresh_t)(const void *data, unsigned width,
      unsigned height, size_t pitch);

/**
 * Renders a single audio frame. Should only be used if implementation generates a single sample at a time.
 *
 * @param left The left audio sample represented as a signed 16-bit native endian.
 * @param right The right audio sample represented as a signed 16-bit native endian.
 *
 * @see retro_set_audio_sample()
 * @see retro_set_audio_sample_batch()
 */
typedef void (RETRO_CALLCONV *retro_audio_sample_t)(int16_t left, int16_t right);

/**
 * Renders multiple audio frames in one go.
 *
 * @note Only one of the audio callbacks must ever be used.
 *
 * @param data A pointer to the audio sample data pairs to render.
 * @param frames The number of frames that are represented in the data. One frame
 *     is defined as a sample of left and right channels, interleaved.
 *     For example: <tt>int16_t buf[4] = { l, r, l, r };</tt> would be 2 frames.
 *
 * @return The number of frames that were processed.
 *
 * @see retro_set_audio_sample_batch()
 * @see retro_set_audio_sample()
 */
typedef size_t (RETRO_CALLCONV *retro_audio_sample_batch_t)(const int16_t *data,
      size_t frames);

/**
 * Polls input.
 *
 * @see retro_set_input_poll()
 */
typedef void (RETRO_CALLCONV *retro_input_poll_t)(void);

/**
 * Queries for input for player 'port'.
 *
 * @param port Which player 'port' to query.
 * @param device Which device to query for. Will be masked with \c RETRO_DEVICE_MASK.
 * @param index The input index to retrieve.
 * The exact semantics depend on the device type given in \c device.
 * @param id The ID of which value to query, like \c RETRO_DEVICE_ID_JOYPAD_B.
 * @returns Depends on the provided arguments,
 * but will return 0 if their values are unsupported
 * by the frontend or the backing physical device.
 * @note Specialization of devices such as \c RETRO_DEVICE_JOYPAD_MULTITAP that
 * have been set with \c retro_set_controller_port_device() will still use the
 * higher level \c RETRO_DEVICE_JOYPAD to request input.
 *
 * @see retro_set_input_state()
 * @see RETRO_DEVICE_NONE
 * @see RETRO_DEVICE_JOYPAD
 * @see RETRO_DEVICE_MOUSE
 * @see RETRO_DEVICE_KEYBOARD
 * @see RETRO_DEVICE_LIGHTGUN
 * @see RETRO_DEVICE_ANALOG
 * @see RETRO_DEVICE_POINTER
 */
typedef int16_t (RETRO_CALLCONV *retro_input_state_t)(unsigned port, unsigned device,
      unsigned index, unsigned id);

/**
 * Sets the environment callback.
 *
 * @param cb The function which is used when making environment calls.
 *
 * @note Guaranteed to be called before \c retro_init().
 *
 * @see RETRO_ENVIRONMENT
 */
RETRO_API void retro_set_environment(retro_environment_t cb);

/**
 * Sets the video refresh callback.
 *
 * @param cb The function which is used when rendering a frame.
 *
 * @note Guaranteed to have been called before the first call to \c retro_run() is made.
 */
RETRO_API void retro_set_video_refresh(retro_video_refresh_t cb);

/**
 * Sets the audio sample callback.
 *
 * @param cb The function which is used when rendering a single audio frame.
 *
 * @note Guaranteed to have been called before the first call to \c retro_run() is made.
 */
RETRO_API void retro_set_audio_sample(retro_audio_sample_t cb);

/**
 * Sets the audio sample batch callback.
 *
 * @param cb The function which is used when rendering multiple audio frames in one go.
 *
 * @note Guaranteed to have been called before the first call to \c retro_run() is made.
 */
RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb);

/**
 * Sets the input poll callback.
 *
 * @param cb The function which is used to poll the active input.
 *
 * @note Guaranteed to have been called before the first call to \c retro_run() is made.
 */
RETRO_API void retro_set_input_poll(retro_input_poll_t cb);

/**
 * Sets the input state callback.
 *
 * @param cb The function which is used to query the input state.
 *
 *@note Guaranteed to have been called before the first call to \c retro_run() is made.
 */
RETRO_API void retro_set_input_state(retro_input_state_t cb);

/**
 * @}
 */

/**
 * Called by the frontend when initializing a libretro core.
 *
 * @warning There are many possible "gotchas" with global state in dynamic libraries.
 * Here are some to keep in mind:
 * <ul>
 * <li>Do not assume that the core was loaded by the operating system
 * for the first time within this call.
 * It may have been statically linked or retained from a previous session.
 * Consequently, cores must not rely on global variables being initialized
 * to their default values before this function is called;
 * this also goes for object constructors in C++.
 * <li>Although C++ requires that constructors be called for global variables,
 * it does not require that their destructors be called
 * if stored within a dynamic library's global scope.
 * <li>If the core is statically linked to the frontend,
 * global variables may be initialized when the frontend itself is initially executed.
 * </ul>
 * @see retro_deinit
 */
RETRO_API void retro_init(void);

/**
 * Called by the frontend when deinitializing a libretro core.
 * The core must release all of its allocated resources before this function returns.
 *
 * @warning There are many possible "gotchas" with global state in dynamic libraries.
 * Here are some to keep in mind:
 * <ul>
 * <li>Do not assume that the operating system will unload the core after this function returns,
 * as the core may be linked statically or retained in memory.
 * Cores should use this function to clean up all allocated resources
 * and reset all global variables to their default states.
 * <li>Do not assume that this core won't be loaded again after this function returns.
 * It may be kept in memory by the frontend for later use,
 * or it may be statically linked.
 * Therefore, all global variables should be reset to their default states within this function.
 * <li>C++ does not require that destructors be called
 * for variables within a dynamic library's global scope.
 * Therefore, global objects that own dynamically-managed resources
 * (such as \c std::string or <tt>std::vector</tt>)
 * should be kept behind pointers that are explicitly deallocated within this function.
 * </ul>
 * @see retro_init
 */
RETRO_API void retro_deinit(void);

/**
 * Retrieves which version of the libretro API is being used.
 *
 * @note This is used to validate ABI compatibility when the API is revised.
 *
 * @return Must return \c RETRO_API_VERSION.
 *
 * @see RETRO_API_VERSION
 */
RETRO_API unsigned retro_api_version(void);

/**
 * Gets statically known system info.
 *
 * @note Can be called at any time, even before retro_init().
 *
 * @param info A pointer to a \c retro_system_info where the info is to be loaded into. This must be statically allocated.
 */
RETRO_API void retro_get_system_info(struct retro_system_info *info);

/**
 * Gets information about system audio/video timings and geometry.
 *
 * @note Can be called only after \c retro_load_game() has successfully completed.
 *
 * @note The implementation of this function might not initialize every variable
 * if needed. For example, \c geom.aspect_ratio might not be initialized if
 * the core doesn't desire a particular aspect ratio.
 *
 * @param info A pointer to a \c retro_system_av_info where the audio/video information should be loaded into.
 *
 * @see retro_system_av_info
 */
RETRO_API void retro_get_system_av_info(struct retro_system_av_info *info);

/**
 * Sets device to be used for player 'port'.
 *
 * By default, \c RETRO_DEVICE_JOYPAD is assumed to be plugged into all
 * available ports.
 *
 * @note Setting a particular device type is not a guarantee that libretro cores
 * will only poll input based on that particular device type. It is only a
 * hint to the libretro core when a core cannot automatically detect the
 * appropriate input device type on its own. It is also relevant when a
 * core can change its behavior depending on device type.
 *
 * @note As part of the core's implementation of retro_set_controller_port_device,
 * the core should call \c RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS to notify the
 * frontend if the descriptions for any controls have changed as a
 * result of changing the device type.
 *
 * @param port Which port to set the device for, usually indicates the player number.
 * @param device Which device the given port is using. By default, \c RETRO_DEVICE_JOYPAD is assumed for all ports.
 *
 * @see RETRO_DEVICE_NONE
 * @see RETRO_DEVICE_JOYPAD
 * @see RETRO_DEVICE_MOUSE
 * @see RETRO_DEVICE_KEYBOARD
 * @see RETRO_DEVICE_LIGHTGUN
 * @see RETRO_DEVICE_ANALOG
 * @see RETRO_DEVICE_POINTER
 * @see RETRO_ENVIRONMENT_SET_CONTROLLER_INFO
 */
RETRO_API void retro_set_controller_port_device(unsigned port, unsigned device);

/**
 * Resets the currently-loaded game.
 * Cores should treat this as a soft reset (i.e. an emulated reset button) if possible,
 * but hard resets are acceptable.
 */
RETRO_API void retro_reset(void);

/**
 * Runs the game for one video frame.
 *
 * During \c retro_run(), the \c retro_input_poll_t callback must be called at least once.
 *
 * @note If a frame is not rendered for reasons where a game "dropped" a frame,
 * this still counts as a frame, and \c retro_run() should explicitly dupe
 * a frame if \c RETRO_ENVIRONMENT_GET_CAN_DUPE returns true. In this case,
 * the video callback can take a NULL argument for data.
 *
 * @see retro_input_poll_t
 */
RETRO_API void retro_run(void);

/**
 * Returns the amount of data the implementation requires to serialize internal state (save states).
 *
 * @note Between calls to \c retro_load_game() and \c retro_unload_game(), the
 * returned size is never allowed to be larger than a previous returned
 * value, to ensure that the frontend can allocate a save state buffer once.
 *
 * @return The amount of data the implementation requires to serialize the internal state.
 *
 * @see retro_serialize()
 */
RETRO_API size_t retro_serialize_size(void);

/**
 * Serializes the internal state.
 *
 * @param data A pointer to where the serialized data should be saved to.
 * @param size The size of the memory.
 *
 * @return If failed, or size is lower than \c retro_serialize_size(), it
 * should return false. On success, it will return true.
 *
 * @see retro_serialize_size()
 * @see retro_unserialize()
 */
RETRO_API bool retro_serialize(void *data, size_t len);

/**
 * Unserialize the given state data, and load it into the internal state.
 *
 * @return Returns true if loading the state was successful, false otherwise.
 *
 * @see retro_serialize()
 */
RETRO_API bool retro_unserialize(const void *data, size_t len);

/**
 * Reset all the active cheats to their default disabled state.
 *
 * @see retro_cheat_set()
 */
RETRO_API void retro_cheat_reset(void);

/**
 * Enable or disable a cheat.
 *
 * @param index The index of the cheat to act upon.
 * @param enabled Whether to enable or disable the cheat.
 * @param code A string of the code used for the cheat.
 *
 * @see retro_cheat_reset()
 */
RETRO_API void retro_cheat_set(unsigned index, bool enabled, const char *code);

/**
 * Loads a game.
 *
 * @param game A pointer to a \c retro_game_info detailing information about the game to load.
 * May be \c NULL if the core is loaded without content.
 *
 * @return Will return true when the game was loaded successfully, or false otherwise.
 *
 * @see retro_game_info
 * @see RETRO_ENVIRONMENT_SET_SUPPORT_NO_GAME
 */
RETRO_API bool retro_load_game(const struct retro_game_info *game);

/**
 * Called when the frontend has loaded one or more "special" content files,
 * typically through subsystems.
 *
 * @note Only necessary for cores that support subsystems.
 * Others may return \c false or delegate to <tt>retro_load_game</tt>.
 *
 * @param game_type The type of game to load,
 * as determined by \c retro_subsystem_info.
 * @param info A pointer to an array of \c retro_game_info objects
 * providing information about the loaded content.
 * @param num_info The number of \c retro_game_info objects passed into the info parameter.
 * @return \c true if loading is successful, false otherwise.
 * If the core returns \c false,
 * the frontend should abort the core
 * and return to its main menu (if applicable).
 *
 * @see RETRO_ENVIRONMENT_GET_GAME_INFO_EXT
 * @see RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO
 * @see retro_load_game()
 * @see retro_subsystem_info
 */
RETRO_API bool retro_load_game_special(
  unsigned game_type,
  const struct retro_game_info *info, size_t num_info
);

/**
 * Unloads the currently loaded game.
 *
 * @note This is called before \c retro_deinit(void).
 *
 * @see retro_load_game()
 * @see retro_deinit()
 */
RETRO_API void retro_unload_game(void);

/**
 * Gets the region of the actively loaded content as either \c RETRO_REGION_NTSC or \c RETRO_REGION_PAL.
 * @note This refers to the region of the content's intended television standard,
 * not necessarily the region of the content's origin.
 * For emulated consoles that don't use either standard
 * (e.g. handhelds or post-HD platforms),
 * the core should return \c RETRO_REGION_NTSC.
 * @return The region of the actively loaded content.
 *
 * @see RETRO_REGION_NTSC
 * @see RETRO_REGION_PAL
 */
RETRO_API unsigned retro_get_region(void);

/**
 * Get a region of memory.
 *
 * @param id The ID for the memory block that's desired to retrieve. Can be \c RETRO_MEMORY_SAVE_RAM, \c RETRO_MEMORY_RTC, \c RETRO_MEMORY_SYSTEM_RAM, or \c RETRO_MEMORY_VIDEO_RAM.
 *
 * @return A pointer to the desired region of memory, or NULL when not available.
 *
 * @see RETRO_MEMORY_SAVE_RAM
 * @see RETRO_MEMORY_RTC
 * @see RETRO_MEMORY_SYSTEM_RAM
 * @see RETRO_MEMORY_VIDEO_RAM
 */
RETRO_API void *retro_get_memory_data(unsigned id);

/**
 * Gets the size of the given region of memory.
 *
 * @param id The ID for the memory block to check the size of. Can be RETRO_MEMORY_SAVE_RAM, RETRO_MEMORY_RTC, RETRO_MEMORY_SYSTEM_RAM, or RETRO_MEMORY_VIDEO_RAM.
 *
 * @return The size of the region in memory, or 0 when not available.
 *
 * @see RETRO_MEMORY_SAVE_RAM
 * @see RETRO_MEMORY_RTC
 * @see RETRO_MEMORY_SYSTEM_RAM
 * @see RETRO_MEMORY_VIDEO_RAM
 */
RETRO_API size_t retro_get_memory_size(unsigned id);

#ifdef __cplusplus
}
#endif

#endif
PATCHEND
mkdir -p 'src/goosestation-libretro'
# Add: src/goosestation-libretro/libretro_opengl_context.h
cat > 'src/goosestation-libretro/libretro_opengl_context.h' <<'PATCHEND'
// GooseStation — libretro OpenGL context wrapper
// SPDX-License-Identifier: GPL-2.0-or-later

#pragma once

#include "libretro.h"
#include "util/opengl_context.h"

// Wraps RetroArch's OpenGL context for use by DuckStation's OpenGLDevice.
// All surface/swap operations are no-ops since RetroArch owns the context.
class LibretroOpenGLContext final : public OpenGLContext
{
public:
  LibretroOpenGLContext(retro_hw_get_proc_address_t get_proc_address)
    : m_get_proc_address(get_proc_address)
  {
#ifdef __ANDROID__
    // Android uses a GLES3 context; desktop-GL glad would leave glGenSamplers et al. null.
    m_version = {Profile::ES, 3, 0};
#else
    m_version = {Profile::Core, 3, 3};
#endif
  }

  ~LibretroOpenGLContext() override = default;

  void* GetProcAddress(const char* name) override
  {
    return reinterpret_cast<void*>(m_get_proc_address(name));
  }

  SurfaceHandle CreateSurface(WindowInfo& wi, Error* error) override { return MAIN_SURFACE; }
  void DestroySurface(SurfaceHandle handle) override {}
  void ResizeSurface(WindowInfo& wi, SurfaceHandle handle) override {}
  bool SwapBuffers() override { return true; }
  bool IsCurrent() const override { return true; }
  bool MakeCurrent(SurfaceHandle surface, Error* error) override { return true; }
  bool DoneCurrent() override { return true; }
  bool SupportsNegativeSwapInterval() const override { return false; }
  bool SetSwapInterval(s32 interval, Error* error) override { return true; }

  std::unique_ptr<OpenGLContext> CreateSharedContext(WindowInfo& wi, SurfaceHandle* surface, Error* error) override
  {
    return nullptr;
  }

private:
  retro_hw_get_proc_address_t m_get_proc_address;
};
PATCHEND
mkdir -p 'src/goosestation-libretro'
# Add: src/goosestation-libretro/libretro_vulkan.h
cat > 'src/goosestation-libretro/libretro_vulkan.h' <<'PATCHEND'
/* Copyright (C) 2010-2020 The RetroArch team
 *
 * ---------------------------------------------------------------------------------------------
 * The following license statement only applies to this libretro API header (libretro_vulkan.h)
 * ---------------------------------------------------------------------------------------------
 *
 * Permission is hereby granted, free of charge,
 * to any person obtaining a copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation the rights to
 * use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software,
 * and to permit persons to whom the Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
 * INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#ifndef LIBRETRO_VULKAN_H__
#define LIBRETRO_VULKAN_H__

#include <libretro.h>
#include <vulkan/vulkan.h>

#define RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION 5
#define RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION 2

struct retro_vulkan_image
{
   VkImageView image_view;
   VkImageLayout image_layout;
   VkImageViewCreateInfo create_info;
};

typedef void (*retro_vulkan_set_image_t)(void *handle,
      const struct retro_vulkan_image *image,
      uint32_t num_semaphores,
      const VkSemaphore *semaphores,
      uint32_t src_queue_family);

typedef uint32_t (*retro_vulkan_get_sync_index_t)(void *handle);
typedef uint32_t (*retro_vulkan_get_sync_index_mask_t)(void *handle);
typedef void (*retro_vulkan_set_command_buffers_t)(void *handle,
      uint32_t num_cmd,
      const VkCommandBuffer *cmd);
typedef void (*retro_vulkan_wait_sync_index_t)(void *handle);
typedef void (*retro_vulkan_lock_queue_t)(void *handle);
typedef void (*retro_vulkan_unlock_queue_t)(void *handle);
typedef void (*retro_vulkan_set_signal_semaphore_t)(void *handle, VkSemaphore semaphore);

typedef const VkApplicationInfo *(*retro_vulkan_get_application_info_t)(void);

struct retro_vulkan_context
{
   VkPhysicalDevice gpu;
   VkDevice device;
   VkQueue queue;
   uint32_t queue_family_index;
   VkQueue presentation_queue;
   uint32_t presentation_queue_family_index;
};

/* This is only used in v1 of the negotiation interface.
 * It is deprecated since it cannot express PDF2 features or optional extensions. */
typedef bool (*retro_vulkan_create_device_t)(
      struct retro_vulkan_context *context,
      VkInstance instance,
      VkPhysicalDevice gpu,
      VkSurfaceKHR surface,
      PFN_vkGetInstanceProcAddr get_instance_proc_addr,
      const char **required_device_extensions,
      unsigned num_required_device_extensions,
      const char **required_device_layers,
      unsigned num_required_device_layers,
      const VkPhysicalDeviceFeatures *required_features);

typedef void (*retro_vulkan_destroy_device_t)(void);

/* v2 CONTEXT_NEGOTIATION_INTERFACE only. */
typedef VkInstance (*retro_vulkan_create_instance_wrapper_t)(
      void *opaque, const VkInstanceCreateInfo *create_info);

/* v2 CONTEXT_NEGOTIATION_INTERFACE only. */
typedef VkInstance (*retro_vulkan_create_instance_t)(
      PFN_vkGetInstanceProcAddr get_instance_proc_addr,
      const VkApplicationInfo *app,
      retro_vulkan_create_instance_wrapper_t create_instance_wrapper,
      void *opaque);

/* v2 CONTEXT_NEGOTIATION_INTERFACE only. */
typedef VkDevice (*retro_vulkan_create_device_wrapper_t)(
      VkPhysicalDevice gpu, void *opaque,
      const VkDeviceCreateInfo *create_info);

/* v2 CONTEXT_NEGOTIATION_INTERFACE only. */
typedef bool (*retro_vulkan_create_device2_t)(
      struct retro_vulkan_context *context,
      VkInstance instance,
      VkPhysicalDevice gpu,
      VkSurfaceKHR surface,
      PFN_vkGetInstanceProcAddr get_instance_proc_addr,
      retro_vulkan_create_device_wrapper_t create_device_wrapper,
      void *opaque);

/* Note on thread safety:
 * The Vulkan API is heavily designed around multi-threading, and
 * the libretro interface for it should also be threading friendly.
 * A core should be able to build command buffers and submit
 * command buffers to the GPU from any thread.
 */

struct retro_hw_render_context_negotiation_interface_vulkan
{
   /* Must be set to RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN. */
   enum retro_hw_render_context_negotiation_interface_type interface_type;
   /* Usually set to RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN_VERSION,
    * but can be lower depending on GET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_SUPPORT. */
   unsigned interface_version;

   /* If non-NULL, returns a VkApplicationInfo struct that the frontend can use instead of
    * its "default" application info.
    * VkApplicationInfo::apiVersion also controls the target core Vulkan version for instance level functionality.
    * Lifetime of the returned pointer must remain until the retro_vulkan_context is initialized.
    *
    * NOTE: For optimal compatibility with e.g. Android which is very slow to update its loader,
    * a core version of 1.1 should be requested. Features beyond that can be requested with extensions.
    * Vulkan 1.0 is only appropriate for legacy cores, but is still supported.
    * A frontend is free to bump the instance creation apiVersion as necessary if the frontend requires more advanced core features.
    *
    * v2: This function must not be NULL, and must not return NULL.
    * v1: It was not clearly defined if this function could return NULL.
    *     Frontends should be defensive and provide a default VkApplicationInfo
    *     if this function returns NULL or if this function is NULL.
    */
   retro_vulkan_get_application_info_t get_application_info;

   /* If non-NULL, the libretro core will choose one or more physical devices,
    * create one or more logical devices and create one or more queues.
    * The core must prepare a designated PhysicalDevice, Device, Queue and queue family index
    * which the frontend will use for its internal operation.
    *
    * If gpu is not VK_NULL_HANDLE, the physical device provided to the frontend must be this PhysicalDevice if the call succeeds.
    * The core is still free to use other physical devices for other purposes that are private to the core.
    *
    * The frontend will request certain extensions and layers for a device which is created.
    * The core must ensure that the queue and queue_family_index support GRAPHICS and COMPUTE.
    *
    * If surface is not VK_NULL_HANDLE, the core must consider presentation when creating the queues.
    * If presentation to "surface" is supported on the queue, presentation_queue must be equal to queue.
    * If not, a second queue must be provided in presentation_queue and presentation_queue_index.
    * If surface is not VK_NULL_HANDLE, the instance from frontend will have been created with supported for
    * VK_KHR_surface extension.
    *
    * The core is free to set its own queue priorities.
    * Device provided to frontend is owned by the frontend, but any additional device resources must be freed by core
    * in destroy_device callback.
    *
    * If this function returns true, a PhysicalDevice, Device and Queues are initialized.
    * If false, none of the above have been initialized and the frontend will attempt
    * to fallback to "default" device creation, as if this function was never called.
    */
   retro_vulkan_create_device_t create_device;

   /* If non-NULL, this callback is called similar to context_destroy for HW_RENDER_INTERFACE.
    * However, it will be called even if context_reset was not called.
    * This can happen if the context never succeeds in being created.
    * destroy_device will always be called before the VkInstance
    * of the frontend is destroyed if create_device was called successfully so that the core has a chance of
    * tearing down its own device resources.
    *
    * Only auxiliary resources should be freed here, i.e. resources which are not part of retro_vulkan_context.
    * v2: Auxiliary instance resources created during create_instance can also be freed here.
    */
   retro_vulkan_destroy_device_t destroy_device;

   /* v2 API: If interface_version is < 2, fields below must be ignored.
    * If the frontend does not support interface version 2, the v1 entry points will be used instead. */

   /* If non-NULL, this is called to create an instance, otherwise a VkInstance is created by the frontend.
    * v1 interface bug: The only way to enable instance features is through core versions signalled in VkApplicationInfo.
    * The frontend may request that certain extensions and layers
    * are enabled on the VkInstance. Application may add additional features.
    * If app is non-NULL, apiVersion controls the minimum core version required by the application.
    * Return a VkInstance or VK_NULL_HANDLE. The VkInstance is owned by the frontend.
    *
    * Rather than call vkCreateInstance directly, a core must call the CreateInstance wrapper provided with:
    * VkInstance instance = create_instance_wrapper(opaque, &create_info);
    * If the core wishes to create a private instance for whatever reason (relying on shared memory for example),
    * it may call vkCreateInstance directly. */
   retro_vulkan_create_instance_t create_instance;

   /* If non-NULL and frontend recognizes negotiation interface >= 2, create_device2 takes precedence over create_device.
    * Similar to create_device, but is extended to better understand new core versions and PDF2 feature enablement.
    * Requirements for create_device2 are the same as create_device unless a difference is mentioned.
    *
    * v2 consideration:
    * If the chosen gpu by frontend cannot be supported, a core must return false.
    *
    * NOTE: "Cannot be supported" is intentionally vaguely defined.
    * Refusing to run on an iGPU for a very intensive core with desktop GPU as a minimum spec may be in the gray area.
    * Not supporting optional features is not a good reason to reject a physical device, however.
    *
    * On device creation feature with explicit gpu, a frontend should fall back create_device2 with gpu == VK_NULL_HANDLE and let core
    * decide on a supported device if possible.
    *
    * A core must assume that the explicitly provided GPU is the only guaranteed attempt it has to create a device.
    * A fallback may not be attempted if there are particular reasons why only a specific physical device can work,
    * but these situations should be esoteric and rare in nature, e.g. a libretro frontend is implemented with external memory
    * and only LUID matching would work.
    * Cores and frontends should ensure "best effort" when negotiating like this and appropriate logging is encouraged.
    *
    * v1 note: In the v1 version of create_device, it was never expected that create_device would fail like this,
    * and frontends are not expected to attempt fall backs.
    *
    * Rather than call vkCreateDevice directly, a core must call the CreateDevice wrapper provided with:
    * VkDevice device = create_device_wrapper(gpu, opaque, &create_info);
    * If the core wishes to create a private device for whatever reason (relying on shared memory for example),
    * it may call vkCreateDevice directly.
    *
    * This allows the frontend to add additional extensions that it requires as well as adjust the PDF2 pNext as required.
    * It is also possible adjust the queue create infos in case the frontend desires to allocate some private queues.
    *
    * The get_instance_proc_addr provided in create_device2 must be the same as create_instance.
    *
    * NOTE: The frontend must not disable features requested by application.
    * NOTE: The frontend must not add any robustness features as some API behavior may change (VK_EXT_descriptor_buffer comes to mind).
    * I.e. robustBufferAccess and the like. (nullDescriptor from robustness2 is allowed to be enabled).
    */
   retro_vulkan_create_device2_t create_device2;
};

struct retro_hw_render_interface_vulkan
{
   /* Must be set to RETRO_HW_RENDER_INTERFACE_VULKAN. */
   enum retro_hw_render_interface_type interface_type;
   /* Must be set to RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION. */
   unsigned interface_version;

   /* Opaque handle to the Vulkan backend in the frontend
    * which must be passed along to all function pointers
    * in this interface.
    *
    * The rationale for including a handle here (which libretro v1
    * doesn't currently do in general) is:
    *
    * - Vulkan cores should be able to be freely threaded without lots of fuzz.
    *   This would break frontends which currently rely on TLS
    *   to deal with multiple cores loaded at the same time.
    * - Fixing this in general is TODO for an eventual libretro v2.
    */
   void *handle;

   /* The Vulkan instance the context is using. */
   VkInstance instance;
   /* The physical device used. */
   VkPhysicalDevice gpu;
   /* The logical device used. */
   VkDevice device;

   /* Allows a core to fetch all its needed symbols without having to link
    * against the loader itself. */
   PFN_vkGetDeviceProcAddr get_device_proc_addr;
   PFN_vkGetInstanceProcAddr get_instance_proc_addr;

   /* The queue the core must use to submit data.
    * This queue and index must remain constant throughout the lifetime
    * of the context.
    *
    * This queue will be the queue that supports graphics and compute
    * if the device supports compute.
    */
   VkQueue queue;
   unsigned queue_index;

   /* Before calling retro_video_refresh_t with RETRO_HW_FRAME_BUFFER_VALID,
    * set which image to use for this frame.
    *
    * If num_semaphores is non-zero, the frontend will wait for the
    * semaphores provided to be signaled before using the results further
    * in the pipeline.
    *
    * Semaphores provided by a single call to set_image will only be
    * waited for once (waiting for a semaphore resets it).
    * E.g. set_image, video_refresh, and then another
    * video_refresh without set_image,
    * but same image will only wait for semaphores once.
    *
    * For this reason, ownership transfer will only occur if semaphores
    * are waited on for a particular frame in the frontend.
    *
    * Using semaphores is optional for synchronization purposes,
    * but if not using
    * semaphores, an image memory barrier in vkCmdPipelineBarrier
    * should be used in the graphics_queue.
    * Example:
    *
    * vkCmdPipelineBarrier(cmd,
    *    srcStageMask = VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT,
    *    dstStageMask = VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    *    image_memory_barrier = {
    *       srcAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
    *       dstAccessMask = VK_ACCESS_SHADER_READ_BIT,
    *    });
    *
    * The use of pipeline barriers instead of semaphores is encouraged
    * as it is simpler and more fine-grained. A layout transition
    * must generally happen anyways which requires a
    * pipeline barrier.
    *
    * The image passed to set_image must have imageUsage flags set to at least
    * VK_IMAGE_USAGE_TRANSFER_SRC_BIT and VK_IMAGE_USAGE_SAMPLED_BIT.
    * The core will naturally want to use flags such as
    * VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT and/or
    * VK_IMAGE_USAGE_TRANSFER_DST_BIT depending
    * on how the final image is created.
    *
    * The image must also have been created with MUTABLE_FORMAT bit set if
    * 8-bit formats are used, so that the frontend can reinterpret sRGB
    * formats as it sees fit.
    *
    * Images passed to set_image should be created with TILING_OPTIMAL.
    * The image layout should be transitioned to either
    * VK_IMAGE_LAYOUT_GENERIC or VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL.
    * The actual image layout used must be set in image_layout.
    *
    * The image must be a 2D texture which may or not be layered
    * and/or mipmapped.
    *
    * The image must be suitable for linear sampling.
    * While the image_view is typically the only field used,
    * the frontend may want to reinterpret the texture as sRGB vs.
    * non-sRGB for example so the VkImageViewCreateInfo used to
    * create the image view must also be passed in.
    *
    * The data in the pointer to the image struct will not be copied
    * as the pNext field in create_info cannot be reliably deep-copied.
    * The image pointer passed to set_image must be valid until
    * retro_video_refresh_t has returned.
    *
    * If frame duping is used when passing NULL to retro_video_refresh_t,
    * the frontend is free to either use the latest image passed to
    * set_image or reuse the older pointer passed to set_image the
    * frame RETRO_HW_FRAME_BUFFER_VALID was last used.
    *
    * Essentially, the lifetime of the pointer passed to
    * retro_video_refresh_t should be extended if frame duping is used
    * so that the frontend can reuse the older pointer.
    *
    * The image itself however, must not be touched by the core until
    * wait_sync_index has been completed later. The frontend may perform
    * layout transitions on the image, so even read-only access is not defined.
    * The exception to read-only rule is if GENERAL layout is used for the image.
    * In this case, the frontend is not allowed to perform any layout transitions,
    * so concurrent reads from core and frontend are allowed.
    *
    * If frame duping is used, or if set_command_buffers is used,
    * the frontend will not wait for any semaphores.
    *
    * The src_queue_family is used to specify which queue family
    * the image is currently owned by. If using multiple queue families
    * (e.g. async compute), the frontend will need to acquire ownership of the
    * image before rendering with it and release the image afterwards.
    *
    * If src_queue_family is equal to the queue family (queue_index),
    * no ownership transfer will occur.
    * Similarly, if src_queue_family is VK_QUEUE_FAMILY_IGNORED,
    * no ownership transfer will occur.
    *
    * The frontend will always release ownership back to src_queue_family.
    * Waiting for frontend to complete with wait_sync_index() ensures that
    * the frontend has released ownership back to the application.
    * Note that in Vulkan, transferring ownership is a two-part process.
    *
    * Example frame:
    *  - core releases ownership from src_queue_index to queue_index with VkImageMemoryBarrier.
    *  - core calls set_image with src_queue_index.
    *  - Frontend will acquire the image with src_queue_index -> queue_index as well, completing the ownership transfer.
    *  - Frontend renders the frame.
    *  - Frontend releases ownership with queue_index -> src_queue_index.
    *  - Next time image is used, core must acquire ownership from queue_index ...
    *
    * Since the frontend releases ownership, we cannot necessarily dupe the frame because
    * the core needs to make the roundtrip of ownership transfer.
    */
   retro_vulkan_set_image_t set_image;

   /* Get the current sync index for this frame which is obtained in
    * frontend by calling e.g. vkAcquireNextImageKHR before calling
    * retro_run().
    *
    * This index will correspond to which swapchain buffer is currently
    * the active one.
    *
    * Knowing this index is very useful for maintaining safe asynchronous CPU
    * and GPU operation without stalling.
    *
    * The common pattern for synchronization is to receive fences when
    * submitting command buffers to Vulkan (vkQueueSubmit) and add this fence
    * to a list of fences for frame number get_sync_index().
    *
    * Next time we receive the same get_sync_index(), we can wait for the
    * fences from before, which will usually return immediately as the
    * frontend will generally also avoid letting the GPU run ahead too much.
    *
    * After the fence has signaled, we know that the GPU has completed all
    * GPU work related to work submitted in the frame we last saw get_sync_index().
    *
    * This means we can safely reuse or free resources allocated in this frame.
    *
    * In theory, even if we wait for the fences correctly, it is not technically
    * safe to write to the image we earlier passed to the frontend since we're
    * not waiting for the frontend GPU jobs to complete.
    *
    * The frontend will guarantee that the appropriate pipeline barrier
    * in graphics_queue has been used such that
    * VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT cannot
    * start until the frontend is done with the image.
    */
   retro_vulkan_get_sync_index_t get_sync_index;

   /* Returns a bitmask of how many swapchain images we currently have
    * in the frontend.
    *
    * If bit #N is set in the return value, get_sync_index can return N.
    * Knowing this value is useful for preallocating per-frame management
    * structures ahead of time.
    *
    * While this value will typically remain constant throughout the
    * applications lifecycle, it may for example change if the frontend
    * suddenly changes fullscreen state and/or latency.
    *
    * If this value ever changes, it is safe to assume that the device
    * is completely idle and all synchronization objects can be deleted
    * right away as desired.
    */
   retro_vulkan_get_sync_index_mask_t get_sync_index_mask;

   /* Instead of submitting the command buffer to the queue first, the core
    * can pass along its command buffer to the frontend, and the frontend
    * will submit the command buffer together with the frontends command buffers.
    *
    * This has the advantage that the overhead of vkQueueSubmit can be
    * amortized into a single call. For this mode, semaphores in set_image
    * will be ignored, so vkCmdPipelineBarrier must be used to synchronize
    * the core and frontend.
    *
    * The command buffers in set_command_buffers are only executed once,
    * even if frame duping is used.
    *
    * If frame duping is used, set_image should be used for the frames
    * which should be duped instead.
    *
    * Command buffers passed to the frontend with set_command_buffers
    * must not actually be submitted to the GPU until retro_video_refresh_t
    * is called.
    *
    * The frontend must submit the command buffer before submitting any
    * other command buffers provided by set_command_buffers. */
   retro_vulkan_set_command_buffers_t set_command_buffers;

   /* Waits on CPU for device activity for the current sync index to complete.
    * This is useful since the core will not have a relevant fence to sync with
    * when the frontend is submitting the command buffers. */
   retro_vulkan_wait_sync_index_t wait_sync_index;

   /* If the core submits command buffers itself to any of the queues provided
    * in this interface, the core must lock and unlock the frontend from
    * racing on the VkQueue.
    *
    * Queue submission can happen on any thread.
    * Even if queue submission happens on the same thread as retro_run(),
    * the lock/unlock functions must still be called.
    *
    * NOTE: Queue submissions are heavy-weight. */
   retro_vulkan_lock_queue_t lock_queue;
   retro_vulkan_unlock_queue_t unlock_queue;

   /* Sets a semaphore which is signaled when the image in set_image can safely be reused.
    * The semaphore is consumed next call to retro_video_refresh_t.
    * The semaphore will be signalled even for duped frames.
    * The semaphore will be signalled only once, so set_signal_semaphore should be called every frame.
    * The semaphore may be VK_NULL_HANDLE, which disables semaphore signalling for next call to retro_video_refresh_t.
    *
    * This is mostly useful to support use cases where you're rendering to a single image that
    * is recycled in a ping-pong fashion with the frontend to save memory (but potentially less throughput).
    */
   retro_vulkan_set_signal_semaphore_t set_signal_semaphore;
};

#endif
PATCHEND
mkdir -p 'src/goosestation-libretro'
# Add: src/goosestation-libretro/link.T
cat > 'src/goosestation-libretro/link.T' <<'PATCHEND'
{
  global: retro_*;
  local: *;
};
PATCHEND
mkdir -p 'src/goosestation-libretro'
# Add: src/goosestation-libretro/main.cpp
cat > 'src/goosestation-libretro/main.cpp' <<'PATCHEND'
// GooseStation — libretro frontend for DuckStation
// SPDX-License-Identifier: GPL-2.0-or-later

#include "libretro.h"

#include "core/achievements.h"
#include "core/bus.h"
#include "core/controller.h"
#include "core/core.h"
#include "core/core_private.h"
#include "core/cpu_core.h"
#include "core/timing_event.h"
#include "core/fullscreenui.h"
#include "core/game_list.h"
#include "core/gpu.h"
#include "core/gpu_backend.h"
#include "core/gpu_types.h"
#include "core/host.h"
#include "core/spu.h"
#include "core/system.h"
#include "core/system_private.h"
#include "core/video_presenter.h"
#include "core/video_thread.h"

#include "scmversion/scmversion.h"

#include "util/audio_stream.h"
#include "util/core_audio_stream.h"
#include "util/gpu_device.h"
#include "util/imgui_manager.h"
#include "util/input_manager.h"
#include "util/opengl_device.h"
#include "util/opengl_texture.h"
#include "util/translation.h"
#include "util/window_info.h"

#include "libretro_opengl_context.h"

#ifdef ENABLE_VULKAN
#include "util/vulkan_headers.h"  // must come first — defines VK_NO_PROTOTYPES before vulkan.h
#include "libretro_vulkan.h"
#include "util/vulkan_device.h"
#include "util/vulkan_loader.h"
#include "util/vulkan_texture.h"
#endif

#include "core/analog_controller.h"
#include "core/digital_controller.h"
#include "core/save_state_version.h"

#include "common/assert.h"
#include "common/error.h"
#include "common/file_system.h"
#include "common/log.h"
#include "common/path.h"
#include "common/string_util.h"
#include "common/task_queue.h"
#include "common/threading.h"
#include "common/time_helpers.h"
#include "common/timer.h"

#include "fmt/format.h"

#include <array>
#include <cstring>
#include <deque>
#include <mutex>
#include <numeric>
#include <vector>

LOG_CHANNEL(Host);

// =============================================================================
// Libretro callback storage
// =============================================================================

static retro_environment_t s_environment_callback;
static retro_video_refresh_t s_video_refresh_callback;
static retro_audio_sample_t s_audio_sample_callback;
static retro_audio_sample_batch_t s_audio_sample_batch_callback;
static retro_input_poll_t s_input_poll_callback;
static retro_input_state_t s_input_state_callback;
static retro_log_printf_t s_log_callback;

// =============================================================================
// Internal state
// =============================================================================

namespace LibretroHost {

static bool s_system_initialized = false;
static bool s_core_initialized = false;
static bool s_game_loaded = false;
static bool s_frame_done = false;
static bool s_shutdown_requested = false;
static bool s_supports_input_bitmasks = false;
static std::string s_system_directory;
static std::string s_save_directory;
static std::string s_core_assets_directory;

static std::mutex s_core_events_mutex;
static std::deque<std::pair<std::function<void()>, bool>> s_core_events;
static std::condition_variable s_core_events_done;
static u32 s_blocking_events_pending = 0;

static TaskQueue s_async_task_queue;

static std::vector<s16> s_audio_buffer;
static constexpr u32 AUDIO_BUFFER_MAX_FRAMES = 2048;

static std::vector<u32> s_video_framebuffer;
static std::vector<u8> s_save_state_buffer;
static Threading::Thread s_video_thread;

static bool s_hw_render_enabled = false;
static std::string s_boot_renderer; // renderer active at load time; changes require restart
static retro_hw_render_callback s_hw_render_callback = {};
static bool s_hw_context_valid = false;
static bool s_deferred_boot_pending = false;
static std::string s_deferred_boot_path;
static bool s_context_lost = false;

// Display blit resources for HW render
static GLuint s_display_program = 0;
static GLuint s_display_vao = 0;
static GLint s_display_uniform_src_rect = -1;
static GLuint s_display_nearest_sampler = 0;

// Cached last valid display frame (re-blit when PSX toggles display_disabled).
// Geometry tracking for RetroArch SET_GEOMETRY calls.
static u32 s_last_geometry_width = 0;
static u32 s_last_geometry_height = 0;

static float s_last_aspect_ratio = 4.0f / 3.0f;
static bool s_fmv_zoom_16_9 = false;

#ifdef ENABLE_VULKAN
// Vulkan HW rendering state
static bool s_using_vulkan_renderer = false;
static const retro_hw_render_interface_vulkan* s_vulkan_render_interface = nullptr;
static VkInstance s_vulkan_instance = VK_NULL_HANDLE;
static VkPhysicalDevice s_vulkan_physical_device = VK_NULL_HANDLE;
static VkDevice s_vulkan_device = VK_NULL_HANDLE;
static VkQueue s_vulkan_queue = VK_NULL_HANDLE;
static u32 s_vulkan_queue_family_index = 0;

static VkImage s_vulkan_presentation_image = VK_NULL_HANDLE;
static VkDeviceMemory s_vulkan_presentation_memory = VK_NULL_HANDLE;
static VkImageView s_vulkan_presentation_view = VK_NULL_HANDLE;
static u32 s_vulkan_presentation_width = 0;
static u32 s_vulkan_presentation_height = 0;
static retro_vulkan_image s_vulkan_retro_image = {};
#endif

// Disc control
struct DiskControlInfo
{
  bool has_sub_images = false;
  u32 image_index = 0;
  u32 image_count = 0;
  std::vector<std::string> image_paths;
  std::vector<std::string> image_labels;
  bool ejected = false;
};
static DiskControlInfo s_disk_control;

// Forward declarations
static void ProcessCoreThreadEvents();
static void VideoThreadEntryPoint();
static bool InitializeFoldersAndConfig(Error* error);
static void UpdateControllers();
static void UpdateVariables(bool force = false);
static void PushVideoFrame();
static void PushHWVideoFrame();
static void PushAudioSamples();
static void RETRO_CALLCONV HWContextReset();
static void RETRO_CALLCONV HWContextDestroy();
static bool SetupHWRender();

#ifdef ENABLE_VULKAN
static bool SetupVulkanHWRender();
static void RETRO_CALLCONV VulkanHWContextReset();
static void RETRO_CALLCONV VulkanHWContextDestroy();
static void PushVulkanHWVideoFrame();
static void DestroyVulkanPresentationImage();
static void EnsureVulkanPresentationImage(u32 width, u32 height);
#endif

} // namespace LibretroHost

// Computes the AR to report to RetroArch for a content buffer of
// content_w × content_h pixels. Delegates to upstream's ComputePixelAspectRatio()
// which handles crop mode correction, display_aspect_ratio, and
// force-4:3-for-24bit internally. The content AR is then content_w/content_h * PAR.
static float GetDisplayAspectRatioFloat(u32 content_w, u32 content_h)
{
  if (g_settings.display_aspect_ratio == DisplayAspectRatio::Stretch())
    return 0.0f;

  // FMV zoom: content already cropped to 16:9 by GetFMVCrop.
  if (LibretroHost::s_fmv_zoom_16_9 && g_gpu.IsDisplayAreaColorDepth24())
    return 16.0f / 9.0f;

  const float par = g_gpu.ComputePixelAspectRatio();
  return static_cast<float>(content_w) / static_cast<float>(content_h) * par;
}

// Returns vertical crop (top, bottom) in pixels when FMV zoom is active.
// Assumes 16:9 content letterboxed in a 4:3 frame.
static std::pair<u32, u32> GetFMVCrop(u32 width, u32 height)
{
  if (!LibretroHost::s_fmv_zoom_16_9 || !g_gpu.IsDisplayAreaColorDepth24())
    return {0, 0};

  // Content height if 16:9: width * 9 / 16
  // Frame is 4:3: width * 3 / 4
  // Bar = (frame_h - content_h) / 2
  const u32 content_h = (width * 9 + 8) / 16;
  if (content_h >= height)
    return {0, 0};
  const u32 total_bar = height - content_h;
  return {total_bar / 2, total_bar - total_bar / 2};
}

// =============================================================================
// Utility
// =============================================================================

static void LibretroLog(retro_log_level level, const char* fmt, ...)
{
  if (!s_log_callback)
    return;

  va_list args;
  va_start(args, fmt);
  char buf[2048];
  std::vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  s_log_callback(level, "%s", buf);
}

static void DuckStationLogCallback(void* pUserParam, Log::MessageCategory cat,
                                   const char* functionName, std::string_view message)
{
  if (!s_log_callback || message.empty())
    return;

  static constexpr retro_log_level s_level_map[] = {
    RETRO_LOG_DEBUG, // None
    RETRO_LOG_ERROR, // Error
    RETRO_LOG_DEBUG, // Warning
    RETRO_LOG_INFO,  // Info
    RETRO_LOG_DEBUG, // Verbose
    RETRO_LOG_DEBUG, // Dev
    RETRO_LOG_DEBUG, // Debug
    RETRO_LOG_DEBUG, // Trace
  };

  const Log::Level level = Log::UnpackLevel(cat);
  const Log::Channel channel = Log::UnpackChannel(cat);
  const retro_log_level retro_level = s_level_map[static_cast<size_t>(level)];
  s_log_callback(retro_level, "[GooseStation] %s: %.*s\n",
                 Log::GetChannelName(channel),
                 static_cast<int>(message.size()), message.data());
}

static bool GetVariable(const char* key, const char** value)
{
  retro_variable var = {key, nullptr};
  if (!s_environment_callback(RETRO_ENVIRONMENT_GET_VARIABLE, &var) || !var.value)
    return false;
  *value = var.value;
  return true;
}

[[maybe_unused]] static std::string GetVariableString(const char* key, const char* default_value = "")
{
  const char* value;
  return GetVariable(key, &value) ? std::string(value) : std::string(default_value);
}

// =============================================================================
// Host:: namespace implementations — Resource files
// =============================================================================

bool Host::ResourceFileExists(std::string_view filename, bool allow_override)
{
  const std::string path(Path::Combine(EmuFolders::Resources, filename));
  return FileSystem::FileExists(path.c_str());
}

std::optional<DynamicHeapArray<u8>> Host::ReadResourceFile(std::string_view filename, bool allow_override, Error* error)
{
  const std::string path(Path::Combine(EmuFolders::Resources, filename));
  return FileSystem::ReadBinaryFile(path.c_str(), error);
}

std::optional<std::string> Host::ReadResourceFileToString(std::string_view filename, bool allow_override, Error* error)
{
  const std::string path(Path::Combine(EmuFolders::Resources, filename));
  return FileSystem::ReadFileToString(path.c_str(), error);
}

std::optional<std::time_t> Host::GetResourceFileTimestamp(std::string_view filename, bool allow_override)
{
  const std::string path(Path::Combine(EmuFolders::Resources, filename));
  FILESYSTEM_STAT_DATA sd;
  if (!FileSystem::StatFile(path.c_str(), &sd))
    return std::nullopt;
  return sd.ModificationTime;
}

// =============================================================================
// Host:: namespace implementations — Error reporting
// =============================================================================

void Host::ReportFatalError(std::string_view title, std::string_view message)
{
  LibretroLog(RETRO_LOG_ERROR, "[GooseStation] FATAL: %.*s: %.*s\n",
              static_cast<int>(title.size()), title.data(),
              static_cast<int>(message.size()), message.data());
  abort();
}

void Host::ReportErrorAsync(std::string_view title, std::string_view message)
{
  LibretroLog(RETRO_LOG_ERROR, "[GooseStation] Error: %.*s: %.*s\n",
              static_cast<int>(title.size()), title.data(),
              static_cast<int>(message.size()), message.data());
}

void Host::ReportStatusMessage(std::string_view message)
{
  LibretroLog(RETRO_LOG_INFO, "[GooseStation] %.*s\n",
              static_cast<int>(message.size()), message.data());
}

void Host::ConfirmMessageAsync(std::string_view title, std::string_view message, ConfirmMessageAsyncCallback callback,
                               std::string_view yes_text, std::string_view no_text)
{
  LibretroLog(RETRO_LOG_WARN, "[GooseStation] Confirm: %.*s: %.*s\n",
              static_cast<int>(title.size()), title.data(),
              static_cast<int>(message.size()), message.data());
  callback(true);
}

// =============================================================================
// Host:: namespace implementations — Language/Translation
// =============================================================================

s32 Host::Internal::GetTranslatedStringImpl(std::string_view context, std::string_view msg,
                                            std::string_view disambiguation, char* tbuf, size_t tbuf_space)
{
  if (msg.size() > tbuf_space)
    return -1;
  if (msg.empty())
    return 0;
  std::memcpy(tbuf, msg.data(), msg.size());
  return static_cast<s32>(msg.size());
}

std::string Host::TranslatePluralToString(const char* context, const char* msg, const char* disambiguation, int count)
{
  TinyString count_str = TinyString::from_format("{}", count);
  std::string ret(msg);
  for (;;)
  {
    std::string::size_type pos = ret.find("%n");
    if (pos == std::string::npos)
      break;
    ret.replace(pos, 2, count_str.view());
  }
  return ret;
}

SmallString Host::TranslatePluralToSmallString(const char* context, const char* msg, const char* disambiguation,
                                               int count)
{
  SmallString ret(msg);
  ret.replace("%n", TinyString::from_format("{}", count));
  return ret;
}

std::string Host::FormatNumber(NumberFormatType type, s64 value)
{
  if (type >= NumberFormatType::ShortDate && type <= NumberFormatType::LongDateTime)
  {
    const char* format;
    switch (type)
    {
      case NumberFormatType::ShortDate:
        format = "%x";
        break;
      case NumberFormatType::LongDate:
        format = "%A %B %e %Y";
        break;
      case NumberFormatType::ShortTime:
      case NumberFormatType::LongTime:
        format = "%X";
        break;
      case NumberFormatType::ShortDateTime:
        format = "%X %x";
        break;
      case NumberFormatType::LongDateTime:
        format = "%c";
        break;
        DefaultCaseIsUnreachable();
    }
    std::string ret(128, '\0');
    if (const std::optional<std::tm> ltime = Common::LocalTime(static_cast<std::time_t>(value)))
      ret.resize(std::strftime(ret.data(), ret.size(), format, &ltime.value()));
    else
      ret = "Invalid";
    return ret;
  }
  return fmt::format("{}", value);
}

std::string Host::FormatNumber(NumberFormatType type, double value)
{
  return fmt::format("{}", value);
}

// =============================================================================
// Host:: namespace implementations — Threading
// =============================================================================

void Host::RunOnCoreThread(std::function<void()> function, bool block)
{
  // Execute blocking calls immediately to avoid deadlock (retro_run is the core thread).
  if (block)
  {
    function();
    return;
  }

  using namespace LibretroHost;
  std::unique_lock lock(s_core_events_mutex);
  s_core_events.emplace_back(std::move(function), false);
}

void Host::RunOnUIThread(std::function<void()> function, bool block)
{
  RunOnCoreThread(std::move(function), block);
}

void Host::QueueAsyncTask(std::function<void()> function)
{
  LibretroHost::s_async_task_queue.SubmitTask(std::move(function));
}

void Host::WaitForAllAsyncTasks()
{
  LibretroHost::s_async_task_queue.WaitForAll();
}

// =============================================================================
// Host:: namespace implementations — Settings
// =============================================================================

void Host::CommitBaseSettingChanges()
{
}

void Host::LoadSettings(const SettingsInterface& si, std::unique_lock<std::mutex>& lock)
{
}

void Host::CheckForSettingsChanges(const Settings& old_settings)
{
  if (LibretroHost::s_hw_render_enabled &&
      g_settings.gpu_resolution_scale != old_settings.gpu_resolution_scale)
  {
    struct retro_system_av_info avi;
    retro_get_system_av_info(&avi);
    struct retro_game_geometry geom = {};
    geom.base_width = avi.geometry.base_width;
    geom.base_height = avi.geometry.base_height;
    geom.max_width = avi.geometry.max_width;
    geom.max_height = avi.geometry.max_height;
    geom.aspect_ratio = avi.geometry.aspect_ratio;
    s_environment_callback(RETRO_ENVIRONMENT_SET_GEOMETRY, &geom);
    LibretroHost::s_last_geometry_width = avi.geometry.base_width;
    LibretroHost::s_last_geometry_height = avi.geometry.base_height;
  }
}

void Host::SetDefaultSettings(SettingsInterface& si)
{
  si.SetStringValue("GPU", "Renderer", Settings::GetRendererName(GPURenderer::Software));
  si.SetBoolValue("GPU", "UseThread", false);
  si.SetStringValue("Audio", "Backend", AudioStream::GetBackendName(AudioBackend::Null));
  si.SetBoolValue("Main", "ApplyGameSettings", false);
  si.SetBoolValue("BIOS", "PatchFastBoot", false);
  si.SetFloatValue("Main", "EmulationSpeed", 0.0f);

  si.SetBoolValue("InputSources", "Keyboard", false);
  si.SetBoolValue("InputSources", "Pointer", false);
}

void Host::OnSettingsResetToDefault(bool host, bool system, bool controller)
{
}

// =============================================================================
// Host:: namespace implementations — System lifecycle
// =============================================================================

void Host::OnSystemStarting()
{
}

void Host::OnSystemStarted()
{
}

void Host::OnSystemStopping()
{
}

void Host::OnSystemDestroyed()
{
}

void Host::OnSystemPaused()
{
}

void Host::OnSystemResumed()
{
}

void Host::OnSystemAbnormalShutdown(const std::string_view reason)
{
  LibretroLog(RETRO_LOG_ERROR, "[GooseStation] Abnormal shutdown: %.*s\n",
              static_cast<int>(reason.size()), reason.data());
}

void Host::OnPerformanceCountersUpdated(const GPUBackend* gpu_backend)
{
}

void Host::OnSystemGameChanged(const std::string& disc_path, const std::string& game_serial,
                               const std::string& game_name, GameHash hash)
{
  LibretroLog(RETRO_LOG_INFO, "[GooseStation] Game: %s (%s)\n", game_name.c_str(), game_serial.c_str());
}

void Host::OnSystemUndoStateAvailabilityChanged(bool available, u64 timestamp)
{
}

void Host::PumpMessagesOnCoreThread()
{
  LibretroHost::ProcessCoreThreadEvents();

  LibretroHost::s_frame_done = true;
  System::PauseSystem(true);
  System::InterruptExecution();
}

void Host::RequestResizeHostDisplay(s32 width, s32 height)
{
}

void Host::RequestSystemShutdown(bool allow_confirm, bool save_state, bool check_memcard_busy)
{
  LibretroHost::s_shutdown_requested = true;
}

// =============================================================================
// Host:: namespace implementations — Video/Display
// =============================================================================

std::optional<WindowInfo> Host::AcquireRenderWindow(RenderAPI render_api, bool fullscreen, bool exclusive_fullscreen,
                                                    Error* error)
{
  // Inject LibretroOpenGLContext into OpenGLDevice for HW rendering.
  if (LibretroHost::s_hw_render_enabled && LibretroHost::s_hw_context_valid &&
      (render_api == RenderAPI::OpenGL || render_api == RenderAPI::OpenGLES) && g_gpu_device)
  {
    auto libretro_context =
      std::make_unique<LibretroOpenGLContext>(LibretroHost::s_hw_render_callback.get_proc_address);
    static_cast<OpenGLDevice*>(g_gpu_device.get())->SetExternalContext(std::move(libretro_context));
  }

#ifdef ENABLE_VULKAN
  // Inject external Vulkan device handles for HW rendering.
  if (LibretroHost::s_using_vulkan_renderer && LibretroHost::s_hw_context_valid &&
      render_api == RenderAPI::Vulkan && g_gpu_device)
  {
    auto* vk_dev = static_cast<VulkanDevice*>(g_gpu_device.get());
    vk_dev->SetExternalDeviceHandles(LibretroHost::s_vulkan_physical_device, LibretroHost::s_vulkan_device,
                                     LibretroHost::s_vulkan_queue, LibretroHost::s_vulkan_queue_family_index);
    vk_dev->SetQueueLockCallbacks(
      [](){ LibretroHost::s_vulkan_render_interface->lock_queue(LibretroHost::s_vulkan_render_interface->handle); },
      [](){ LibretroHost::s_vulkan_render_interface->unlock_queue(LibretroHost::s_vulkan_render_interface->handle); });
  }
#endif

  return WindowInfo();
}

WindowInfoType Host::GetRenderWindowInfoType()
{
  return WindowInfoType::Surfaceless;
}

void Host::ReleaseRenderWindow()
{
}

bool Host::CanChangeFullscreenMode(bool new_fullscreen_state)
{
  return false;
}

// =============================================================================
// Host:: namespace implementations — Fullscreen UI
// =============================================================================

#ifdef RC_CLIENT_SUPPORTS_RAINTEGRATION
void Host::OnRAIntegrationMenuChanged()
{
}
#endif

// =============================================================================
// Host:: namespace implementations — Debugger
// =============================================================================

void Host::ReportDebuggerEvent(CPU::DebuggerEvent event, std::string_view message)
{
  LibretroLog(RETRO_LOG_WARN, "[GooseStation] Debug: %.*s\n",
              static_cast<int>(message.size()), message.data());
}

// =============================================================================
// Internal helpers
// =============================================================================

void LibretroHost::ProcessCoreThreadEvents()
{
  std::unique_lock lock(s_core_events_mutex);
  for (;;)
  {
    if (s_core_events.empty())
      break;

    auto event = std::move(s_core_events.front());
    s_core_events.pop_front();
    lock.unlock();
    event.first();
    lock.lock();

    if (event.second)
    {
      s_blocking_events_pending--;
      s_core_events_done.notify_one();
    }
  }
}

void LibretroHost::VideoThreadEntryPoint()
{
  Threading::SetNameOfCurrentThread("Video Thread");
  VideoThread::Internal::VideoThreadEntryPoint();
}

bool LibretroHost::InitializeFoldersAndConfig(Error* error)
{
  EmuFolders::AppRoot = s_system_directory;
  EmuFolders::DataRoot = s_save_directory.empty() ? s_system_directory : s_save_directory;

  const std::string resources_subpath = Path::Combine(s_system_directory, "duckstation/resources");
  const std::string resources_altpath = Path::Combine(s_system_directory, "duckstation");
  if (FileSystem::DirectoryExists(resources_subpath.c_str()))
    EmuFolders::Resources = resources_subpath;
  else if (FileSystem::DirectoryExists(resources_altpath.c_str()))
    EmuFolders::Resources = resources_altpath;
  else
    EmuFolders::Resources = Path::Combine(s_system_directory, "goosestation/resources");

  LibretroLog(RETRO_LOG_INFO, "[GooseStation] Resources: %s (%s)\n", EmuFolders::Resources.c_str(),
              FileSystem::DirectoryExists(EmuFolders::Resources.c_str()) ? "found" : "not found, non-fatal");

  EmuFolders::Bios = s_system_directory;

  if (!s_save_directory.empty())
  {
    EmuFolders::MemoryCards = s_save_directory;
    EmuFolders::SaveStates = s_save_directory;
    EmuFolders::Cache = Path::Combine(s_save_directory, "cache");
  }

  if (!Core::InitializeBaseSettingsLayer({}, error))
    return false;

  // InitializeBaseSettingsLayer enables console output on Linux by default.
  // Disable it immediately — all logging goes through our retro_log callback.
  Log::SetConsoleOutputParams(false, false);

  const auto lock = Core::GetSettingsLock();
  SettingsInterface& si = *Core::GetBaseSettingsLayer();
  si.SetStringValue("GPU", "Renderer", Settings::GetRendererName(GPURenderer::Software));
  si.SetBoolValue("GPU", "UseThread", false);
  si.SetBoolValue("GPU", "DisableShaderCache", false);
  si.SetStringValue("Audio", "Backend", AudioStream::GetBackendName(AudioBackend::Null));
  si.SetStringValue("Pad1", "Type", Controller::GetControllerInfo(ControllerType::AnalogController).name);
  si.SetStringValue("Pad2", "Type", Controller::GetControllerInfo(ControllerType::None).name);
  si.SetStringValue("MemoryCards", "Card1Type", Settings::GetMemoryCardTypeName(MemoryCardType::Shared));
  si.SetStringValue("MemoryCards", "Card2Type", Settings::GetMemoryCardTypeName(MemoryCardType::None));
  si.SetStringValue("ControllerPorts", "MultitapMode", Settings::GetMultitapModeName(MultitapMode::Disabled));
  si.SetBoolValue("Logging", "LogToConsole", false);
  si.SetBoolValue("Logging", "LogToFile", false);
  si.SetStringValue("Logging", "LogLevel", Settings::GetLogLevelName(Log::Level::Dev));
  si.SetBoolValue("Main", "ApplyGameSettings", false);
  si.SetBoolValue("BIOS", "PatchFastBoot", false);
  si.SetFloatValue("Main", "EmulationSpeed", 0.0f);

  si.SetStringValue("BIOS", "SearchDirectory", s_system_directory.c_str());

  si.SetBoolValue("InputSources", "Keyboard", false);
  si.SetBoolValue("InputSources", "Pointer", false);

  EmuFolders::LoadConfig(si);

  return true;
}

void LibretroHost::UpdateControllers()
{
  if (!s_input_poll_callback)
    return;

  s_input_poll_callback();

  for (u32 port = 0; port < NUM_CONTROLLER_AND_CARD_PORTS; port++)
  {
    Controller* controller = System::GetController(port);
    if (!controller)
      continue;

    const ControllerType type = controller->GetType();

    static constexpr std::array<std::pair<u32, u32>, 14> s_button_mapping = {{
      {static_cast<u32>(DigitalController::Button::Up), RETRO_DEVICE_ID_JOYPAD_UP},
      {static_cast<u32>(DigitalController::Button::Down), RETRO_DEVICE_ID_JOYPAD_DOWN},
      {static_cast<u32>(DigitalController::Button::Left), RETRO_DEVICE_ID_JOYPAD_LEFT},
      {static_cast<u32>(DigitalController::Button::Right), RETRO_DEVICE_ID_JOYPAD_RIGHT},
      {static_cast<u32>(DigitalController::Button::Cross), RETRO_DEVICE_ID_JOYPAD_B},
      {static_cast<u32>(DigitalController::Button::Circle), RETRO_DEVICE_ID_JOYPAD_A},
      {static_cast<u32>(DigitalController::Button::Square), RETRO_DEVICE_ID_JOYPAD_Y},
      {static_cast<u32>(DigitalController::Button::Triangle), RETRO_DEVICE_ID_JOYPAD_X},
      {static_cast<u32>(DigitalController::Button::L1), RETRO_DEVICE_ID_JOYPAD_L},
      {static_cast<u32>(DigitalController::Button::R1), RETRO_DEVICE_ID_JOYPAD_R},
      {static_cast<u32>(DigitalController::Button::L2), RETRO_DEVICE_ID_JOYPAD_L2},
      {static_cast<u32>(DigitalController::Button::R2), RETRO_DEVICE_ID_JOYPAD_R2},
      {static_cast<u32>(DigitalController::Button::Select), RETRO_DEVICE_ID_JOYPAD_SELECT},
      {static_cast<u32>(DigitalController::Button::Start), RETRO_DEVICE_ID_JOYPAD_START},
    }};

    if (s_supports_input_bitmasks)
    {
      const u16 active =
        static_cast<u16>(s_input_state_callback(port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_MASK));
      for (const auto& [bind_index, retro_id] : s_button_mapping)
        controller->SetBindState(bind_index, (active & (1u << retro_id)) ? 1.0f : 0.0f);
    }
    else
    {
      for (const auto& [bind_index, retro_id] : s_button_mapping)
      {
        const int16_t state = s_input_state_callback(port, RETRO_DEVICE_JOYPAD, 0, retro_id);
        controller->SetBindState(bind_index, state != 0 ? 1.0f : 0.0f);
      }
    }

    if (type == ControllerType::AnalogController || type == ControllerType::AnalogJoystick)
    {
      controller->SetBindState(static_cast<u32>(AnalogController::Button::L3),
                               s_input_state_callback(port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_L3) != 0 ? 1.0f : 0.0f);
      controller->SetBindState(static_cast<u32>(AnalogController::Button::R3),
                               s_input_state_callback(port, RETRO_DEVICE_JOYPAD, 0, RETRO_DEVICE_ID_JOYPAD_R3) != 0 ? 1.0f : 0.0f);

      static constexpr u32 HALF_AXIS_BASE = static_cast<u32>(AnalogController::Button::Count);

      {
        const int16_t lx = s_input_state_callback(port, RETRO_DEVICE_ANALOG,
                                                   RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_X);
        const float neg = (lx < 0) ? (static_cast<float>(-lx) / 32768.0f) : 0.0f;
        const float pos = (lx > 0) ? (static_cast<float>(lx) / 32767.0f) : 0.0f;
        controller->SetBindState(HALF_AXIS_BASE + static_cast<u32>(AnalogController::HalfAxis::LLeft), neg);
        controller->SetBindState(HALF_AXIS_BASE + static_cast<u32>(AnalogController::HalfAxis::LRight), pos);
      }

      {
        const int16_t ly = s_input_state_callback(port, RETRO_DEVICE_ANALOG,
                                                   RETRO_DEVICE_INDEX_ANALOG_LEFT, RETRO_DEVICE_ID_ANALOG_Y);
        const float neg = (ly < 0) ? (static_cast<float>(-ly) / 32768.0f) : 0.0f;
        const float pos = (ly > 0) ? (static_cast<float>(ly) / 32767.0f) : 0.0f;
        controller->SetBindState(HALF_AXIS_BASE + static_cast<u32>(AnalogController::HalfAxis::LUp), neg);
        controller->SetBindState(HALF_AXIS_BASE + static_cast<u32>(AnalogController::HalfAxis::LDown), pos);
      }

      {
        const int16_t rx = s_input_state_callback(port, RETRO_DEVICE_ANALOG,
                                                   RETRO_DEVICE_INDEX_ANALOG_RIGHT, RETRO_DEVICE_ID_ANALOG_X);
        const float neg = (rx < 0) ? (static_cast<float>(-rx) / 32768.0f) : 0.0f;
        const float pos = (rx > 0) ? (static_cast<float>(rx) / 32767.0f) : 0.0f;
        controller->SetBindState(HALF_AXIS_BASE + static_cast<u32>(AnalogController::HalfAxis::RLeft), neg);
        controller->SetBindState(HALF_AXIS_BASE + static_cast<u32>(AnalogController::HalfAxis::RRight), pos);
      }

      {
        const int16_t ry = s_input_state_callback(port, RETRO_DEVICE_ANALOG,
                                                   RETRO_DEVICE_INDEX_ANALOG_RIGHT, RETRO_DEVICE_ID_ANALOG_Y);
        const float neg = (ry < 0) ? (static_cast<float>(-ry) / 32768.0f) : 0.0f;
        const float pos = (ry > 0) ? (static_cast<float>(ry) / 32767.0f) : 0.0f;
        controller->SetBindState(HALF_AXIS_BASE + static_cast<u32>(AnalogController::HalfAxis::RUp), neg);
        controller->SetBindState(HALF_AXIS_BASE + static_cast<u32>(AnalogController::HalfAxis::RDown), pos);
      }
    }
  }
}

void LibretroHost::UpdateVariables(bool force)
{
  if (!force)
  {
    bool updated = false;
    if (s_environment_callback(RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE, &updated) && !updated)
      return;
  }

  auto lock = Core::GetSettingsLock();
  SettingsInterface& si = *Core::GetBaseSettingsLayer();
  const char* value;

  // =====================================================================
  // SYSTEM
  // =====================================================================
  if (GetVariable("goosestation_region", &value))
    si.SetStringValue("Console", "Region", value);

  if (GetVariable("goosestation_bios_path_ntsc_j", &value))
    si.SetStringValue("BIOS", "PathNTSCJ", std::strcmp(value, "auto") != 0 ? value : "");
  if (GetVariable("goosestation_bios_path_ntsc_u", &value))
    si.SetStringValue("BIOS", "PathNTSCU", std::strcmp(value, "auto") != 0 ? value : "");
  if (GetVariable("goosestation_bios_path_pal", &value))
    si.SetStringValue("BIOS", "PathPAL", std::strcmp(value, "auto") != 0 ? value : "");

  if (GetVariable("goosestation_bios_fast_boot", &value))
    si.SetBoolValue("BIOS", "PatchFastBoot", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_bios_fast_forward_boot", &value))
    si.SetBoolValue("BIOS", "FastForwardBoot", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_bios_tty_logging", &value))
    si.SetBoolValue("BIOS", "TTYLogging", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_cpu_execution_mode", &value))
    si.SetStringValue("CPU", "ExecutionMode", value);

  if (GetVariable("goosestation_cpu_overclock", &value))
  {
    const u32 percent = static_cast<u32>(std::atoi(value));
    if (percent != 100 && percent > 0)
    {
      si.SetBoolValue("CPU", "OverclockEnable", true);
      const u32 gcd_val = std::gcd(percent, 100u);
      si.SetUIntValue("CPU", "OverclockNumerator", percent / gcd_val);
      si.SetUIntValue("CPU", "OverclockDenominator", 100u / gcd_val);
    }
    else
    {
      si.SetBoolValue("CPU", "OverclockEnable", false);
      si.SetUIntValue("CPU", "OverclockNumerator", 1);
      si.SetUIntValue("CPU", "OverclockDenominator", 1);
    }
  }

  if (GetVariable("goosestation_cpu_recompiler_memory_exceptions", &value))
    si.SetBoolValue("CPU", "RecompilerMemoryExceptions", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_cpu_recompiler_block_linking", &value))
    si.SetBoolValue("CPU", "RecompilerBlockLinking", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_cpu_recompiler_icache", &value))
    si.SetBoolValue("CPU", "RecompilerICache", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_cpu_fastmem_mode", &value))
    si.SetStringValue("CPU", "FastmemMode", value);

  if (GetVariable("goosestation_8mb_ram", &value))
    si.SetBoolValue("Console", "Enable8MBRAM", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_apply_compatibility_settings", &value))
    si.SetBoolValue("Main", "ApplyCompatibilitySettings", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_disable_all_enhancements", &value))
    si.SetBoolValue("Main", "DisableAllEnhancements", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_load_devices_from_save_states", &value))
    si.SetBoolValue("Main", "LoadDevicesFromSaveStates", std::strcmp(value, "true") == 0);

  // =====================================================================
  // VIDEO
  // =====================================================================
  if (GetVariable("goosestation_renderer", &value))
  {
    // Renderer can only be set at boot — switching at runtime freezes because
    // RETRO_ENVIRONMENT_SET_HW_RENDER is only valid during retro_load_game.
    if (s_boot_renderer.empty())
      s_boot_renderer = value;
    si.SetStringValue("GPU", "Renderer", s_boot_renderer.c_str());
  }

  if (GetVariable("goosestation_resolution_scale", &value))
    si.SetUIntValue("GPU", "ResolutionScale", static_cast<u32>(std::atoi(value)));

  if (GetVariable("goosestation_gpu_multisamples", &value))
    si.SetUIntValue("GPU", "Multisamples", static_cast<u32>(std::atoi(value)));

  if (GetVariable("goosestation_texture_filter", &value))
    si.SetStringValue("GPU", "TextureFilter", value);

  if (GetVariable("goosestation_sprite_texture_filter", &value))
    si.SetStringValue("GPU", "SpriteTextureFilter", value);

  if (GetVariable("goosestation_dithering_mode", &value))
    si.SetStringValue("GPU", "DitheringMode", value);

  if (GetVariable("goosestation_deinterlacing", &value))
    si.SetStringValue("GPU", "DeinterlacingMode", value);

  if (GetVariable("goosestation_gpu_scaled_interlacing", &value))
    si.SetBoolValue("GPU", "ScaledInterlacing", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_line_detect_mode", &value))
    si.SetStringValue("GPU", "LineDetectMode", value);

  if (GetVariable("goosestation_gpu_downsample_mode", &value))
    si.SetStringValue("GPU", "DownsampleMode", value);

  if (GetVariable("goosestation_gpu_downsample_scale", &value))
    si.SetUIntValue("GPU", "DownsampleScale", static_cast<u32>(std::atoi(value)));

  if (GetVariable("goosestation_gpu_wireframe_mode", &value))
    si.SetStringValue("GPU", "WireframeMode", value);

  if (GetVariable("goosestation_gpu_force_video_timing", &value))
    si.SetStringValue("GPU", "ForceVideoTiming", value);

  if (GetVariable("goosestation_chroma_smoothing", &value))
    si.SetBoolValue("GPU", "ChromaSmoothing24Bit", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_widescreen_hack", &value))
    si.SetBoolValue("GPU", "WidescreenHack", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_per_sample_shading", &value))
    si.SetBoolValue("GPU", "PerSampleShading", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_force_round_texcoords", &value))
    si.SetBoolValue("GPU", "ForceRoundTextureCoordinates", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_modulation_crop", &value))
    si.SetBoolValue("GPU", "EnableModulationCrop", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_texture_cache", &value))
    si.SetBoolValue("GPU", "EnableTextureCache", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_software_readbacks", &value))
    si.SetBoolValue("GPU", "UseSoftwareRendererForReadbacks", std::strcmp(value, "true") == 0);

  // =====================================================================
  // PGXP
  // =====================================================================
  if (GetVariable("goosestation_pgxp_enable", &value))
    si.SetBoolValue("GPU", "PGXPEnable", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_pgxp_culling", &value))
    si.SetBoolValue("GPU", "PGXPCulling", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_pgxp_texture_correction", &value))
    si.SetBoolValue("GPU", "PGXPTextureCorrection", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_pgxp_color_correction", &value))
    si.SetBoolValue("GPU", "PGXPColorCorrection", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_pgxp_depth_buffer", &value))
    si.SetBoolValue("GPU", "PGXPDepthBuffer", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_pgxp_vertex_cache", &value))
    si.SetBoolValue("GPU", "PGXPVertexCache", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_pgxp_cpu", &value))
    si.SetBoolValue("GPU", "PGXPCPU", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_pgxp_preserve_proj_fp", &value))
    si.SetBoolValue("GPU", "PGXPPreserveProjFP", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_pgxp_tolerance", &value))
    si.SetFloatValue("GPU", "PGXPTolerance", static_cast<float>(std::atof(value)));

  if (GetVariable("goosestation_pgxp_disable_2d", &value))
    si.SetBoolValue("GPU", "PGXPDisableOn2DPolygons", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_pgxp_transparent_depth", &value))
    si.SetBoolValue("GPU", "PGXPTransparentDepthTest", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_pgxp_depth_clear_threshold", &value))
    si.SetFloatValue("GPU", "PGXPDepthThreshold", static_cast<float>(std::atof(value)));

  // =====================================================================
  // DISPLAY
  // =====================================================================
  if (GetVariable("goosestation_crop_mode", &value))
    si.SetStringValue("Display", "CropMode", value);

  if (GetVariable("goosestation_aspect_ratio", &value))
    si.SetStringValue("Display", "AspectRatio", value);

  if (GetVariable("goosestation_display_force_4_3_for_24bit", &value))
  {
    si.SetBoolValue("Display", "Force4_3For24Bit",
                    std::strcmp(value, "true") == 0 || std::strcmp(value, "zoom_16_9") == 0);
    LibretroHost::s_fmv_zoom_16_9 = (std::strcmp(value, "zoom_16_9") == 0);
  }

  if (GetVariable("goosestation_display_rotation", &value))
    si.SetStringValue("Display", "Rotation", value);

  if (GetVariable("goosestation_display_active_start_offset", &value))
    si.SetIntValue("Display", "ActiveStartOffset", std::atoi(value));

  if (GetVariable("goosestation_display_active_end_offset", &value))
    si.SetIntValue("Display", "ActiveEndOffset", std::atoi(value));

  if (GetVariable("goosestation_display_line_start_offset", &value))
    si.SetIntValue("Display", "LineStartOffset", std::atoi(value));

  if (GetVariable("goosestation_display_line_end_offset", &value))
    si.SetIntValue("Display", "LineEndOffset", std::atoi(value));

  // =====================================================================
  // AUDIO
  // =====================================================================
  if (GetVariable("goosestation_audio_output_volume", &value))
    si.SetUIntValue("Audio", "OutputVolume", static_cast<u32>(std::atoi(value)));

  if (GetVariable("goosestation_audio_fast_forward_volume", &value))
    si.SetUIntValue("Audio", "FastForwardVolume", static_cast<u32>(std::atoi(value)));

  if (GetVariable("goosestation_audio_output_muted", &value))
    si.SetBoolValue("Audio", "OutputMuted", std::strcmp(value, "true") == 0);

  // =====================================================================
  // INPUT
  // =====================================================================
  if (GetVariable("goosestation_controller_1_type", &value))
    si.SetStringValue("Pad1", "Type", value);

  if (GetVariable("goosestation_controller_2_type", &value))
    si.SetStringValue("Pad2", "Type", value);

  if (GetVariable("goosestation_multitap", &value))
    si.SetStringValue("ControllerPorts", "MultitapMode", value);

  if (GetVariable("goosestation_memory_card_1_type", &value))
    si.SetStringValue("MemoryCards", "Card1Type", value);

  if (GetVariable("goosestation_memory_card_2_type", &value))
    si.SetStringValue("MemoryCards", "Card2Type", value);

  if (GetVariable("goosestation_memory_card_use_playlist_title", &value))
    si.SetBoolValue("MemoryCards", "UsePlaylistTitle", std::strcmp(value, "true") == 0);

  // =====================================================================
  // CD-ROM
  // =====================================================================
  if (GetVariable("goosestation_cd_read_speedup", &value))
    si.SetUIntValue("CDROM", "ReadSpeedup", static_cast<u32>(std::atoi(value)));

  if (GetVariable("goosestation_cd_seek_speedup", &value))
    si.SetUIntValue("CDROM", "SeekSpeedup", static_cast<u32>(std::atoi(value)));

  if (GetVariable("goosestation_cdrom_region_check", &value))
    si.SetBoolValue("CDROM", "RegionCheck", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_cdrom_subq_skew", &value))
    si.SetBoolValue("CDROM", "SubQSkew", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_cdrom_load_image_to_ram", &value))
    si.SetBoolValue("CDROM", "LoadImageToRAM", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_cdrom_load_image_patches", &value))
    si.SetBoolValue("CDROM", "LoadImagePatches", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_cdrom_mute_cd_audio", &value))
    si.SetBoolValue("CDROM", "MuteCDAudio", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_cdrom_readahead_sectors", &value))
    si.SetUIntValue("CDROM", "ReadaheadSectors", static_cast<u32>(std::atoi(value)));

  if (GetVariable("goosestation_cdrom_mechacon_version", &value))
    si.SetStringValue("CDROM", "MechaconVersion", value);

  if (GetVariable("goosestation_cdrom_disable_speedup_on_mdec", &value))
    si.SetBoolValue("CDROM", "DisableSpeedupOnMDEC", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_cdrom_ignore_host_subcode", &value))
    si.SetBoolValue("CDROM", "IgnoreHostSubcode", std::strcmp(value, "true") == 0);

  // =====================================================================
  // TEXTURE REPLACEMENTS
  // =====================================================================
  if (GetVariable("goosestation_texture_replacement_enable", &value))
    si.SetBoolValue("TextureReplacements", "EnableTextureReplacements", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_vram_write_replacement_enable", &value))
    si.SetBoolValue("TextureReplacements", "EnableVRAMWriteReplacements", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_replacement_preload", &value))
    si.SetBoolValue("TextureReplacements", "PreloadTextures", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_replacement_always_track", &value))
    si.SetBoolValue("TextureReplacements", "AlwaysTrackUploads", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_dump_enable", &value))
    si.SetBoolValue("TextureReplacements", "DumpTextures", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_vram_write_dump_enable", &value))
    si.SetBoolValue("TextureReplacements", "DumpVRAMWrites", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_replacement_linear_filter", &value))
    si.SetBoolValue("TextureReplacements", "ReplacementScaleLinearFilter", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_dump_texture_pages", &value))
    si.SetBoolValue("TextureReplacements", "DumpTexturePages", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_dump_full_texture_pages", &value))
    si.SetBoolValue("TextureReplacements", "DumpFullTexturePages", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_dump_force_alpha", &value))
    si.SetBoolValue("TextureReplacements", "DumpTextureForceAlphaChannel", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_vram_write_dump_force_alpha", &value))
    si.SetBoolValue("TextureReplacements", "DumpVRAMWriteForceAlphaChannel", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_dump_replaced", &value))
    si.SetBoolValue("TextureReplacements", "DumpReplacedTextures", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_dump_c16", &value))
    si.SetBoolValue("TextureReplacements", "DumpC16Textures", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_reduce_palette_range", &value))
    si.SetBoolValue("TextureReplacements", "ReducePaletteRange", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_texture_convert_copies_to_writes", &value))
    si.SetBoolValue("TextureReplacements", "ConvertCopiesToWrites", std::strcmp(value, "true") == 0);

  // =====================================================================
  // HACKS
  // =====================================================================
  if (GetVariable("goosestation_dma_max_slice_ticks", &value))
    si.SetIntValue("Hacks", "DMAMaxSliceTicks", std::atoi(value));

  if (GetVariable("goosestation_dma_halt_ticks", &value))
    si.SetIntValue("Hacks", "DMAHaltTicks", std::atoi(value));

  if (GetVariable("goosestation_gpu_fifo_size", &value))
    si.SetUIntValue("Hacks", "GPUFIFOSize", static_cast<u32>(std::atoi(value)));

  if (GetVariable("goosestation_gpu_max_run_ahead", &value))
    si.SetIntValue("Hacks", "GPUMaxRunAhead", std::atoi(value));

  if (GetVariable("goosestation_mdec_use_old_routines", &value))
    si.SetBoolValue("Hacks", "UseOldMDECRoutines", std::strcmp(value, "true") == 0);

  // =====================================================================
  // ADVANCED (GPU backend toggles)
  // =====================================================================
  if (GetVariable("goosestation_gpu_disable_shader_cache", &value))
    si.SetBoolValue("GPU", "DisableShaderCache", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_disable_dual_source_blend", &value))
    si.SetBoolValue("GPU", "DisableDualSourceBlend", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_disable_framebuffer_fetch", &value))
    si.SetBoolValue("GPU", "DisableFramebufferFetch", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_disable_texture_buffers", &value))
    si.SetBoolValue("GPU", "DisableTextureBuffers", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_disable_texture_copy_to_self", &value))
    si.SetBoolValue("GPU", "DisableTextureCopyToSelf", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_disable_memory_import", &value))
    si.SetBoolValue("GPU", "DisableMemoryImport", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_disable_raster_order_views", &value))
    si.SetBoolValue("GPU", "DisableRasterOrderViews", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_disable_compute_shaders", &value))
    si.SetBoolValue("GPU", "DisableComputeShaders", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_disable_compressed_textures", &value))
    si.SetBoolValue("GPU", "DisableCompressedTextures", std::strcmp(value, "true") == 0);

  if (GetVariable("goosestation_gpu_show_vram", &value))
    si.SetBoolValue("Debug", "ShowVRAM", std::strcmp(value, "true") == 0);

  // Unlock before ApplySettings() which re-acquires the settings mutex.
  lock.unlock();
  if (System::IsValid())
  {
    System::ApplySettings(false);
  }
}

void LibretroHost::PushVideoFrame()
{
  if (!s_video_refresh_callback)
    return;

  if (g_gpu.IsDisplayDisabled())
  {
    s_video_framebuffer.resize(320 * 240);
    std::fill(s_video_framebuffer.begin(), s_video_framebuffer.end(), 0xFF000000u);
    s_video_refresh_callback(s_video_framebuffer.data(), 320, 240, 320 * sizeof(u32));
    return;
  }

  const GSVector4i src_rect = g_gpu.GetCRTCVRAMSourceRect();
  const u32 vram_left = static_cast<u32>(src_rect.x);
  const u32 vram_top = static_cast<u32>(src_rect.y);
  const u32 vram_right = static_cast<u32>(src_rect.z);
  const u32 vram_bottom = static_cast<u32>(src_rect.w);

  u32 vram_width = vram_right - vram_left;
  u32 vram_height = vram_bottom - vram_top;

  if (vram_width == 0 || vram_height == 0)
  {
    s_video_refresh_callback(NULL, 320, 240, 320 * sizeof(u32));
    return;
  }

  vram_width = std::min(vram_width, static_cast<u32>(VRAM_WIDTH));
  vram_height = std::min(vram_height, static_cast<u32>(VRAM_HEIGHT));

  s_video_framebuffer.resize(static_cast<size_t>(vram_width) * vram_height);

  const bool is_24bit = g_gpu.IsDisplayAreaColorDepth24();

  if (is_24bit)
  {
    const u32 src_x_base = g_gpu.GetDisplayAddressStartX();
    const u32 skip_x = vram_left - src_x_base;

    for (u32 y = 0; y < vram_height; y++)
    {
      const u32 src_y = (vram_top + y) & VRAM_HEIGHT_MASK;
      const u16* src_row = &g_vram[src_y * VRAM_WIDTH];
      u32* dst_row = &s_video_framebuffer[y * vram_width];

      for (u32 x = 0; x < vram_width; x++)
      {
        const u32 offset = (src_x_base + (((skip_x + x) * 3) / 2));
        const u16 s0 = src_row[offset % VRAM_WIDTH];
        const u16 s1 = src_row[(offset + 1) % VRAM_WIDTH];
        const u8 shift = static_cast<u8>(x & 1u) * 8;
        const u32 rgb = ((static_cast<u32>(s1) << 16) | static_cast<u32>(s0)) >> shift;

        const u8 r = static_cast<u8>(rgb);
        const u8 g = static_cast<u8>(rgb >> 8);
        const u8 b = static_cast<u8>(rgb >> 16);

        dst_row[x] = 0xFF000000u | (static_cast<u32>(r) << 16) | (static_cast<u32>(g) << 8) | static_cast<u32>(b);
      }
    }
  }
  else
  {
    // 15-bit BGR555
    for (u32 y = 0; y < vram_height; y++)
    {
      const u32 src_y = (vram_top + y) & VRAM_HEIGHT_MASK;
      u32* dst_row = &s_video_framebuffer[y * vram_width];

      for (u32 x = 0; x < vram_width; x++)
      {
        const u32 src_x = (vram_left + x) & VRAM_WIDTH_MASK;
        const u16 pixel = g_vram[src_y * VRAM_WIDTH + src_x];

        const u8 r = static_cast<u8>(((pixel & 0x1F) * 527 + 23) >> 6);
        const u8 g = static_cast<u8>((((pixel >> 5) & 0x1F) * 527 + 23) >> 6);
        const u8 b = static_cast<u8>((((pixel >> 10) & 0x1F) * 527 + 23) >> 6);

        dst_row[x] = 0xFF000000u | (static_cast<u32>(r) << 16) | (static_cast<u32>(g) << 8) | static_cast<u32>(b);
      }
    }
  }

  const auto [crop_top, crop_bottom] = GetFMVCrop(vram_width, vram_height);
  const u32 cropped_height = vram_height - crop_top - crop_bottom;
  const u32* frame_data = s_video_framebuffer.data() + (crop_top * vram_width);
  s_video_refresh_callback(frame_data, vram_width, cropped_height, vram_width * sizeof(u32));
}

void LibretroHost::PushAudioSamples()
{
  if (!s_audio_sample_batch_callback)
    return;

  CoreAudioStream& stream = SPU::GetOutputStream();
  const u32 available = stream.GetBufferedFramesRelaxed();
  if (available == 0)
    return;

  const u32 frames_to_read = std::min(available, AUDIO_BUFFER_MAX_FRAMES);
  s_audio_buffer.resize(frames_to_read * 2); // stereo

  const u32 frames_read = stream.DrainSamples(s_audio_buffer.data(), frames_to_read);
  if (frames_read > 0)
    s_audio_sample_batch_callback(s_audio_buffer.data(), frames_read);
}

// =============================================================================
// Hardware rendering support
// =============================================================================

bool LibretroHost::SetupHWRender()
{
  s_hw_render_callback = {};
#ifdef __ANDROID__
  s_hw_render_callback.context_type = RETRO_HW_CONTEXT_OPENGLES3;
  s_hw_render_callback.version_major = 3;
  s_hw_render_callback.version_minor = 0;
#else
  s_hw_render_callback.context_type = RETRO_HW_CONTEXT_OPENGL_CORE;
  s_hw_render_callback.version_major = 3;
  s_hw_render_callback.version_minor = 3;
#endif
  s_hw_render_callback.context_reset = LibretroHost::HWContextReset;
  s_hw_render_callback.context_destroy = LibretroHost::HWContextDestroy;
  s_hw_render_callback.bottom_left_origin = true;
  s_hw_render_callback.depth = true;
  s_hw_render_callback.stencil = true;
  s_hw_render_callback.cache_context = true;

  if (!s_environment_callback(RETRO_ENVIRONMENT_SET_HW_RENDER, &s_hw_render_callback))
  {
    LibretroLog(RETRO_LOG_WARN, "[GooseStation] Frontend rejected HW render request, falling back to software\n");
    s_hw_render_callback = {};
    return false;
  }

  LibretroLog(RETRO_LOG_INFO, "[GooseStation] HW render context negotiated (OpenGL 3.3 Core)\n");
  s_hw_render_enabled = true;
  return true;
}

void RETRO_CALLCONV LibretroHost::HWContextReset()
{
  LibretroLog(RETRO_LOG_INFO, "[GooseStation] HW context reset\n");
  s_hw_context_valid = true;

  if (s_deferred_boot_pending)
  {
    LibretroHost::UpdateVariables(true);

    SystemBootParameters params;
    params.path = s_deferred_boot_path;

    Error error;
    if (!System::BootSystem(std::move(params), &error))
    {
      LibretroLog(RETRO_LOG_ERROR, "[GooseStation] BootSystem() failed in HWContextReset: %s\n",
                  error.GetDescription().c_str());
      s_deferred_boot_pending = false;
      s_deferred_boot_path.clear();
      return;
    }

    if (System::HasMediaSubImages())
    {
      s_disk_control.has_sub_images = true;
      s_disk_control.image_index = System::GetMediaSubImageIndex();
      s_disk_control.image_count = System::GetMediaSubImageCount();
      s_disk_control.image_paths.clear();
      s_disk_control.image_labels.clear();
      for (u32 i = 0; i < s_disk_control.image_count; i++)
      {
        s_disk_control.image_paths.push_back(s_deferred_boot_path);
        s_disk_control.image_labels.push_back(System::GetMediaSubImageTitle(i));
      }
    }

    s_deferred_boot_pending = false;
    s_deferred_boot_path.clear();
    s_game_loaded = true;

    s_save_state_buffer.resize(System::GetMaxSaveStateSize(g_settings.cpu_enable_8mb_ram));

    // Update timing now that System is valid — retro_get_system_av_info returned
    // a default 60/50 Hz before boot; the real NTSC rate is ~59.82 Hz.
    {
      struct retro_system_av_info avi;
      retro_get_system_av_info(&avi);
      s_environment_callback(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO, &avi);
      s_last_geometry_width = avi.geometry.base_width;
      s_last_geometry_height = avi.geometry.base_height;
      s_last_aspect_ratio = avi.geometry.aspect_ratio;
    }

    {
#ifdef __ANDROID__
      const char* vs_src = R"(#version 300 es
precision highp float;
uniform vec4 u_src_rect;
out vec2 v_tex0;
void main() {
vec2 pos = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
v_tex0 = u_src_rect.xy + pos * u_src_rect.zw;
gl_Position = vec4(pos * vec2(2.0f, -2.0f) + vec2(-1.0f, 1.0f), 0.0f, 1.0f);
}
)";
      const char* fs_src = R"(#version 300 es
precision highp float;
uniform sampler2D samp0;
in vec2 v_tex0;
out vec4 o_col0;
void main() {
o_col0 = vec4(texture(samp0, v_tex0).rgb, 1.0);
}
)";
#else
      const char* vs_src = R"(
        #version 330 core
        uniform vec4 u_src_rect;
        out vec2 v_tex0;
        void main() {
          vec2 pos = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));
          v_tex0 = u_src_rect.xy + pos * u_src_rect.zw;
          gl_Position = vec4(pos * vec2(2.0f, -2.0f) + vec2(-1.0f, 1.0f), 0.0f, 1.0f);
        }
      )";
      const char* fs_src = R"(
        #version 330 core
        uniform sampler2D samp0;
        in vec2 v_tex0;
        out vec4 o_col0;
        void main() {
          o_col0 = vec4(texture(samp0, v_tex0).rgb, 1.0);
        }
      )";
#endif
      GLuint vs = glCreateShader(GL_VERTEX_SHADER);
      glShaderSource(vs, 1, &vs_src, nullptr);
      glCompileShader(vs);
      GLint compile_status = 0;
      glGetShaderiv(vs, GL_COMPILE_STATUS, &compile_status);
      if (!compile_status)
      {
        GLint len = 0;
        glGetShaderiv(vs, GL_INFO_LOG_LENGTH, &len);
        std::string log(len, '\0');
        glGetShaderInfoLog(vs, len, &len, log.data());
        LibretroLog(RETRO_LOG_ERROR, "[GooseStation] VS compile failed: %s", log.c_str());
      }

      GLuint fs = glCreateShader(GL_FRAGMENT_SHADER);
      glShaderSource(fs, 1, &fs_src, nullptr);
      glCompileShader(fs);
      s_display_program = glCreateProgram();
      glAttachShader(s_display_program, vs);
      glAttachShader(s_display_program, fs);
#ifndef __ANDROID__
      glBindFragDataLocation(s_display_program, 0, "o_col0");
#endif
      glLinkProgram(s_display_program);

      GLint link_status = 0;
      glGetProgramiv(s_display_program, GL_LINK_STATUS, &link_status);
      if (!link_status)
      {
        GLint len = 0;
        glGetProgramiv(s_display_program, GL_INFO_LOG_LENGTH, &len);
        std::string log(len, '\0');
        glGetProgramInfoLog(s_display_program, len, &len, log.data());
        LibretroLog(RETRO_LOG_ERROR, "[GooseStation] Display program link failed: %s", log.c_str());
      }

      glDeleteShader(vs);
      glDeleteShader(fs);
      s_display_uniform_src_rect = glGetUniformLocation(s_display_program, "u_src_rect");
      glUseProgram(s_display_program);
      GLint samp_loc = glGetUniformLocation(s_display_program, "samp0");
      if (samp_loc >= 0)
        glUniform1i(samp_loc, 0);
      glUseProgram(0);
      glGenVertexArrays(1, &s_display_vao);
    }

    glGenSamplers(1, &s_display_nearest_sampler);
    glSamplerParameteri(s_display_nearest_sampler, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glSamplerParameteri(s_display_nearest_sampler, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glSamplerParameteri(s_display_nearest_sampler, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glSamplerParameteri(s_display_nearest_sampler, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

    LibretroLog(RETRO_LOG_INFO, "[GooseStation] HW render: game booted successfully\n");
  }
}

void RETRO_CALLCONV LibretroHost::HWContextDestroy()
{
  LibretroLog(RETRO_LOG_INFO, "[GooseStation] HW context destroyed\n");
  s_hw_context_valid = false;

  if (s_display_program)
  {
    glDeleteProgram(s_display_program);
    s_display_program = 0;
  }
  if (s_display_vao)
  {
    glDeleteVertexArrays(1, &s_display_vao);
    s_display_vao = 0;
  }
  if (s_display_nearest_sampler)
  {
    glDeleteSamplers(1, &s_display_nearest_sampler);
    s_display_nearest_sampler = 0;
  }

  if (g_gpu_device)
  {
    if (System::IsValid())
      System::ShutdownSystem(false);
  }
}

#ifdef ENABLE_VULKAN

// =============================================================================
// Vulkan HW rendering
// =============================================================================

static const VkApplicationInfo* GetVulkanApplicationInfo()
{
  static VkApplicationInfo app_info{VK_STRUCTURE_TYPE_APPLICATION_INFO};
  app_info.pApplicationName = "GooseStation";
  app_info.applicationVersion = VK_MAKE_VERSION(1, 0, 0);
  app_info.pEngineName = "GooseStation";
  app_info.engineVersion = VK_MAKE_VERSION(1, 0, 0);
  app_info.apiVersion = VK_API_VERSION_1_0;
  return &app_info;
}

static bool RETRO_CALLCONV VulkanCreateDevice(struct retro_vulkan_context* context, VkInstance instance,
                                               VkPhysicalDevice gpu, VkSurfaceKHR surface,
                                               PFN_vkGetInstanceProcAddr get_instance_proc_addr,
                                               const char** required_device_extensions,
                                               unsigned num_required_device_extensions,
                                               const char** required_device_layers,
                                               unsigned num_required_device_layers,
                                               const VkPhysicalDeviceFeatures* required_features)
{
  Error error;
  if (!VulkanLoader::AdoptExternalInstance(instance, get_instance_proc_addr, &error))
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] AdoptExternalInstance failed: %s\n", error.GetDescription().c_str());
    return false;
  }

  if (gpu == VK_NULL_HANDLE)
  {
    u32 gpu_count = 0;
    vkEnumeratePhysicalDevices(instance, &gpu_count, nullptr);
    if (gpu_count == 0)
    {
      LibretroLog(RETRO_LOG_ERROR, "[GooseStation] No Vulkan physical devices found\n");
      return false;
    }
    std::vector<VkPhysicalDevice> gpus(gpu_count);
    vkEnumeratePhysicalDevices(instance, &gpu_count, gpus.data());
    gpu = gpus[0];
    LibretroLog(RETRO_LOG_INFO, "[GooseStation] No GPU specified, using first device\n");
  }

  u32 queue_family_count = 0;
  vkGetPhysicalDeviceQueueFamilyProperties(gpu, &queue_family_count, nullptr);
  std::vector<VkQueueFamilyProperties> queue_families(queue_family_count);
  vkGetPhysicalDeviceQueueFamilyProperties(gpu, &queue_family_count, queue_families.data());

  u32 graphics_queue_family = UINT32_MAX;
  for (u32 i = 0; i < queue_family_count; i++)
  {
    if (queue_families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT)
    {
      graphics_queue_family = i;
      break;
    }
  }
  if (graphics_queue_family == UINT32_MAX)
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] No graphics queue family found\n");
    return false;
  }

  // Enable only the extensions DuckStation actually uses, plus RetroArch's required ones.
  // Enabling ALL available extensions causes VK_ERROR_EXTENSION_NOT_PRESENT on some drivers
  // (e.g. Mali-G78) due to conflicting extensions.
  u32 avail_ext_count = 0;
  vkEnumerateDeviceExtensionProperties(gpu, nullptr, &avail_ext_count, nullptr);
  std::vector<VkExtensionProperties> avail_extensions(avail_ext_count);
  vkEnumerateDeviceExtensionProperties(gpu, nullptr, &avail_ext_count, avail_extensions.data());

  const auto IsAvailable = [&avail_extensions](const char* name) {
    return std::find_if(avail_extensions.begin(), avail_extensions.end(),
                        [name](const VkExtensionProperties& p) {
                          return std::strcmp(name, p.extensionName) == 0;
                        }) != avail_extensions.end();
  };

  // Extensions that DuckStation's EnableOptionalDeviceExtensions() may enable.
  static const char* const s_duckstation_extensions[] = {
    VK_KHR_DRIVER_PROPERTIES_EXTENSION_NAME,
    VK_EXT_MEMORY_BUDGET_EXTENSION_NAME,
    VK_EXT_RASTERIZATION_ORDER_ATTACHMENT_ACCESS_EXTENSION_NAME,
    VK_ARM_RASTERIZATION_ORDER_ATTACHMENT_ACCESS_EXTENSION_NAME,
    VK_KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME,
    VK_KHR_CREATE_RENDERPASS_2_EXTENSION_NAME,
    VK_KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
    VK_KHR_DYNAMIC_RENDERING_LOCAL_READ_EXTENSION_NAME,
    VK_KHR_PUSH_DESCRIPTOR_EXTENSION_NAME,
    VK_EXT_EXTERNAL_MEMORY_HOST_EXTENSION_NAME,
    VK_EXT_FRAGMENT_SHADER_INTERLOCK_EXTENSION_NAME,
    VK_KHR_MAINTENANCE_4_EXTENSION_NAME,
    VK_KHR_MAINTENANCE_5_EXTENSION_NAME,
  };

  // Start with RetroArch's required extensions.
  std::vector<const char*> all_extensions;
  for (unsigned i = 0; i < num_required_device_extensions; i++)
    all_extensions.push_back(required_device_extensions[i]);

  // Add DuckStation extensions that are available on this device.
  for (const char* ext : s_duckstation_extensions)
  {
    if (!IsAvailable(ext))
      continue;
    bool already = false;
    for (const char* existing : all_extensions)
    {
      if (std::strcmp(ext, existing) == 0)
      {
        already = true;
        break;
      }
    }
    if (!already)
      all_extensions.push_back(ext);
  }

  const float queue_priority = 1.0f;
  VkDeviceQueueCreateInfo queue_ci = {VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO};
  queue_ci.queueFamilyIndex = graphics_queue_family;
  queue_ci.queueCount = 1;
  queue_ci.pQueuePriorities = &queue_priority;

  VkPhysicalDeviceFeatures device_features = {};
  if (required_features)
    device_features = *required_features;

  VkDeviceCreateInfo device_ci = {VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO};
  device_ci.queueCreateInfoCount = 1;
  device_ci.pQueueCreateInfos = &queue_ci;
  device_ci.enabledExtensionCount = static_cast<u32>(all_extensions.size());
  device_ci.ppEnabledExtensionNames = all_extensions.data();
  device_ci.enabledLayerCount = num_required_device_layers;
  device_ci.ppEnabledLayerNames = required_device_layers;
  device_ci.pEnabledFeatures = &device_features;

  VkDevice device;
  VkResult res = vkCreateDevice(gpu, &device_ci, nullptr, &device);
  if (res != VK_SUCCESS)
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] vkCreateDevice failed: %d\n", static_cast<int>(res));
    return false;
  }

  if (!VulkanLoader::LoadDeviceFunctions(device, &error))
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] LoadDeviceFunctions failed: %s\n", error.GetDescription().c_str());
    vkDestroyDevice(device, nullptr);
    return false;
  }

  VkQueue queue;
  vkGetDeviceQueue(device, graphics_queue_family, 0, &queue);

  LibretroHost::s_vulkan_instance = instance;
  LibretroHost::s_vulkan_physical_device = gpu;
  LibretroHost::s_vulkan_device = device;
  LibretroHost::s_vulkan_queue = queue;
  LibretroHost::s_vulkan_queue_family_index = graphics_queue_family;

  context->gpu = gpu;
  context->device = device;
  context->queue = queue;
  context->queue_family_index = graphics_queue_family;
  context->presentation_queue = queue;
  context->presentation_queue_family_index = graphics_queue_family;

  LibretroLog(RETRO_LOG_INFO, "[GooseStation] Vulkan device created (queue family %u)\n", graphics_queue_family);
  return true;
}

static retro_hw_render_context_negotiation_interface_vulkan s_vulkan_negotiation_interface = {
  RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN,  // interface_type
  1,                                                      // interface_version
  GetVulkanApplicationInfo,                               // get_application_info
  VulkanCreateDevice,                                     // create_device
  nullptr                                                 // destroy_device
};

bool LibretroHost::SetupVulkanHWRender()
{
  s_hw_render_callback = {};
  s_hw_render_callback.context_type = RETRO_HW_CONTEXT_VULKAN;
  s_hw_render_callback.version_major = VK_API_VERSION_1_0;
  s_hw_render_callback.version_minor = 0;
  s_hw_render_callback.context_reset = LibretroHost::VulkanHWContextReset;
  s_hw_render_callback.context_destroy = LibretroHost::VulkanHWContextDestroy;
  s_hw_render_callback.bottom_left_origin = false;
  s_hw_render_callback.depth = false;
  s_hw_render_callback.stencil = false;
  s_hw_render_callback.cache_context = false;

  if (!s_environment_callback(RETRO_ENVIRONMENT_SET_HW_RENDER, &s_hw_render_callback))
  {
    LibretroLog(RETRO_LOG_WARN, "[GooseStation] Frontend rejected Vulkan HW render request\n");
    s_hw_render_callback = {};
    return false;
  }

  if (!s_environment_callback(RETRO_ENVIRONMENT_SET_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE,
                              &s_vulkan_negotiation_interface))
  {
    LibretroLog(RETRO_LOG_WARN, "[GooseStation] Frontend rejected Vulkan context negotiation interface\n");
    s_hw_render_callback = {};
    return false;
  }

  LibretroLog(RETRO_LOG_INFO, "[GooseStation] Vulkan HW render context negotiated\n");
  s_hw_render_enabled = true;
  s_using_vulkan_renderer = true;
  return true;
}

void RETRO_CALLCONV LibretroHost::VulkanHWContextReset()
{
  LibretroLog(RETRO_LOG_INFO, "[GooseStation] Vulkan HW context reset\n");
  s_hw_context_valid = true;

  retro_hw_render_interface* ri = nullptr;
  if (!s_environment_callback(RETRO_ENVIRONMENT_GET_HW_RENDER_INTERFACE, &ri) ||
      ri->interface_type != RETRO_HW_RENDER_INTERFACE_VULKAN ||
      ri->interface_version != RETRO_HW_RENDER_INTERFACE_VULKAN_VERSION)
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] Failed to get Vulkan HW render interface\n");
    s_hw_context_valid = false;
    return;
  }
  s_vulkan_render_interface = reinterpret_cast<const retro_hw_render_interface_vulkan*>(ri);

  if (s_deferred_boot_pending)
  {
    LibretroHost::UpdateVariables(true);

    SystemBootParameters params;
    params.path = s_deferred_boot_path;

    Error error;
    if (!System::BootSystem(std::move(params), &error))
    {
      LibretroLog(RETRO_LOG_ERROR, "[GooseStation] BootSystem() failed: %s\n", error.GetDescription().c_str());
      s_deferred_boot_pending = false;
      s_deferred_boot_path.clear();
      s_hw_context_valid = false;
      return;
    }
    if (System::HasMediaSubImages())
    {
      s_disk_control.has_sub_images = true;
      s_disk_control.image_index = System::GetMediaSubImageIndex();
      s_disk_control.image_count = System::GetMediaSubImageCount();
      s_disk_control.image_paths.clear();
      s_disk_control.image_labels.clear();
      for (u32 i = 0; i < s_disk_control.image_count; i++)
      {
        s_disk_control.image_paths.push_back(s_deferred_boot_path);
        s_disk_control.image_labels.push_back(System::GetMediaSubImageTitle(i));
      }
    }

    s_deferred_boot_pending = false;
    s_deferred_boot_path.clear();
    s_game_loaded = true;

    s_save_state_buffer.resize(System::GetMaxSaveStateSize(g_settings.cpu_enable_8mb_ram));

    // Update timing now that System is valid — retro_get_system_av_info returned
    // a default 60/50 Hz before boot; the real NTSC rate is ~59.82 Hz.
    {
      struct retro_system_av_info avi;
      retro_get_system_av_info(&avi);
      s_environment_callback(RETRO_ENVIRONMENT_SET_SYSTEM_AV_INFO, &avi);
      s_last_geometry_width = avi.geometry.base_width;
      s_last_geometry_height = avi.geometry.base_height;
      s_last_aspect_ratio = avi.geometry.aspect_ratio;
    }

    LibretroLog(RETRO_LOG_INFO, "[GooseStation] Vulkan HW render: game booted successfully\n");
  }
  else if (s_context_lost)
  {
    LibretroLog(RETRO_LOG_INFO, "[GooseStation] Recreating GPU backend after context loss...\n");
    s_context_lost = false;

    Error error;
    if (!VideoThread::CreateGPUBackend(g_settings.gpu_renderer, true, std::nullopt, &error))
    {
      LibretroLog(RETRO_LOG_ERROR, "[GooseStation] Failed to recreate GPU backend: %s\n",
                  error.GetDescription().c_str());
      return;
    }

    g_gpu.UpdateDisplay(false);
    LibretroLog(RETRO_LOG_INFO, "[GooseStation] GPU backend recreated after context loss\n");
  }
}

void RETRO_CALLCONV LibretroHost::VulkanHWContextDestroy()
{
  LibretroLog(RETRO_LOG_INFO, "[GooseStation] Vulkan HW context destroyed\n");
  s_hw_context_valid = false;

  DestroyVulkanPresentationImage();

  if (g_gpu_device && System::IsValid())
  {
    // Destroy GPU backend only — keep the system (CPU, memory, etc.) alive so we can
    // recreate the backend when context_reset fires after fullscreen toggle.
    VideoThread::DestroyGPUBackend();
    s_context_lost = true;
    LibretroLog(RETRO_LOG_INFO, "[GooseStation] GPU backend destroyed, system kept alive for context restore\n");
  }
  else if (g_gpu_device)
  {
    System::ShutdownSystem(false);
  }

  s_vulkan_render_interface = nullptr;
}

void LibretroHost::DestroyVulkanPresentationImage()
{
  if (s_vulkan_presentation_view != VK_NULL_HANDLE)
  {
    vkDestroyImageView(s_vulkan_device, s_vulkan_presentation_view, nullptr);
    s_vulkan_presentation_view = VK_NULL_HANDLE;
  }
  if (s_vulkan_presentation_image != VK_NULL_HANDLE)
  {
    vkDestroyImage(s_vulkan_device, s_vulkan_presentation_image, nullptr);
    s_vulkan_presentation_image = VK_NULL_HANDLE;
  }
  if (s_vulkan_presentation_memory != VK_NULL_HANDLE)
  {
    vkFreeMemory(s_vulkan_device, s_vulkan_presentation_memory, nullptr);
    s_vulkan_presentation_memory = VK_NULL_HANDLE;
  }
  s_vulkan_presentation_width = 0;
  s_vulkan_presentation_height = 0;
  s_vulkan_retro_image = {};
}

void LibretroHost::EnsureVulkanPresentationImage(u32 width, u32 height)
{
  if (s_vulkan_presentation_width == width && s_vulkan_presentation_height == height &&
      s_vulkan_presentation_image != VK_NULL_HANDLE)
    return;

  if (s_vulkan_presentation_image != VK_NULL_HANDLE)
  {
    vkDeviceWaitIdle(s_vulkan_device);
    DestroyVulkanPresentationImage();
  }

  VkImageCreateInfo image_ci = {VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO};
  image_ci.imageType = VK_IMAGE_TYPE_2D;
  image_ci.format = VK_FORMAT_R8G8B8A8_UNORM;
  image_ci.extent = {width, height, 1};
  image_ci.mipLevels = 1;
  image_ci.arrayLayers = 1;
  image_ci.samples = VK_SAMPLE_COUNT_1_BIT;
  image_ci.tiling = VK_IMAGE_TILING_OPTIMAL;
  image_ci.usage = VK_IMAGE_USAGE_SAMPLED_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT;
  image_ci.sharingMode = VK_SHARING_MODE_EXCLUSIVE;
  image_ci.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

  VkResult res = vkCreateImage(s_vulkan_device, &image_ci, nullptr, &s_vulkan_presentation_image);
  if (res != VK_SUCCESS)
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] Failed to create presentation image: %d\n", static_cast<int>(res));
    return;
  }

  VkMemoryRequirements mem_req;
  vkGetImageMemoryRequirements(s_vulkan_device, s_vulkan_presentation_image, &mem_req);

  VkPhysicalDeviceMemoryProperties mem_props;
  vkGetPhysicalDeviceMemoryProperties(s_vulkan_physical_device, &mem_props);

  u32 memory_type_index = UINT32_MAX;
  for (u32 i = 0; i < mem_props.memoryTypeCount; i++)
  {
    if ((mem_req.memoryTypeBits & (1u << i)) &&
        (mem_props.memoryTypes[i].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT))
    {
      memory_type_index = i;
      break;
    }
  }
  if (memory_type_index == UINT32_MAX)
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] No suitable memory type for presentation image\n");
    vkDestroyImage(s_vulkan_device, s_vulkan_presentation_image, nullptr);
    s_vulkan_presentation_image = VK_NULL_HANDLE;
    return;
  }

  VkMemoryAllocateInfo alloc_info = {VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
  alloc_info.allocationSize = mem_req.size;
  alloc_info.memoryTypeIndex = memory_type_index;

  res = vkAllocateMemory(s_vulkan_device, &alloc_info, nullptr, &s_vulkan_presentation_memory);
  if (res != VK_SUCCESS)
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] Failed to allocate presentation image memory: %d\n",
                static_cast<int>(res));
    vkDestroyImage(s_vulkan_device, s_vulkan_presentation_image, nullptr);
    s_vulkan_presentation_image = VK_NULL_HANDLE;
    return;
  }

  vkBindImageMemory(s_vulkan_device, s_vulkan_presentation_image, s_vulkan_presentation_memory, 0);

  VkImageViewCreateInfo view_ci = {VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO};
  view_ci.image = s_vulkan_presentation_image;
  view_ci.viewType = VK_IMAGE_VIEW_TYPE_2D;
  view_ci.format = VK_FORMAT_R8G8B8A8_UNORM;
  view_ci.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};

  res = vkCreateImageView(s_vulkan_device, &view_ci, nullptr, &s_vulkan_presentation_view);
  if (res != VK_SUCCESS)
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] Failed to create presentation image view: %d\n",
                static_cast<int>(res));
    vkFreeMemory(s_vulkan_device, s_vulkan_presentation_memory, nullptr);
    s_vulkan_presentation_memory = VK_NULL_HANDLE;
    vkDestroyImage(s_vulkan_device, s_vulkan_presentation_image, nullptr);
    s_vulkan_presentation_image = VK_NULL_HANDLE;
    return;
  }

  s_vulkan_presentation_width = width;
  s_vulkan_presentation_height = height;

  s_vulkan_retro_image.image_view = s_vulkan_presentation_view;
  s_vulkan_retro_image.image_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
  s_vulkan_retro_image.create_info = view_ci;

  LibretroLog(RETRO_LOG_INFO, "[GooseStation] Created Vulkan presentation image %ux%u\n", width, height);
}

void LibretroHost::PushVulkanHWVideoFrame()
{
  if (!s_video_refresh_callback || !s_hw_context_valid || !g_gpu_device || !s_vulkan_render_interface)
    return;

  // Serialize submissions to 1-in-flight: wait for the previous submit's GPU work
  // to complete before recording a new frame. CPU naturally throttles to the GPU's
  // real rate, so we never flood Android's present pipeline with submits faster
  // than Mali/SurfaceFlinger can retire them. Without this, turbo at 3x+ emits
  // frames faster than the display can ingest and MAILBOX drops surface as black.
  {
    VulkanDevice* vk_dev_for_wait = static_cast<VulkanDevice*>(g_gpu_device.get());
    const u64 current = vk_dev_for_wait->GetCurrentFenceCounter();
    if (current > 1)
      vk_dev_for_wait->WaitForFenceCounter(current - 1);
  }

  const bool has_display = VideoPresenter::HasDisplayTexture();
  GPUTexture* display_texture = has_display ? VideoPresenter::GetDisplayTexture() : nullptr;
  GSVector4i display_rect = has_display ? VideoPresenter::GetDisplayTextureRect() : GSVector4i::zero();
  u32 display_width = has_display ? static_cast<u32>(display_rect.z - display_rect.x) : 0;
  u32 display_height = has_display ? static_cast<u32>(display_rect.w - display_rect.y) : 0;

  if (has_display && display_width > 0 && display_height > 0)
  {
    const auto [crop_top, crop_bottom] = GetFMVCrop(display_width, display_height);
    if (crop_top + crop_bottom > 0)
    {
      display_rect.y += static_cast<s32>(crop_top);
      display_rect.w -= static_cast<s32>(crop_bottom);
      display_height -= (crop_top + crop_bottom);
    }
  }
  else
  {
    // No display texture this frame (blanking, resolution change in progress).
    // Size the black frame to match the dims SET_GEOMETRY reported earlier
    // this frame — never use cached-from-prior-frame values, never re-read
    // VideoPresenter (the video thread could have advanced between retro_run's
    // read and ours).
    display_width = std::max(1u, s_last_geometry_width);
    display_height = std::max(1u, s_last_geometry_height);
    display_texture = nullptr;
  }

  // Always use the geometry dimensions for the frame size — the display texture
  // may transiently have native-res dimensions during mode switches. Using
  // geometry dims avoids thrashing the presentation image (vkDeviceWaitIdle).
  const u32 frame_width = std::max(1u, s_last_geometry_width);
  const u32 frame_height = std::max(1u, s_last_geometry_height);

  EnsureVulkanPresentationImage(frame_width, frame_height);
  if (s_vulkan_presentation_image == VK_NULL_HANDLE)
  {
    s_video_refresh_callback(nullptr, frame_width, frame_height, 0);
    return;
  }

  VulkanDevice* vk_dev = static_cast<VulkanDevice*>(g_gpu_device.get());

  if (vk_dev->InRenderPass())
    vk_dev->EndRenderPass();

  VkCommandBuffer cmd = vk_dev->GetCurrentCommandBuffer();

  // Presentation image -> TRANSFER_DST.
  {
    VkImageMemoryBarrier barrier = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = s_vulkan_presentation_image;
    barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &barrier);
  }

  // Always clear to black first (provides borders).
  {
    VkClearColorValue clear = {{0.0f, 0.0f, 0.0f, 1.0f}};
    VkImageSubresourceRange range = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdClearColorImage(cmd, s_vulkan_presentation_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &clear, 1, &range);
  }

  if (display_texture)
  {
    VulkanTexture* vk_tex = static_cast<VulkanTexture*>(display_texture);

    vk_tex->TransitionToLayout(cmd, VulkanTexture::Layout::TransferSrc);
    VkImageBlit blit = {};
    blit.srcSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    blit.srcOffsets[0] = {display_rect.x, display_rect.y, 0};
    blit.srcOffsets[1] = {display_rect.z, display_rect.w, 1};
    blit.dstSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1};
    blit.dstOffsets[0] = {0, 0, 0};
    blit.dstOffsets[1] = {static_cast<s32>(frame_width), static_cast<s32>(frame_height), 1};

    vkCmdBlitImage(cmd, vk_tex->GetImage(), VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                   s_vulkan_presentation_image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
                   1, &blit, VK_FILTER_NEAREST);

    vk_tex->TransitionToLayout(cmd, VulkanTexture::Layout::ShaderReadOnly);
  }

  // Presentation image -> SHADER_READ_ONLY.
  {
    VkImageMemoryBarrier barrier = {VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER};
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = s_vulkan_presentation_image;
    barrier.subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1};
    vkCmdPipelineBarrier(cmd, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
                         0, 0, nullptr, 0, nullptr, 1, &barrier);
  }

  s_vulkan_retro_image.image_layout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

  // Create a fresh binary semaphore every frame. Reuse is unsafe: under turbo,
  // RetroArch may dupe frames and not wait on the signaled semaphore (libretro
  // vulkan spec: "If frame duping is used ... the frontend will not wait for any
  // semaphores"). Re-signaling an already-signaled binary semaphore is undefined.
  // Destruction is deferred by VulkanDevice until the fence for this submit
  // signals — by then the GPU has consumed our signal and RetroArch's wait.
  VkSemaphore sem = VK_NULL_HANDLE;
  VkSemaphoreCreateInfo sci = {VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO};
  vkCreateSemaphore(s_vulkan_device, &sci, nullptr, &sem);

  s_vulkan_render_interface->set_image(s_vulkan_render_interface->handle, &s_vulkan_retro_image,
                                       1, &sem, VK_QUEUE_FAMILY_IGNORED);

  vk_dev->SubmitCommandBufferAndSignal(sem);
  vk_dev->DeferSemaphoreDestruction(sem);

  s_video_refresh_callback(RETRO_HW_FRAME_BUFFER_VALID, frame_width, frame_height, 0);
}

#endif // ENABLE_VULKAN

void LibretroHost::PushHWVideoFrame()
{
  if (!s_video_refresh_callback || !s_hw_context_valid)
    return;

  if (!g_gpu_device || !s_hw_context_valid)
    return;

  const bool has_display = VideoPresenter::HasDisplayTexture();
  GPUTexture* display_texture = has_display ? VideoPresenter::GetDisplayTexture() : nullptr;
  GSVector4i display_rect = has_display ? VideoPresenter::GetDisplayTextureRect() : GSVector4i::zero();
  u32 display_width = has_display ? static_cast<u32>(display_rect.z - display_rect.x) : 0;
  u32 display_height = has_display ? static_cast<u32>(display_rect.w - display_rect.y) : 0;

  if (has_display && display_width > 0 && display_height > 0)
  {
    const auto [crop_top, crop_bottom] = GetFMVCrop(display_width, display_height);
    if (crop_top + crop_bottom > 0)
    {
      display_rect.y += static_cast<s32>(crop_top);
      display_rect.w -= static_cast<s32>(crop_bottom);
      display_height -= (crop_top + crop_bottom);
    }
  }
  else
  {
    // No display texture this frame — match SET_GEOMETRY's dims (cached in
    // s_last_geometry_* at the top of retro_run just before this call).
    display_width = std::max(1u, s_last_geometry_width);
    display_height = std::max(1u, s_last_geometry_height);
    display_texture = nullptr;
  }

  // Render the display content only (no bordered frame). Aspect correction
  // is applied via SET_GEOMETRY aspect_ratio.
  u32 frame_width = display_width;
  u32 frame_height = display_height;

#ifdef __ANDROID__
  // RA's HW-render FBO on Android is capped at 8192x8192 (POT of MAX_SCALE*1024,
  // clamped by Mali's 16383 texture limit). 640-wide PSX modes at 15x internal
  // produce a 9600-wide output that would get right-edge-clipped by the FBO.
  // Proportionally shrink the blit viewport so the full image fits, RA scales
  // to screen from there.
  static constexpr u32 FBO_LIMIT = 8192;
  if (frame_width > FBO_LIMIT || frame_height > FBO_LIMIT)
  {
    const double sx = static_cast<double>(FBO_LIMIT) / frame_width;
    const double sy = static_cast<double>(FBO_LIMIT) / frame_height;
    const double s = std::min(sx, sy);
    frame_width = static_cast<u32>(std::max(1.0, frame_width * s));
    frame_height = static_cast<u32>(std::max(1.0, frame_height * s));
  }
#endif

  g_gpu_device->FlushCommands();

  const GLuint retroarch_fbo = static_cast<GLuint>(s_hw_render_callback.get_current_framebuffer());

  // Disable scissor test — DuckStation leaves it enabled with VRAM-space coords.
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, retroarch_fbo);
  glDisable(GL_SCISSOR_TEST);
  glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  glDisable(GL_BLEND);
  glDisable(GL_DEPTH_TEST);
  glDisable(GL_STENCIL_TEST);
  glDepthMask(GL_FALSE);

  // Clear the full frame (black borders).
  glViewport(0, 0, static_cast<GLsizei>(frame_width), static_cast<GLsizei>(frame_height));
  glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);

  if (display_texture && s_display_program != 0)
  {
    OpenGLTexture* gl_display_texture = static_cast<OpenGLTexture*>(display_texture);

    const GLuint src_texture = gl_display_texture->GetGLId();
    const float tex_width = static_cast<float>(display_texture->GetWidth());
    const float tex_height = static_cast<float>(display_texture->GetHeight());

    glViewport(0, 0, static_cast<GLsizei>(frame_width), static_cast<GLsizei>(frame_height));

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, src_texture);
    glBindSampler(0, s_display_nearest_sampler);

    glUseProgram(s_display_program);
    glUniform4f(s_display_uniform_src_rect,
                static_cast<float>(display_rect.x) / tex_width,
                static_cast<float>(display_rect.y) / tex_height,
                static_cast<float>(display_width) / tex_width,
                static_cast<float>(display_height) / tex_height);

    glBindVertexArray(s_display_vao);
    glDrawArrays(GL_TRIANGLES, 0, 3);

    glBindSampler(0, 0);
  }

  // Clean up.
  glUseProgram(0);
  glBindVertexArray(0);
  glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);

  s_video_refresh_callback(RETRO_HW_FRAME_BUFFER_VALID, frame_width, frame_height, 0);
}

// =============================================================================
// retro_* API entry points
// =============================================================================

RETRO_API void retro_set_environment(retro_environment_t cb)
{
  s_environment_callback = cb;

  // Get log callback
  retro_log_callback log_cb;
  if (cb(RETRO_ENVIRONMENT_GET_LOG_INTERFACE, &log_cb))
    s_log_callback = log_cb.log;

  // Check for input bitmask support
  LibretroHost::s_supports_input_bitmasks = cb(RETRO_ENVIRONMENT_GET_INPUT_BITMASKS, nullptr);

  // Core option categories
  static retro_core_option_v2_category s_option_categories[] = {
    {"system", "System", "Console region, CPU, and emulation behavior."},
    {"bios", "BIOS", "BIOS image selection and boot behavior."},
    {"video", "Video", "GPU renderer, resolution, filtering, and enhancements."},
    {"pgxp", "PGXP", "Precision geometry transform pipeline settings."},
    {"display", "Display", "Aspect ratio, cropping, and display adjustments."},
    {"audio", "Audio", "Audio output settings."},
    {"input", "Input", "Controller and memory card settings."},
    {"cdrom", "CD-ROM", "CD-ROM emulation behavior and speed settings."},
    {"texture_replacements", "Texture Replacements", "Texture replacement, dumping, and caching."},
    {"hacks", "Hacks", "Emulation timing hacks and compatibility tweaks."},
    {"advanced", "Advanced", "GPU backend feature toggles for troubleshooting."},
    {nullptr, nullptr, nullptr},
  };

  // Core option definitions
  static retro_core_option_v2_definition s_option_definitions[] = {

    // =====================================================================
    // SYSTEM
    // =====================================================================
    {
      "goosestation_region", "Console Region", "Region",
      "Auto-detect from disc or force a specific region.",
      nullptr, "system",
      {{"Auto", "Auto-Detect"}, {"NTSC-J", "NTSC-J (Japan)"}, {"NTSC-U", "NTSC-U (North America)"}, {"PAL", "PAL (Europe)"}, {nullptr, nullptr}},
      "Auto"
    },
    // =====================================================================
    // BIOS
    // =====================================================================
    {
      "goosestation_bios_path_ntsc_j", "BIOS Image (NTSC-J)", "BIOS (JP)",
      "Select a BIOS image for the NTSC-J (Japan) region. BIOS files should be placed in the frontend's system directory. SCPH-5500 is the recommended BIOS for this region. PSX-XBOO is a region-free alternative.",
      nullptr, "bios",
      {{"auto", "Auto-Detect"}, {"PSX-XBOO.ROM", "PSX-XBOO (nocash)"}, {"scph5500.bin", "SCPH-5500"}, {"scph1001.bin", "SCPH-1001"}, {"ps1_rom.bin", "ps1_rom.bin"}, {"psxonpsp660.bin", "psxonpsp660.bin"}, {nullptr, nullptr}},
      "auto"
    },
    {
      "goosestation_bios_path_ntsc_u", "BIOS Image (NTSC-U)", "BIOS (US)",
      "Select a BIOS image for the NTSC-U (North America) region. BIOS files should be placed in the frontend's system directory. SCPH-5501 is the recommended BIOS for this region. PSX-XBOO is a region-free alternative.",
      nullptr, "bios",
      {{"auto", "Auto-Detect"}, {"PSX-XBOO.ROM", "PSX-XBOO (nocash)"}, {"scph5501.bin", "SCPH-5501"}, {"scph1001.bin", "SCPH-1001"}, {"ps1_rom.bin", "ps1_rom.bin"}, {"psxonpsp660.bin", "psxonpsp660.bin"}, {nullptr, nullptr}},
      "auto"
    },
    {
      "goosestation_bios_path_pal", "BIOS Image (PAL)", "BIOS (EU)",
      "Select a BIOS image for the PAL (Europe) region. BIOS files should be placed in the frontend's system directory. SCPH-5502 is the recommended BIOS for this region. PSX-XBOO is a region-free alternative.",
      nullptr, "bios",
      {{"auto", "Auto-Detect"}, {"PSX-XBOO.ROM", "PSX-XBOO (nocash)"}, {"scph5502.bin", "SCPH-5502"}, {"scph1001.bin", "SCPH-1001"}, {"ps1_rom.bin", "ps1_rom.bin"}, {"psxonpsp660.bin", "psxonpsp660.bin"}, {nullptr, nullptr}},
      "auto"
    },
    {
      "goosestation_bios_fast_boot", "Fast Boot", "Fast Boot",
      "Patches the BIOS to skip the boot animation and go straight to the game. Safe to enable. Not supported by all BIOS images (e.g. PSX-XBOO, OpenBIOS).",
      nullptr, "bios",
      {{"true", "Enabled"}, {"false", "Disabled"}, {nullptr, nullptr}},
      "true"
    },
    {
      "goosestation_bios_fast_forward_boot", "Fast Forward Boot", "FF Boot",
      "Fast-forward through the early loading process when fast booting, saving time. Results may vary between games.",
      nullptr, "bios",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_bios_tty_logging", "BIOS TTY Logging", "TTY Logging",
      "Logs BIOS calls to printf(). Not all games contain debugging messages.",
      nullptr, "bios",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_cpu_execution_mode", "CPU Execution Mode", "Execution Mode",
      "Determines how the emulated CPU executes instructions.",
      nullptr, "system",
      {{"Recompiler", "Recompiler"}, {"CachedInterpreter", "Cached Interpreter"}, {"Interpreter", "Interpreter"}, {nullptr, nullptr}},
      "Recompiler"
    },
    {
      "goosestation_cpu_overclock", "CPU Overclock", "Overclock",
      "Overclock or underclock the emulated CPU. May improve or break games.",
      nullptr, "system",
      {{"25", "25% (Underclock)"}, {"50", "50% (Underclock)"}, {"75", "75% (Underclock)"}, {"100", "100% (Default)"}, {"125", "125%"}, {"150", "150%"}, {"175", "175%"}, {"200", "200%"}, {"250", "250%"}, {"300", "300%"}, {"400", "400%"}, {"500", "500%"}, {nullptr, nullptr}},
      "100"
    },
    {
      "goosestation_cpu_recompiler_memory_exceptions", "Recompiler Memory Exceptions", "Memory Exceptions",
      "Enables alignment and bus exceptions. Not needed for any known games.",
      nullptr, "system",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_cpu_recompiler_block_linking", "Recompiler Block Linking", "Block Linking",
      "Performance enhancement - jumps directly between blocks instead of returning to the dispatcher.",
      nullptr, "system",
      {{"true", "Enabled"}, {"false", "Disabled"}, {nullptr, nullptr}},
      "true"
    },
    {
      "goosestation_cpu_recompiler_icache", "Recompiler ICache", "ICache",
      "Makes games run closer to their console framerate, at a small cost to performance.",
      nullptr, "system",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_cpu_fastmem_mode", "CPU Fastmem Mode", "Fastmem",
      "Avoids calls to C++ code, significantly speeding up the recompiler.",
      nullptr, "system",
      {{"MMap", "MMap (Fastest)"}, {"LUT", "LUT (Compatible)"}, {"Disabled", "Disabled (Safest)"}, {nullptr, nullptr}},
      "MMap"
    },
    {
      "goosestation_8mb_ram", "Enable 8MB RAM (Restart)", "8MB RAM",
      "Expands RAM from 2MB to 8MB. Required by some homebrew.",
      nullptr, "system",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_apply_compatibility_settings", "Apply Compatibility Settings", "Compat Settings",
      "Automatically apply per-game compatibility fixes from the database.",
      nullptr, "system",
      {{"true", "Enabled"}, {"false", "Disabled"}, {nullptr, nullptr}},
      "true"
    },
    {
      "goosestation_disable_all_enhancements", "Disable All Enhancements", "No Enhancements",
      "Temporarily disable all enhancements (resolution scale, texture filtering, PGXP, etc.).",
      nullptr, "system",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_load_devices_from_save_states", "Load Devices From Save States", "Devices from States",
      "Load controller and memory card configuration from save states.",
      nullptr, "system",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },

    // =====================================================================
    // VIDEO
    // =====================================================================
    {
      "goosestation_renderer", "GPU Renderer (Restart)", "Renderer",
      "Selects the backend to use for rendering the console/game visuals. Changing this requires restarting the core.",
      nullptr, "video",
      {{"Software", "Software"}, {"OpenGL", "OpenGL"}, {"Vulkan", "Vulkan"}, {nullptr, nullptr}},
      "Software"
    },
    {
      "goosestation_resolution_scale", "Internal Resolution Scale", "Resolution Scale",
      "Upscales the game's rendering by the specified multiplier. Only applies to hardware renderers.",
      nullptr, "video",
      {{"1", "1x (Native)"}, {"2", "2x"}, {"3", "3x"}, {"4", "4x"}, {"5", "5x"}, {"6", "6x"}, {"7", "7x"}, {"8", "8x"}, {"9", "9x"}, {"10", "10x"}, {"11", "11x"}, {"12", "12x"}, {"13", "13x"}, {"14", "14x"}, {"15", "15x"}, {"16", "16x"}, {nullptr, nullptr}},
      "1"
    },
    {
      "goosestation_gpu_multisamples", "Multisample Antialiasing", "MSAA",
      "Applies MSAA to reduce jagged edges. Higher values are more demanding. Hardware renderers only.",
      nullptr, "video",
      {{"1", "Disabled"}, {"2", "2x MSAA"}, {"4", "4x MSAA"}, {"8", "8x MSAA"}, {"16", "16x MSAA"}, {nullptr, nullptr}},
      "1"
    },
    {
      "goosestation_texture_filter", "Texture Filtering", "Texture Filter",
      "Smooths out the blockiness of magnified textures on 3D objects.",
      nullptr, "video",
      {{"Nearest", "Nearest (Default)"}, {"Bilinear", "Bilinear"}, {"BilinearBinAlpha", "Bilinear (No Edge Blending)"}, {"JINC2", "JINC2"}, {"JINC2BinAlpha", "JINC2 (No Edge Blending)"}, {"xBR", "xBR"}, {"xBRBinAlpha", "xBR (No Edge Blending)"}, {"Scale2x", "Scale2x"}, {"Scale3x", "Scale3x"}, {"MMPX", "MMPX"}, {"MMPXEnhanced", "MMPX Enhanced"}, {nullptr, nullptr}},
      "Nearest"
    },
    {
      "goosestation_sprite_texture_filter", "Sprite Texture Filtering", "Sprite Filter",
      "Smooths out the blockiness of magnified textures on 2D objects.",
      nullptr, "video",
      {{"Nearest", "Nearest (Default)"}, {"Bilinear", "Bilinear"}, {"BilinearBinAlpha", "Bilinear (No Edge Blending)"}, {"JINC2", "JINC2"}, {"JINC2BinAlpha", "JINC2 (No Edge Blending)"}, {"xBR", "xBR"}, {"xBRBinAlpha", "xBR (No Edge Blending)"}, {"Scale2x", "Scale2x"}, {"Scale3x", "Scale3x"}, {"MMPX", "MMPX"}, {"MMPXEnhanced", "MMPX Enhanced"}, {nullptr, nullptr}},
      "Nearest"
    },
    {
      "goosestation_dithering_mode", "Dithering Mode", "Dithering",
      "Controls how dithering is applied in the emulated GPU. True Color disables dithering and produces the nicest looking gradients.",
      nullptr, "video",
      {{"TrueColor", "True Color (No Dithering)"}, {"TrueColorFull", "True Color (Full Precision)"}, {"Unscaled", "Unscaled (Authentic)"}, {"UnscaledShaderBlend", "Unscaled (Shader Blend)"}, {"Scaled", "Scaled"}, {"ScaledShaderBlend", "Scaled (Shader Blend)"}, {nullptr, nullptr}},
      "TrueColor"
    },
    {
      "goosestation_deinterlacing", "Deinterlacing Mode", "Deinterlacing",
      "Determines which algorithm is used to convert interlaced frames to progressive for display on your system.",
      nullptr, "video",
      {{"Progressive", "Progressive"}, {"Adaptive", "Adaptive"}, {"Weave", "Weave"}, {"Blend", "Blend"}, {"Disabled", "Disabled"}, {nullptr, nullptr}},
      "Progressive"
    },
    {
      "goosestation_gpu_scaled_interlacing", "Scaled Interlacing", "Scaled Interlace",
      "Scales line skipping in interlaced rendering to the internal resolution, making it less noticeable. Usually safe to enable.",
      nullptr, "video",
      {{"true", "Enabled"}, {"false", "Disabled"}, {nullptr, nullptr}},
      "true"
    },
    {
      "goosestation_gpu_line_detect_mode", "Line Detection Mode", "Line Detect",
      "Attempts to detect one pixel high/wide lines that rely on non-upscaled rasterization behavior, filling in gaps introduced by upscaling.",
      nullptr, "video",
      {{"Disabled", "Disabled"}, {"Quads", "Quads"}, {"BasicTriangles", "Basic Triangles"}, {"AggressiveTriangles", "Aggressive Triangles"}, {nullptr, nullptr}},
      "Disabled"
    },
    {
      "goosestation_gpu_downsample_mode", "Downsampling Mode", "Downsample",
      "Downsamples the rendered image prior to displaying it. Can improve overall image quality in mixed 2D/3D games.",
      nullptr, "video",
      {{"Disabled", "Disabled"}, {"Box", "Box Filter"}, {"Adaptive", "Adaptive"}, {nullptr, nullptr}},
      "Disabled"
    },
    {
      "goosestation_gpu_downsample_scale", "Downsample Scale", "DS Scale",
      "Selects the resolution scale that will be applied to the final image. 1x will downsample to the original console resolution.",
      nullptr, "video",
      {{"1", "1x (Native)"}, {"2", "2x"}, {"3", "3x"}, {"4", "4x"}, {nullptr, nullptr}},
      "1"
    },
    {
      "goosestation_gpu_wireframe_mode", "Wireframe Mode", "Wireframe",
      "Overlays or replaces normal triangle drawing with a wireframe/line view.",
      nullptr, "video",
      {{"Disabled", "Disabled"}, {"OverlayWireframe", "Overlay"}, {"OnlyWireframe", "Only Wireframe"}, {nullptr, nullptr}},
      "Disabled"
    },
    {
      "goosestation_gpu_force_video_timing", "Force Video Timing", "Force Timing",
      "Force NTSC or PAL video timing regardless of disc region.",
      nullptr, "video",
      {{"Disabled", "Disabled (Auto)"}, {"NTSC", "NTSC (60Hz)"}, {"PAL", "PAL (50Hz)"}, {nullptr, nullptr}},
      "Disabled"
    },
    {
      "goosestation_chroma_smoothing", "24-Bit Chroma Smoothing", "Chroma Smoothing",
      "Smooths out blockyness between colour transitions in 24-bit content, usually FMVs.",
      nullptr, "video",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_widescreen_hack", "Widescreen Hack", "Widescreen",
      "Increases the field of view from 4:3 to the chosen display aspect ratio in 3D games.",
      nullptr, "video",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_per_sample_shading", "Per-Sample Shading", "Per-Sample",
      "Shade each MSAA sample independently. Improves quality with MSAA but is more demanding.",
      nullptr, "video",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_force_round_texcoords", "Force Round Texture Coordinates", "Round TexCoords",
      "Rounds texture coordinates instead of flooring when upscaling. Can fix misaligned textures in some games, but break others, and is incompatible with texture filtering.",
      nullptr, "video",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_modulation_crop", "Modulation Crop", "Mod Crop",
      "Crops vertex colours to 5:5:5 before modulating with the texture colour, which typically results in more visible banding.",
      nullptr, "video",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_texture_cache", "Texture Cache", "Tex Cache",
      "Enables caching of guest textures, required for texture replacement.",
      nullptr, "video",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_software_readbacks", "Software Renderer for Readbacks", "SW Readbacks",
      "Runs the software renderer in parallel for VRAM readbacks. On some systems, this may result in greater performance when using graphical enhancements with the hardware renderer.",
      nullptr, "video",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },

    // =====================================================================
    // PGXP
    // =====================================================================
    {
      "goosestation_pgxp_enable", "PGXP Geometry Correction", "PGXP",
      "Reduces \"wobbly\" polygons by attempting to preserve the fractional component through memory transfers. Hardware renderers only.",
      nullptr, "pgxp",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_pgxp_culling", "PGXP Culling Correction", "Culling",
      "Increases the precision of polygon culling, reducing the number of holes in geometry.",
      nullptr, "pgxp",
      {{"true", "Enabled"}, {"false", "Disabled"}, {nullptr, nullptr}},
      "true"
    },
    {
      "goosestation_pgxp_texture_correction", "PGXP Texture Correction", "Texture Correction",
      "Uses perspective-correct interpolation for texture coordinates, straightening out warped textures.",
      nullptr, "pgxp",
      {{"true", "Enabled"}, {"false", "Disabled"}, {nullptr, nullptr}},
      "true"
    },
    {
      "goosestation_pgxp_color_correction", "PGXP Color Correction", "Color Correction",
      "Uses perspective-correct interpolation for colors, which can improve visuals in some games.",
      nullptr, "pgxp",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_pgxp_depth_buffer", "PGXP Depth Buffer", "Depth Buffer",
      "Reduces polygon Z-fighting through depth testing. Low compatibility with games.",
      nullptr, "pgxp",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_pgxp_vertex_cache", "PGXP Vertex Cache", "Vertex Cache",
      "Uses screen positions to resolve PGXP data. May improve visuals in some games.",
      nullptr, "pgxp",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_pgxp_cpu", "PGXP CPU Mode", "CPU Mode",
      "Uses PGXP for all instructions, not just memory operations.",
      nullptr, "pgxp",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_pgxp_preserve_proj_fp", "PGXP Preserve Projection Precision", "Preserve Proj FP",
      "Adds additional precision to PGXP data post-projection. May improve visuals in some games.",
      nullptr, "pgxp",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_pgxp_tolerance", "PGXP Geometry Tolerance", "Tolerance",
      "Sets a threshold for discarding precise values when exceeded. May help with glitches in some games.",
      nullptr, "pgxp",
      {{"-1.0", "Automatic"}, {"0.5", "0.5"}, {"1.0", "1.0"}, {"2.0", "2.0"}, {"4.0", "4.0"}, {"8.0", "8.0"}, {"16.0", "16.0"}, {nullptr, nullptr}},
      "-1.0"
    },
    {
      "goosestation_pgxp_disable_2d", "PGXP Disable on 2D Polygons", "Disable 2D",
      "Uses native resolution coordinates for 2D polygons, instead of precise coordinates. Can fix misaligned UI in some games, but otherwise should be left disabled.",
      nullptr, "pgxp",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_pgxp_transparent_depth", "PGXP Transparent Depth Test", "Transparent Depth",
      "Enables depth testing for semi-transparent polygons. Usually these include shadows, and tend to clip through the ground when depth testing is enabled.",
      nullptr, "pgxp",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_pgxp_depth_clear_threshold", "PGXP Depth Clear Threshold", "Depth Threshold",
      "Sets a threshold for discarding the emulated depth buffer. May help in some games.",
      nullptr, "pgxp",
      {{"300", "300"}, {"500", "500"}, {"1000", "1000"}, {"1024", "1024"}, {"2048", "2048"}, {"4096", "4096 (Default)"}, {"8192", "8192"}, {"16384", "16384"}, {nullptr, nullptr}},
      "4096"
    },

    // =====================================================================
    // DISPLAY
    // =====================================================================
    {
      "goosestation_crop_mode", "Display Crop Mode", "Crop Mode",
      "Determines how much of the area typically not visible on a consumer TV set to crop/hide.",
      nullptr, "display",
      {{"None", "None (Full Image)"}, {"Overscan", "Overscan Area Only"}, {"OverscanUncorrected", "Overscan (Uncorrected)"}, {"Borders", "All Borders"}, {"BordersUncorrected", "All Borders (Uncorrected)"}, {nullptr, nullptr}},
      "Overscan"
    },
    {
      "goosestation_aspect_ratio", "Aspect Ratio", "Aspect Ratio",
      "Display aspect ratio. Auto uses the game's native ratio.",
      nullptr, "display",
      {{"Auto (Game Native)", "Auto (Game Native)"}, {"4:3", "4:3"}, {"16:9", "16:9"}, {"16:10", "16:10"}, {"19:9", "19:9"}, {"20:9", "20:9"}, {"21:9", "21:9"}, {"32:9", "32:9"}, {"2:1", "2:1"}, {"1:1", "1:1"}, {"5:4", "5:4"}, {"3:2", "3:2"}, {"PAR 1:1", "Pixel Aspect 1:1"}, {"Stretch To Fill", "Stretch To Fill"}, {nullptr, nullptr}},
      "Auto (Game Native)"
    },
    {
      "goosestation_display_force_4_3_for_24bit", "FMV Aspect Ratio (24-Bit)", "FMV Aspect",
      "Switches back to 4:3 display aspect ratio when displaying 24-bit content, usually FMVs. 'Zoom 16:9' crops letterbox bars by assuming 16:9 content in a 4:3 frame.",
      nullptr, "display",
      {{"false", "Disabled"}, {"true", "Force 4:3"}, {"zoom_16_9", "Zoom 16:9"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_display_rotation", "Display Rotation", "Rotation",
      "Determines the rotation of the simulated TV screen.",
      nullptr, "display",
      {{"Normal", "Normal (0\xc2\xb0)"}, {"Rotate90", "90\xc2\xb0"}, {"Rotate180", "180\xc2\xb0"}, {"Rotate270", "270\xc2\xb0"}, {nullptr, nullptr}},
      "Normal"
    },
    {
      "goosestation_display_active_start_offset", "Active Start Offset", "Start Offset",
      "Pixel offset for the left edge of the active display area. Range: -128 to 128.",
      nullptr, "display",
      {{"-32", "-32"}, {"-16", "-16"}, {"-8", "-8"}, {"-4", "-4"}, {"0", "0 (Default)"}, {"4", "4"}, {"8", "8"}, {"16", "16"}, {"32", "32"}, {nullptr, nullptr}},
      "0"
    },
    {
      "goosestation_display_active_end_offset", "Active End Offset", "End Offset",
      "Pixel offset for the right edge of the active display area. Range: -128 to 128.",
      nullptr, "display",
      {{"-32", "-32"}, {"-16", "-16"}, {"-8", "-8"}, {"-4", "-4"}, {"0", "0 (Default)"}, {"4", "4"}, {"8", "8"}, {"16", "16"}, {"32", "32"}, {nullptr, nullptr}},
      "0"
    },
    {
      "goosestation_display_line_start_offset", "Line Start Offset", "Line Start",
      "Scanline offset for the top of the display. Range: -16 to 16.",
      nullptr, "display",
      {{"-16", "-16"}, {"-8", "-8"}, {"-4", "-4"}, {"-2", "-2"}, {"0", "0 (Default)"}, {"2", "2"}, {"4", "4"}, {"8", "8"}, {"16", "16"}, {nullptr, nullptr}},
      "0"
    },
    {
      "goosestation_display_line_end_offset", "Line End Offset", "Line End",
      "Scanline offset for the bottom of the display. Range: -16 to 16.",
      nullptr, "display",
      {{"-16", "-16"}, {"-8", "-8"}, {"-4", "-4"}, {"-2", "-2"}, {"0", "0 (Default)"}, {"2", "2"}, {"4", "4"}, {"8", "8"}, {"16", "16"}, {nullptr, nullptr}},
      "0"
    },

    // =====================================================================
    // AUDIO
    // =====================================================================
    {
      "goosestation_audio_output_volume", "Output Volume", "Volume",
      "Audio output volume (0-100%).",
      nullptr, "audio",
      {{"0", "0% (Mute)"}, {"10", "10%"}, {"20", "20%"}, {"30", "30%"}, {"40", "40%"}, {"50", "50%"}, {"60", "60%"}, {"70", "70%"}, {"80", "80%"}, {"90", "90%"}, {"100", "100% (Default)"}, {nullptr, nullptr}},
      "100"
    },
    {
      "goosestation_audio_fast_forward_volume", "Fast Forward Volume", "FF Volume",
      "Audio volume during fast-forward (0-100%).",
      nullptr, "audio",
      {{"0", "0% (Mute)"}, {"10", "10%"}, {"20", "20%"}, {"30", "30%"}, {"40", "40%"}, {"50", "50%"}, {"60", "60%"}, {"70", "70%"}, {"80", "80%"}, {"90", "90%"}, {"100", "100% (Default)"}, {nullptr, nullptr}},
      "100"
    },
    {
      "goosestation_audio_output_muted", "Mute Audio", "Mute",
      "Mute all audio output.",
      nullptr, "audio",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },

    // =====================================================================
    // INPUT
    // =====================================================================
    {
      "goosestation_controller_1_type", "Port 1 Controller Type", "Port 1 Type",
      "Type of controller connected to port 1.",
      nullptr, "input",
      {{"AnalogController", "DualShock (Analog)"}, {"DigitalController", "Digital Pad"}, {"AnalogJoystick", "Analog Joystick"}, {"NeGcon", "NeGcon"}, {"NeGconRumble", "NeGcon (Rumble)"}, {"GunCon", "GunCon"}, {"Justifier", "Justifier"}, {"PlayStationMouse", "PlayStation Mouse"}, {"PopnController", "Pop'n Controller"}, {"DDGoController", "DD Go! Controller"}, {"JogCon", "JogCon"}, {"None", "None"}, {nullptr, nullptr}},
      "AnalogController"
    },
    {
      "goosestation_controller_2_type", "Port 2 Controller Type", "Port 2 Type",
      "Type of controller connected to port 2.",
      nullptr, "input",
      {{"None", "None"}, {"AnalogController", "DualShock (Analog)"}, {"DigitalController", "Digital Pad"}, {"AnalogJoystick", "Analog Joystick"}, {"NeGcon", "NeGcon"}, {"NeGconRumble", "NeGcon (Rumble)"}, {"GunCon", "GunCon"}, {"Justifier", "Justifier"}, {"PlayStationMouse", "PlayStation Mouse"}, {"PopnController", "Pop'n Controller"}, {"DDGoController", "DD Go! Controller"}, {"JogCon", "JogCon"}, {nullptr, nullptr}},
      "None"
    },
    {
      "goosestation_multitap", "Multitap Mode", "Multitap",
      "Enables multitap adapter for additional controller ports.",
      nullptr, "input",
      {{"Disabled", "Disabled"}, {"Port1Only", "Port 1 Only"}, {"Port2Only", "Port 2 Only"}, {"BothPorts", "Both Ports"}, {nullptr, nullptr}},
      "Disabled"
    },
    {
      "goosestation_memory_card_1_type", "Memory Card 1 Type", "Card 1 Type",
      "Type of memory card in slot 1.",
      nullptr, "input",
      {{"PerGameTitle", "Per-Game (Title)"}, {"PerGame", "Per-Game (Serial)"}, {"PerGameFileTitle", "Per-Game (File Title)"}, {"Shared", "Shared"}, {"NonPersistent", "Non-Persistent"}, {"None", "None"}, {nullptr, nullptr}},
      "PerGameTitle"
    },
    {
      "goosestation_memory_card_2_type", "Memory Card 2 Type", "Card 2 Type",
      "Type of memory card in slot 2.",
      nullptr, "input",
      {{"None", "None"}, {"PerGameTitle", "Per-Game (Title)"}, {"PerGame", "Per-Game (Serial)"}, {"PerGameFileTitle", "Per-Game (File Title)"}, {"Shared", "Shared"}, {"NonPersistent", "Non-Persistent"}, {nullptr, nullptr}},
      "None"
    },
    {
      "goosestation_memory_card_use_playlist_title", "Use Playlist Title for Memory Cards", "Playlist Title",
      "Use the playlist/M3U title for per-game memory cards instead of individual disc titles.",
      nullptr, "input",
      {{"true", "Enabled"}, {"false", "Disabled"}, {nullptr, nullptr}},
      "true"
    },

    // =====================================================================
    // CD-ROM
    // =====================================================================
    {
      "goosestation_cd_read_speedup", "CD-ROM Read Speedup", "Read Speedup",
      "Speeds up CD-ROM reads by the specified factor. May improve loading speeds in some games, and break others.",
      nullptr, "cdrom",
      {{"1", "1x (Default)"}, {"2", "2x"}, {"3", "3x"}, {"4", "4x"}, {"5", "5x"}, {"6", "6x"}, {"7", "7x"}, {"8", "8x"}, {"10", "10x"}, {"14", "14x"}, {"20", "20x"}, {nullptr, nullptr}},
      "1"
    },
    {
      "goosestation_cd_seek_speedup", "CD-ROM Seek Speedup", "Seek Speedup",
      "Speeds up CD-ROM seeks by the specified factor. May improve loading speeds in some games, and break others.",
      nullptr, "cdrom",
      {{"1", "1x (Default)"}, {"2", "2x"}, {"3", "3x"}, {"5", "5x"}, {"7", "7x"}, {"10", "10x"}, {"0", "Instant"}, {nullptr, nullptr}},
      "1"
    },
    {
      "goosestation_cdrom_region_check", "CD-ROM Region Check", "Region Check",
      "Simulates the region check present in original, unmodified consoles.",
      nullptr, "cdrom",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_cdrom_subq_skew", "CD-ROM SubQ Skew", "SubQ Skew",
      "Enable SubQ skew emulation. Improves timing accuracy for some games.",
      nullptr, "cdrom",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_cdrom_load_image_to_ram", "Preload Image to RAM", "Preload RAM",
      "Loads the game image into RAM. Useful for network paths that may become unreliable during gameplay.",
      nullptr, "cdrom",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_cdrom_load_image_patches", "Apply Image Patches (Restart)", "Image Patches",
      "Automatically applies patches to disc images when they are present, currently only PPF is supported.",
      nullptr, "cdrom",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_cdrom_mute_cd_audio", "Mute CD Audio", "Mute CD",
      "Mute CD-DA audio tracks. Game sound effects and music from the SPU are unaffected.",
      nullptr, "cdrom",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_cdrom_readahead_sectors", "Readahead Sectors", "Readahead",
      "Number of sectors to read ahead. Higher values may reduce stuttering.",
      nullptr, "cdrom",
      {{"0", "0 (Disabled)"}, {"1", "1"}, {"2", "2"}, {"4", "4"}, {"8", "8 (Default)"}, {"16", "16"}, {"32", "32"}, {"64", "64"}, {nullptr, nullptr}},
      "8"
    },
    {
      "goosestation_cdrom_mechacon_version", "Mechacon Version", "Mechacon",
      "CD-ROM controller version to emulate. Affects copy protection behavior.",
      nullptr, "cdrom",
      {{"VC0A", "VC0A (SCPH-1000/DTL-H1000)"}, {"VC0B", "VC0B (SCPH-1001)"}, {"VC1A", "VC1A (SCPH-3000, Default)"}, {"VC1B", "VC1B (SCPH-3500)"}, {"VD1", "VD1 (DTL-H1001)"}, {"VC2", "VC2 (SCPH-5000)"}, {"VC1", "VC1 (SCPH-5500)"}, {"VC2J", "VC2J (SCPH-5500)"}, {"VC2A", "VC2A (SCPH-5501/5503)"}, {"VC2B", "VC2B (SCPH-5502)"}, {"VC3A", "VC3A (SCPH-7000)"}, {"VC3B", "VC3B (SCPH-7001)"}, {"VC3C", "VC3C (SCPH-7002)"}, {nullptr, nullptr}},
      "VC1A"
    },
    {
      "goosestation_cdrom_disable_speedup_on_mdec", "Disable Speedup on MDEC", "No FMV Speedup",
      "Disable CD-ROM read speedup during MDEC (FMV) playback to prevent stuttering.",
      nullptr, "cdrom",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_cdrom_ignore_host_subcode", "Ignore Drive Subcode", "Ignore Subcode",
      "Ignores the subchannel provided by the drive when using physical discs, instead always generating subchannel data. Can improve read reliability on some drives.",
      nullptr, "cdrom",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },

    // =====================================================================
    // TEXTURE REPLACEMENTS
    // =====================================================================
    {
      "goosestation_texture_replacement_enable", "Enable Texture Replacements", "Tex Replace",
      "Load replacement textures from the textures directory. Requires texture cache.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_vram_write_replacement_enable", "Enable VRAM Write Replacements", "VRAM Replace",
      "Load VRAM write replacement textures. Works without texture cache.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_texture_replacement_preload", "Preload Replacement Textures", "Preload",
      "Load all replacement textures into memory at startup. Uses more RAM but prevents stutter.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_texture_replacement_always_track", "Always Track Uploads", "Track Uploads",
      "Always track texture uploads even when replacements are not active. Required for dumping.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_texture_dump_enable", "Dump Textures", "Dump Textures",
      "Dump textures to the dump directory for creating texture packs.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_vram_write_dump_enable", "Dump VRAM Writes", "Dump VRAM",
      "Dump VRAM writes to the dump directory for creating texture packs.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_texture_replacement_linear_filter", "Replacement Scale Linear Filter", "Scale Filter",
      "Use linear filtering when scaling replacement textures to match resolution.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_texture_dump_texture_pages", "Dump Texture Pages", "Dump Pages",
      "Dump full 256x256 texture pages instead of individual textures.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_texture_dump_full_texture_pages", "Dump Full Texture Pages", "Dump Full Pages",
      "Include unused regions when dumping texture pages.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_texture_dump_force_alpha", "Dump Texture Force Alpha", "Force Alpha",
      "Force alpha channel to fully opaque when dumping textures.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_vram_write_dump_force_alpha", "VRAM Write Dump Force Alpha", "VRAM Force Alpha",
      "Force alpha channel to fully opaque when dumping VRAM writes.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "true"
    },
    {
      "goosestation_texture_dump_replaced", "Dump Replaced Textures", "Dump Replaced",
      "Re-dump textures that already have replacements. Useful for debugging texture packs.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "true"
    },
    {
      "goosestation_texture_dump_c16", "Dump C16 Textures", "Dump C16",
      "Dump textures in C16 format instead of PNG.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_texture_reduce_palette_range", "Reduce Palette Range", "Palette Range",
      "Reduce palette matching range for texture replacements. Improves matching accuracy.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "true"
    },
    {
      "goosestation_texture_convert_copies_to_writes", "Convert Copies to Writes", "Copies→Writes",
      "Treat VRAM copies as writes for texture replacement. Some games need this.",
      nullptr, "texture_replacements",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },

    // =====================================================================
    // HACKS
    // =====================================================================
    {
      "goosestation_dma_max_slice_ticks", "DMA Max Slice Ticks", "DMA Slice",
      "Maximum number of ticks per DMA transfer slice. Lower values improve timing accuracy.",
      nullptr, "hacks",
      {{"100", "100"}, {"200", "200"}, {"500", "500"}, {"1000", "1000 (Default)"}, {"2000", "2000"}, {"5000", "5000"}, {"10000", "10000"}, {nullptr, nullptr}},
      "1000"
    },
    {
      "goosestation_dma_halt_ticks", "DMA Halt Ticks", "DMA Halt",
      "Number of ticks the CPU halts during DMA. Affects DMA/CPU timing interaction.",
      nullptr, "hacks",
      {{"50", "50"}, {"100", "100 (Default)"}, {"150", "150"}, {"200", "200"}, {"500", "500"}, {"1000", "1000"}, {nullptr, nullptr}},
      "100"
    },
    {
      "goosestation_gpu_fifo_size", "GPU FIFO Size", "GPU FIFO",
      "Size of the GPU command FIFO buffer. Affects GPU/CPU timing.",
      nullptr, "hacks",
      {{"8", "8"}, {"16", "16 (Default)"}, {"32", "32"}, {nullptr, nullptr}},
      "16"
    },
    {
      "goosestation_gpu_max_run_ahead", "GPU Max Run-Ahead", "GPU Runahead",
      "Maximum number of ticks the GPU can run ahead of the CPU.",
      nullptr, "hacks",
      {{"0", "0"}, {"64", "64"}, {"128", "128 (Default)"}, {"256", "256"}, {"512", "512"}, {"1024", "1024"}, {nullptr, nullptr}},
      "128"
    },
    {
      "goosestation_mdec_use_old_routines", "Use Old MDEC Routines", "Old MDEC",
      "Use older MDEC decoding routines. May fix FMV issues in some games.",
      nullptr, "hacks",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },

    // =====================================================================
    // ADVANCED (GPU backend toggles)
    // =====================================================================
    {
      "goosestation_gpu_disable_shader_cache", "Disable Shader Cache", "No Shader Cache",
      "Disable the GPU shader cache. Shaders will be recompiled each launch.",
      nullptr, "advanced",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_disable_dual_source_blend", "Disable Dual Source Blend", "No DSB",
      "Disable dual-source blending. May fix rendering on some GPU drivers.",
      nullptr, "advanced",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_disable_framebuffer_fetch", "Disable Framebuffer Fetch", "No FB Fetch",
      "Disable framebuffer fetch extension. May fix rendering on some GPU drivers.",
      nullptr, "advanced",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_disable_texture_buffers", "Disable Texture Buffers", "No Tex Buffers",
      "Disable texture buffer objects. May fix rendering on some GPU drivers.",
      nullptr, "advanced",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_disable_texture_copy_to_self", "Disable Texture Copy to Self", "No Tex Self-Copy",
      "Disable texture self-copy optimization. May fix rendering artifacts.",
      nullptr, "advanced",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_disable_memory_import", "Disable Memory Import", "No Mem Import",
      "Disable memory import for VRAM uploads. May fix issues on some drivers.",
      nullptr, "advanced",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_disable_raster_order_views", "Disable Raster Order Views", "No ROV",
      "Disable raster order views. May fix rendering on some GPU drivers.",
      nullptr, "advanced",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_disable_compute_shaders", "Disable Compute Shaders", "No Compute",
      "Disable compute shader usage. May fix rendering on some GPU drivers.",
      nullptr, "advanced",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_disable_compressed_textures", "Disable Compressed Textures", "No Compressed Tex",
      "Disable compressed texture formats. May fix rendering on some GPU drivers.",
      nullptr, "advanced",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },
    {
      "goosestation_gpu_show_vram", "Show VRAM", "Show VRAM",
      "Display the raw VRAM contents instead of the game output. Debug feature.",
      nullptr, "advanced",
      {{"false", "Disabled"}, {"true", "Enabled"}, {nullptr, nullptr}},
      "false"
    },

    // Terminator
    {nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, {{nullptr, nullptr}}, nullptr},
  };

  static retro_core_options_v2 s_core_options = {
    s_option_categories,
    s_option_definitions,
  };


  cb(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_V2, &s_core_options);

  // Option visibility: hide HW-only options when using software renderer.
  static retro_core_options_update_display_callback update_display_cb = {};
  update_display_cb.callback = []() -> bool {
    const char* renderer = nullptr;
    GetVariable("goosestation_renderer", &renderer);
    const bool is_hw = renderer && (std::strcmp(renderer, "Software") != 0);

    const char* pgxp_val = nullptr;
    GetVariable("goosestation_pgxp_enable", &pgxp_val);
    const bool pgxp_on = pgxp_val && (std::strcmp(pgxp_val, "true") == 0);

    // HW renderer only — matches DuckStation's graphicssettingswidget.cpp gating.
    // SW renderer: 1x native, point sampling, no PGXP, native dithering only.
    static const char* hw_only_keys[] = {
      "goosestation_resolution_scale",
      "goosestation_gpu_multisamples",
      "goosestation_texture_filter",
      "goosestation_sprite_texture_filter",
      "goosestation_dithering_mode",
      "goosestation_gpu_line_detect_mode",
      "goosestation_gpu_downsample_mode",
      "goosestation_gpu_downsample_scale",
      "goosestation_gpu_wireframe_mode",
      "goosestation_gpu_per_sample_shading",
      "goosestation_gpu_force_round_texcoords",
      "goosestation_gpu_texture_cache",
      "goosestation_gpu_software_readbacks",
      "goosestation_gpu_scaled_interlacing",
    };
    retro_core_option_display opt = {};
    for (const char* key : hw_only_keys)
    {
      opt.key = key;
      opt.visible = is_hw;
      s_environment_callback(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY, &opt);
    }

    // PGXP sub-options: only visible when PGXP is enabled (and HW renderer)
    static const char* pgxp_sub_keys[] = {
      "goosestation_pgxp_culling",
      "goosestation_pgxp_texture_correction",
      "goosestation_pgxp_color_correction",
      "goosestation_pgxp_depth_buffer",
      "goosestation_pgxp_vertex_cache",
      "goosestation_pgxp_cpu",
      "goosestation_pgxp_preserve_proj_fp",
      "goosestation_pgxp_tolerance",
      "goosestation_pgxp_disable_2d",
      "goosestation_pgxp_transparent_depth",
      "goosestation_pgxp_depth_clear_threshold",
    };
    for (const char* key : pgxp_sub_keys)
    {
      opt.key = key;
      opt.visible = is_hw && pgxp_on;
      s_environment_callback(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY, &opt);
    }

    // PGXP enable itself: only with HW renderer
    opt.key = "goosestation_pgxp_enable";
    opt.visible = is_hw;
    s_environment_callback(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_DISPLAY, &opt);

    return true;
  };
  cb(RETRO_ENVIRONMENT_SET_CORE_OPTIONS_UPDATE_DISPLAY_CALLBACK, &update_display_cb);

  // Set up disk control interface
  retro_disk_control_ext_callback disk_control = {};
  disk_control.set_eject_state = [](bool ejected) -> bool {
    LibretroHost::s_disk_control.ejected = ejected;
    if (ejected)
    {
      System::RemoveMedia();
    }
    else if (LibretroHost::s_disk_control.image_index < LibretroHost::s_disk_control.image_count)
    {
      if (LibretroHost::s_disk_control.has_sub_images)
        System::SwitchMediaSubImage(LibretroHost::s_disk_control.image_index);
      else
        System::InsertMedia(LibretroHost::s_disk_control.image_paths[LibretroHost::s_disk_control.image_index].c_str());
    }
    return true;
  };
  disk_control.get_eject_state = []() -> bool {
    return LibretroHost::s_disk_control.ejected;
  };
  disk_control.get_image_index = []() -> unsigned {
    return LibretroHost::s_disk_control.image_index;
  };
  disk_control.set_image_index = [](unsigned index) -> bool {
    if (index >= LibretroHost::s_disk_control.image_count)
      return false;
    LibretroHost::s_disk_control.image_index = index;
    return true;
  };
  disk_control.get_num_images = []() -> unsigned {
    return LibretroHost::s_disk_control.image_count;
  };
  disk_control.replace_image_index = [](unsigned index, const retro_game_info* info) -> bool {
    if (index >= LibretroHost::s_disk_control.image_count)
      return false;
    if (info && info->path)
    {
      LibretroHost::s_disk_control.image_paths[index] = info->path;
      LibretroHost::s_disk_control.image_labels[index] = Path::GetFileTitle(info->path);
    }
    return true;
  };
  disk_control.add_image_index = []() -> bool {
    LibretroHost::s_disk_control.image_count++;
    LibretroHost::s_disk_control.image_paths.emplace_back();
    LibretroHost::s_disk_control.image_labels.emplace_back();
    return true;
  };
  disk_control.set_initial_image = [](unsigned index, const char* path) -> bool {
    return true;
  };
  disk_control.get_image_path = [](unsigned index, char* path, size_t len) -> bool {
    if (index >= LibretroHost::s_disk_control.image_count)
      return false;
    StringUtil::Strlcpy(path, LibretroHost::s_disk_control.image_paths[index], len);
    return true;
  };
  disk_control.get_image_label = [](unsigned index, char* label, size_t len) -> bool {
    if (index >= LibretroHost::s_disk_control.image_count)
      return false;
    StringUtil::Strlcpy(label, LibretroHost::s_disk_control.image_labels[index], len);
    return true;
  };
  cb(RETRO_ENVIRONMENT_SET_DISK_CONTROL_EXT_INTERFACE, &disk_control);
}

RETRO_API void retro_set_video_refresh(retro_video_refresh_t cb)
{
  s_video_refresh_callback = cb;
}

RETRO_API void retro_set_audio_sample(retro_audio_sample_t cb)
{
  s_audio_sample_callback = cb;
}

RETRO_API void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb)
{
  s_audio_sample_batch_callback = cb;
}

RETRO_API void retro_set_input_poll(retro_input_poll_t cb)
{
  s_input_poll_callback = cb;
}

RETRO_API void retro_set_input_state(retro_input_state_t cb)
{
  s_input_state_callback = cb;
}

RETRO_API void retro_init(void)
{
  // Get directories
  const char* system_dir = nullptr;
  const char* save_dir = nullptr;
  const char* content_dir = nullptr;

  if (s_environment_callback(RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY, &system_dir) && system_dir)
    LibretroHost::s_system_directory = system_dir;
  if (s_environment_callback(RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY, &save_dir) && save_dir)
    LibretroHost::s_save_directory = save_dir;
  if (s_environment_callback(RETRO_ENVIRONMENT_GET_CORE_ASSETS_DIRECTORY, &content_dir) && content_dir)
    LibretroHost::s_core_assets_directory = content_dir;

  Log::RegisterCallback(DuckStationLogCallback, nullptr);

  Error error;
  if (!System::PerformEarlyHardwareChecks(&error)) {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] EarlyHWChecks failed: %s\n", error.GetDescription().c_str());
    return;
  }

  if (!System::ProcessStartup(&error))
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] ProcessStartup() failed: %s\n", error.GetDescription().c_str());
    return;
  }

  if (!LibretroHost::InitializeFoldersAndConfig(&error))
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] InitializeFoldersAndConfig() failed: %s\n",
                error.GetDescription().c_str());
    return;
  }

  if (!System::CoreThreadInitialize(&error))
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] CoreThreadInitialize() failed: %s\n",
                error.GetDescription().c_str());
    return;
  }

  LibretroHost::s_async_task_queue.SetWorkerCount(1);
  LibretroHost::s_core_initialized = true;

  LibretroHost::s_video_thread.Start(&LibretroHost::VideoThreadEntryPoint);

  LibretroLog(RETRO_LOG_INFO, "[GooseStation] Initialized successfully\n");
}

RETRO_API void retro_deinit(void)
{
  if (LibretroHost::s_game_loaded)
  {
    System::ShutdownSystem(false);
    LibretroHost::s_game_loaded = false;
  }

  if (LibretroHost::s_video_thread.Joinable())
  {
    VideoThread::Internal::RequestShutdown();
    LibretroHost::s_video_thread.Join();
  }

  LibretroHost::s_async_task_queue.SetWorkerCount(0);

  if (LibretroHost::s_core_initialized)
  {
    LibretroHost::ProcessCoreThreadEvents();
    System::CoreThreadShutdown();
    LibretroHost::s_core_initialized = false;
  }

  if (LibretroHost::s_system_initialized)
  {
    System::ProcessShutdown();
    LibretroHost::s_system_initialized = false;
  }

  Log::UnregisterCallback(DuckStationLogCallback, nullptr);

  LibretroLog(RETRO_LOG_INFO, "[GooseStation] Deinitialized\n");
}

RETRO_API unsigned retro_api_version(void)
{
  return RETRO_API_VERSION;
}

RETRO_API void retro_get_system_info(struct retro_system_info* info)
{
  std::memset(info, 0, sizeof(*info));
  info->library_name = "GooseStation";
  info->library_version = "0.1 (" __DATE__ " " __TIME__ ")";
  info->valid_extensions = "cue|bin|img|mdf|chd|pbp|iso|m3u|exe|psf|psxexe";
  info->need_fullpath = true;
  info->block_extract = true;
}

RETRO_API void retro_get_system_av_info(struct retro_system_av_info* info)
{
  std::memset(info, 0, sizeof(*info));

  const u32 resolution_scale =
    (LibretroHost::s_hw_render_enabled && System::IsValid()) ? g_settings.gpu_resolution_scale : 1;

  if (System::IsValid() && !g_gpu.IsDisplayDisabled())
  {
    const GSVector4i active_rect = VideoPresenter::GetVideoActiveRect();
    info->geometry.base_width = static_cast<unsigned>(active_rect.z - active_rect.x) * resolution_scale;
    info->geometry.base_height = static_cast<unsigned>(active_rect.w - active_rect.y) * resolution_scale;
  }
  else
  {
    info->geometry.base_width = 320 * resolution_scale;
    info->geometry.base_height = 240 * resolution_scale;
  }

  // RA's gl driver rounds both max_width and max_height to the next power of two and
  // allocates a square FBO at the larger of the two (confirmed: max=15360x7680 gets a
  // 16384x16384 FBO). Mali's GL_MAX_TEXTURE_SIZE is 16383, so the biggest POT square
  // we can fit is 8192 -> scale cap of 8. Asymmetric "-1" tricks don't help because
  // the POT rounding is per-dimension before the squaring.
#ifdef __ANDROID__
  static constexpr unsigned MAX_SCALE = 8;
#else
  static constexpr unsigned MAX_SCALE = 16;
#endif
  info->geometry.max_width = VRAM_WIDTH * MAX_SCALE;
  info->geometry.max_height = VRAM_HEIGHT * MAX_SCALE;
  info->geometry.aspect_ratio =
    GetDisplayAspectRatioFloat(info->geometry.base_width, info->geometry.base_height);
  info->timing.fps = System::IsValid() ? static_cast<double>(System::GetVideoFrameRate())
                                       : (System::IsPALRegion() ? 50.0 : 60.0);
  info->timing.sample_rate = 44100.0;

}

RETRO_API void retro_set_controller_port_device(unsigned port, unsigned device)
{
  if (port >= NUM_CONTROLLER_AND_CARD_PORTS)
    return;

  const auto lock = Core::GetSettingsLock();
  SettingsInterface& si = *Core::GetBaseSettingsLayer();

  ControllerType type = ControllerType::None;
  switch (device)
  {
    case RETRO_DEVICE_NONE:
      type = ControllerType::None;
      break;
    case RETRO_DEVICE_JOYPAD:
      type = ControllerType::DigitalController;
      break;
    case RETRO_DEVICE_ANALOG:
      type = ControllerType::AnalogController;
      break;
    default:
      type = ControllerType::DigitalController;
      break;
  }

  const TinyString section = TinyString::from_format("Pad{}", port + 1);
  si.SetStringValue(section, "Type", Controller::GetControllerInfo(type).name);

  if (System::IsValid())
    System::UpdateControllerSettings();
}

RETRO_API void retro_reset(void)
{
  if (System::IsValid())
    System::ResetSystem();
}

RETRO_API void retro_run(void)
{
  if (LibretroHost::s_deferred_boot_pending || LibretroHost::s_context_lost)
    return;

  if (!LibretroHost::s_game_loaded || !System::IsValid())
    return;

  LibretroHost::UpdateVariables();
  LibretroHost::UpdateControllers();

  LibretroHost::s_frame_done = false;
  LibretroHost::s_shutdown_requested = false;

  if (System::IsPaused())
    System::PauseSystem(false);

  // Invalidate cached GL state and sync to zeros (RetroArch clobbers state between frames).
  if (LibretroHost::s_hw_render_enabled && g_gpu_device
#ifdef ENABLE_VULKAN
      && !LibretroHost::s_using_vulkan_renderer
#endif
  )
  {
    static_cast<OpenGLDevice*>(g_gpu_device.get())->InvalidateCachedState();

    glUseProgram(0);
    glBindVertexArray(0);
    for (GLuint i = 0; i < 8; i++)
    {
      glActiveTexture(GL_TEXTURE0 + i);
      glBindTexture(GL_TEXTURE_2D, 0);
      glBindSampler(i, 0);
    }
    glActiveTexture(GL_TEXTURE0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    glColorMask(GL_TRUE, GL_TRUE, GL_TRUE, GL_TRUE);
  }

  System::Execute();
  const bool display_disabled_after = g_gpu.IsDisplayDisabled();

  {
    const u32 scale = LibretroHost::s_hw_render_enabled ? g_settings.gpu_resolution_scale : 1;
    u32 content_w, content_h;
    if (!display_disabled_after)
    {
      if (LibretroHost::s_hw_render_enabled)
      {
        // HW renderers read from VideoPresenter's snapshot — SET_GEOMETRY must
        // use the same snapshot the HW push will read.
        const GSVector4i active_rect = VideoPresenter::GetVideoActiveRect();
        content_w = static_cast<u32>(active_rect.z - active_rect.x) * scale;
        content_h = static_cast<u32>(active_rect.w - active_rect.y) * scale;
      }
      else
      {
        // Software pushes the VRAM source rect verbatim — SET_GEOMETRY must
        // match those exact dims or RA reinterprets the buffer width.
        const GSVector4i vsrc = g_gpu.GetCRTCVRAMSourceRect();
        u32 vw = static_cast<u32>(vsrc.z - vsrc.x);
        u32 vh = static_cast<u32>(vsrc.w - vsrc.y);
        if (vw == 0 || vh == 0)
        {
          vw = 320;
          vh = 240;
        }
        content_w = std::min(vw, static_cast<u32>(VRAM_WIDTH));
        content_h = std::min(vh, static_cast<u32>(VRAM_HEIGHT));
      }
    }
    else
    {
      content_w = 320 * scale;
      content_h = 240 * scale;
    }
    const auto [crop_top, crop_bottom] = GetFMVCrop(content_w, content_h);
    const u32 cropped_h = content_h - crop_top - crop_bottom;
    const float ar = GetDisplayAspectRatioFloat(content_w, cropped_h);

    // Filter out CRTC scanline jitter: the PSX display height fluctuates by
    // a few lines frame-to-frame due to timing of GP1(05h) vs vblank. A CRT
    // absorbs this in overscan; on a digital display it causes needless
    // SET_GEOMETRY churn. Only update when width changes or height shifts by
    // more than 8 native lines (significant mode switch, not jitter).
    const u32 height_delta = (cropped_h > LibretroHost::s_last_geometry_height)
      ? (cropped_h - LibretroHost::s_last_geometry_height)
      : (LibretroHost::s_last_geometry_height - cropped_h);
    const u32 height_threshold = 8 * (LibretroHost::s_hw_render_enabled ? g_settings.gpu_resolution_scale : 1);
    const bool geometry_changed = content_w != LibretroHost::s_last_geometry_width ||
                                  height_delta > height_threshold;
    if (geometry_changed)
    {
      LibretroHost::s_last_geometry_width = content_w;
      LibretroHost::s_last_geometry_height = cropped_h;
      LibretroHost::s_last_aspect_ratio = ar;

      struct retro_game_geometry geom = {};
      geom.base_width = content_w;
      geom.base_height = cropped_h;
#ifdef __ANDROID__
      geom.max_width = VRAM_WIDTH * 8;
      geom.max_height = VRAM_HEIGHT * 8;
#else
      geom.max_width = VRAM_WIDTH * 16;
      geom.max_height = VRAM_HEIGHT * 16;
#endif
      geom.aspect_ratio = ar;
      s_environment_callback(RETRO_ENVIRONMENT_SET_GEOMETRY, &geom);
    }
  }

  if (LibretroHost::s_hw_render_enabled)
  {
#ifdef ENABLE_VULKAN
    if (LibretroHost::s_using_vulkan_renderer)
      LibretroHost::PushVulkanHWVideoFrame();
    else
#endif
      LibretroHost::PushHWVideoFrame();
  }
  else
    LibretroHost::PushVideoFrame();

  LibretroHost::PushAudioSamples();
}

RETRO_API bool retro_load_game(const struct retro_game_info* game)
{
  if (!game || !game->path || !LibretroHost::s_core_initialized)
    return false;

  // Set pixel format
  enum retro_pixel_format fmt = RETRO_PIXEL_FORMAT_XRGB8888;
  if (!s_environment_callback(RETRO_ENVIRONMENT_SET_PIXEL_FORMAT, &fmt))
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] XRGB8888 pixel format not supported\n");
    return false;
  }

  {
    const char* renderer_value = nullptr;
    GetVariable("goosestation_renderer", &renderer_value);
    if (renderer_value && (std::strcmp(renderer_value, "OpenGL") == 0))
    {
      const auto lock = Core::GetSettingsLock();
      SettingsInterface& si = *Core::GetBaseSettingsLayer();
      si.SetStringValue("GPU", "Renderer", renderer_value);

      if (LibretroHost::SetupHWRender())
      {
        LibretroHost::s_deferred_boot_pending = true;
        LibretroHost::s_deferred_boot_path = game->path;
        LibretroLog(RETRO_LOG_INFO, "[GooseStation] HW render: deferring boot until context_reset\n");
        return true;
      }
      else
      {
        si.SetStringValue("GPU", "Renderer", Settings::GetRendererName(GPURenderer::Software));
      }
    }
#ifdef ENABLE_VULKAN
    else if (renderer_value && (std::strcmp(renderer_value, "Vulkan") == 0))
    {
      const auto lock = Core::GetSettingsLock();
      SettingsInterface& si = *Core::GetBaseSettingsLayer();
      si.SetStringValue("GPU", "Renderer", renderer_value);

      if (LibretroHost::SetupVulkanHWRender())
      {
        LibretroHost::s_deferred_boot_pending = true;
        LibretroHost::s_deferred_boot_path = game->path;
        LibretroLog(RETRO_LOG_INFO, "[GooseStation] Vulkan HW render: deferring boot until context_reset\n");
        return true;
      }
      else
      {
        si.SetStringValue("GPU", "Renderer", Settings::GetRendererName(GPURenderer::Software));
      }
    }
#endif
  }

  LibretroHost::UpdateVariables(true);

  SystemBootParameters params;
  params.path = game->path;

  Error error;
  if (!System::BootSystem(std::move(params), &error))
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] BootSystem() failed: %s\n", error.GetDescription().c_str());
    return false;
  }

  if (System::HasMediaSubImages())
  {
    LibretroHost::s_disk_control.has_sub_images = true;
    LibretroHost::s_disk_control.image_index = System::GetMediaSubImageIndex();
    LibretroHost::s_disk_control.image_count = System::GetMediaSubImageCount();
    LibretroHost::s_disk_control.image_paths.clear();
    LibretroHost::s_disk_control.image_labels.clear();
    for (u32 i = 0; i < LibretroHost::s_disk_control.image_count; i++)
    {
      LibretroHost::s_disk_control.image_paths.push_back(game->path); // TODO: get actual sub-image paths
      LibretroHost::s_disk_control.image_labels.push_back(System::GetMediaSubImageTitle(i));
    }

  }
  else
  {
    LibretroHost::s_disk_control.image_index = 0;
    LibretroHost::s_disk_control.image_count = 1;
    LibretroHost::s_disk_control.image_paths.clear();
    LibretroHost::s_disk_control.image_paths.push_back(game->path);
    LibretroHost::s_disk_control.image_labels.clear();
    LibretroHost::s_disk_control.image_labels.push_back(std::string(Path::GetFileTitle(game->path)));
  }

  LibretroHost::s_game_loaded = true;

  LibretroHost::s_save_state_buffer.resize(System::GetMaxSaveStateSize(g_settings.cpu_enable_8mb_ram));

  LibretroLog(RETRO_LOG_INFO, "[GooseStation] Game loaded: %s\n", game->path);
  return true;
}

RETRO_API bool retro_load_game_special(unsigned game_type, const struct retro_game_info* info, size_t num_info)
{
  return false;
}

RETRO_API void retro_unload_game(void)
{
  if (LibretroHost::s_game_loaded && System::IsValid())
  {
    System::ShutdownSystem(false);
    LibretroHost::s_game_loaded = false;
  }

  LibretroHost::s_deferred_boot_pending = false;
  LibretroHost::s_deferred_boot_path.clear();
  LibretroHost::s_context_lost = false;
  LibretroHost::s_hw_render_enabled = false;
  LibretroHost::s_hw_context_valid = false;
  LibretroHost::s_hw_render_callback = {};
  LibretroHost::s_boot_renderer.clear();
#ifdef ENABLE_VULKAN
  LibretroHost::s_using_vulkan_renderer = false;
  LibretroHost::s_vulkan_render_interface = nullptr;
#endif
  LibretroHost::s_disk_control = {};
  LibretroHost::s_save_state_buffer.clear();
}

RETRO_API unsigned retro_get_region(void)
{
  return System::IsPALRegion() ? RETRO_REGION_PAL : RETRO_REGION_NTSC;
}

// =============================================================================
// Save state support
// =============================================================================

RETRO_API size_t retro_serialize_size(void)
{
  return System::GetMaxSaveStateSize(g_settings.cpu_enable_8mb_ram);
}

RETRO_API bool retro_serialize(void* data, size_t size)
{
  if (!System::IsValid())
    return false;

  size_t state_size = 0;
  Error error;
  if (!System::SaveStateDataToBuffer(std::span<u8>(static_cast<u8*>(data), size), &state_size, &error))
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] SaveState failed: %s\n", error.GetDescription().c_str());
    return false;
  }

  return true;
}

RETRO_API bool retro_unserialize(const void* data, size_t size)
{
  if (!System::IsValid())
    return false;

  Error error;
  if (!System::LoadStateDataFromBuffer(std::span<const u8>(static_cast<const u8*>(data), size),
                                       SAVE_STATE_VERSION, &error, true))
  {
    LibretroLog(RETRO_LOG_ERROR, "[GooseStation] LoadState failed: %s\n", error.GetDescription().c_str());
    return false;
  }

  return true;
}

// =============================================================================
// Memory access
// =============================================================================

RETRO_API void* retro_get_memory_data(unsigned id)
{
  switch (id)
  {
    case RETRO_MEMORY_SYSTEM_RAM:
      return Bus::g_ram;
    default:
      return nullptr;
  }
}

RETRO_API size_t retro_get_memory_size(unsigned id)
{
  switch (id)
  {
    case RETRO_MEMORY_SYSTEM_RAM:
      return Bus::g_ram_size;
    default:
      return 0;
  }
}

// =============================================================================
// Cheat support (stubs)
// =============================================================================

RETRO_API void retro_cheat_reset(void)
{
}

RETRO_API void retro_cheat_set(unsigned index, bool enabled, const char* code)
{
}
PATCHEND
# Modify: src/util/CMakeLists.txt
ed -s 'src/util/CMakeLists.txt' <<'PATCHEND'
191s/^/  /
211,336d
194,209d
193a
if(LINUX)
  target_link_libraries(util PRIVATE UDEV::UDEV)
.
192a
include("${CMAKE_SOURCE_DIR}/CMakeModules/GooseLibretroLinking.cmake")
.
191a
elseif(TARGET spirv-cross-c)
  get_target_property(SPIRV_CROSS_INCLUDE_DIR spirv-cross-c INTERFACE_INCLUDE_DIRECTORIES)
endif()
.
190a
if(TARGET spirv-cross-c-shared)
.
189a
# For libretro builds, link statically (dlopen is impractical on Android).
.
134,162d
121,127d
100,101d
99a
target_precompile_headers(util PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/pch.h")
target_include_directories(util PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/..")
target_include_directories(util PRIVATE "${PROJECT_SOURCE_DIR}/dep/imgui/include")
target_link_libraries(util PUBLIC common)
target_link_libraries(util PRIVATE libchdr lzma PNG::PNG xxhash libjpeg-turbo::jpeg WebP::webp ZLIB::ZLIB zstd::libzstd_shared)
if(NOT BUILD_LIBRETRO)
  target_link_libraries(util PRIVATE plutosvg::plutosvg SoundTouch::SoundTouchDLL)
.
86,97d
85a
target_sources(util PRIVATE compress_helpers.cpp compress_helpers.h core_audio_stream.cpp core_audio_stream.h ini_settings_interface.cpp ini_settings_interface.h input_manager.cpp input_manager.h shadergen.cpp shadergen.h)
if(NOT BUILD_LIBRETRO)
  target_sources(util PRIVATE imgui_gsvector.h animated_image.cpp animated_image.h input_source.cpp input_source.h media_capture.cpp)
.
80,81d
77a
  wav_reader_writer.cpp
  wav_reader_writer.h
.
70,73d
56,67d
52,53d
41,49d
37,38d
19,22d
2,3d
wq
PATCHEND
# Modify: src/util/audio_stream.cpp
ed -s 'src/util/audio_stream.cpp' <<'PATCHEND'
130a
#endif
.
122a
#ifndef __LIBRETRO__
.
121a
#endif
.
114a
#ifndef __LIBRETRO__
.
97a
#endif
.
94a
#ifndef __LIBRETRO__
.
78a
#endif
.
75a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/util/cd_image.cpp
ed -s 'src/util/cd_image.cpp' <<'PATCHEND'
140d
139a
#if defined(__ANDROID__) && !defined(__LIBRETRO__)
.
121d
120a
#if defined(__ANDROID__) && !defined(__LIBRETRO__)
.
57d
56a
#if defined(__ANDROID__) && !defined(__LIBRETRO__)
.
wq
PATCHEND
# Modify: src/util/cd_image_device.cpp
ed -s 'src/util/cd_image_device.cpp' <<'PATCHEND'
184d
183a
#if defined(_WIN32) && defined(_MSC_VER)
.
wq
PATCHEND
# Modify: src/util/core_audio_stream.cpp
ed -s 'src/util/core_audio_stream.cpp' <<'PATCHEND'
928a
#endif // !__LIBRETRO__
.
613a
#ifdef __LIBRETRO__
void CoreAudioStream::StretchAllocate() {}
void CoreAudioStream::StretchDestroy() {}
void CoreAudioStream::StretchWriteBlock(const float*) {}
void CoreAudioStream::StretchUpdateParameters(const AudioStreamParameters&) {}
void CoreAudioStream::StretchUnderrun() {}
void CoreAudioStream::StretchOverrun() {}
void CoreAudioStream::EmptyStretchBuffers() {}
void CoreAudioStream::UpdateStretchTempo() {}
float CoreAudioStream::AddAndGetAverageTempo(float) { return 1.0f; }
#else
.
486a
#endif
.
482a
#ifndef __LIBRETRO__
.
475a
#endif
.
469a
#ifndef __LIBRETRO__
.
258a
}

u32 CoreAudioStream::DrainSamples(SampleType* output, u32 max_frames)
{
  const u32 available = GetBufferedFramesRelaxed();
  const u32 frames_to_read = std::min(available, max_frames);
  if (frames_to_read == 0)
    return 0;

  u32 rpos = m_rpos.load(std::memory_order_acquire);

  u32 end = m_buffer_size - rpos;
  if (end > frames_to_read)
    end = frames_to_read;

  if (end > 0)
  {
    std::memcpy(output, &m_buffer[rpos * NUM_CHANNELS], end * NUM_CHANNELS * sizeof(SampleType));
    rpos += end;
    rpos = (rpos == m_buffer_size) ? 0 : rpos;
  }

  const u32 start = frames_to_read - end;
  if (start > 0)
  {
    std::memcpy(&output[end * NUM_CHANNELS], &m_buffer[0], start * NUM_CHANNELS * sizeof(SampleType));
    rpos = start;
  }

  m_rpos.store(rpos, std::memory_order_release);
  return frames_to_read;
.
131a
#endif
.
129a
#ifdef __LIBRETRO__
    m_paused = false;
#else
.
16a
#endif
.
14a
#ifndef __LIBRETRO__
.
wq
PATCHEND
# Modify: src/util/core_audio_stream.h
ed -s 'src/util/core_audio_stream.h' <<'PATCHEND'
116a
  u32 DrainSamples(SampleType* output, u32 max_frames);

.
wq
PATCHEND
# Modify: src/util/dyn_shaderc.h
ed -s 'src/util/dyn_shaderc.h' <<'PATCHEND'
32a
DYN_SHADERC_OPTIONAL_FUNCTIONS(ADD_FUNC)
.
24d
23a
  X(shaderc_result_get_error_message)

// Custom DuckStation extensions — optional, only in DuckStation's bundled shaderc.
// Loaded opportunistically; fallback implementations used when not available.
#define DYN_SHADERC_OPTIONAL_FUNCTIONS(X)                                                                              \
  X(shaderc_compilation_status_to_string)                                                                              \
.
17d
7a
// Standard shaderc functions — required, present in all shaderc builds.
.
6a
#include "shaderc_compat.h"
.
wq
PATCHEND
# Modify: src/util/gpu_device.cpp
ed -s 'src/util/gpu_device.cpp' <<'PATCHEND'
1702d
1701a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
1585a
#endif
.
1583a
#ifndef __LIBRETRO__
.
1527a

  if (!dyn_libs::shaderc_optimize_spv)
  {
    Error::SetStringView(error, "shaderc_optimize_spv not available (system shaderc)");
    return ret;
  }
.
1498a
#undef DYN_SHADERC_OPTIONAL_FUNCTIONS
.
1492a
#endif
.
1482a
#if defined(__LIBRETRO__) && defined(__ANDROID__)
  // Nothing to do — statically linked.
#else
.
1478a
#endif
.
1449a

#if defined(__LIBRETRO__) && defined(__ANDROID__)
  // Android libretro builds link spirv-cross statically — assign function pointers directly.
  static bool s_spirv_cross_initialized = false;
  if (s_spirv_cross_initialized)
    return true;

#define ASSIGN_FUNC(F) F = &::F;
  SPIRV_CROSS_FUNCTIONS(ASSIGN_FUNC)
  SPIRV_CROSS_HLSL_FUNCTIONS(ASSIGN_FUNC)
  SPIRV_CROSS_MSL_FUNCTIONS(ASSIGN_FUNC)
#undef ASSIGN_FUNC

  s_spirv_cross_initialized = true;
  return true;
#else
.
1444a
#endif
.
1441a
  DYN_SHADERC_OPTIONAL_FUNCTIONS(UNLOAD_FUNC)
.
1427a
#if defined(__LIBRETRO__) && defined(__ANDROID__)
  if (g_shaderc_compiler)
  {
    ::shaderc_compiler_release(g_shaderc_compiler);
    g_shaderc_compiler = nullptr;
  }
#else
.
1423a
#endif
.
1414a
  // Optional functions — DuckStation extensions, not in system shaderc.
  // Load silently; fallbacks are used when not found.
#define LOAD_OPTIONAL_FUNC(F) s_shaderc_library.GetSymbol(#F, &F);
  DYN_SHADERC_OPTIONAL_FUNCTIONS(LOAD_OPTIONAL_FUNC)
#undef LOAD_OPTIONAL_FUNC

  // Provide fallbacks for DuckStation-custom functions not in system shaderc.
  if (!shaderc_compilation_status_to_string)
    shaderc_compilation_status_to_string = shaderc_compilation_status_to_string_fallback;

.
1393a

#if defined(__LIBRETRO__) && defined(__ANDROID__)
  // Android libretro builds link shaderc statically — assign function pointers directly.
  if (g_shaderc_compiler)
    return true;

#define ASSIGN_FUNC(F) F = &::F;
  DYN_SHADERC_FUNCTIONS(ASSIGN_FUNC)
#undef ASSIGN_FUNC

  // Optional DuckStation-custom functions don't exist in standard shaderc.
  // Use fallbacks instead.
  shaderc_compilation_status_to_string = shaderc_compilation_status_to_string_fallback;
  shaderc_optimize_spv = nullptr;

  g_shaderc_compiler = ::shaderc_compiler_initialize();
  if (!g_shaderc_compiler)
  {
    Error::SetStringView(error, "shaderc_compiler_initialize() failed");
    return false;
  }

  return true;
#else
.
1390a
// Fallback for DuckStation's custom shaderc_compilation_status_to_string.
// System shaderc doesn't export this function.
static const char* shaderc_compilation_status_to_string_fallback(shaderc_compilation_status status)
{
  switch (status)
  {
    case shaderc_compilation_status_success: return "success";
    case shaderc_compilation_status_invalid_stage: return "invalid stage";
    case shaderc_compilation_status_compilation_error: return "compilation error";
    case shaderc_compilation_status_internal_error: return "internal error";
    case shaderc_compilation_status_null_result_object: return "null result object";
    case shaderc_compilation_status_invalid_assembly: return "invalid assembly";
    case shaderc_compilation_status_validation_error: return "validation error";
    case shaderc_compilation_status_transformation_error: return "transformation error";
    case shaderc_compilation_status_configuration_error: return "configuration error";
    default: return "unknown error";
  }
}

.
1383a
DYN_SHADERC_OPTIONAL_FUNCTIONS(ADD_FUNC)
.
1353d
1352a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
461,462d
460a
      WARNING_LOG("Non-standard GPU device flags: {}", message);
.
405d
404a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
32d
31a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
28d
10d
wq
PATCHEND
# Modify: src/util/gpu_device.h
ed -s 'src/util/gpu_device.h' <<'PATCHEND'
25a
#include <unordered_map>
.
wq
PATCHEND
# Modify: src/util/image.cpp
ed -s 'src/util/image.cpp' <<'PATCHEND'
426a
#endif
.
390a
#ifndef __LIBRETRO__
.
24a
#ifndef __LIBRETRO__
#include <plutosvg.h>
#endif
.
21d
wq
PATCHEND
# Modify: src/util/imgui_manager.h
ed -s 'src/util/imgui_manager.h' <<'PATCHEND'
276a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "imgui_manager_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/util'
# Add: src/util/imgui_manager_libretro.h
cat > 'src/util/imgui_manager_libretro.h' <<'PATCHEND'
// Stub imgui_manager for libretro builds — owned by GooseStation.
#pragma once

#include "common/types.h"

#include <string>
#include <string_view>

class Error;
class SettingsInterface;
struct WindowInfo;

namespace Host {

using AuxiliaryRenderWindowHandle = void*;
using AuxiliaryRenderWindowUserData = void*;

inline void BeginTextInput() {}
inline void EndTextInput() {}
#ifndef __ANDROID__
inline bool CreateAuxiliaryRenderWindow(s32, s32, u32, u32, std::string_view,
                                        std::string_view, AuxiliaryRenderWindowUserData,
                                        AuxiliaryRenderWindowHandle*, WindowInfo*, Error*) { return false; }
inline void DestroyAuxiliaryRenderWindow(AuxiliaryRenderWindowHandle, s32* = nullptr, s32* = nullptr,
                                         u32* = nullptr, u32* = nullptr) {}
#endif

inline void OnMediaCaptureStarted() {}
inline void OnMediaCaptureStopped() {}

} // namespace Host

namespace ImGuiManager {

inline void SetSoftwareCursor(u32, std::string, float, u32 = 0xFFFFFF) {}
inline bool HasSoftwareCursor(u32) { return false; }
inline void ClearSoftwareCursor(u32) {}
inline void SetSoftwareCursorPosition(u32, float, float) {}
inline void UpdateInputOverlay() {}
inline bool AreAnyDebugWindowsEnabled(const SettingsInterface&) { return false; }
inline void NewFrame(u64) {}
inline void RenderOSDMessages() {}
inline void RenderSoftwareCursors() {}
inline bool UpdateDebugWindowConfig() { return false; }
inline void SkipFrame() {}

static constexpr const char* LOGO_IMAGE_NAME = "";

inline constexpr float DEFAULT_SCREEN_MARGIN = 10.0f;

} // namespace ImGuiManager
PATCHEND
# Modify: src/util/input_manager.cpp
ed -s 'src/util/input_manager.cpp' <<'PATCHEND'
2660d
2659a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
2602d
2601a
#if defined(__ANDROID__) && !defined(__LIBRETRO__)
.
2580d
2579a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
2373d
2372a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
1933,1934d
1932a
    INFO_LOG("Controller {} disconnected.", identifier);
.
1931d
1930a
  if (System::IsValid())
.
1920,1922d
1896,1897d
1895a
    INFO_LOG("Controller {} connected.", identifier);
.
1754a
#endif
.
1752a
#ifndef __LIBRETRO__
.
1626d
1625a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
1591d
1590a
  const bool hide_mouse_cursor = has_relative_mode_bindings;
.
1556,1558d
1529,1530d
1493d
1492a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
1458,1462d
1424,1440d
959a
#endif
.
951a
#ifdef __LIBRETRO__
  return;
#else
.
818d
817a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
787d
786a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
268d
267a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
256d
255a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
183d
182a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
42d
41a
#if defined(_WIN32) && !defined(__LIBRETRO__)
.
5d
wq
PATCHEND
# Modify: src/util/input_manager.h
ed -s 'src/util/input_manager.h' <<'PATCHEND'
440a
#endif
.
426a
#ifdef __LIBRETRO__
inline void AddFixedInputBindings(const SettingsInterface&) {}
inline void OnInputDeviceConnected(InputBindingKey, std::string_view, std::string_view) {}
inline void OnInputDeviceDisconnected(InputBindingKey, std::string_view) {}
inline void SetMouseMode(bool, bool) {}
inline std::optional<WindowInfo> GetTopLevelWindowInfo() { return std::nullopt; }
#else
.
wq
PATCHEND
# Modify: src/util/media_capture.cpp
ed -s 'src/util/media_capture.cpp' <<'PATCHEND'
35d
34a
#include <mferror.h>
.
wq
PATCHEND
# Modify: src/util/media_capture.h
ed -s 'src/util/media_capture.h' <<'PATCHEND'
77a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "media_capture_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/util'
# Add: src/util/media_capture_libretro.h
cat > 'src/util/media_capture_libretro.h' <<'PATCHEND'
// Stub media_capture for libretro builds — owned by GooseStation.
#pragma once

#include "common/types.h"

#include <memory>
#include <string>
#include <string_view>
#include <vector>

class Error;
class GPUTexture;
enum class MediaCaptureBackend : u8
{
  MaxCount,
};

class MediaCapture
{
public:
  virtual ~MediaCapture() = default;

  static const char* GetBackendName(MediaCaptureBackend) { return ""; }
  static MediaCaptureBackend ParseBackendName(const char*) { return static_cast<MediaCaptureBackend>(0); }
  static void AdjustVideoSize(u32*, u32*) {}

  virtual bool IsCapturingAudio() const { return false; }
  virtual bool IsCapturingVideo() const { return false; }
  virtual time_t GetElapsedTime() const { return 0; }
  virtual float GetCaptureThreadUsage() const { return 0.0f; }
  virtual float GetCaptureThreadTime() const { return 0.0f; }
  virtual float GetVideoFPS() const { return 0.0f; }
  virtual u32 GetVideoWidth() const { return 0; }
  virtual u32 GetVideoHeight() const { return 0; }
  virtual std::string GetNextCapturePath() const { return {}; }
  virtual std::string GetPath() const { return {}; }
  virtual void UpdateCaptureThreadUsage(double, double) {}
  virtual GPUTexture* GetRenderTexture() { return nullptr; }
  virtual bool DeliverVideoFrame(GPUTexture*) { return false; }
  virtual bool DeliverAudioFrames(const s16*, u32) { return false; }
  virtual bool BeginCapture(float, Error*) { return false; }
  virtual bool EndCapture(Error*) { return true; }
  virtual void Flush() {}
};
PATCHEND
# Modify: src/util/opengl_context.cpp
ed -s 'src/util/opengl_context.cpp' <<'PATCHEND'
148d
147a
#elif defined(__ANDROID__) && !defined(__LIBRETRO__)
.
144d
143a
#if defined(_WIN32) && defined(__LIBRETRO__)
  // libretro frontend manages the GL context; no creation here.
  (void)surface;
  (void)versions_to_try;
  Error::SetStringView(error, "OpenGL context creation not used in libretro build");
#elif defined(_WIN32) && !defined(_M_ARM64)
.
25a
#include "opengl_context_egl.h"
.
22d
21a
#elif defined(__ANDROID__) && !defined(__LIBRETRO__)
.
wq
PATCHEND
# Modify: src/util/opengl_device.cpp
ed -s 'src/util/opengl_device.cpp' <<'PATCHEND'
276,282s/^/  /
336a

#ifdef __LIBRETRO__
void OpenGLDevice::SetExternalContext(std::unique_ptr<OpenGLContext> context)
{
  m_gl_context = std::move(context);
}

void OpenGLDevice::InvalidateCachedState()
{
  // Reset ALL cached state so next draw call re-applies everything.
  // This is needed because RetroArch modifies GL state between retro_run() calls.

  // FBO / render targets
  m_current_fbo = 0;
  m_num_current_render_targets = 0;
  std::memset(m_current_render_targets.data(), 0, sizeof(m_current_render_targets));
  m_current_depth_target = nullptr;

  // Pipeline (forces re-apply of blend, depth, rasterization, program, VAO)
  m_current_pipeline = nullptr;
  m_last_program = 0;
  m_last_vao = m_vao_cache.cend();

  // Force re-apply of blend/depth/rasterization by using impossible sentinel values.
  // The bitfield structs use 0 as a valid state, so we set them to all-bits-set.
  std::memset(&m_last_blend_state, 0xFF, sizeof(m_last_blend_state));
  std::memset(&m_last_rasterization_state, 0xFF, sizeof(m_last_rasterization_state));
  std::memset(&m_last_depth_state, 0xFF, sizeof(m_last_depth_state));

  // Viewport and scissor — re-enable scissor test since RetroArch may disable it.
  glEnable(GL_SCISSOR_TEST);
  m_last_viewport = GSVector4i::cxpr(0, 0, 1, 1);
  m_last_scissor = GSVector4i::cxpr(0, 0, 1, 1);

  // Textures and samplers
  m_last_texture_unit = 0;
  m_last_samplers = {};
  m_last_ssbo = 0;
}
#endif
.
282a
    }
.
275a

#ifdef __LIBRETRO__
  if (m_gl_context)
  {
    // GLAD must be loaded manually since we skipped OpenGLContext::Create() which normally does this.
    // Use a static pointer for the non-capturing lambda that GLAD requires.
    static OpenGLContext* s_glad_context;
    s_glad_context = m_gl_context.get();
    const bool loaded =
      m_gl_context->IsGLES()
        ? gladLoadGLES2([](const char* name) { return (GLADapiproc)s_glad_context->GetProcAddress(name); })
        : gladLoadGL([](const char* name) { return (GLADapiproc)s_glad_context->GetProcAddress(name); });
    if (!loaded)
    {
      ERROR_LOG("Failed to load GL functions via GLAD for external context");
      Error::SetStringView(error, "Failed to load GL functions via GLAD for external context");
      m_gl_context.reset();
      return false;
    }
  }
  else
#endif
  {
.
wq
PATCHEND
# Modify: src/util/opengl_device.h
ed -s 'src/util/opengl_device.h' <<'PATCHEND'
147a
#ifdef __LIBRETRO__
  // Set an externally-created OpenGL context (e.g. from RetroArch's HW render callback).
  // Must be called before CreateDeviceAndMainSwapChain().
  void SetExternalContext(std::unique_ptr<OpenGLContext> context);
  ALWAYS_INLINE GLuint GetCurrentFBO() const { return m_current_fbo; }

  // Invalidate all cached GL state so next draw re-applies everything.
  // Must be called when an external user (e.g. RetroArch) may have modified GL state.
  void InvalidateCachedState();
#endif

.
wq
PATCHEND
# Modify: src/util/page_fault_handler.cpp
ed -s 'src/util/page_fault_handler.cpp' <<'PATCHEND'
353d
352a
  if (sigaction(SIGBUS, &sa, &s_prev_sigbus_action) != 0)
.
346d
345a
  if (sigaction(SIGSEGV, &sa, &s_prev_sigsegv_action) != 0)
.
327a
  // Not our fault - chain to the previous handler (e.g. Mali driver's internal guard-page
  // handler on Android, libsigchain's next entry). Without this, on libretro-Android the
  // CrashSignalHandler call below is a no-op and we loop re-running the faulting instruction.
#if defined(__APPLE__) || defined(__aarch64__)
  const struct sigaction& prev = (sig == SIGBUS) ? s_prev_sigbus_action : s_prev_sigsegv_action;
#else
  const struct sigaction& prev = s_prev_sigsegv_action;
#endif
  if (prev.sa_flags & SA_SIGINFO)
  {
    if (prev.sa_sigaction)
    {
      prev.sa_sigaction(sig, info, ctx);
      return;
    }
  }
  else if (prev.sa_handler && prev.sa_handler != SIG_DFL && prev.sa_handler != SIG_IGN)
  {
    prev.sa_handler(sig);
    return;
  }

.
263d
262a
  const bool is_write = exception_pc ? IsStoreInstruction(exception_pc) : false;
.
247a
static struct sigaction s_prev_sigsegv_action;
#if defined(__APPLE__) || defined(__aarch64__)
static struct sigaction s_prev_sigbus_action;
#endif
.
240d
239a
#elif (!defined(__ANDROID__) || defined(__LIBRETRO__))
.
18d
17a
#elif defined(__linux__) && (!defined(__ANDROID__) || defined(__LIBRETRO__))
.
wq
PATCHEND
# Modify: src/util/postprocessing.h
ed -s 'src/util/postprocessing.h' <<'PATCHEND'
186a
#endif // !__LIBRETRO__
.
4a

#ifdef __LIBRETRO__
#include "postprocessing_libretro.h"
#else
.
wq
PATCHEND
mkdir -p 'src/util'
# Add: src/util/postprocessing_libretro.h
cat > 'src/util/postprocessing_libretro.h' <<'PATCHEND'
// Stub postprocessing for libretro builds — owned by GooseStation.
#pragma once

#include "common/types.h"

class SettingsInterface;
class GPUTexture;

namespace PostProcessing {

namespace Config {
static constexpr const char* DISPLAY_CHAIN_SECTION = "PostProcessing";
static constexpr const char* INTERNAL_CHAIN_SECTION = "InternalPostProcessing";

inline u32 GetStageCount(const SettingsInterface&, const char*) { return 0; }
inline bool IsEnabled(const SettingsInterface&, const char*) { return false; }
inline void ClearStages(SettingsInterface&, const char*) {}
} // namespace Config

class Chain
{
public:
  Chain(const char*) {}
  bool IsActive() const { return false; }
  bool NeedsDepthBuffer() const { return false; }
  bool CheckTargets(u32, u32, u8, u32, u32, u32, u32) { return false; }
  GPUTexture* GetOutputTexture() { return nullptr; }
  void Apply(GPUTexture*, GPUTexture*, GPUTexture*, const struct GSVector4i&, u32, u32, u32, u32) {}
  void LoadStages(auto&, const SettingsInterface&, bool) {}
  void UpdateSettings(auto&, const SettingsInterface&) {}
};

} // namespace PostProcessing
PATCHEND
# Modify: src/util/postprocessing_shader_slang.cpp
ed -s 'src/util/postprocessing_shader_slang.cpp' <<'PATCHEND'
1084a
#endif
.
1083a
#ifndef __LIBRETRO__
.
wq
PATCHEND
mkdir -p 'src/util'
# Add: src/util/shaderc_compat.h
cat > 'src/util/shaderc_compat.h' <<'PATCHEND'
// shaderc_compat.h — declares DuckStation's custom shaderc extensions
// These functions exist in DuckStation's prebuilt shaderc but not in system shaderc.
// For libretro builds using system shaderc, we provide declarations so code compiles.
// The functions are loaded dynamically; if absent from the .so they simply won't load.
#pragma once

#include "shaderc/shaderc.h"

#ifdef __cplusplus
extern "C" {
#endif

// Custom function to convert status enum to string.
SHADERC_EXPORT const char* shaderc_compilation_status_to_string(
    shaderc_compilation_status status);

// Custom function to optimize existing SPIR-V.
SHADERC_EXPORT shaderc_compilation_result_t shaderc_optimize_spv(
    const shaderc_compiler_t compiler, const void* spirv, size_t spirv_size,
    const shaderc_compile_options_t additional_options);

#ifdef __cplusplus
}
#endif
PATCHEND
# Modify: src/util/vulkan_device.cpp
ed -s 'src/util/vulkan_device.cpp' <<'PATCHEND'
1705s/^/  /
1706a
    m_external_device = false;
.
1704a
    if (!m_external_device)
.
1665a
bool VulkanDevice::CreateDeviceFromExternal(VkPhysicalDevice physical_device, VkDevice device, VkQueue graphics_queue,
                                            u32 graphics_queue_family_index, CreateFlags create_flags, Error* error)
{
  m_physical_device = physical_device;
  m_device = device;
  m_graphics_queue = graphics_queue;
  m_graphics_queue_family_index = graphics_queue_family_index;
  m_present_queue = VK_NULL_HANDLE;
  m_present_queue_family_index = 0;
  m_external_device = true;

  if (!VulkanLoader::LoadDeviceFunctions(device, error))
    return false;

  vkGetPhysicalDeviceProperties(physical_device, &m_device_properties);
  m_device_driver_properties = {};

  // Query device properties2 for driver info if available.
  if (vkGetPhysicalDeviceProperties2)
  {
    m_device_driver_properties.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRIVER_PROPERTIES;
    VkPhysicalDeviceProperties2 properties2 = {VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2, nullptr};
    properties2.pNext = &m_device_driver_properties;
    vkGetPhysicalDeviceProperties2(physical_device, &properties2);
  }

  // Enumerate available extensions and set feature flags.
  u32 extension_count = 0;
  VkResult res = vkEnumerateDeviceExtensionProperties(physical_device, nullptr, &extension_count, nullptr);
  if (res != VK_SUCCESS || extension_count == 0)
  {
    Error::SetStringView(error, "Failed to enumerate device extensions.");
    return false;
  }

  DynamicHeapArray<VkExtensionProperties> available_extensions(extension_count);
  vkEnumerateDeviceExtensionProperties(physical_device, nullptr, &extension_count, available_extensions.data());

  // Check which optional extensions are available (don't enable — device already created).
  VkPhysicalDeviceFeatures enabled_features = {};
  ExtensionList dummy_extensions;
  EnableOptionalDeviceExtensions(physical_device, available_extensions.cspan(), dummy_extensions, enabled_features,
                                 false, nullptr);

  SetFeatures(create_flags, physical_device, enabled_features);

  if (!CreateAllocator() || !CreatePersistentDescriptorPool() || !CreateCommandBuffers() || !CreatePipelineLayouts())
    return false;

  if (!CreateNullTexture(error))
    return false;

  if (!CreateBuffers() || !CreatePersistentDescriptorSets())
  {
    Error::SetStringView(error, "Failed to create buffers/descriptor sets");
    return false;
  }

  INFO_LOG("Created VulkanDevice from external handles (GPU: {})", m_device_properties.deviceName);
  return true;
}

void VulkanDevice::SetExternalDeviceHandles(VkPhysicalDevice physical_device, VkDevice device,
                                             VkQueue graphics_queue, u32 graphics_queue_family_index)
{
  m_pending_external_physical_device = physical_device;
  m_pending_external_device = device;
  m_pending_external_queue = graphics_queue;
  m_pending_external_queue_family = graphics_queue_family_index;
}

void VulkanDevice::SetQueueLockCallbacks(QueueCallback lock, QueueCallback unlock)
{
  m_queue_lock_callback = std::move(lock);
  m_queue_unlock_callback = std::move(unlock);
}

.
1578a
  // If external device handles were pre-set (libretro Vulkan), use them instead of creating our own.
  if (m_pending_external_device != VK_NULL_HANDLE)
  {
    INFO_LOG("Using pre-set external Vulkan device handles");
    const bool result = CreateDeviceFromExternal(m_pending_external_physical_device, m_pending_external_device,
                                                 m_pending_external_queue, m_pending_external_queue_family,
                                                 create_flags, error);
    m_pending_external_physical_device = VK_NULL_HANDLE;
    m_pending_external_device = VK_NULL_HANDLE;
    m_pending_external_queue = VK_NULL_HANDLE;
    m_pending_external_queue_family = 0;
    return result;
  }

.
1392a
}

void VulkanDevice::DeferSemaphoreDestruction(VkSemaphore object)
{
  m_cleanup_objects.emplace_back(GetCurrentFenceCounter(),
                                 [this, object]() { vkDestroySemaphore(m_device, object, nullptr); });
.
1361a
void VulkanDevice::SubmitCommandBufferAndSignal(VkSemaphore signal_semaphore)
{
  if (InRenderPass())
    EndRenderPass();

  EndAndSubmitCommandBuffer(false, nullptr, false, signal_semaphore);

  InvalidateCachedState();
}

.
1228a

  if (m_queue_unlock_callback)
    m_queue_unlock_callback();

.
1226a
  else if (signal_semaphore != VK_NULL_HANDLE)
  {
    submit_info.pSignalSemaphores = &signal_semaphore;
    submit_info.signalSemaphoreCount = 1;
  }

  if (m_queue_lock_callback)
    m_queue_lock_callback();
.
1163d
1162a
                                             bool explicit_present, VkSemaphore signal_semaphore)
.
wq
PATCHEND
# Modify: src/util/vulkan_device.h
ed -s 'src/util/vulkan_device.h' <<'PATCHEND'
378a
  bool m_external_device = false;

  // Pending external device handles (set via SetExternalDeviceHandles, consumed by CreateDeviceAndMainSwapChain).
  VkPhysicalDevice m_pending_external_physical_device = VK_NULL_HANDLE;
  VkDevice m_pending_external_device = VK_NULL_HANDLE;
  VkQueue m_pending_external_queue = VK_NULL_HANDLE;
  u32 m_pending_external_queue_family = 0;

  QueueCallback m_queue_lock_callback;
  QueueCallback m_queue_unlock_callback;
.
370d
369a
  void EndAndSubmitCommandBuffer(bool wait_for_completion, VulkanSwapChain* present_swap_chain, bool explicit_present,
                                 VkSemaphore signal_semaphore = VK_NULL_HANDLE);
.
237a

  /// Creates a VulkanDevice from externally-provided handles (libretro Vulkan context).
  /// VulkanLoader must already have the instance adopted via AdoptExternalInstance().
  bool CreateDeviceFromExternal(VkPhysicalDevice physical_device, VkDevice device, VkQueue graphics_queue,
                                u32 graphics_queue_family_index, CreateFlags create_flags, Error* error);

  /// Pre-stores external device handles for use by CreateDeviceAndMainSwapChain().
  /// When set, CreateDeviceAndMainSwapChain will use these instead of creating its own device.
  void SetExternalDeviceHandles(VkPhysicalDevice physical_device, VkDevice device, VkQueue graphics_queue,
                                u32 graphics_queue_family_index);

  using QueueCallback = std::function<void()>;
  void SetQueueLockCallbacks(QueueCallback lock, QueueCallback unlock);
.
234a
  /// Submits the current command buffers via vkQueueSubmit with our own fence, signaling
  /// the provided semaphore for an external consumer (e.g. libretro set_image sync).
  /// Advances to the next CB slot, waiting on the fence for that slot if needed.
  void SubmitCommandBufferAndSignal(VkSemaphore signal_semaphore);

.
213a
  void DeferSemaphoreDestruction(VkSemaphore object);
.
wq
PATCHEND
# Modify: src/util/vulkan_loader.cpp
ed -s 'src/util/vulkan_loader.cpp' <<'PATCHEND'
528a
}

bool VulkanLoader::AdoptExternalInstance(VkInstance instance, PFN_vkGetInstanceProcAddr get_instance_proc_addr,
                                         Error* error)
{
  const std::lock_guard lock(s_locals.mutex);

  // If we already have an instance, release it first.
  if (s_locals.instance != VK_NULL_HANDLE)
    LockedDestroyVulkanInstance();

  // Use the provided proc addr to bootstrap function loading.
  vkGetInstanceProcAddr = get_instance_proc_addr;

  if (!LoadInstanceFunctions(instance, error))
  {
    ResetInstanceFunctions();
    return false;
  }

  s_locals.instance = instance;
  s_locals.reference_count = 1;
  s_locals.is_external_instance = true;
  s_locals.is_debug_instance = false;
  s_locals.window_type = WindowInfoType::Surfaceless;
  s_locals.optional_extensions = {};

  INFO_LOG("Adopted external Vulkan instance {:p}", static_cast<void*>(instance));
  return true;
.
500a
  s_locals.is_external_instance = false;
.
497a
  }
.
496a
  {
.
495a
  }
.
494d
493a
  if (s_locals.is_external_instance)
  {
    // External instance is owned by the frontend (e.g., libretro) — do not destroy.
    DEV_LOG("Releasing external Vulkan instance (not destroying).");
  }
  else if (vkDestroyInstance)
  {
.
66a
  bool is_external_instance = false;
.
wq
PATCHEND
# Modify: src/util/vulkan_loader.h
ed -s 'src/util/vulkan_loader.h' <<'PATCHEND'
35a
/// Adopts an externally-provided VkInstance (e.g., from libretro frontend).
/// The caller retains ownership; VulkanLoader will NOT destroy this instance.
/// Loads instance-level function pointers from the provided instance.
bool AdoptExternalInstance(VkInstance instance, PFN_vkGetInstanceProcAddr get_instance_proc_addr, Error* error);

.
wq
PATCHEND
# Modify: src/util/xinput_source.h
ed -s 'src/util/xinput_source.h' <<'PATCHEND'
7d
6a
#include <xinput.h>
.
wq
PATCHEND
