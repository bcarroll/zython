# Vendor Layout

`vendor/micropython` contains the upstream `boochow/micropython-raspberrypi` source tree.

For this project, the active bare-metal target is:

```text
vendor/micropython/raspberrypi
```

The top-level project wraps that upstream port and does not carry a second local port implementation.

When `vendor/micropython` is absent, the top-level `Makefile` can clone it and initialize the submodules expected by the upstream README.

After initialization, the top-level `Makefile` advances the nested `micropython` checkout to the pinned official upstream revision used by this wrapper, instead of leaving it at BooChow's historical `v1.11` pin.

This directory is treated as a generated vendor checkout and is ignored by the top-level `.gitignore`. Local upstream-facing changes should be captured in `patches/upstream-micropython/`.
