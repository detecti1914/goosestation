#!/bin/bash
# Build the GooseStation macOS libretro deps that aren't in Homebrew:
# cpuinfo (pytorch/cpuinfo, not the unrelated macOS menu bar app).
# Static, into a private prefix that the macOS Makefile target adds
# to CMAKE_PREFIX_PATH.
set -euo pipefail

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build/macos}"
PREFIX="$BUILD_DIR/deps"
SRC_DIR="$BUILD_DIR/deps-src"

mkdir -p "$PREFIX" "$SRC_DIR"

CMAKE_COMMON=(
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_INSTALL_PREFIX="$PREFIX"
  -DCMAKE_PREFIX_PATH="$PREFIX"
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON
  -DBUILD_SHARED_LIBS=OFF
  -DBUILD_TESTING=OFF
)

build_cmake() {
  local name=$1 srcdir=$2; shift 2
  local builddir="$BUILD_DIR/build-$name"
  echo "=== Building $name ==="
  mkdir -p "$builddir"
  cmake -S "$srcdir" -B "$builddir" "${CMAKE_COMMON[@]}" "$@"
  cmake --build "$builddir" -j"$JOBS"
  cmake --install "$builddir"
}

if [ ! -d "$SRC_DIR/cpuinfo" ]; then
  git clone --depth 1 https://github.com/pytorch/cpuinfo.git "$SRC_DIR/cpuinfo"
fi
build_cmake cpuinfo "$SRC_DIR/cpuinfo" \
  -DCPUINFO_BUILD_TOOLS=OFF \
  -DCPUINFO_BUILD_UNIT_TESTS=OFF \
  -DCPUINFO_BUILD_MOCK_TESTS=OFF \
  -DCPUINFO_BUILD_BENCHMARKS=OFF

echo "=== macOS extras built into $PREFIX ==="
