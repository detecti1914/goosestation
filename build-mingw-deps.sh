#!/bin/bash
# Cross-compile GooseStation libretro dependencies for Windows x86_64 (mingw-w64).
set -euo pipefail

MINGW_PREFIX="${MINGW_PREFIX:-x86_64-w64-mingw32}"
JOBS="${JOBS:-$(nproc)}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOOLCHAIN="${TOOLCHAIN:-$SCRIPT_DIR/cmake/mingw-w64-x86_64.cmake}"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build/mingw}"
PREFIX="$BUILD_DIR/deps"
SRC_DIR="$BUILD_DIR/deps-src"

test -f "$TOOLCHAIN" || { echo "ERROR: toolchain file not found: $TOOLCHAIN" >&2; exit 1; }
command -v "${MINGW_PREFIX}-gcc" >/dev/null || { echo "ERROR: ${MINGW_PREFIX}-gcc not in PATH" >&2; exit 1; }

mkdir -p "$PREFIX" "$SRC_DIR"

CMAKE_COMMON=(
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_FIND_ROOT_PATH="$PREFIX;/usr/${MINGW_PREFIX}"
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_TESTING=OFF
)

fetch() {
  local name=$1 url=$2
  local archive_name
  archive_name=$(basename "$url")
  local archive="$SRC_DIR/$archive_name"
  if [ ! -f "$archive" ]; then
    echo "Fetching $name..." >&2
    curl -fsSL -o "$archive.tmp" "$url" && mv "$archive.tmp" "$archive"
  fi
  # Re-extract whenever the cached dir was made from a different archive
  # (different URL/version), so version bumps don't reuse stale sources.
  local dir="$SRC_DIR/$name"
  local stamp="$dir/.fetched-from"
  if [ ! -d "$dir" ] || [ ! -f "$stamp" ] || [ "$(cat "$stamp" 2>/dev/null)" != "$archive_name" ]; then
    rm -rf "$dir"
    mkdir -p "$dir"
    tar xf "$archive" -C "$dir" --strip-components=1
    printf '%s' "$archive_name" > "$stamp"
  fi
  printf '%s' "$dir"
}

build_cmake() {
  local name=$1 srcdir=$2
  shift 2
  local builddir="$BUILD_DIR/build-$name"
  echo "=== Building $name ==="
  mkdir -p "$builddir"
  cmake -S "$srcdir" -B "$builddir" "${CMAKE_COMMON[@]}" "$@"
  cmake --build "$builddir" -j"$JOBS"
  cmake --install "$builddir"
  echo "=== $name done ==="
}

# zlib (delete shared output afterwards so dependents pick up the static lib)
ZLIB_DIR=$(fetch zlib "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz")
build_cmake zlib "$ZLIB_DIR" \
  -DZLIB_BUILD_EXAMPLES=OFF
rm -f "$PREFIX"/bin/zlib*.dll "$PREFIX"/lib/libzlib.dll.a "$PREFIX"/lib/libzlibstatic.a.bak
# Some configs name the static archive libzlibstatic.a; ensure libz.a / libzlib.a is the one CMake's FindZLIB will pick.
if [ -f "$PREFIX/lib/libzlibstatic.a" ] && [ ! -f "$PREFIX/lib/libzlib.a" ]; then
  cp "$PREFIX/lib/libzlibstatic.a" "$PREFIX/lib/libzlib.a"
fi

# zstd
ZSTD_DIR=$(fetch zstd "https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz")
build_cmake zstd "$ZSTD_DIR/build/cmake" \
  -DZSTD_BUILD_PROGRAMS=OFF \
  -DZSTD_BUILD_SHARED=OFF \
  -DZSTD_BUILD_STATIC=ON

# libpng
PNG_DIR=$(fetch libpng "https://downloads.sourceforge.net/project/libpng/libpng16/1.6.47/libpng-1.6.47.tar.xz")
build_cmake libpng "$PNG_DIR" \
  -DPNG_SHARED=OFF \
  -DPNG_STATIC=ON \
  -DPNG_TESTS=OFF

# libjpeg-turbo
JPEG_DIR=$(fetch libjpeg-turbo "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.0/libjpeg-turbo-3.1.0.tar.gz")
build_cmake libjpeg-turbo "$JPEG_DIR" \
  -DENABLE_SHARED=OFF \
  -DENABLE_STATIC=ON \
  -DWITH_TURBOJPEG=OFF

# libwebp
WEBP_DIR=$(fetch libwebp "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz")
build_cmake libwebp "$WEBP_DIR" \
  -DWEBP_BUILD_ANIM_UTILS=OFF \
  -DWEBP_BUILD_CWEBP=OFF \
  -DWEBP_BUILD_DWEBP=OFF \
  -DWEBP_BUILD_GIF2WEBP=OFF \
  -DWEBP_BUILD_IMG2WEBP=OFF \
  -DWEBP_BUILD_VWEBP=OFF \
  -DWEBP_BUILD_WEBPINFO=OFF \
  -DWEBP_BUILD_WEBPMUX=OFF \
  -DWEBP_BUILD_EXTRAS=OFF

# cpuinfo
if [ ! -d "$SRC_DIR/cpuinfo" ]; then
  git clone --depth 1 https://github.com/pytorch/cpuinfo.git "$SRC_DIR/cpuinfo"
fi
build_cmake cpuinfo "$SRC_DIR/cpuinfo" \
  -DCPUINFO_BUILD_TOOLS=OFF \
  -DCPUINFO_BUILD_UNIT_TESTS=OFF \
  -DCPUINFO_BUILD_MOCK_TESTS=OFF \
  -DCPUINFO_BUILD_BENCHMARKS=OFF


# Vulkan-Headers
VKH_DIR=$(fetch vulkan-headers "https://github.com/KhronosGroup/Vulkan-Headers/archive/refs/tags/v1.4.323.tar.gz")
build_cmake vulkan-headers "$VKH_DIR"

# Vulkan-Loader (provides vulkan-1 import lib)
VKL_DIR=$(fetch vulkan-loader "https://github.com/KhronosGroup/Vulkan-Loader/archive/refs/tags/v1.4.323.tar.gz")
build_cmake vulkan-loader "$VKL_DIR" \
  -DBUILD_TESTS=OFF \
  -DBUILD_WSI_XCB_SUPPORT=OFF \
  -DBUILD_WSI_XLIB_SUPPORT=OFF \
  -DBUILD_WSI_WAYLAND_SUPPORT=OFF \
  -DUSE_MASM=OFF \
  -DENABLE_WERROR=OFF

# SPIRV-Cross
SPIRV_CROSS_DIR=$(fetch spirv-cross "https://github.com/KhronosGroup/SPIRV-Cross/archive/refs/tags/vulkan-sdk-1.4.304.1.tar.gz")
build_cmake spirv-cross "$SPIRV_CROSS_DIR" \
  -DSPIRV_CROSS_CLI=OFF \
  -DSPIRV_CROSS_ENABLE_TESTS=OFF \
  -DSPIRV_CROSS_SHARED=OFF \
  -DSPIRV_CROSS_STATIC=ON

# shaderc (pulls glslang + SPIRV-Tools)
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

echo ""
echo "=== All Windows dependencies built ==="
echo "Prefix: $PREFIX"
ls "$PREFIX/lib/"
