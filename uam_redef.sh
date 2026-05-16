#!/usr/bin/env bash
# Generate redefine-syms list from libuam.a — rename all UAM-defined symbols
# with __uam_ prefix to avoid collision with RA's bundled mesa GLSL compiler.
set -eu
NMPROG="${DEVKITPRO}/devkitA64/bin/aarch64-none-elf-nm"
OBJCOPY="${DEVKITPRO}/devkitA64/bin/aarch64-none-elf-objcopy"
ARCHIVE="$1"
REDEF_FILE="$2"
OUTPUT="$3"

# Include V (weak vtable/RTTI) and W (weak function) — RetroArch's libEGL.a
# also bundles mesa GLSL frontend, leading to vtable COMDAT collision on
# ast_function_definition / ast_node / ir_* etc. The wrong vtable wins at
# link time, then UAM's ctor sets vptr to its (renamed) class layout but the
# vtable that's actually live belongs to libEGL — vptr dispatch jumps to the
# wrong slot and crashes (NULL deref) during the AST walk in _mesa_ast_to_hir.
"$NMPROG" --defined-only "$ARCHIVE" \
  | awk '$2 ~ /[TDBRVWn]/ && !seen[$3]++ {print $3 " __uam_" $3}' > "$REDEF_FILE"

"$OBJCOPY" --redefine-syms="$REDEF_FILE" "$ARCHIVE"
mv "$ARCHIVE" "$OUTPUT"
