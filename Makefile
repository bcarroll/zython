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
UPSTREAM_MICROPYTHON_REF ?= 1f601e89878b2c60a9b193a7a9d7e47a7627c869
RPI_FIRMWARE_BOOTCODE_URL ?= https://raw.githubusercontent.com/raspberrypi/firmware/master/boot/bootcode.bin
RPI_FIRMWARE_FIXUP_URL ?= https://raw.githubusercontent.com/raspberrypi/firmware/master/boot/fixup.dat
RPI_FIRMWARE_START_URL ?= https://raw.githubusercontent.com/raspberrypi/firmware/master/boot/start.elf

UPSTREAM_PATCHES := \
	0001-raspberrypi-refresh-port-for-latest-micropython.patch

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
		'                         Then retarget the nested micropython checkout to $(UPSTREAM_MICROPYTHON_REF).' \
		'  make apply-upstream-patches Apply this repo'"'"'s local upstream patch series if needed.' \
		'  make validate        Verify that the upstream port is present and the wrapper is consistent.' \
		'  make all             Build the upstream Raspberry Pi port for Raspberry Pi Zero defaults.' \
		'  make stage-sdcard    Copy build/config.txt and build/firmware.img, enable UART, append conservative HDMI settings, then download bootcode.bin, fixup.dat, and start.elf into build/sdcard/.' \
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
	@if [ "$$(git -C "$(UPSTREAM_MICROPYTHON_DIR)" rev-parse HEAD)" = "$(UPSTREAM_MICROPYTHON_REF)" ]; then \
		printf '%s\n' "Nested MicroPython checkout already at $(UPSTREAM_MICROPYTHON_REF)"; \
	else \
		git -C "$(UPSTREAM_MICROPYTHON_DIR)" fetch origin master; \
		git -C "$(UPSTREAM_MICROPYTHON_DIR)" checkout --detach "$(UPSTREAM_MICROPYTHON_REF)"; \
	fi
	@if [ -f "$(UPSTREAM_MICROPYTHON_DIR)/lib/axtls/README.md" ] && [ -f "$(UPSTREAM_MICROPYTHON_DIR)/lib/stm32lib/README.md" ]; then \
		printf '%s\n' "Nested MicroPython submodules already initialized."; \
	else \
		git -C "$(UPSTREAM_MICROPYTHON_DIR)" submodule update --init; \
	fi

apply-upstream-patches: bootstrap-submodules
	@set -eu; \
	if grep -Fq 'FROZEN_MANIFEST ?= manifest.py' "$(UPSTREAM_DIR)/raspberrypi/Makefile" && \
		grep -Fq 'MICROPY_PY_TIME             (1)' "$(UPSTREAM_DIR)/raspberrypi/mpconfigport.h" && \
		grep -Fq 'MP_DEFINE_CONST_OBJ_TYPE(' "$(UPSTREAM_DIR)/raspberrypi/machine_pin.c" && \
		grep -Fq 'mp_os_dupterm_obj' "$(UPSTREAM_DIR)/raspberrypi/moduos.c" && \
		[ -f "$(UPSTREAM_DIR)/raspberrypi/manifest.py" ]; then \
		printf '%s\n' 'Patch already applied: 0001-raspberrypi-refresh-port-for-latest-micropython.patch'; \
	else \
		printf '%s\n' 'Applying patch: 0001-raspberrypi-refresh-port-for-latest-micropython.patch'; \
		git -C "$(UPSTREAM_DIR)" apply "$(PATCH_DIR)/0001-raspberrypi-refresh-port-for-latest-micropython.patch"; \
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
	@for line in 'enable_uart=1' 'hdmi_force_hotplug=1' 'hdmi_group=2' 'hdmi_mode=4' 'disable_overscan=1'; do \
		if grep -qx "$$line" "$(SDCARD_DIR)/config.txt"; then \
			printf '%s\n' "Using existing $$line in $(SDCARD_DIR)/config.txt"; \
		else \
			printf '\n%s\n' "$$line" >> "$(SDCARD_DIR)/config.txt"; \
		fi; \
	done
	@if [ -f "$(SDCARD_DIR)/bootcode.bin" ]; then \
		printf '%s\n' "Using existing $(SDCARD_DIR)/bootcode.bin"; \
	else \
		curl -fL "$(RPI_FIRMWARE_BOOTCODE_URL)" -o "$(SDCARD_DIR)/bootcode.bin"; \
	fi
	@if [ -f "$(SDCARD_DIR)/fixup.dat" ]; then \
		printf '%s\n' "Using existing $(SDCARD_DIR)/fixup.dat"; \
	else \
		curl -fL "$(RPI_FIRMWARE_FIXUP_URL)" -o "$(SDCARD_DIR)/fixup.dat"; \
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
