# GooseStation libretro core builder.
#

UPSTREAM_COMMIT := 3a10c16b10d3dd23155ccd83a3af97c421d3cab1

UPSTREAM_URL := https://github.com/stenzek/duckstation/archive/$(UPSTREAM_COMMIT).tar.gz

ROOT := $(abspath .)
GOOSIFY := $(ROOT)/goosify.sh
CACHE_DIR := $(ROOT)/.cache
TARBALL := $(CACHE_DIR)/duckstation-$(UPSTREAM_COMMIT).tar.gz
SRC_ROOT := $(ROOT)/src
SRC_DIR := $(SRC_ROOT)/duckstation-$(UPSTREAM_COMMIT)
BUILD_ROOT := $(ROOT)/build
DIST_DIR := $(ROOT)/dist

ANDROID_NDK_VERSION ?= r29
# Branch both build paths build from; it contains the deko3d backend directly
# (no separate 0003 delta). Passed to the Docker build via --build-arg.
RETROARCH_BRANCH ?= deko3d-driver-shaders
NDK_HOST_ARCH := $(shell uname -m)
ifeq ($(NDK_HOST_ARCH),$(filter $(NDK_HOST_ARCH),aarch64 arm64))
ANDROID_NDK_ARCHIVE := $(CACHE_DIR)/android-ndk-$(ANDROID_NDK_VERSION)-linux-aarch64.tar.gz
ANDROID_NDK_URL := https://github.com/SnowNF/ndk-aarch64-linux/releases/download/0.0.2/android-ndk-$(ANDROID_NDK_VERSION)-linux-aarch64.tar.gz
else
ANDROID_NDK_ARCHIVE := $(CACHE_DIR)/android-ndk-$(ANDROID_NDK_VERSION)-linux.zip
ANDROID_NDK_URL := https://dl.google.com/android/repository/android-ndk-$(ANDROID_NDK_VERSION)-linux.zip
endif
ANDROID_NDK ?= $(CACHE_DIR)/android-ndk-$(ANDROID_NDK_VERSION)
ANDROID_ABI ?= arm64-v8a
ANDROID_PLATFORM ?= android-28

HOST_ARCH := $(shell uname -m)
LINUX_BUILD_DIR ?= $(CACHE_DIR)/linux-$(HOST_ARCH)
LINUX_DEPS_DIR ?= $(LINUX_BUILD_DIR)/deps

MINGW_PREFIX ?= x86_64-w64-mingw32
MINGW_BUILD_DIR ?= $(CACHE_DIR)/mingw
MINGW_DEPS_DIR ?= $(MINGW_BUILD_DIR)/deps

MACOS_BUILD_DIR := $(CACHE_DIR)/macos
MACOS_DEPS_DIR := $(MACOS_BUILD_DIR)/deps

CMAKE ?= cmake
STRIP ?= strip
ANDROID_PREBUILT = $(firstword $(wildcard $(ANDROID_NDK)/toolchains/llvm/prebuilt/linux-*))
ANDROID_STRIP = $(ANDROID_PREBUILT)/bin/llvm-strip
MINGW_STRIP = llvm-strip
JOBS ?= $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

.PHONY: all linux linux-unstripped linux-static linux-static-unstripped android android-unstripped windows windows-unstripped macos macos-unstripped switch switch-retroarch clean distclean prepare help

help:
	@echo "Targets:"
	@echo "  linux               build stripped libretro core for host Linux (system libs)"
	@echo "  linux-unstripped    same, keep debug symbols (.unstripped.so)"
	@echo "  linux-static        build stripped libretro core for host Linux (deps baked in)"
	@echo "  linux-static-unstripped  same, keep debug symbols (.unstripped.so)"
	@echo "  android             build stripped libretro core for Android (arm64)"
	@echo "  android-unstripped  same, keep debug symbols (.unstripped.so)"
	@echo "  windows             build stripped libretro core for Windows x64 (mingw cross via LLVM)"
	@echo "  windows-unstripped  same, keep debug symbols (.unstripped.dll)"
	@echo "  macos               build stripped libretro core for macOS (native, requires Homebrew deps)"
	@echo "  macos-unstripped    same, keep debug symbols (.unstripped.dylib)"
	@echo "  switch              build static libretro archive for Nintendo Switch (devkitA64)"
	@echo "  switch-retroarch    build per-core RetroArch NRO with goosestation core baked in"
	@echo "  all                 stripped linux + android + windows"
	@echo "  clean               remove build and dist dirs (keep fetched source)"
	@echo "  distclean           remove everything, including fetched source"
	@echo ""
	@echo "Pinned:"
	@echo "  DuckStation upstream: $(UPSTREAM_COMMIT)"

