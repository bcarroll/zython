# Upstream Patch Series

These patches capture the local fixes made to the upstream bare-metal Raspberry Pi
MicroPython port in `vendor/micropython/raspberrypi`.

Base tree used when generating them:

```text
vendor/micropython @ 0fb6bf7
```

Patch order:

1. `0001-raspberrypi-fix-gcc-13-build-flags.patch`
2. `0002-raspberrypi-fix-fiq-attribute-and-root-pointers.patch`
3. `0003-raspberrypi-add-perf-profile-and-frozen-boot.patch`
4. `0004-mpy-cross-fix-gcc-13-for-frozen-mpy-builds.patch`

Apply patches `0001` through `0003` from the `vendor/micropython` repository root:

```sh
git apply ../../patches/upstream-micropython/0001-raspberrypi-fix-gcc-13-build-flags.patch
git apply ../../patches/upstream-micropython/0002-raspberrypi-fix-fiq-attribute-and-root-pointers.patch
git apply ../../patches/upstream-micropython/0003-raspberrypi-add-perf-profile-and-frozen-boot.patch
```

Apply patch `0004` from the nested `vendor/micropython/micropython` repository root:

```sh
git apply ../../../patches/upstream-micropython/0004-mpy-cross-fix-gcc-13-for-frozen-mpy-builds.patch
```
