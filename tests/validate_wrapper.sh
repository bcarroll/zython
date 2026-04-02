#!/usr/bin/env sh

set -eu

project_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
port_dir="$project_dir/vendor/micropython/raspberrypi"

required_files='
Makefile
README.md
tools/make_fat16_image.py
tests/test_make_fat16_image.py
vendor/README.md
vendor/micropython/README.md
patches/upstream-micropython/0001-raspberrypi-fix-gcc-13-build-flags.patch
patches/upstream-micropython/0002-raspberrypi-fix-fiq-attribute-and-root-pointers.patch
patches/upstream-micropython/0003-raspberrypi-add-perf-profile-and-frozen-boot.patch
patches/upstream-micropython/0004-mpy-cross-fix-gcc-13-for-frozen-mpy-builds.patch
vendor/micropython/raspberrypi/Makefile
vendor/micropython/raspberrypi/main.c
vendor/micropython/raspberrypi/mpconfigport.h
vendor/micropython/raspberrypi/kernel.ld
'

for file in $required_files; do
    if [ ! -f "$project_dir/$file" ]; then
        printf 'Missing required file: %s\n' "$file" >&2
        exit 1
    fi
done

grep -q 'vendor/micropython/raspberrypi' "$project_dir/README.md"
grep -q 'BOARD ?= RPI1' "$project_dir/Makefile"
grep -q 'PERF ?= 1' "$project_dir/Makefile"
grep -q 'MICROPY_HW_USBHOST ?= 0' "$project_dir/Makefile"
grep -q 'MICROPY_MOUNT_SD_CARD ?= 1' "$project_dir/Makefile"
grep -q 'MICROPY_MOUNT_FIRST_PARTITION_ONLY ?= 1' "$project_dir/Makefile"
grep -q 'MICROPY_BOOT_FROZEN_MPY ?= 1' "$project_dir/Makefile"
grep -q 'UPSTREAM_GIT_URL ?= https://github.com/boochow/micropython-raspberrypi.git' "$project_dir/Makefile"
grep -q 'bootstrap-upstream' "$project_dir/Makefile"
grep -q 'apply-upstream-patches' "$project_dir/Makefile"
grep -q '^release:' "$project_dir/Makefile"
grep -q 'make_fat16_image.py' "$project_dir/Makefile"
grep -q 'git clone "\$(UPSTREAM_GIT_URL)" "\$(UPSTREAM_DIR)"' "$project_dir/Makefile"
grep -q 'git -C "\$(UPSTREAM_DIR)" submodule update --init' "$project_dir/Makefile"
grep -q 'git -C "\$(UPSTREAM_MICROPYTHON_DIR)" submodule update --init' "$project_dir/Makefile"
grep -q 'git -C "\$(UPSTREAM_DIR)" apply' "$project_dir/Makefile"
grep -q 'git -C "\$(UPSTREAM_MICROPYTHON_DIR)" apply' "$project_dir/Makefile"
grep -q 'bootcode.bin' "$project_dir/Makefile"
grep -q 'start.elf' "$project_dir/Makefile"
grep -q 'rpi_zero_micropython-sdcard.img' "$project_dir/README.md"
grep -q 'raspberrypi' "$project_dir/vendor/README.md"
test -d "$port_dir/fs"

printf '%s\n' 'Wrapper validation passed.'
