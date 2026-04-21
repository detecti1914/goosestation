### GooseStation libretro core builder
###
### Usage:
###   docker build -t goosestation-builder .
###   docker run --rm -v "$PWD/dist:/work/dist" -v "$PWD/.cache:/work/.cache" \
###       goosestation-builder windows android
###
### Arguments after the image name are passed straight to `make` inside the
### container - pass any of: linux, android, windows, clean, distclean, help, etc.
###
### dist/ on the host receives:
###   dist/windows/goosestation_libretro.dll
###   dist/android/goosestation_libretro.so
###   etc
###
### .cache/ caches the upstream tarball + Android NDK download across runs.

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        ninja-build \
        git \
        curl \
        wget \
        ca-certificates \
        tar \
        xz-utils \
        unzip \
        ed \
        python3 \
        pkg-config \
        zlib1g-dev \
        libzstd-dev \
        libpng-dev \
        libjpeg62-turbo-dev \
        libwebp-dev \
        libfreetype-dev \
        libzip-dev \
        libcurl4-openssl-dev \
        libsdl3-dev \
        libshaderc-dev \
        libspirv-cross-c-shared-dev \
        libvulkan-dev \
        nasm \
        mingw-w64 \
        mingw-w64-tools \
        file \
    && rm -rf /var/lib/apt/lists/* \
    && update-alternatives --set x86_64-w64-mingw32-gcc /usr/bin/x86_64-w64-mingw32-gcc-posix \
    && update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix

# Android NDK r28b (matches what the README is tested with).
ENV ANDROID_NDK_VERSION=r28b
ENV ANDROID_NDK=/opt/android-ndk
RUN mkdir -p /opt && cd /tmp \
    && curl -fsSLO "https://dl.google.com/android/repository/android-ndk-${ANDROID_NDK_VERSION}-linux.zip" \
    && unzip -q "android-ndk-${ANDROID_NDK_VERSION}-linux.zip" -d /opt \
    && mv "/opt/android-ndk-${ANDROID_NDK_VERSION}" "${ANDROID_NDK}" \
    && rm -f "/tmp/android-ndk-${ANDROID_NDK_VERSION}-linux.zip"

WORKDIR /work
COPY . /work

ENTRYPOINT ["make"]
