# Upstream Patch Series

These patches capture the local fixes made to the upstream bare-metal Raspberry Pi
MicroPython port in `vendor/micropython/raspberrypi`.

Base tree used when generating them:

```text
vendor/micropython @ 0fb6bf7
vendor/micropython/micropython @ 1f601e89878b2c60a9b193a7a9d7e47a7627c869
```

Patch order:

1. `0001-raspberrypi-refresh-port-for-latest-micropython.patch`

Apply the patch from the `vendor/micropython` repository root:

```sh
git apply ../../patches/upstream-micropython/0001-raspberrypi-refresh-port-for-latest-micropython.patch
```