all: linux android windows

prepare: $(SRC_DIR)/.goosified
	@mkdir -p "$(DIST_DIR)" "$(CACHE_DIR)"
	@echo "Prepared host dirs: $(DIST_DIR) $(CACHE_DIR)"

$(TARBALL):
	@mkdir -p $(CACHE_DIR)
	@echo "==> Fetching upstream $(UPSTREAM_COMMIT)..."
	@curl -fsSL $(UPSTREAM_URL) -o $@.tmp && mv $@.tmp $@

$(SRC_DIR)/.goosified: $(GOOSIFY)
	@if [ -f "$@" ]; then \
		echo "(source already goosified, skipping fetch+patch)"; \
	else \
		rm -rf $(SRC_DIR); \
		mkdir -p $(SRC_ROOT) $(CACHE_DIR); \
		test -f "$(TARBALL)" || { echo "==> Fetching upstream $(UPSTREAM_COMMIT)..."; \
			curl -fsSL $(UPSTREAM_URL) -o $(TARBALL).tmp && mv $(TARBALL).tmp $(TARBALL); }; \
		echo "==> Extracting upstream from cached tarball..."; \
		tar -xzf $(TARBALL) -C $(SRC_ROOT); \
		echo "==> Goosifying..."; \
		cp $(GOOSIFY) $(SRC_DIR)/goosify.sh; \
		cd $(SRC_DIR) && bash ./goosify.sh; \
	fi
	@touch $@

LINUX_DIST_DIR := $(DIST_DIR)/linux-$(HOST_ARCH)
LINUX_BUILT := $(BUILD_ROOT)/linux/src/goosestation-libretro/goosestation_libretro.so
LINUX_UNSTRIPPED := $(LINUX_DIST_DIR)/goosestation_libretro.unstripped.so
LINUX_SO := $(LINUX_DIST_DIR)/goosestation_libretro.so

# linux-static: like linux, but every external dep (zlib/zstd/png/jpeg/webp/
# shaderc/spirv-cross/cpuinfo) is built static
LINUX_STATIC_MARCH ?= -march=x86-64-v2
LINUX_STATIC_BUILD_DIR ?= $(CACHE_DIR)/linux-static-$(HOST_ARCH)
LINUX_STATIC_DEPS_DIR ?= $(LINUX_STATIC_BUILD_DIR)/deps
LINUX_STATIC_DIST_DIR := $(DIST_DIR)/linux-static-$(HOST_ARCH)
LINUX_STATIC_BUILT := $(BUILD_ROOT)/linux-static/src/goosestation-libretro/goosestation_libretro.so
LINUX_STATIC_UNSTRIPPED := $(LINUX_STATIC_DIST_DIR)/goosestation_libretro.unstripped.so
LINUX_STATIC_SO := $(LINUX_STATIC_DIST_DIR)/goosestation_libretro.so

ANDROID_BUILD_DIR ?= $(CACHE_DIR)/android
ANDROID_DEPS_DIR ?= $(ANDROID_BUILD_DIR)/deps

ANDROID_BUILT := $(BUILD_ROOT)/android/src/goosestation-libretro/goosestation_libretro.so
ANDROID_UNSTRIPPED := $(DIST_DIR)/android/goosestation_libretro.unstripped.so
ANDROID_SO := $(DIST_DIR)/android/goosestation_libretro.so

linux: $(LINUX_SO)
linux-unstripped: $(LINUX_UNSTRIPPED)

$(LINUX_UNSTRIPPED): prepare $(LINUX_DEPS_DIR)/.deps-ready
	@echo "==> Configuring Linux build"
	@PKG_CONFIG_PATH="$(LINUX_DEPS_DIR)/lib/pkgconfig:$${PKG_CONFIG_PATH}" \
		$(CMAKE) -S $(SRC_DIR) -B $(BUILD_ROOT)/linux \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_LIBRETRO=ON \
		-DBUILD_REGTEST=OFF \
		-DBUILD_TESTS=OFF \
		-DENABLE_OPENGL=ON \
		-DENABLE_VULKAN=ON \
		-DCMAKE_MODULE_PATH=$(SRC_DIR)/cmake \
		-DCMAKE_PREFIX_PATH="$(LINUX_DEPS_DIR);$(SRC_DIR)/cmake" \
		-DCMAKE_CXX_FLAGS="-Wno-invalid-offsetof" \
		-Wno-dev
	@echo "==> Building"
	@$(CMAKE) --build $(BUILD_ROOT)/linux --parallel $(JOBS) --target goosestation_libretro
	@mkdir -p $(LINUX_DIST_DIR)
	@cp $(LINUX_BUILT) $@
	@cp $(ROOT)/goosestation_libretro.info $(LINUX_DIST_DIR)/goosestation_libretro.info
	@cp $(SRC_DIR)/src/goosestation-libretro/overlays/cursor_only.cfg $(LINUX_DIST_DIR)/cursor_only.cfg
	@echo ""
	@echo "Linux core built (unstripped):"
	@echo "  $@"

