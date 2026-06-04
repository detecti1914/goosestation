#!/bin/bash
# Build the GooseStation deps for the *fully static* Linux libretro core
# (the `linux-static` Makefile target). Unlike build-linux-deps.sh — which
# builds only cpuinfo and links everything else against Debian's shared libs —
# this builds every dependency the core actually references as a static, PIC
# archive into a private prefix, so the resulting goosestation_libretro.so has
# no external NEEDED entries beyond glibc.

# Versions/flags track DuckStation's deps (github.com/duckstation/dependencies
# `versions` + build-dependencies-linux.sh); SPIRV-Cross follows DuckStation's
# GLSL-only selection (no HLSL/MSL — the core has no D3D/Metal renderer).
set -euo pipefail

JOBS="${JOBS:-$(nproc)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build/linux-static}"
PREFIX="$BUILD_DIR/deps"
SRC_DIR="$BUILD_DIR/deps-src"

# DuckStation-pinned versions (dep/PREBUILT-VERSION release-20260404).
ZLIBNG_VERSION=2.3.3
ZSTD_VERSION=1.5.7
LIBPNG_VERSION=1.6.58
LIBJPEGTURBO_VERSION=3.1.4.1
LIBWEBP_VERSION=1.6.0
SPIRV_CROSS_TAG=vulkan-sdk-1.4.341.0

mkdir -p "$PREFIX" "$SRC_DIR"

# Baseline ISA, passed by the Makefile (default -march=x86-64-v2).
MARCH="${MARCH:--march=x86-64-v2}"

CMAKE_COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_TESTING=OFF
  -DCMAKE_C_FLAGS="$MARCH"
  -DCMAKE_CXX_FLAGS="$MARCH"
)

