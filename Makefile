PROJECT_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
VENDOR_DIR ?= $(PROJECT_DIR)/vendor
UPSTREAM_DIR ?= $(VENDOR_DIR)/micropython
UPSTREAM_MICROPYTHON_DIR ?= $(UPSTREAM_DIR)/micropython
PORT_DIR ?= $(UPSTREAM_DIR)/raspberrypi
BUILD_DIR ?= $(PROJECT_DIR)/build
SDCARD_DIR ?= $(BUILD_DIR)/sdcard
RELEASE_IMAGE ?= $(BUILD_DIR)/zython.img
RELEASE_IMAGE_SIZE_MB ?= 64
RELEASE_VOLUME_LABEL ?= RPI_MICROPY
PATCH_DIR ?= $(PROJECT_DIR)/patches/upstream-micropython
UPSTREAM_GIT_URL ?= https://github.com/boochow/micropython-raspberrypi.git
RPI_FIRMWARE_BOOTCODE_URL ?= https://raw.githubusercontent.com/raspberrypi/firmware/master/boot/bootcode.bin
RPI_FIRMWARE_START_URL ?= https://raw.githubusercontent.com/raspberrypi/firmware/master/boot/start.elf

UPSTREAM_PATCHES := \
	0001-raspberrypi-fix-gcc-13-build-flags.patch \
	0002-raspberrypi-fix-fiq-attribute-and-root-pointers.patch \
	0003-raspberrypi-add-perf-profile-and-frozen-boot.patch

NESTED_UPSTREAM_PATCHES := \
	0004-mpy-cross-fix-gcc-13-for-frozen-mpy-builds.patch

BOARD ?= RPI1
PERF ?= 1
MICROPY_HW_USBHOST ?= 0
MICROPY_MOUNT_SD_CARD ?= 1
MICROPY_MOUNT_FIRST_PARTITION_ONLY ?= 1
MICROPY_BOOT_FROZEN_MPY ?= 1

.PHONY: help validate all clean distclean release stage-sdcard bootstrap-upstream bootstrap-submodules apply-upstream-patches upstream-ready upstream-build upstream-clean

help:
	@printf '%s\n' \
		'Raspberry Pi Zero bare-metal MicroPython wrapper' \
		'' \
		'This top-level project wraps the upstream bare-metal Raspberry Pi port in' \
		'vendor/micropython/raspberrypi and does not maintain a second port.' \
		'' \
		'Targets:' \
		'  make bootstrap-upstream Clone vendor/micropython and initialize the upstream submodules.' \
		'  make apply-upstream-patches Apply this repo'"'"'s local upstream patch series if needed.' \
		'  make validate        Verify that the upstream port is present and the wrapper is consistent.' \
		'  make all             Build the upstream Raspberry Pi port for Raspberry Pi Zero defaults.' \
		'  make stage-sdcard    Copy build/config.txt and build/firmware.img, then download bootcode.bin and start.elf into build/sdcard/.' \
		'  make release         Create a raw disk image containing the staged sdcard boot files.' \
		'  make clean           Remove wrapper staging, upstream build output, and vendor/micropython.' \
		'  make distclean       Alias for clean.' \
		'' \
		'Defaults:' \
		'  BOARD=RPI1' \
		'  PERF=1' \
		'  MICROPY_HW_USBHOST=0' \
		'  MICROPY_MOUNT_SD_CARD=1' \
		'  MICROPY_MOUNT_FIRST_PARTITION_ONLY=1' \
		'  MICROPY_BOOT_FROZEN_MPY=1' \
		'' \
		'Override example:' \
		'  make BOARD=RPI1 PERF=1 MICROPY_HW_USBHOST=0 MICROPY_MOUNT_SD_CARD=1 MICROPY_BOOT_FROZEN_MPY=1'

validate:
	@./tests/validate_wrapper.sh

all: upstream-build

bootstrap-upstream:
	@mkdir -p "$(VENDOR_DIR)"
	@if [ -d "$(UPSTREAM_DIR)/.git" ]; then \
		printf '%s\n' "Using existing upstream tree at $(UPSTREAM_DIR)"; \
	elif [ -e "$(UPSTREAM_DIR)" ]; then \
		printf '%s\n' "Refusing to clone into existing non-git path $(UPSTREAM_DIR)" >&2; \
		exit 1; \
	else \
		git clone "$(UPSTREAM_GIT_URL)" "$(UPSTREAM_DIR)"; \
	fi