ifneq ($(filter $(CACHE_DIR)/%,$(LINUX_DEPS_DIR)),)
$(LINUX_DEPS_DIR)/.deps-ready: $(ROOT)/build-linux-deps.sh
	@echo "==> Building Linux extras into $(LINUX_BUILD_DIR)..."
	@BUILD_DIR=$(LINUX_BUILD_DIR) bash $(ROOT)/build-linux-deps.sh
	@touch $@
endif

$(LINUX_SO): $(LINUX_UNSTRIPPED)
	@cp $< $@
	@$(STRIP) --strip-unneeded $@
	@echo ""
	@echo "Linux core built (stripped):"
	@echo "  $@"

linux-static: $(LINUX_STATIC_SO)
linux-static-unstripped: $(LINUX_STATIC_UNSTRIPPED)

$(LINUX_STATIC_UNSTRIPPED): prepare $(LINUX_STATIC_DEPS_DIR)/.deps-ready
	@echo "==> Configuring Linux static build"
	@PKG_CONFIG_PATH="$(LINUX_STATIC_DEPS_DIR)/lib/pkgconfig:$${PKG_CONFIG_PATH}" \
		$(CMAKE) -S $(SRC_DIR) -B $(BUILD_ROOT)/linux-static \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_LIBRETRO=ON \
		-DBUILD_REGTEST=OFF \
		-DBUILD_TESTS=OFF \
		-DENABLE_OPENGL=ON \
		-DENABLE_VULKAN=ON \
		-DGOOSE_LIBRETRO_STATIC_DEPS=ON \
		-DCMAKE_MODULE_PATH=$(SRC_DIR)/cmake \
		-DCMAKE_PREFIX_PATH="$(LINUX_STATIC_DEPS_DIR);$(SRC_DIR)/cmake" \
		-DCMAKE_C_FLAGS="$(LINUX_STATIC_MARCH)" \
		-DCMAKE_CXX_FLAGS="-Wno-invalid-offsetof $(LINUX_STATIC_MARCH)" \
		-Wno-dev
	@echo "==> Building"
	@$(CMAKE) --build $(BUILD_ROOT)/linux-static --parallel $(JOBS) --target goosestation_libretro
	@mkdir -p $(LINUX_STATIC_DIST_DIR)
	@cp $(LINUX_STATIC_BUILT) $@
	@cp $(ROOT)/goosestation_libretro.info $(LINUX_STATIC_DIST_DIR)/goosestation_libretro.info
	@cp $(SRC_DIR)/src/goosestation-libretro/overlays/cursor_only.cfg $(LINUX_STATIC_DIST_DIR)/cursor_only.cfg
	@echo ""
	@echo "Linux static core built (unstripped):"
	@echo "  $@"

ifneq ($(filter $(CACHE_DIR)/%,$(LINUX_STATIC_DEPS_DIR)),)
$(LINUX_STATIC_DEPS_DIR)/.deps-ready: $(ROOT)/build-linux-static-deps.sh
	@echo "==> Building Linux static deps into $(LINUX_STATIC_BUILD_DIR)..."
	@BUILD_DIR=$(LINUX_STATIC_BUILD_DIR) MARCH="$(LINUX_STATIC_MARCH)" bash $(ROOT)/build-linux-static-deps.sh
	@touch $@
endif

$(LINUX_STATIC_SO): $(LINUX_STATIC_UNSTRIPPED)
	@cp $< $@
	@$(STRIP) --strip-unneeded $@
	@echo ""
	@echo "Linux static core built (stripped):"
	@echo "  $@"

android: $(ANDROID_SO)
android-unstripped: $(ANDROID_UNSTRIPPED)

