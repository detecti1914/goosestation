#!/bin/bash
# Build the GooseStation linux libretro deps that aren't packaged on Debian:
# libjpeg-turbo (no CMake config), plutovg, plutosvg, cpuinfo. Static, into
# a private prefix that the linux Makefile target adds to CMAKE_PREFIX_PATH.
set -euo pipefail

JOBS="${JOBS:-$(nproc)}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build/linux}"
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

PLUTOVG_DIR=$(fetch plutovg "https://github.com/sammycage/plutovg/archive/refs/tags/v1.0.0.tar.gz")
build_cmake plutovg "$PLUTOVG_DIR" -DPLUTOVG_BUILD_EXAMPLES=OFF

mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/plutovg.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: PlutoVG
Description: stub
Version: 1.0.0
Cflags: -I\${includedir}/plutovg -DPLUTOVG_BUILD_STATIC
Libs: -L\${libdir} -lplutovg
Libs.private: -lm
EOF

PLUTOSVG_DIR=$(fetch plutosvg "https://github.com/sammycage/plutosvg/archive/refs/tags/v0.0.7.tar.gz")
build_cmake plutosvg "$PLUTOSVG_DIR" -DPLUTOSVG_BUILD_EXAMPLES=OFF

if [ ! -d "$SRC_DIR/cpuinfo" ]; then
  git clone --depth 1 https://github.com/pytorch/cpuinfo.git "$SRC_DIR/cpuinfo"
fi
build_cmake cpuinfo "$SRC_DIR/cpuinfo" \
  -DCPUINFO_BUILD_TOOLS=OFF \
  -DCPUINFO_BUILD_UNIT_TESTS=OFF \
  -DCPUINFO_BUILD_MOCK_TESTS=OFF \
  -DCPUINFO_BUILD_BENCHMARKS=OFF

echo "=== Linux extras built into $PREFIX ==="
