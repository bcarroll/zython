# Raspberry Pi Zero Bare-Metal MicroPython

Thin wrapper around the upstream Raspberry Pi bare-metal MicroPython port in `vendor/micropython/raspberrypi`, targeting Raspberry Pi Zero and Zero W with `BOARD=RPI1`.

## Prerequisites

- `git`
- `python3`
- `arm-none-eabi-gcc`
- `arm-none-eabi-objcopy`
- `curl`
- `make`

## Quick Start

Run from the repository root:

```sh
make validate
make all
make stage-sdcard
make release
```

What those targets do:

- `make all`: clones `vendor/micropython` if needed, initializes pinned submodules, applies the local patch series, and builds the firmware
- `make stage-sdcard`: writes boot files to `build/sdcard/`
- `make release`: creates `build/rpi_zero_micropython-sdcard.img`
- `make clean`: removes `build/` and deletes `vendor/micropython`

## Output

- Firmware build output: `vendor/micropython/raspberrypi/build/`
- Staged SD card files: `build/sdcard/`
- Raw disk image: `build/rpi_zero_micropython-sdcard.img`

The release image is a raw disk image with an MBR and one FAT16 boot partition, suitable for SD card imaging tools.

## Boot Files

Copy these to the FAT boot partition if you are not using `make release`:

- `build/sdcard/config.txt`
- `build/sdcard/firmware.img`
- `build/sdcard/bootcode.bin`
- `build/sdcard/start.elf`
- any files you want from `vendor/micropython/raspberrypi/fs/`

The runtime is bare-metal after the Raspberry Pi firmware loads `firmware.img`; Linux is not involved.

## Notes

- `vendor/micropython` is a generated checkout and is ignored by `.gitignore`
- the nested `micropython` submodule is checked out to the commit pinned by `boochow/micropython-raspberrypi`, not the latest upstream `HEAD`
- local upstream-facing changes are captured in `patches/upstream-micropython/`
- default wrapper settings are `BOARD=RPI1 PERF=1 MICROPY_HW_USBHOST=0 MICROPY_MOUNT_SD_CARD=1 MICROPY_MOUNT_FIRST_PARTITION_ONLY=1 MICROPY_BOOT_FROZEN_MPY=1`
- Raspberry Pi Zero 2 W is a different board class and should not use these defaults blindly
