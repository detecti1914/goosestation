# GooseStation Builder

Reproducible builder for the **GooseStation** libretro core. Fetches a pinned
upstream DuckStation tarball, runs `goosify.sh`, then builds the libretro core
for the selected target.

Run `make help` for the full target list and pinned commits.

## Targets

| Target | Output | Native | Docker |
|--------|--------|--------|--------|
| linux | `.so` (x86_64) | `make linux` | `make docker-linux` |
| android | `.so` (arm64) | `make android` | `make docker-android` |
| windows | `.dll` (x86_64) | `make windows` | `make docker-windows` |
| macos | `.dylib` (host arch) | `make macos` | — |
| switch | `.nro` (aarch64) | — | `make docker-switch` |

    make all          # linux + android + windows
    make clean        # wipe build/ dist/
    make distclean    # also wipe src/ .cache/

## Native builds

Native builds cache downloads and cross-compiled deps in `.cache/`.

### Prerequisites (all native targets)
- `cmake` ≥ 3.22, `curl`, `tar`, `bash`, `ed`
- GCC or Clang with C++20

### Linux
Build libs (Arch package names): `zstd libjpeg-turbo libpng libwebp
cpuinfo-pytorch-git zlib systemd-libs vulkan-headers shaderc spirv-cross
libglvnd`

### Android
- Android NDK (tested with r29). Auto-detected from `ANDROID_NDK`,
  `ANDROID_NDK_ROOT`, `ANDROID_NDK_HOME`, or highest version under
  `$ANDROID_HOME/ndk/`. Override: `make android ANDROID_NDK=/path/to/ndk`.
- First run cross-compiles deps into `.cache/android/deps/`.
- Defaults: `ANDROID_ABI=arm64-v8a`, `ANDROID_PLATFORM=android-28`

### Windows
- Requires `x86_64-w64-mingw32` cross toolchain.

### macOS
- Requires Xcode command-line tools. Builds universal (x86_64 + arm64).

## Docker builds

Per-platform Dockerfiles (`Dockerfile.linux`, `.android`, `.windows`,
`.switch`) are fully self-contained — all toolchains, deps, and source are
baked into the image. Only `dist/` is mounted for output. No `.cache/` needed.

    make docker-linux
    make docker-android
    make docker-windows
    make docker-switch    # produces .nro via RetroArch + libnx

Images are rebuilt automatically when pinned commits or Dockerfiles change.

## License

- Builder (this repo): GPL-2.0 (see `LICENSE`).
- Upstream DuckStation: CC-BY-NC-ND-4.0.
- Resulting binary inherits CC-BY-NC-ND-4.0. Do not redistribute.
