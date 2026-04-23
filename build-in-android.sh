#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

UPSTREAM_COMMIT="5e7be496a2d0480aaabbe9746a1a4576b469d301"
UPSTREAM_URL="https://github.com/stenzek/duckstation/archive/${UPSTREAM_COMMIT}.tar.gz"

CACHE_DIR="${SCRIPT_DIR}/.cache"
TARBALL="${CACHE_DIR}/duckstation-${UPSTREAM_COMMIT}.tar.gz"
SRC_ROOT="${SCRIPT_DIR}/src"
SRC_DIR="${SRC_ROOT}/duckstation-${UPSTREAM_COMMIT}"
BUILD_DIR="${SCRIPT_DIR}/build/android"
DIST_DIR="${SCRIPT_DIR}/dist/android"
ANDROID_DEPS_DIR="${CACHE_DIR}/android/deps"

ANDROID_ABI="${ANDROID_ABI:-arm64-v8a}"
ANDROID_API="${ANDROID_API:-28}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

# lzhiyong/termux-ndk provides aarch64 prebuilt tools required to run on arm64 Android.
NDK_DIR="${TERMUX_NDK_DIR:-${HOME}/android/android-ndk-r29}"
NDK_ARCHIVE="${CACHE_DIR}/android-ndk-r29-aarch64.7z"
NDK_DOWNLOAD_URL="https://github.com/lzhiyong/termux-ndk/releases/download/android-ndk/android-ndk-r29-aarch64.7z"

# ── 1. Termux packages ────────────────────────────────────────────────────────

echo "==> running apt full-upgrade to avoid breaking curl..."
DEBIAN_FRONTEND=noninteractive apt full-upgrade -y -o Dpkg::Options::='--force-confnew'

echo "==> Installing Termux packages..."
pkg install -y cmake clang lld llvm binutils make git curl python p7zip ed xz-utils

# ── 2. NDK r29 (lzhiyong aarch64 build) ──────────────────────────────────────

if [ ! -d "$NDK_DIR" ] && [ "${SKIP_NDK_DOWNLOAD:-0}" != "1" ]; then
    echo "==> NDK not found at $NDK_DIR — downloading from lzhiyong/termux-ndk..."
    mkdir -p "$CACHE_DIR" "${HOME}/android"
    if [ ! -f "$NDK_ARCHIVE" ]; then
        curl -fL --progress-bar -o "${NDK_ARCHIVE}.tmp" "$NDK_DOWNLOAD_URL"
        mv "${NDK_ARCHIVE}.tmp" "$NDK_ARCHIVE"
    fi
    echo "==> Extracting NDK (~333 MB, may take a minute)..."
    7z x "$NDK_ARCHIVE" -o"${HOME}/android" -y
elif [ ! -d "$NDK_DIR" ]; then
    echo "ERROR: NDK not found at $NDK_DIR and SKIP_NDK_DOWNLOAD=1" >&2
    exit 1
fi

# ── 3. Fetch source ───────────────────────────────────────────────────────────

mkdir -p "$CACHE_DIR"
if [ ! -f "$TARBALL" ]; then
    echo "==> Fetching upstream ${UPSTREAM_COMMIT}..."
    curl -fL --progress-bar -o "${TARBALL}.tmp" "$UPSTREAM_URL"
    mv "${TARBALL}.tmp" "$TARBALL"
fi

# ── 4. Goosify ────────────────────────────────────────────────────────────────

if [ ! -f "${SRC_DIR}/.goosified" ]; then
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_ROOT"
    echo "==> Extracting source..."
    tar -xzf "$TARBALL" -C "$SRC_ROOT"
    echo "==> Goosifying..."
    cp "${SCRIPT_DIR}/goosify.sh" "${SRC_DIR}/goosify.sh"
    (cd "$SRC_DIR" && bash ./goosify.sh)
    touch "${SRC_DIR}/.goosified"
fi

# ── 5. Build static deps ──────────────────────────────────────────────────────

