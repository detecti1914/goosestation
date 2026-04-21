# GooseStation libretro core builder.
#

UPSTREAM_COMMIT := 5e7be496a2d0480aaabbe9746a1a4576b469d301

UPSTREAM_URL := https://github.com/stenzek/duckstation/archive/$(UPSTREAM_COMMIT).tar.gz

ROOT       := $(abspath .)
GOOSIFY    := $(ROOT)/goosify.sh
CACHE_DIR  := $(ROOT)/.cache
TARBALL    := $(CACHE_DIR)/duckstation-$(UPSTREAM_COMMIT).tar.gz
SRC_ROOT   := $(ROOT)/src
SRC_DIR    := $(SRC_ROOT)/duckstation-$(UPSTREAM_COMMIT)
BUILD_ROOT := $(ROOT)/build
DIST_DIR   := $(ROOT)/dist

ANDROID_NDK ?= $(or \
    $(ANDROID_NDK_ROOT), \
    $(ANDROID_NDK_HOME), \
    $(shell ls -d $${ANDROID_HOME:-$${ANDROID_SDK_ROOT:-$$HOME/Android/Sdk}}/ndk/* 2>/dev/null | sort -V | tail -1), \
    $(shell ls -d /opt/android-sdk/ndk/* 2>/dev/null | sort -V | tail -1))
ANDROID_ABI      ?= arm64-v8a
ANDROID_PLATFORM ?= android-28

# Cache linux extras (libjpeg-turbo cmake config, plutovg/plutosvg, cpuinfo —
# things Debian doesn't package) under .cache/ alongside other targets.
LINUX_BUILD_DIR := $(CACHE_DIR)/linux
LINUX_DEPS_DIR  := $(LINUX_BUILD_DIR)/deps

MINGW_PREFIX  ?= x86_64-w64-mingw32
MINGW_TC      := $(ROOT)/cmake/mingw-w64-x86_64.cmake
# Cache mingw deps under .cache/ so they survive `make clean` and `--rm` containers.
MINGW_BUILD_DIR := $(CACHE_DIR)/mingw
MINGW_DEPS_DIR  := $(MINGW_BUILD_DIR)/deps

CMAKE    ?= cmake
STRIP    ?= strip
ANDROID_STRIP = $(ANDROID_NDK)/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
MINGW_STRIP   = $(MINGW_PREFIX)-strip
JOBS     ?= $(shell nproc 2>/dev/null || echo 4)

.PHONY: all linux linux-unstripped android android-unstripped windows windows-unstripped clean distclean prepare help

help:
	@echo "Targets:"
	@echo "  linux               build stripped libretro core for host Linux"
	@echo "  linux-unstripped    same, keep debug symbols (.unstripped.so)"
	@echo "  android             build stripped libretro core for Android (arm64)"
	@echo "  android-unstripped  same, keep debug symbols (.unstripped.so)"
	@echo "  windows             build stripped libretro core for Windows x64 (mingw cross)"
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
	@# Let env NDK override the hardcoded path inside build-android-deps.sh.
	@sed -i 's|^NDK=/opt/android-sdk/ndk/.*|NDK="$${NDK:-&}"|' $(SRC_DIR)/build-android-deps.sh
	@# Allow BUILD_DIR override (so we can redirect into .cache/) and skip the
	@# per-package `rm -rf $$builddir` so cached object files survive reruns.
	@sed -i 's|^BUILD_DIR="$$SCRIPT_DIR/build-android"|BUILD_DIR="$${BUILD_DIR:-$$SCRIPT_DIR/build-android}"|' $(SRC_DIR)/build-android-deps.sh
	@sed -i '/^  rm -rf "\$$builddir"$$/d' $(SRC_DIR)/build-android-deps.sh
	@touch $@

LINUX_BUILT       := $(BUILD_ROOT)/linux/src/goosestation-libretro/goosestation_libretro.so
LINUX_UNSTRIPPED  := $(DIST_DIR)/goosestation_libretro_linux.unstripped.so
LINUX_SO          := $(DIST_DIR)/goosestation_libretro_linux.so

# Cache android deps under .cache/ (build-android-deps.sh hardcodes its prefix
# as $SCRIPT_DIR/build-android by default; we override via BUILD_DIR env after
# patching the script in `prepare`).
ANDROID_BUILD_DIR := $(CACHE_DIR)/android
ANDROID_DEPS_DIR  := $(ANDROID_BUILD_DIR)/deps

ANDROID_BUILT      := $(BUILD_ROOT)/android/src/goosestation-libretro/goosestation_libretro.so
ANDROID_UNSTRIPPED := $(DIST_DIR)/android/goosestation_libretro.unstripped.so
ANDROID_SO         := $(DIST_DIR)/android/goosestation_libretro.so

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

$(ANDROID_DEPS_DIR)/.deps-ready: $(SRC_DIR)/.goosified
	@test -d "$(ANDROID_NDK)" || { echo "ERROR: ANDROID_NDK not found at $(ANDROID_NDK). Set ANDROID_NDK=/path/to/ndk"; exit 1; }
	@echo "==> Building Android dependencies (cached at $(ANDROID_BUILD_DIR))..."
	@cd $(SRC_DIR) && NDK=$(ANDROID_NDK) BUILD_DIR=$(ANDROID_BUILD_DIR) bash ./build-android-deps.sh
	@# plutovg's CMake build doesn't ship a .pc file; plutosvg.pc requires it.
	@# (Same workaround as build-mingw-deps.sh.) On Arch host this is satisfied
	@# by the system plutovg pkg; in the docker image there's nothing.
	@mkdir -p $(ANDROID_DEPS_DIR)/lib/pkgconfig
	@printf 'prefix=%s\nexec_prefix=$${prefix}\nlibdir=$${prefix}/lib\nincludedir=$${prefix}/include\n\nName: PlutoVG\nDescription: stub\nVersion: 1.0.0\nCflags: -I$${includedir}/plutovg -DPLUTOVG_BUILD_STATIC\nLibs: -L$${libdir} -lplutovg\nLibs.private: -lm\n' \
	    "$(ANDROID_DEPS_DIR)" > $(ANDROID_DEPS_DIR)/lib/pkgconfig/plutovg.pc
	@touch $@

WINDOWS_BUILT      := $(BUILD_ROOT)/windows/bin/goosestation_libretro.dll
WINDOWS_UNSTRIPPED := $(DIST_DIR)/windows/goosestation_libretro.unstripped.dll
WINDOWS_DLL        := $(DIST_DIR)/windows/goosestation_libretro.dll

windows: $(WINDOWS_DLL)
windows-unstripped: $(WINDOWS_UNSTRIPPED)

$(WINDOWS_UNSTRIPPED): prepare $(MINGW_DEPS_DIR)/.deps-ready
	@command -v $(MINGW_PREFIX)-gcc >/dev/null || { echo "ERROR: $(MINGW_PREFIX)-gcc not in PATH"; exit 1; }
	@echo "==> Configuring Windows build"
	@PKG_CONFIG_LIBDIR="$(MINGW_DEPS_DIR)/lib/pkgconfig" \
	 PKG_CONFIG_PATH= \
	 $(CMAKE) -S $(SRC_DIR) -B $(BUILD_ROOT)/windows \
	    -DCMAKE_TOOLCHAIN_FILE=$(MINGW_TC) \
	    -DCMAKE_BUILD_TYPE=Release \
	    -DBUILD_LIBRETRO=ON \
	    -DBUILD_REGTEST=OFF \
	    -DBUILD_TESTS=OFF \
	    -DENABLE_OPENGL=ON \
	    -DENABLE_VULKAN=ON \
	    -DCMAKE_PREFIX_PATH="$(MINGW_DEPS_DIR);$(SRC_DIR)/cmake" \
	    -DCMAKE_FIND_ROOT_PATH="$(MINGW_DEPS_DIR);/usr/$(MINGW_PREFIX)" \
	    -DCMAKE_MODULE_PATH=$(SRC_DIR)/cmake \
	    -DCMAKE_CXX_FLAGS="-Wno-invalid-offsetof" \
	    -Wno-dev
	@echo "==> Building"
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
	@command -v $(MINGW_PREFIX)-gcc >/dev/null || { echo "ERROR: $(MINGW_PREFIX)-gcc not in PATH"; exit 1; }
	@echo "==> Building Windows (mingw) dependencies (cached at $(MINGW_BUILD_DIR))..."
	@BUILD_DIR=$(MINGW_BUILD_DIR) bash $(ROOT)/build-mingw-deps.sh
	@touch $@

clean:
	rm -rf $(BUILD_ROOT) $(DIST_DIR)

distclean: clean
	rm -rf $(SRC_ROOT) $(CACHE_DIR)
