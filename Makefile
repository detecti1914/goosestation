# GooseStation libretro core builder.
#

UPSTREAM_COMMIT := 5e7be496a2d0480aaabbe9746a1a4576b469d301

UPSTREAM_URL := https://github.com/stenzek/duckstation/archive/$(UPSTREAM_COMMIT).tar.gz

ROOT := $(abspath .)
GOOSIFY := $(ROOT)/goosify.sh
CACHE_DIR := $(ROOT)/.cache
TARBALL := $(CACHE_DIR)/duckstation-$(UPSTREAM_COMMIT).tar.gz
SRC_ROOT := $(ROOT)/src
SRC_DIR := $(SRC_ROOT)/duckstation-$(UPSTREAM_COMMIT)
BUILD_ROOT := $(ROOT)/build
DIST_DIR := $(ROOT)/dist

ANDROID_NDK ?= $(or \
		$(ANDROID_NDK_ROOT), \
		$(ANDROID_NDK_HOME), \
		$(shell ls -d $${ANDROID_HOME:-$${ANDROID_SDK_ROOT:-$$HOME/Android/Sdk}}/ndk/* 2>/dev/null | sort -V | tail -1), \
		$(shell ls -d /opt/android-sdk/ndk/* 2>/dev/null | sort -V | tail -1))
ANDROID_ABI ?= arm64-v8a
ANDROID_PLATFORM ?= android-28

# Cache linux extras (libjpeg-turbo cmake config, plutovg/plutosvg, cpuinfo —
# things Debian doesn't package) under .cache/ alongside other targets.
LINUX_BUILD_DIR := $(CACHE_DIR)/linux
LINUX_DEPS_DIR := $(LINUX_BUILD_DIR)/deps

MINGW_PREFIX ?= x86_64-w64-mingw32
# Cache mingw deps under .cache/ so they survive `make clean` and `--rm` containers.
MINGW_BUILD_DIR := $(CACHE_DIR)/mingw
MINGW_DEPS_DIR := $(MINGW_BUILD_DIR)/deps

CMAKE ?= cmake
STRIP ?= strip
ANDROID_STRIP = $(ANDROID_NDK)/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
MINGW_STRIP = llvm-strip
JOBS ?= $(shell nproc 2>/dev/null || echo 4)

.PHONY: all linux linux-unstripped android android-unstripped windows windows-unstripped clean distclean prepare help

help:
	@echo "Targets:"
	@echo "  linux               build stripped libretro core for host Linux"
	@echo "  linux-unstripped    same, keep debug symbols (.unstripped.so)"
	@echo "  android             build stripped libretro core for Android (arm64)"
	@echo "  android-unstripped  same, keep debug symbols (.unstripped.so)"
	@echo "  windows             build stripped libretro core for Windows x64 (mingw cross via LLVM)"
	@echo "  windows-unstripped  same, keep debug symbols (.unstripped.dll)"
	@echo "  all                 stripped linux + android"
	@echo "  clean               remove build and dist dirs (keep fetched source)"
	@echo "  distclean           remove everything, including fetched source"
	@echo ""
	@echo "Pinned:"
	@echo "  DuckStation upstream: $(UPSTREAM_COMMIT)"

all: linux android

prepare: $(SRC_DIR)/.goosified

$(TARBALL):
	@mkdir -p $(CACHE_DIR)
	@echo "==> Fetching upstream $(UPSTREAM_COMMIT)..."
	@curl -fsSL $(UPSTREAM_URL) -o $@.tmp && mv $@.tmp $@

$(SRC_DIR)/.goosified: $(GOOSIFY) $(TARBALL)
	@rm -rf $(SRC_DIR)
	@mkdir -p $(SRC_ROOT)
	@echo "==> Extracting upstream from cached tarball..."
	@tar -xzf $(TARBALL) -C $(SRC_ROOT)
	@echo "==> Goosifying..."
	@cp $(GOOSIFY) $(SRC_DIR)/goosify.sh
	@cd $(SRC_DIR) && bash ./goosify.sh
	@touch $@

LINUX_BUILT := $(BUILD_ROOT)/linux/src/goosestation-libretro/goosestation_libretro.so
LINUX_UNSTRIPPED := $(DIST_DIR)/goosestation_libretro_linux.unstripped.so
LINUX_SO := $(DIST_DIR)/goosestation_libretro_linux.so

# Cache android deps under .cache/ so they survive `make clean` and `--rm` containers.
ANDROID_BUILD_DIR := $(CACHE_DIR)/android
ANDROID_DEPS_DIR := $(ANDROID_BUILD_DIR)/deps

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
	@mkdir -p $(DIST_DIR)
	@cp $(LINUX_BUILT) $@
	@echo ""
	@echo "Linux core built (unstripped):"
	@echo "  $@"

$(LINUX_DEPS_DIR)/.deps-ready: $(ROOT)/build-linux-deps.sh
	@echo "==> Building Linux extras (libjpeg-turbo, plutovg, plutosvg, cpuinfo) into $(LINUX_BUILD_DIR)..."
	@BUILD_DIR=$(LINUX_BUILD_DIR) bash $(ROOT)/build-linux-deps.sh
	@touch $@

$(LINUX_SO): $(LINUX_UNSTRIPPED)
	@cp $< $@
	@$(STRIP) --strip-unneeded $@
	@echo ""
	@echo "Linux core built (stripped):"
	@echo "  $@"

android: $(ANDROID_SO)
android-unstripped: $(ANDROID_UNSTRIPPED)

$(ANDROID_UNSTRIPPED): prepare $(ANDROID_DEPS_DIR)/.deps-ready
	@test -d "$(ANDROID_NDK)" || { echo "ERROR: ANDROID_NDK not found at $(ANDROID_NDK). Set ANDROID_NDK=/path/to/ndk"; exit 1; }
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
	@echo ""
	@echo "Android core built (unstripped):"
	@echo "  $@"

$(ANDROID_SO): $(ANDROID_UNSTRIPPED)
	@cp $< $@
	@$(ANDROID_STRIP) --strip-unneeded $@
	@echo ""
	@echo "Android core built (stripped):"
	@echo "  $@"

$(ANDROID_DEPS_DIR)/.deps-ready: $(ROOT)/build-android-deps.sh
	@test -d "$(ANDROID_NDK)" || { echo "ERROR: ANDROID_NDK not found at $(ANDROID_NDK). Set ANDROID_NDK=/path/to/ndk"; exit 1; }
	@echo "==> Building Android dependencies (cached at $(ANDROID_BUILD_DIR))..."
	@NDK=$(ANDROID_NDK) ANDROID_ABI=$(ANDROID_ABI) BUILD_DIR=$(ANDROID_BUILD_DIR) bash $(ROOT)/build-android-deps.sh
	@touch $@

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
	@echo ""
	@echo "Windows core built (unstripped):"
	@echo "  $@"

$(WINDOWS_DLL): $(WINDOWS_UNSTRIPPED)
	@cp $< $@
	@$(MINGW_STRIP) --strip-unneeded $@
	@echo ""
	@echo "Windows core built (stripped):"
	@echo "  $@"

$(MINGW_DEPS_DIR)/.deps-ready: $(ROOT)/build-mingw-deps.sh
	@command -v clang >/dev/null || { echo "ERROR: clang not in PATH"; exit 1; }
	@echo "==> Building Windows (mingw) dependencies with LLVM (cached at $(MINGW_BUILD_DIR))..."
	@CC="clang --target=$(MINGW_PREFIX) -femulated-tls" \
		CXX="clang++ --target=$(MINGW_PREFIX) -femulated-tls" \
		AR="llvm-ar" RANLIB="llvm-ranlib" RC="llvm-rc" WINDRES="llvm-windres" \
		BUILD_DIR=$(MINGW_BUILD_DIR) bash $(ROOT)/build-mingw-deps.sh
	@touch $@

clean:
	rm -rf $(BUILD_ROOT) $(DIST_DIR)

distclean: clean
	rm -rf $(SRC_ROOT) $(CACHE_DIR)