bootstrap-submodules: bootstrap-upstream
	@if [ -d "$(UPSTREAM_MICROPYTHON_DIR)/.git" ] || [ -f "$(UPSTREAM_MICROPYTHON_DIR)/py/mkenv.mk" ]; then \
		printf '%s\n' "Outer submodule already initialized: $(UPSTREAM_MICROPYTHON_DIR)"; \
	else \
		git -C "$(UPSTREAM_DIR)" submodule update --init micropython; \
	fi
	@if [ -d "$(PORT_DIR)/csud/.git" ] || [ -f "$(PORT_DIR)/csud/README.md" ]; then \
		printf '%s\n' "Outer submodule already initialized: $(PORT_DIR)/csud"; \
	else \
		git -C "$(UPSTREAM_DIR)" submodule update --init raspberrypi/csud; \
	fi
	@if [ -f "$(UPSTREAM_MICROPYTHON_DIR)/lib/axtls/README.md" ] && [ -f "$(UPSTREAM_MICROPYTHON_DIR)/lib/stm32lib/README.md" ]; then \
		printf '%s\n' "Nested MicroPython submodules already initialized."; \
	else \
		git -C "$(UPSTREAM_MICROPYTHON_DIR)" submodule update --init; \
	fi

apply-upstream-patches: bootstrap-submodules
	@set -eu; \
	if grep -Fq 'QSTR_GEN_EXTRA_CFLAGS += -mgeneral-regs-only' "$(UPSTREAM_DIR)/raspberrypi/Makefile" && \
		grep -Fq '$(BUILD)/py/stackctrl.o: CFLAGS += -Wno-error=dangling-pointer' "$(UPSTREAM_DIR)/raspberrypi/Makefile" && \
		! grep -Fq '#include "arm_exceptions.h"' "$(UPSTREAM_DIR)/raspberrypi/mpconfigport.h" && \
		grep -Fq 'bic r0, r0, #0x80' "$(UPSTREAM_DIR)/raspberrypi/mpconfigport.h" && \
		grep -Fq 'orr r0, r0, #0x80' "$(UPSTREAM_DIR)/raspberrypi/mpconfigport.h"; then \
		printf '%s\n' 'Patch already applied: 0001-raspberrypi-fix-gcc-13-build-flags.patch'; \
	else \
		printf '%s\n' 'Applying patch: 0001-raspberrypi-fix-gcc-13-build-flags.patch'; \
		git -C "$(UPSTREAM_DIR)" apply "$(PATCH_DIR)/0001-raspberrypi-fix-gcc-13-build-flags.patch"; \
	fi; \
	if grep -Fq 'interrupt("FIQ")' "$(UPSTREAM_DIR)/raspberrypi/arm_ex_handler_weak.c" && \
		grep -Fxq '    hcd_globals_t *hcd_globals;' "$(UPSTREAM_DIR)/raspberrypi/mpconfigport.h"; then \
		printf '%s\n' 'Patch already applied: 0002-raspberrypi-fix-fiq-attribute-and-root-pointers.patch'; \
	else \
		printf '%s\n' 'Applying patch: 0002-raspberrypi-fix-fiq-attribute-and-root-pointers.patch'; \
		git -C "$(UPSTREAM_DIR)" apply "$(PATCH_DIR)/0002-raspberrypi-fix-fiq-attribute-and-root-pointers.patch"; \
	fi; \
	if grep -Fq 'FROZEN_MPY_DIR ?= fs' "$(UPSTREAM_DIR)/raspberrypi/Makefile" && \
		grep -Fq 'CFLAGS += -DMICROPY_BOOT_FROZEN_MPY=' "$(UPSTREAM_DIR)/raspberrypi/Makefile" && \
		grep -Fq 'pyexec_file_if_exists' "$(UPSTREAM_DIR)/raspberrypi/main.c" && \
		grep -Fq 'MICROPY_BOOT_FROZEN_MPY (0)' "$(UPSTREAM_DIR)/raspberrypi/mpconfigport.h" && \
		grep -Fq 'MICROPY_BOOT_FROZEN_MPY ?=0' "$(UPSTREAM_DIR)/raspberrypi/mpconfigport.mk" && \
		grep -Fq 'Q(boot.py)' "$(UPSTREAM_DIR)/raspberrypi/qstrdefsport.h"; then \
		printf '%s\n' 'Patch already applied: 0003-raspberrypi-add-perf-profile-and-frozen-boot.patch'; \
	else \
		printf '%s\n' 'Applying patch: 0003-raspberrypi-add-perf-profile-and-frozen-boot.patch'; \
		git -C "$(UPSTREAM_DIR)" apply "$(PATCH_DIR)/0003-raspberrypi-add-perf-profile-and-frozen-boot.patch"; \
	fi; \
	if grep -Fq -- '-Wno-error=dangling-pointer' "$(UPSTREAM_MICROPYTHON_DIR)/mpy-cross/Makefile" && \
		grep -Fq 'mp_import_stat_t mp_import_stat' "$(UPSTREAM_MICROPYTHON_DIR)/mpy-cross/main.c"; then \
		printf '%s\n' 'Patch already applied: 0004-mpy-cross-fix-gcc-13-for-frozen-mpy-builds.patch'; \
	else \
		printf '%s\n' 'Applying patch: 0004-mpy-cross-fix-gcc-13-for-frozen-mpy-builds.patch'; \
		git -C "$(UPSTREAM_MICROPYTHON_DIR)" apply "$(PATCH_DIR)/0004-mpy-cross-fix-gcc-13-for-frozen-mpy-builds.patch"; \
	fi

