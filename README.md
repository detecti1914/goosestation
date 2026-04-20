# GooseStation Builder

Reproducible builder for the **GooseStation** libretro core. Fetches a pinned
upstream DuckStation tarball, runs `goosify.sh`, then builds the libretro core for the selected target.

Run `make help` for the full target list and the pinned commits this build
would use.

## Prerequisites

### All targets
- `cmake` ≥ 3.22
- `curl`, `tar`, `bash`, `ed`
- GCC or Clang with C++20 support

### Linux target
Runtime/build libs (Arch/aur package names shown; adapt to your distro):

    zstd libzip freetype libjpeg-turbo libpng libwebp plutosvg
    cpuinfo-pytorch-git zlib systemd-libs
    vulkan-headers shaderc spirv-cross
    libglvnd

### Android target
- Android NDK (tested with `28.2.13676358`).
- NDK auto-detected in this order, first hit wins:
  1. `ANDROID_NDK` (explicit)
  2. `ANDROID_NDK_ROOT` or `ANDROID_NDK_HOME` env vars
  3. highest-versioned `ndk/*` under `$ANDROID_HOME` or `$ANDROID_SDK_ROOT`
     (falling back to `~/Android/Sdk` and `/opt/android-sdk`)

  To override: `make android ANDROID_NDK=/path/to/ndk`.
- First `make android` run cross-compiles all native deps (shaderc,
  spirv-cross, freetype, libpng, etc.) into `src/.../build-android/deps/`.
- Defaults: `ANDROID_ABI=arm64-v8a`, `ANDROID_PLATFORM=android-28`

## Usage

    make linux                              # host Linux .so
    make android                            # Android arm64 .so
    make all                                # both
    make clean                              # wipe build/ dist/
    make distclean                          # also wipe src/

On success the full path to the produced `.so` is printed on the last line.


## License

- Builder (this repo): GPL-2.0 (see `LICENSE`).
- Upstream DuckStation: CC-BY-NC-ND-4.0.
- Resulting binary inherits CC-BY-NC-ND-4.0. Do not redistribute.
