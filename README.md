# Raspberry Pi Zero Bare-Metal MicroPython

This repository is a thin wrapper around the upstream bare-metal Raspberry Pi MicroPython port at `vendor/micropython/raspberrypi`. It targets Raspberry Pi Zero and Zero W boards by building that upstream port with `BOARD=RPI1`.

## Layout

- `vendor/micropython/raspberrypi/`: the actual bare-metal MicroPython port and source tree.
- `Makefile`: top-level wrapper that forwards build settings to the upstream port.
- `tests/validate_wrapper.sh`: checks that the wrapper points at a usable upstream port.

The top level intentionally does not maintain its own duplicate startup code, linker script, HAL, or port configuration.

## Prerequisites

- `git`
- `python3`
- `arm-none-eabi-gcc`
- `arm-none-eabi-objcopy`
- `curl`
- `make`

If `vendor/micropython` is missing, the wrapper can bootstrap it from:

```text
https://github.com/boochow/micropython-raspberrypi.git
```

and then initialize the submodules required by the upstream README in both:

```text
vendor/micropython
vendor/micropython/micropython
```

After cloning and submodule setup, the wrapper also applies this repository's local patch series from `patches/upstream-micropython/` so the vendored tree matches the expected GCC compatibility and performance profile.

The submodule initialization step does not fetch the latest upstream MicroPython `HEAD`. It checks out the exact submodule commits pinned by the cloned `boochow/micropython-raspberrypi` repository at that point in time.

## Build

Run from the repository root:

```sh
make bootstrap-upstream
make validate
make all
make stage-sdcard
make release
```

`make all` and `make stage-sdcard` automatically run the bootstrap, submodule, and patch-apply steps first, so a fresh checkout does not need a separate manual clone.

`make clean` removes `build/` and deletes `vendor/micropython`, which clears the vendored upstream checkout and any locally applied patch state. The next `make all` will reclone and reapply the patch series.

Because `vendor/micropython` is a bootstrapped checkout, it is ignored by the top-level `.gitignore`. The source of truth for local upstream changes is the patch series under `patches/upstream-micropython/`, not the cloned vendor tree itself.

The wrapper defaults to Raspberry Pi Zero-compatible settings:

```sh
make BOARD=RPI1 PERF=1 MICROPY_HW_USBHOST=0 MICROPY_MOUNT_SD_CARD=1 MICROPY_MOUNT_FIRST_PARTITION_ONLY=1 MICROPY_BOOT_FROZEN_MPY=1
```

`make all` delegates to:

```text
vendor/micropython/raspberrypi
```

and produces upstream artifacts in:

```text
vendor/micropython/raspberrypi/build/
```

The wrapper staging target copies the boot files into:

```text
build/sdcard/
```

The release target writes a raw disk image to:

```text
build/rpi_zero_micropython-sdcard.img
```

That image contains an MBR and a single FAT16 partition built from the current contents of `build/sdcard/`, so it can be handed directly to SD card imaging tools.

During `make stage-sdcard`, the wrapper also downloads:

- `bootcode.bin`
- `start.elf`

from the Raspberry Pi firmware repository and stores them in `build/sdcard/`.
If those files are already present in `build/sdcard/`, the wrapper reuses them instead of downloading them again.

## Boot files

For SD card staging, copy these onto the FAT boot partition:

- Raspberry Pi firmware files required by the board
- `build/sdcard/config.txt`
- `build/sdcard/firmware.img`
- `build/sdcard/bootcode.bin`
- `build/sdcard/start.elf`
- any files from `vendor/micropython/raspberrypi/fs/` you want available on the mounted SD card

For `make release`, non-8.3 filenames are stored using FAT short-name aliases inside the generated image.

The runtime remains bare-metal after the Raspberry Pi firmware loads `firmware.img`; Linux is not involved.

## Notes

- Raspberry Pi Zero and Zero W use `BOARD=RPI1`.
- Raspberry Pi Zero 2 W is a different board class and should not use these defaults blindly.
- `PERF=1` switches the upstream port from `-Os` to a faster `-O2` build profile.
- `MICROPY_MOUNT_FIRST_PARTITION_ONLY=1` avoids probing all four partition slots during boot.
- `MICROPY_BOOT_FROZEN_MPY=1` freezes `vendor/micropython/raspberrypi/fs/boot.py` and `main.py` as `.mpy` and lets `pyexec_file_if_exists()` use the frozen versions first.
- USB host support is opt-in in the wrapper because it adds startup cost and is not needed for a UART-first Pi Zero bring-up.