upstream-ready: apply-upstream-patches
	@test -f "$(PORT_DIR)/Makefile"

upstream-build: upstream-ready
	@mkdir -p "$(PORT_DIR)/build/genhdr"
	@$(MAKE) -C "$(PORT_DIR)" \
		BOARD="$(BOARD)" \
		PERF="$(PERF)" \
		MICROPY_HW_USBHOST="$(MICROPY_HW_USBHOST)" \
		MICROPY_MOUNT_SD_CARD="$(MICROPY_MOUNT_SD_CARD)" \
		MICROPY_MOUNT_FIRST_PARTITION_ONLY="$(MICROPY_MOUNT_FIRST_PARTITION_ONLY)" \
		MICROPY_BOOT_FROZEN_MPY="$(MICROPY_BOOT_FROZEN_MPY)"

stage-sdcard: upstream-build
	@mkdir -p "$(SDCARD_DIR)"
	@cp "$(PORT_DIR)/build/config.txt" "$(SDCARD_DIR)/config.txt"
	@cp "$(PORT_DIR)/build/firmware.img" "$(SDCARD_DIR)/firmware.img"
	@if [ -f "$(SDCARD_DIR)/bootcode.bin" ]; then \
		printf '%s\n' "Using existing $(SDCARD_DIR)/bootcode.bin"; \
	else \
		curl -fL "$(RPI_FIRMWARE_BOOTCODE_URL)" -o "$(SDCARD_DIR)/bootcode.bin"; \
	fi
	@if [ -f "$(SDCARD_DIR)/start.elf" ]; then \
		printf '%s\n' "Using existing $(SDCARD_DIR)/start.elf"; \
	else \
		curl -fL "$(RPI_FIRMWARE_START_URL)" -o "$(SDCARD_DIR)/start.elf"; \
	fi
	@printf '%s\n' "Staged boot files in $(SDCARD_DIR)"

release: stage-sdcard
	@python3 "$(PROJECT_DIR)/tools/make_fat16_image.py" \
		--source "$(SDCARD_DIR)" \
		--output "$(RELEASE_IMAGE)" \
		--size-mb "$(RELEASE_IMAGE_SIZE_MB)" \
		--volume-label "$(RELEASE_VOLUME_LABEL)"
	@printf '%s\n' "Created release image $(RELEASE_IMAGE)"

upstream-clean:
	@if [ -d "$(PORT_DIR)" ]; then \
		$(MAKE) -C "$(PORT_DIR)" clean; \
	fi

clean: upstream-clean
	@rm -rf "$(BUILD_DIR)"
	@rm -rf "$(UPSTREAM_DIR)"

distclean: clean
