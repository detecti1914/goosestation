#!/bin/bash
# Cross-compile GooseStation libretro dependencies for Android.
set -euo pipefail

NDK="${NDK:-${ANDROID_NDK:-${ANDROID_NDK_ROOT:-${ANDROID_NDK_HOME:-}}}}"
ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
ANDROID_API="${ANDROID_API:-26}"
JOBS="${JOBS:-$(nproc)}"

test -n "$NDK" || { echo "ERROR: set NDK=/path/to/android-ndk" >&2; exit 1; }
test -d "$NDK" || { echo "ERROR: NDK not found at $NDK" >&2; exit 1; }
TOOLCHAIN="$NDK/build/cmake/android.toolchain.cmake"
test -f "$TOOLCHAIN" || { echo "ERROR: toolchain file not found: $TOOLCHAIN" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build/android}"
PREFIX="$BUILD_DIR/deps"
SRC_DIR="$BUILD_DIR/deps-src"

mkdir -p "$PREFIX" "$SRC_DIR"

CMAKE_COMMON=(
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN"
  -DANDROID_ABI="$ANDROID_ABI"
  -DANDROID_PLATFORM="android-$ANDROID_API"
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_FIND_ROOT_PATH="$PREFIX"
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
echo "=== All Android dependencies built ==="
echo "Prefix: $PREFIX"
ls "$PREFIX/lib/"
