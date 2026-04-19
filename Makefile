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

CMAKE    ?= cmake
STRIP    ?= strip
ANDROID_STRIP = $(ANDROID_NDK)/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-strip
JOBS     ?= $(shell nproc 2>/dev/null || echo 4)

.PHONY: all linux linux-unstripped android android-unstripped clean distclean prepare help

help:
	@echo "Targets:"
	@echo "  linux               build stripped libretro core for host Linux"
	@echo "  linux-unstripped    same, keep debug symbols (.unstripped.so)"
	@echo "  android             build stripped libretro core for Android (arm64)"
	@echo "  android-unstripped  same, keep debug symbols (.unstripped.so)"
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
	@touch $@

LINUX_BUILT       := $(BUILD_ROOT)/linux/src/goosestation-libretro/goosestation_libretro.so
LINUX_UNSTRIPPED  := $(DIST_DIR)/goosestation_libretro_linux.unstripped.so
LINUX_SO          := $(DIST_DIR)/goosestation_libretro_linux.so

ANDROID_BUILT      := $(BUILD_ROOT)/android/src/goosestation-libretro/goosestation_libretro.so
ANDROID_UNSTRIPPED := $(DIST_DIR)/android/goosestation_libretro.unstripped.so
ANDROID_SO         := $(DIST_DIR)/android/goosestation_libretro.so

linux: $(LINUX_SO)
linux-unstripped: $(LINUX_UNSTRIPPED)

$(LINUX_UNSTRIPPED): prepare
	@echo "==> Configuring Linux build"
	@$(CMAKE) -S $(SRC_DIR) -B $(BUILD_ROOT)/linux \
	    -DCMAKE_BUILD_TYPE=Release \
	    -DBUILD_LIBRETRO=ON \
	    -DBUILD_REGTEST=OFF \
	    -DBUILD_TESTS=OFF \
	    -DENABLE_OPENGL=ON \
	    -DENABLE_VULKAN=ON \
	    -DCMAKE_MODULE_PATH=$(SRC_DIR)/cmake \
	    -DCMAKE_PREFIX_PATH=$(SRC_DIR)/cmake \
	    -DCMAKE_CXX_FLAGS="-Wno-invalid-offsetof" \
	    -Wno-dev
	@echo "==> Building"
	@$(CMAKE) --build $(BUILD_ROOT)/linux --parallel $(JOBS) --target goosestation_libretro
	@mkdir -p $(DIST_DIR)
	@cp $(LINUX_BUILT) $@
	@echo ""
	@echo "Linux core built (unstripped):"
	@echo "  $@"

$(LINUX_SO): $(LINUX_UNSTRIPPED)
	@cp $< $@
	@$(STRIP) --strip-unneeded $@
	@echo ""
	@echo "Linux core built (stripped):"
	@echo "  $@"

android: $(ANDROID_SO)
android-unstripped: $(ANDROID_UNSTRIPPED)

$(ANDROID_UNSTRIPPED): prepare $(SRC_DIR)/build-android/.deps-ready
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
	    -DCMAKE_PREFIX_PATH=$(SRC_DIR)/build-android/deps \
	    -DCMAKE_FIND_ROOT_PATH=$(SRC_DIR)/build-android/deps \
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

$(SRC_DIR)/build-android/.deps-ready: $(SRC_DIR)/.goosified
	@test -d "$(ANDROID_NDK)" || { echo "ERROR: ANDROID_NDK not found at $(ANDROID_NDK). Set ANDROID_NDK=/path/to/ndk"; exit 1; }
	@echo "==> Building Android dependencies..."
	@cd $(SRC_DIR) && NDK=$(ANDROID_NDK) bash ./build-android-deps.sh
	@touch $@

clean:
	rm -rf $(BUILD_ROOT) $(DIST_DIR)

distclean: clean
	rm -rf $(SRC_ROOT) $(CACHE_DIR)
