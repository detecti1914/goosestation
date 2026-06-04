#!/usr/bin/env bash
# Build the patched libuam.a + uam.h into a SELF-CONTAINED prefix dir.
#
# We patch uam (disable the broken experimental PostRADualIssue pass — see
# patches/uam/). Both build paths use THIS script so they produce an identical
# patched libuam:
#   - host  (update-build.sh -> make switch-uam): PREFIX defaults to .cache/switch-uam
#   - docker (Dockerfile.switch): PREFIX is a fixed container dir
# Makefile.libnx is then pointed at $PREFIX via a LIBDIRS prepend, so the patched
# libuam/uam.h win over the toolchain's copies. IMPORTANT: this NEVER writes into
# $DEVKITPRO — the system/container devkitPro install is left untouched.
#

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
: "${DEVKITPRO:=/opt/devkitpro}"
export DEVKITPRO
# Keep UAM_COMMIT in sync with ARG UAM_COMMIT in Dockerfile.switch.
UAM_COMMIT="${UAM_COMMIT:-6599d8e32a735baec09dc5a4549622cb82bd829a}"
UAM_REPO="${UAM_REPO:-https://github.com/RSDuck/uam.git}"
# Self-contained install prefix (lib/ + include/). Override via PREFIX env.
PREFIX="${PREFIX:-$HERE/.cache/switch-uam}"
WORK="$HERE/.cache/uam-host"
AR="$DEVKITPRO/devkitA64/bin/aarch64-none-elf-ar"

echo "==> Building patched libuam (pin ${UAM_COMMIT:0:10}) -> $PREFIX"

# 1. Clean clone at the pinned commit.
if [ ! -d "$WORK/.git" ]; then
	rm -rf "$WORK"
	git clone "$UAM_REPO" "$WORK"
fi
git -C "$WORK" fetch -q origin 2>/dev/null || true
git -C "$WORK" checkout -q "$UAM_COMMIT"
git -C "$WORK" reset --hard -q "$UAM_COMMIT"
git -C "$WORK" clean -fdq -e build

# 2. Apply every uam patch (single source of truth, shared with Docker).
shopt -s nullglob
for p in "$HERE"/patches/uam/*.patch; do
	echo "    applying $(basename "$p")"
	git -C "$WORK" apply "$p"
done
shopt -u nullglob

# 3. Cross-build as a static library. The pinned commit references the
#    build_as_library option but doesn't declare it; declare it here.
cd "$WORK"
echo "option('build_as_library', type: 'boolean', value: false, description: 'Build uam as a static library instead of an executable')" > meson_options.txt
rm -rf build
meson setup build --cross-file crossfile --buildtype=release \
	-Dbuild_as_library=true \
	-Dcpp_args=-fno-omit-frame-pointer -Dc_args=-fno-omit-frame-pointer
ninja -C build
test -f build/libuam.a

# 4. __uam_ symbol redirect (avoid collision with RA's bundled mesa GLSL),
#    install into the prefix lib dir.
mkdir -p "$PREFIX/lib" "$PREFIX/include"
cd build
"$AR" -t libuam.a > members.txt
rm -f libuam_fat.a
"$AR" rcs libuam_fat.a $(cat members.txt)
bash "$HERE/uam_redef.sh" libuam_fat.a uam_redef "$PREFIX/lib/libuam.a"

# 5. uam.h with the symbol-redirect prefix macros prepended (original uam_*
#    names map to the renamed __uam_uam_* symbols).
cat "$HERE/uam_prefix.h" "$WORK/source/uam.h" > "$PREFIX/include/uam.h"

echo "==> Installed libuam.a + uam.h -> $PREFIX/{lib,include}"
