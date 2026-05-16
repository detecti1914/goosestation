### GooseStation libretro core builder
###
### Usage:
###   docker build -t goosestation-builder .
###   docker run --rm -v "$PWD/dist:/work/dist:Z" -v "$PWD/.cache:/work/.cache:Z" goosestation-builder linux
###
### Builds for the host platform by default. Use --platform to cross-build:
###   docker build --platform linux/amd64 -t goosestation-builder-amd64 .
###
### Arguments after the image name are passed straight to `make` inside the
### container - pass any of: linux, android, windows, clean, distclean, help, etc.
###
### dist/ on the host receives the built cores (e.g. dist/linux-aarch64/).
### .cache/ caches the upstream tarballs and dependency builds.
###
### Speed notes:
### - BuildKit cache mounts persist apt's .deb cache across rebuilds. Works on
###   podman natively, and on docker 23+ (BuildKit on by default). On older
###   docker, set DOCKER_BUILDKIT=1 or use `docker buildx build`.
### - eatmydata disables fsync during apt install for ~2x throughput.

# syntax=docker/dockerfile:1.6
FROM debian:trixie-slim

ARG TARGETARCH

ENV DEBIAN_FRONTEND=noninteractive

# Set native compilers to Clang
ENV CC=clang
ENV CXX=clang++

RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
    rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --no-install-recommends eatmydata \
    && eatmydata apt-get install -y --no-install-recommends \
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
    && ln -sf llvm-ml-19 /usr/bin/llvm-ml

# SnowNF aarch64 NDK's ld.lld dynamically links libxml2.so.16 (libxml2 2.14+).
# Debian trixie ships 2.12 (libxml2.so.2). Build a parallel install to satisfy
# the NDK toolchain. Only needed on arm64 hosts — Google's amd64 NDK has its
# tools statically linked and doesn't need this.
ARG LIBXML2_VERSION=2.14.6
RUN if [ "$TARGETARCH" = "arm64" ]; then \
        curl -fsSL "https://download.gnome.org/sources/libxml2/2.14/libxml2-${LIBXML2_VERSION}.tar.xz" \
            | tar -xJ -C /tmp \
        && cd "/tmp/libxml2-${LIBXML2_VERSION}" \
        && ./configure --prefix=/usr/local --disable-static --without-python --without-zlib --without-lzma \
        && make -j"$(nproc)" \
        && make install \
        && ldconfig \
        && rm -rf "/tmp/libxml2-${LIBXML2_VERSION}"; \
    fi

WORKDIR /work
COPY . /work

ENTRYPOINT ["make"]