fetch() {
  local name=$1 url=$2
  local archive_name; archive_name=$(basename "$url")
  local archive="$SRC_DIR/$archive_name"
  if [ ! -f "$archive" ]; then
    echo "Fetching $name..." >&2
    curl -fsSL -o "$archive.tmp" "$url" && mv "$archive.tmp" "$archive"
  fi
  local dir="$SRC_DIR/$name"
  local stamp="$dir/.fetched-from"
  if [ ! -d "$dir" ] || [ ! -f "$stamp" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$archive_name" ]; then
    rm -rf "$dir"; mkdir -p "$dir"
    tar xf "$archive" -C "$dir" --strip-components=1
    printf '%s' "$archive_name" > "$stamp"
  fi
  printf '%s' "$dir"
}

build_cmake() {
  local name=$1 srcdir=$2; shift 2
  local builddir="$BUILD_DIR/build-$name"
  echo "=== Building $name ==="
  mkdir -p "$builddir"
  cmake -S "$srcdir" -B "$builddir" "${CMAKE_COMMON[@]}" "$@"
  cmake --build "$builddir" -j"$JOBS"
  cmake --install "$builddir"
}

# zlib-ng in zlib-compat mode provides libz.a + zlib.pc (FindZLIB finds the .a).
# Built first because libpng links against it.
ZLIBNG_DIR=$(fetch zlib-ng "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/$ZLIBNG_VERSION.tar.gz")
build_cmake zlib-ng "$ZLIBNG_DIR" \
  -DZLIB_COMPAT=ON \
  -DZLIB_ENABLE_TESTS=OFF \
  -DZLIBNG_ENABLE_TESTS=OFF \
  -DWITH_GTEST=OFF

# zstd — cmake project lives under build/cmake.
ZSTD_DIR=$(fetch zstd "https://github.com/facebook/zstd/releases/download/v$ZSTD_VERSION/zstd-$ZSTD_VERSION.tar.gz")
build_cmake zstd "$ZSTD_DIR/build/cmake" \
  -DZSTD_BUILD_SHARED=OFF \
  -DZSTD_BUILD_STATIC=ON \
  -DZSTD_BUILD_PROGRAMS=OFF \
  -DZSTD_LEGACY_SUPPORT=OFF \
  -DZSTD_BUILD_TESTS=OFF

# libpng (links zlib from the prefix).
LIBPNG_DIR=$(fetch libpng "https://github.com/pnggroup/libpng/archive/refs/tags/v$LIBPNG_VERSION.tar.gz")
build_cmake libpng "$LIBPNG_DIR" \
  -DPNG_SHARED=OFF \
  -DPNG_STATIC=ON \
  -DPNG_TESTS=OFF \
  -DPNG_TOOLS=OFF \
  -DPNG_FRAMEWORK=OFF

# libjpeg-turbo
LIBJPEGTURBO_DIR=$(fetch libjpeg-turbo "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$LIBJPEGTURBO_VERSION/libjpeg-turbo-$LIBJPEGTURBO_VERSION.tar.gz")
build_cmake libjpeg-turbo "$LIBJPEGTURBO_DIR" \
  -DENABLE_SHARED=OFF \
  -DENABLE_STATIC=ON \
  -DWITH_TURBOJPEG=OFF \
  -DWITH_TESTS=OFF

# libwebp (+ libsharpyuv)
LIBWEBP_DIR=$(fetch libwebp "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$LIBWEBP_VERSION.tar.gz")
build_cmake libwebp "$LIBWEBP_DIR" \
  -DWEBP_BUILD_ANIM_UTILS=OFF \
  -DWEBP_BUILD_CWEBP=OFF \
  -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF \
  -DWEBP_BUILD_IMG2WEBP=OFF \
  -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPINFO=OFF \
  -DWEBP_BUILD_WEBPMUX=OFF \
  -DWEBP_BUILD_EXTRAS=OFF

# SPIRV-Cross — GLSL only (matches DuckStation; the Linux core has no D3D/Metal
# renderer, so HLSL/MSL/CPP/reflect are not needed). C API + util enabled.
SPIRV_CROSS_DIR=$(fetch spirv-cross "https://github.com/KhronosGroup/SPIRV-Cross/archive/refs/tags/$SPIRV_CROSS_TAG.tar.gz")
build_cmake spirv-cross "$SPIRV_CROSS_DIR" \
  -DSPIRV_CROSS_SHARED=OFF \
  -DSPIRV_CROSS_STATIC=ON \
  -DSPIRV_CROSS_CLI=OFF \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF \
  -DSPIRV_CROSS_ENABLE_GLSL=ON \
  -DSPIRV_CROSS_ENABLE_HLSL=OFF \
  -DSPIRV_CROSS_ENABLE_MSL=OFF \
  -DSPIRV_CROSS_ENABLE_CPP=OFF \
  -DSPIRV_CROSS_ENABLE_REFLECT=OFF \
  -DSPIRV_CROSS_ENABLE_C_API=ON \
  -DSPIRV_CROSS_ENABLE_UTIL=ON

# shaderc — produces libshaderc_combined.a (shaderc + glslang + SPIRV-Tools in
# one archive), which GooseLibretroLinking.cmake links. git-sync-deps pins the
# matching glslang/SPIRV-Tools/SPIRV-Headers. Upstream google/shaderc is fine:
# the static code path in gpu_device.cpp uses fallbacks for DuckStation's
# optional shaderc extensions, so the fork's extras are not required.
if [ ! -d "$SRC_DIR/shaderc" ]; then
  git clone --depth 1 https://github.com/google/shaderc.git "$SRC_DIR/shaderc"
  (cd "$SRC_DIR/shaderc" && python3 utils/git-sync-deps)
fi
build_cmake shaderc "$SRC_DIR/shaderc" \
  -DSHADERC_SKIP_TESTS=ON \
  -DSHADERC_SKIP_EXAMPLES=ON \
  -DSHADERC_SKIP_COPYRIGHT_CHECK=ON \
  -DSPIRV_SKIP_TESTS=ON \
  -DSPIRV_SKIP_EXECUTABLES=ON \
  -DENABLE_GLSLANG_BINARIES=OFF

# cpuinfo
if [ ! -d "$SRC_DIR/cpuinfo" ]; then
  git clone --depth 1 https://github.com/pytorch/cpuinfo.git "$SRC_DIR/cpuinfo"
fi
build_cmake cpuinfo "$SRC_DIR/cpuinfo" \
  -DCPUINFO_BUILD_TOOLS=OFF \
  -DCPUINFO_BUILD_UNIT_TESTS=OFF \
  -DCPUINFO_BUILD_MOCK_TESTS=OFF \
  -DCPUINFO_BUILD_BENCHMARKS=OFF

echo "=== Linux static deps built into $PREFIX ==="
ls "$PREFIX/lib" 2>/dev/null || true