$(ANDROID_UNSTRIPPED): prepare $(ANDROID_DEPS_DIR)/.deps-ready $(ANDROID_NDK)/.ndk-ready
	@echo "==> Configuring Android build"
	@$(CMAKE) -S $(SRC_DIR) -B $(BUILD_ROOT)/android \
		-DCMAKE_TOOLCHAIN_FILE=$(ANDROID_NDK)/build/cmake/android.toolchain.cmake \
		-DANDROID_ABI=$(ANDROID_ABI) \
		-DANDROID_PLATFORM=$(ANDROID_PLATFORM) \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_LIBRETRO=ON \
		-DBUILD_REGTEST=OFF \
		-DBUILD_TESTS=OFF \
		-DENABLE_OPENGL=ON \
		-DENABLE_VULKAN=ON \
		-DCMAKE_PREFIX_PATH=$(ANDROID_DEPS_DIR) \
		-DCMAKE_FIND_ROOT_PATH=$(ANDROID_DEPS_DIR) \
		-DCMAKE_CXX_FLAGS="-Wno-invalid-offsetof" \
		-Wno-dev
	@echo "==> Building"
	@$(CMAKE) --build $(BUILD_ROOT)/android --parallel $(JOBS) --target goosestation_libretro
	@mkdir -p $(DIST_DIR)/android
	@cp $(ANDROID_BUILT) $@
	@cp $(ROOT)/goosestation_libretro.info $(DIST_DIR)/android/goosestation_libretro.info
	@cp $(SRC_DIR)/src/goosestation-libretro/overlays/cursor_only.cfg $(DIST_DIR)/android/cursor_only.cfg
	@echo ""
	@echo "Android core built (unstripped):"
	@echo "  $@"

$(ANDROID_SO): $(ANDROID_UNSTRIPPED)
	@cp $< $@
	@$(ANDROID_STRIP) --strip-unneeded $@
	@echo ""
	@echo "Android core built (stripped):"
	@echo "  $@"

# Native builds: download NDK and build deps into .cache/
# Docker: NDK + deps pre-installed externally, rules skipped.
ifneq ($(filter $(CACHE_DIR)/%,$(ANDROID_NDK)),)
$(ANDROID_NDK_ARCHIVE):
	@mkdir -p $(CACHE_DIR)
	@echo "==> Fetching NDK archive..."
	@curl -fsSL $(ANDROID_NDK_URL) -o $@.tmp && mv $@.tmp $@

$(ANDROID_NDK_ARCHIVE).ndk-downloaded: $(ANDROID_NDK_ARCHIVE)
	@touch $@

