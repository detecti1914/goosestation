### GooseStation libretro core builder
###
### Usage:
###   docker build -t goosestation-builder .
###   docker run --rm -v "$PWD/dist:/work/dist" -v "$PWD/.cache:/work/.cache" goosestation-builder linux
###
### Arguments after the image name are passed straight to `make` inside the
### container - pass any of: linux, android, windows, clean, distclean, help, etc.
###
### dist/ on the host receives:
###   dist/windows/goosestation_libretro.dll
###   dist/android/goosestation_libretro.so
###   etc
###
### .cache/ caches the upstream tarballs

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# Set native compilers to Clang
ENV CC=clang
ENV CXX=clang++

RUN apt-get update && apt-get install -y --no-install-recommends \
        make \
        libc6-dev \
        clang \
        llvm-dev \
        lld \
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
        binutils-mingw-w64-x86-64 \
        gcc-mingw-w64-x86-64-posix \
        g++-mingw-w64-x86-64-posix \
        mingw-w64-x86-64-dev \
        mingw-w64-tools \
        file \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf llvm-ml-19 /usr/bin/llvm-ml

# Android NDK r29
ENV ANDROID_NDK_VERSION=r29
ENV ANDROID_NDK=/opt/android-ndk
RUN mkdir -p /opt && cd /tmp \
    && curl -fsSLO "https://dl.google.com/android/repository/android-ndk-${ANDROID_NDK_VERSION}-linux.zip" \
    && unzip -q "android-ndk-${ANDROID_NDK_VERSION}-linux.zip" -d /opt \
    && mv "/opt/android-ndk-${ANDROID_NDK_VERSION}" "${ANDROID_NDK}" \
    && rm -f "/tmp/android-ndk-${ANDROID_NDK_VERSION}-linux.zip" \
    # Prune unused NDK sysroots to save space (safely keeps the bin/ toolchain)
    && rm -rf "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/i686-linux-android" \
    && rm -rf "${ANDROID_NDK}/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/x86_64-linux-android"


WORKDIR /work
COPY . /work

ENTRYPOINT ["make"]