if [ ! -f "${ANDROID_DEPS_DIR}/.deps-ready" ] && [ "${SKIP_DEPS:-0}" != "1" ]; then
    echo "==> Building Android dependencies (this takes ~20-40 min on first run)..."
    NDK="$NDK_DIR" \
    ANDROID_ABI="$ANDROID_ABI" \
    ANDROID_API="$ANDROID_API" \
    BUILD_DIR="${CACHE_DIR}/android" \
    bash "${SCRIPT_DIR}/build-android-deps.sh"
    touch "${ANDROID_DEPS_DIR}/.deps-ready"
fi

# ── 6. Configure & build ──────────────────────────────────────────────────────

echo "==> Clearing build dir to prevent stale cmake cache..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Configuring..."

# Fix Termux heredoc/tmp issues (gen_scmversion.sh)
export TMPDIR="${TERMUX_PREFIX:-/data/data/com.termux/files/usr}/tmp"
mkdir -p "$TMPDIR"

# 2. Configure PkgConfig for cross-compilation: point to built deps, hide host paths
export PKG_CONFIG_LIBDIR="${ANDROID_DEPS_DIR}/lib/pkgconfig"
export PKG_CONFIG_PATH=""
export PKG_CONFIG_SYSROOT_DIR="/"

# Create a shim zlib.pc since NDK provides zlib but no .pc file
# libpng.pc requires zlib, so pkg-config fails without this.
mkdir -p "${PKG_CONFIG_LIBDIR}"
cat > "${PKG_CONFIG_LIBDIR}/zlib.pc" << EOF
Name: zlib
Description: zlib compression library
Version: 1.2.11
Libs: -lz
EOF

# 3. Prevent NDK from being confused by host environment
unset ANDROID_NDK ANDROID_NDK_ROOT ANDROID_NDK_HOME
unset CC CXX CFLAGS CXXFLAGS LDFLAGS

TOOLCHAIN_FILE="${NDK_DIR}/build/cmake/android.toolchain.cmake"
NDK_TOOLCHAIN_BIN="${NDK_DIR}/toolchains/llvm/prebuilt/linux-aarch64/bin"

cmake -S "$SRC_DIR" -B "$BUILD_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
    -DANDROID_ABI="$ANDROID_ABI" \
    -DANDROID_PLATFORM="android-${ANDROID_API}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${NDK_TOOLCHAIN_BIN}/clang" \
    -DCMAKE_CXX_COMPILER="${NDK_TOOLCHAIN_BIN}/clang++" \
    -DBUILD_LIBRETRO=ON \
    -DBUILD_REGTEST=OFF \
    -DBUILD_TESTS=OFF \
    -DENABLE_OPENGL=ON \
    -DENABLE_VULKAN=ON \
    -DCMAKE_PREFIX_PATH="$ANDROID_DEPS_DIR" \
    -DCMAKE_FIND_ROOT_PATH="$ANDROID_DEPS_DIR" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_CXX_FLAGS="-Wno-invalid-offsetof" \
    -Wno-dev

echo "==> Building (using $JOBS jobs)..."
cmake --build "$BUILD_DIR" --parallel "$JOBS" --target goosestation_libretro

# ── 7. Install ────────────────────────────────────────────────────────────────

mkdir -p "$DIST_DIR"
BUILT_SO="${BUILD_DIR}/src/goosestation-libretro/goosestation_libretro.so"
if [ ! -f "$BUILT_SO" ]; then
    BUILT_SO="$(find "$BUILD_DIR" -name 'goosestation_libretro.so' | head -1)"
fi

echo "==> Stripping..."
cp "$BUILT_SO" "${DIST_DIR}/goosestation_libretro.so"
"${NDK_DIR}/toolchains/llvm/prebuilt/linux-aarch64/bin/llvm-strip" --strip-unneeded "${DIST_DIR}/goosestation_libretro.so"
cp "${SCRIPT_DIR}/goosestation_libretro.info" "${DIST_DIR}/goosestation_libretro.info"

echo ""
echo "==> Done!"
echo "  Artifact: ${DIST_DIR}/goosestation_libretro.so"