$(ANDROID_NDK)/.ndk-ready: $(ANDROID_NDK_ARCHIVE).ndk-downloaded
	@echo "==> Extracting NDK to $(ANDROID_NDK)..."
	@rm -rf $(ANDROID_NDK)
	@case "$(ANDROID_NDK_ARCHIVE)" in \
		*.zip) TMPDIR=$$(mktemp -d /tmp/android-ndk-extract-XXXXXX) && \
			unzip -q $(ANDROID_NDK_ARCHIVE) -d "$$TMPDIR" && \
			EXTRACT_DIR=$$(find "$$TMPDIR" -maxdepth 1 -mindepth 1 -type d -print -quit) && \
			if [ -n "$$EXTRACT_DIR" ]; then \
				mv "$$EXTRACT_DIR" $(ANDROID_NDK); \
			else \
				mkdir -p $(ANDROID_NDK) && mv "$$TMPDIR"/* $(ANDROID_NDK); \
			fi && \
			rm -rf "$$TMPDIR" ;; \
		*.tar.gz) mkdir -p $(ANDROID_NDK) && tar -xf $(ANDROID_NDK_ARCHIVE) -C $(ANDROID_NDK) --strip-components=1 ;; \
	esac
	@touch $@
endif

ifneq ($(filter $(CACHE_DIR)/%,$(ANDROID_DEPS_DIR)),)
$(ANDROID_DEPS_DIR)/.deps-ready: $(ROOT)/build-android-deps.sh $(ANDROID_NDK)/.ndk-ready
	@echo "==> Building Android dependencies (cached at $(ANDROID_BUILD_DIR))..."
	@NDK=$(ANDROID_NDK) ANDROID_ABI=$(ANDROID_ABI) BUILD_DIR=$(ANDROID_BUILD_DIR) bash $(ROOT)/build-android-deps.sh
	@touch $@
endif

WINDOWS_BUILT := $(BUILD_ROOT)/windows/bin/goosestation_libretro.dll
WINDOWS_UNSTRIPPED := $(DIST_DIR)/windows/goosestation_libretro.unstripped.dll
WINDOWS_DLL := $(DIST_DIR)/windows/goosestation_libretro.dll

windows: $(WINDOWS_DLL)
windows-unstripped: $(WINDOWS_UNSTRIPPED)

$(WINDOWS_UNSTRIPPED): prepare $(MINGW_DEPS_DIR)/.deps-ready
	@command -v clang >/dev/null || { echo "ERROR: clang not in PATH"; exit 1; }
	@echo "==> Configuring Windows build via LLVM"
	@PKG_CONFIG_LIBDIR="$(MINGW_DEPS_DIR)/lib/pkgconfig" \
		PKG_CONFIG_PATH= \
		$(CMAKE) -S $(SRC_DIR) -B $(BUILD_ROOT)/windows \
		-DCMAKE_SYSTEM_NAME=Windows \
		-DCMAKE_SYSTEM_PROCESSOR=x86_64 \
		-DCMAKE_C_COMPILER=clang \
		-DCMAKE_CXX_COMPILER=clang++ \
		-DCMAKE_RC_COMPILER=x86_64-w64-mingw32-windres \
		-DCMAKE_ASM_MASM_COMPILER=llvm-ml \
		-DCMAKE_ASM_MASM_FLAGS="-m64" \
		-DCMAKE_C_COMPILER_TARGET=$(MINGW_PREFIX) \
		-DCMAKE_CXX_COMPILER_TARGET=$(MINGW_PREFIX) \
		-DCMAKE_EXE_LINKER_FLAGS="-fuse-ld=lld" \
		-DCMAKE_SHARED_LINKER_FLAGS="-fuse-ld=lld" \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_LIBRETRO=ON \
		-DBUILD_REGTEST=OFF \
		-DBUILD_TESTS=OFF \
		-DENABLE_OPENGL=ON \
		-DENABLE_VULKAN=ON \
		-DCMAKE_PREFIX_PATH="$(MINGW_DEPS_DIR);$(SRC_DIR)/cmake" \
		-DCMAKE_FIND_ROOT_PATH="$(MINGW_DEPS_DIR);/usr/$(MINGW_PREFIX)" \
		-DCMAKE_MODULE_PATH=$(SRC_DIR)/cmake \
		-DCMAKE_CXX_FLAGS_RELEASE="-O2 -g -fno-optimize-sibling-calls" \
		-DCMAKE_C_FLAGS_RELEASE="-O2 -g -fno-optimize-sibling-calls" \
		-DCMAKE_CXX_FLAGS="-Wno-invalid-offsetof -D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DNTDDI_VERSION=0x0A000005 -femulated-tls" \
		-DCMAKE_C_FLAGS="-D_WIN32_WINNT=0x0A00 -DWINVER=0x0A00 -DNTDDI_VERSION=0x0A000005 -femulated-tls" \
		-Wno-dev
	@echo "==> Building"
	@touch $(SRC_DIR)/src/goosestation-libretro/main.cpp
	@$(CMAKE) --build $(BUILD_ROOT)/windows --parallel $(JOBS) --target goosestation_libretro
	@mkdir -p $(DIST_DIR)/windows
	@cp $(WINDOWS_BUILT) $@
	@cp $(ROOT)/goosestation_libretro.info $(DIST_DIR)/windows/goosestation_libretro.info
	@cp $(SRC_DIR)/src/goosestation-libretro/overlays/cursor_only.cfg $(DIST_DIR)/windows/cursor_only.cfg
	@echo ""
	@echo "Windows core built (unstripped):"
	@echo "  $@"

$(WINDOWS_DLL): $(WINDOWS_UNSTRIPPED)
	@cp $< $@
	@$(MINGW_STRIP) --strip-unneeded $@
	@echo ""
	@echo "Windows core built (stripped):"
	@echo "  $@"

ifneq ($(filter $(CACHE_DIR)/%,$(MINGW_DEPS_DIR)),)
$(MINGW_DEPS_DIR)/.deps-ready: $(ROOT)/build-mingw-deps.sh
	@command -v clang >/dev/null || { echo "ERROR: clang not in PATH"; exit 1; }
	@echo "==> Building Windows (mingw) dependencies with LLVM (cached at $(MINGW_BUILD_DIR))..."
	@CC="clang --target=$(MINGW_PREFIX) -femulated-tls" \
		CXX="clang++ --target=$(MINGW_PREFIX) -femulated-tls" \
		AR="llvm-ar" RANLIB="llvm-ranlib" RC="llvm-rc" WINDRES="llvm-windres" \
		BUILD_DIR=$(MINGW_BUILD_DIR) bash $(ROOT)/build-mingw-deps.sh
	@touch $@
endif

MACOS_DIST_DIR := $(DIST_DIR)/macos-$(HOST_ARCH)
MACOS_BUILT := $(BUILD_ROOT)/macos/src/goosestation-libretro/goosestation_libretro.dylib
MACOS_UNSTRIPPED := $(MACOS_DIST_DIR)/goosestation_libretro.unstripped.dylib
MACOS_DYLIB := $(MACOS_DIST_DIR)/goosestation_libretro.dylib

macos: $(MACOS_DYLIB)
macos-unstripped: $(MACOS_UNSTRIPPED)

$(MACOS_UNSTRIPPED): prepare $(MACOS_DEPS_DIR)/.deps-ready
	@echo "==> Configuring macOS build"
	@$(CMAKE) -S $(SRC_DIR) -B $(BUILD_ROOT)/macos \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_LIBRETRO=ON \
		-DBUILD_REGTEST=OFF \
		-DBUILD_TESTS=OFF \
		-DENABLE_OPENGL=ON \
		-DENABLE_VULKAN=ON \
		-DCMAKE_MODULE_PATH=$(SRC_DIR)/cmake \
		-DCMAKE_PREFIX_PATH="$(MACOS_DEPS_DIR);$(SRC_DIR)/cmake" \
		-DCMAKE_CXX_FLAGS="-Wno-invalid-offsetof" \
		-Wno-dev
	@echo "==> Building"
	@$(CMAKE) --build $(BUILD_ROOT)/macos --parallel $(JOBS) --target goosestation_libretro
	@mkdir -p $(MACOS_DIST_DIR)
	@cp $(MACOS_BUILT) $@
	@cp $(ROOT)/goosestation_libretro.info $(MACOS_DIST_DIR)/goosestation_libretro.info
	@cp $(SRC_DIR)/src/goosestation-libretro/overlays/cursor_only.cfg $(MACOS_DIST_DIR)/cursor_only.cfg
	@echo ""
	@echo "macOS core built (unstripped):"
	@echo "  $@"

$(MACOS_DEPS_DIR)/.deps-ready: $(ROOT)/build-macos-deps.sh
	@echo "==> Building macOS extras into $(MACOS_BUILD_DIR)..."
	@BUILD_DIR=$(MACOS_BUILD_DIR) bash $(ROOT)/build-macos-deps.sh
	@touch $@

$(MACOS_DYLIB): $(MACOS_UNSTRIPPED)
	@cp $< $@
	@$(STRIP) -x $@
	@echo ""
	@echo "macOS core built (stripped):"
	@echo "  $@"

SWITCH_DIST_DIR := $(DIST_DIR)/switch
SWITCH_BUILT := $(BUILD_ROOT)/switch/src/goosestation-libretro/goosestation_libretro.a
SWITCH_LIB := $(SWITCH_DIST_DIR)/libgoosestation_libretro.a
DEVKITPRO ?= /opt/devkitpro
export DEVKITPRO
SHADER_HEADERS ?= $(if $(wildcard /opt/shader-headers),/opt/shader-headers,$(DEVKITPRO)/shader-headers)

switch: $(SWITCH_LIB)

$(SWITCH_LIB): prepare
	@test -f $(DEVKITPRO)/cmake/Switch.cmake || { echo "ERROR: $(DEVKITPRO)/cmake/Switch.cmake not found — install devkitPro or run inside the Docker image"; exit 1; }
	@test -d $(SHADER_HEADERS)/shaderc || { echo "ERROR: shader headers not found at $(SHADER_HEADERS) — run setup.sh or check SHADER_HEADERS"; exit 1; }
	@echo "==> Configuring Switch build"
	@$(CMAKE) -S $(SRC_DIR) -B $(BUILD_ROOT)/switch \
		-DCMAKE_TOOLCHAIN_FILE=$(DEVKITPRO)/cmake/Switch.cmake \
		-DCMAKE_BUILD_TYPE=Release \
		-DBUILD_LIBRETRO=ON \
		-DBUILD_REGTEST=OFF \
		-DBUILD_TESTS=OFF \
		-DENABLE_OPENGL=ON \
		-DENABLE_VULKAN=OFF \
		-DBUILD_SHARED_LIBS=OFF \
		-DCMAKE_MODULE_PATH=$(SRC_DIR)/cmake \
		-DCMAKE_CXX_FLAGS="-Wno-invalid-offsetof -flax-vector-conversions" \
		-DSHADERC_INCLUDE_DIR=$(SHADER_HEADERS) \
		-DSPIRV_CROSS_INCLUDE_DIR=$(SHADER_HEADERS)/spirv_cross \
		-Wno-dev
	@echo "==> Building"
	@$(CMAKE) --build $(BUILD_ROOT)/switch --parallel $(JOBS) --target goosestation_libretro
	@mkdir -p $(SWITCH_DIST_DIR)
	@echo "==> Bundling dependency archives into single static lib"
	@{ \
		echo "create $@.tmp"; \
		for a in $$(find $(BUILD_ROOT)/switch -name '*.a' ! -name 'libgoosestation_libretro_combined.a'); do \
			echo "addlib $$a"; \
		done; \
		echo "save"; echo "end"; \
	} | $(DEVKITPRO)/devkitA64/bin/aarch64-none-elf-ar -M
	@mv $@.tmp $@
	@cp $(ROOT)/goosestation_libretro.info $(SWITCH_DIST_DIR)/goosestation_libretro.info
	@cp $(SRC_DIR)/src/goosestation-libretro/overlays/cursor_only.cfg $(SWITCH_DIST_DIR)/cursor_only.cfg
	@echo ""
	@echo "Switch core built (static archive):"
	@echo "  $@"

RETROARCH_DIR    ?= $(CACHE_DIR)/RetroArch
RETROARCH_PATCHES := $(ROOT)/patches/retroarch
SWITCH_RA_NRO    := $(SWITCH_DIST_DIR)/goosestation_libretro_libnx.nro

# Patched libuam. switch-retroarch points Makefile.libnx at it via a
# LIBDIRS prepend below, so the patched libuam/uam.h win over the toolchain copy.
# Each build path provisions it explicitly (host: update-build.sh runs switch-uam
# before switch-retroarch; docker: Dockerfile.switch runs build-switch-uam.sh),
# so it is NOT a prereq of the shared switch-retroarch target.
# Override SWITCH_UAM_PREFIX to relocate (Dockerfile passes a fixed container dir).
SWITCH_UAM_PREFIX ?= $(CACHE_DIR)/switch-uam
SWITCH_UAM_STAMP := $(CACHE_DIR)/switch-uam.stamp
$(SWITCH_UAM_STAMP): $(ROOT)/build-switch-uam.sh $(ROOT)/uam_redef.sh $(ROOT)/uam_prefix.h $(wildcard $(ROOT)/patches/uam/*.patch)
	@PREFIX="$(SWITCH_UAM_PREFIX)" bash $(ROOT)/build-switch-uam.sh
	@mkdir -p $(dir $@)
	@touch $@

switch-uam: $(SWITCH_UAM_STAMP)

switch-retroarch: $(SWITCH_RA_NRO)

$(SWITCH_RA_NRO): $(SWITCH_LIB)
	@test -f $(DEVKITPRO)/cmake/Switch.cmake || { echo "ERROR: $(DEVKITPRO)/cmake/Switch.cmake not found — install devkitPro or run inside the Docker image"; exit 1; }
	@test -d $(RETROARCH_DIR) || { echo "ERROR: $(RETROARCH_DIR) missing — clone RetroArch and apply patches first"; exit 1; }
	@echo "==> Staging core archive as libretro_libnx.a"
	@cp $(SWITCH_LIB) $(RETROARCH_DIR)/libretro_libnx.a
	@# Force ELF relink
	@rm -f $(RETROARCH_DIR)/retroarch_switch.elf $(RETROARCH_DIR)/retroarch_switch.nro \
	       $(RETROARCH_DIR)/cores/dynamic_dummy.o
	@# page_fault_handler.cpp overrides libnx's weak __libnx_exception_entry;
	@# copying it as a loose .o ensures the strong symbol wins at link time
	@# even in interpreter-only builds where the archive member isn't pulled.
	@HANDLER_OBJ=$$(find $(BUILD_ROOT)/switch -name 'page_fault_handler*' -name '*.o' -print -quit); \
	 test -n "$$HANDLER_OBJ" || { echo "ERROR: could not find page_fault_handler object in build tree"; exit 1; }; \
	 cp "$$HANDLER_OBJ" $(RETROARCH_DIR)/goose_excpt.o
	@echo "==> Building RetroArch NRO (Makefile.libnx)"
	@# Prepend our self-contained libuam prefix to LIBDIRS so the patched
	@# libuam.a + uam.h are linked/included ahead of the toolchain's copies,
	@# without modifying the system devkitPro. (PORTLIBS=$$DEVKITPRO/portlibs/switch,
	@# LIBNX=$$DEVKITPRO/libnx — reconstructed here since we replace LIBDIRS.)
	@test -f "$(SWITCH_UAM_PREFIX)/lib/libuam.a" || { echo "ERROR: patched libuam not provisioned at $(SWITCH_UAM_PREFIX) — run 'make switch-uam' (host) or provision in Docker"; exit 1; }
	@$(MAKE) -C $(RETROARCH_DIR) -f Makefile.libnx -j$(JOBS) HAVE_STATIC_DUMMY= \
		LIBDIRS="$(SWITCH_UAM_PREFIX) $(DEVKITPRO)/portlibs/switch $(DEVKITPRO)/libnx"
	@mkdir -p $(SWITCH_DIST_DIR)
	@cp $(RETROARCH_DIR)/retroarch_switch.nro $@
	@cp $(RETROARCH_DIR)/retroarch_switch.elf $(SWITCH_DIST_DIR)/retroarch_switch.elf
	@echo ""
	@echo "Switch RetroArch NRO built (static):"
	@echo "  $@"

clean:
	rm -rf $(BUILD_ROOT) $(DIST_DIR)


distclean: clean
	rm -rf $(SRC_ROOT) $(CACHE_DIR)

# Docker helper targets: each platform has its own self-contained image.
# Only dist/ is mounted for output — no .cache/ needed.
DOCKER_LINUX_IMAGE ?= goosestation-builder-linux
DOCKER_LINUX_DOCKERFILE ?= Dockerfile.linux
DOCKER_LINUX_STATIC_IMAGE ?= goosestation-builder-linux-static
DOCKER_LINUX_STATIC_DOCKERFILE ?= Dockerfile.linux-static
DOCKER_WINDOWS_IMAGE ?= goosestation-builder-windows
DOCKER_WINDOWS_DOCKERFILE ?= Dockerfile.windows
DOCKER_ANDROID_IMAGE ?= goosestation-builder-android
DOCKER_ANDROID_DOCKERFILE ?= Dockerfile.android
DOCKER_SWITCH_IMAGE ?= goosestation-builder-switch
DOCKER_SWITCH_DOCKERFILE ?= Dockerfile.switch
DOCKER_MOUNT_DIST := -v "$(CURDIR)/dist:/work/dist:Z"
DOCKER_RUN_LINUX := docker run --rm $(DOCKER_MOUNT_DIST) $(DOCKER_LINUX_IMAGE)
DOCKER_RUN_LINUX_STATIC := docker run --rm $(DOCKER_MOUNT_DIST) $(DOCKER_LINUX_STATIC_IMAGE)
DOCKER_RUN_WINDOWS := docker run --rm $(DOCKER_MOUNT_DIST) $(DOCKER_WINDOWS_IMAGE)
DOCKER_RUN_ANDROID := docker run --rm $(DOCKER_MOUNT_DIST) $(DOCKER_ANDROID_IMAGE)
DOCKER_RUN_SWITCH := docker run --rm $(DOCKER_MOUNT_DIST) $(DOCKER_SWITCH_IMAGE)

.PHONY: docker-linux-image docker-linux-static-image docker-windows-image docker-android-image docker-switch-image
.PHONY: docker-linux docker-linux-static docker-android docker-windows docker-switch docker-all

docker-linux-image:
	docker build -t $(DOCKER_LINUX_IMAGE) -f $(DOCKER_LINUX_DOCKERFILE) \
		--build-arg UPSTREAM_COMMIT=$(UPSTREAM_COMMIT) .

docker-linux-static-image:
	docker build -t $(DOCKER_LINUX_STATIC_IMAGE) -f $(DOCKER_LINUX_STATIC_DOCKERFILE) \
		--build-arg UPSTREAM_COMMIT=$(UPSTREAM_COMMIT) .

docker-windows-image:
	docker build -t $(DOCKER_WINDOWS_IMAGE) -f $(DOCKER_WINDOWS_DOCKERFILE) \
		--build-arg UPSTREAM_COMMIT=$(UPSTREAM_COMMIT) .

docker-android-image:
	docker build -t $(DOCKER_ANDROID_IMAGE) -f $(DOCKER_ANDROID_DOCKERFILE) \
		--build-arg UPSTREAM_COMMIT=$(UPSTREAM_COMMIT) \
		--build-arg ANDROID_NDK_VERSION=$(ANDROID_NDK_VERSION) .

docker-switch-image:
	docker build -t $(DOCKER_SWITCH_IMAGE) -f $(DOCKER_SWITCH_DOCKERFILE) \
		--build-arg UPSTREAM_COMMIT=$(UPSTREAM_COMMIT) \
		--build-arg RETROARCH_BRANCH=$(RETROARCH_BRANCH) .

docker-linux: docker-linux-image
	@mkdir -p $(DIST_DIR)
	@$(DOCKER_RUN_LINUX)

docker-linux-static: docker-linux-static-image
	@mkdir -p $(DIST_DIR)
	@$(DOCKER_RUN_LINUX_STATIC)

docker-android: docker-android-image
	@mkdir -p $(DIST_DIR)
	@$(DOCKER_RUN_ANDROID)

docker-windows: docker-windows-image
	@mkdir -p $(DIST_DIR)
	@$(DOCKER_RUN_WINDOWS)

docker-switch: docker-switch-image
	@mkdir -p $(DIST_DIR)
	@$(DOCKER_RUN_SWITCH)

docker-all: docker-linux docker-android docker-windows docker-switch
