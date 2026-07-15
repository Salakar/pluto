# Framebuffer observer

This directory contains a diagnostics-only ARMv7 `LD_PRELOAD` observer for
recovering the exact framebuffer protocol used by stock `xochitl` on
reMarkable 1 and reMarkable 2. It is an oracle for native Pluto work, not a
runtime dependency and not a second display owner.

Nothing here is referenced by either product payload assembler. Builds go to
the ignored `.pluto-cache/diagnostics/framebuffer-observer/` tree. The observer
is deliberately not installed, provisioned, or started by any Pluto command.

## What it records

The shared object interposes `open`, `open64`, `close`, `mmap`, `mmap64`,
`munmap`, and `ioctl`. It records only `/dev/fb0` activity and only when all of
these gates pass:

- the process executable basename is exactly `xochitl`;
- `PLUTO_FB_OBSERVER_ENABLE=1`;
- `PLUTO_FB_OBSERVER_PROFILE` is exactly `remarkable1` or `remarkable2`.

Observed ioctls include the 72-byte MXCFB update and 8-byte completion marker
used on RM1, plus the ARM 160-byte variable-screen and 68-byte fixed-screen
structures, pan, blank, and vsync operations. Pointer arguments are copied with
`process_vm_readv` so a bad pointer is marked unavailable rather than
dereferenced by the observer.

For every recognized ioctl, the observer:

1. captures a pre-call snapshot when readable;
2. calls the real ioctl exactly once with the original fd, request, and
   argument;
3. captures the post-call snapshot;
4. restores the real return value and exact post-call `errno`.

The ioctl path performs no allocation, locking, text formatting, or file I/O.
Records are published into a fixed, preallocated, shared mmap. Once its bounded
capacity is exhausted, later records are counted as dropped and never block.

Framebuffer phase hashes have a reserved schema record kind, but this minimal
observer does not yet copy or hash panel memory. That should be added only after
measuring observer perturbation on each real device.

## Build and test

Host tests need only a C11 compiler and Python 3:

```bash
bash tools/device/diagnostics/framebuffer-observer/build.sh --test
```

The ARM build reuses Pluto's existing linux/amd64 builder image and official
reMarkable SDK volume, then runs the repository's ARM EABI5, hard-float, and
GLIBC 2.35 ELF gate:

```bash
bash tools/device/diagnostics/framebuffer-observer/build.sh --arm
```

Use `--sdk-dir PATH`, `--sdk-volume NAME`, `--image NAME`, or
`--skip-image-build` with the same meanings as the normal ARM embedder build.
The output is:

```text
.pluto-cache/diagnostics/framebuffer-observer/arm/libpluto-fb-observer.so
```

## Trace contract and decoder

`include/pluto_fb_observer_schema.h` is the fixed little-endian binary contract.
It contains compile-time size and offset assertions for every captured ARM
structure. A trace starts with a 64-byte header followed by bounded 416-byte
record slots. A slot is valid only when its nonzero `commit_sequence` matches
its `sequence`; this lets a decoder reject an in-progress/torn record.

Decode a copied trace to JSON with:

```bash
python3 tools/device/diagnostics/framebuffer-observer/tools/decode.py \
  trace.bin --pretty
```

Runtime configuration for a future explicitly managed diagnostic session:

| Variable | Meaning |
| --- | --- |
| `PLUTO_FB_OBSERVER_ENABLE=1` | Required activation gate |
| `PLUTO_FB_OBSERVER_PROFILE=remarkable1\|remarkable2` | Required ABI selector |
| `PLUTO_FB_OBSERVER_OUTPUT=/path/trace.bin` | Output; defaults to `/run/pluto-fb-observer.bin` |
| `PLUTO_FB_OBSERVER_CAPACITY=N` | Record slots; default 32768, maximum 131072 |

This directory intentionally provides no device/service wrapper. Any later
on-device capture must use the repository's normal safety rules and must first
prove that preload injection and trace storage are reversible on that firmware.
