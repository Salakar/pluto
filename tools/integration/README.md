# Cooperative ARMv7 integration provenance

Pluto uses XOVI, Qt Resource Rebuilder (QRR), and AppLoad internally when the
connected tablet requires the cooperative `linux-arm` backend. Users still use
the same `pluto build`, `pluto install`, `pluto run`, and `pluto provision`
commands; device discovery selects the backend and target.

This directory is the complete corresponding-source and rebuild record for
those third-party integration binaries. It exists so no release depends on an
unrecorded download or a floating `latest` tag.

## Locked inputs

[`sources.lock`](sources.lock) records all source commits, patch hashes,
immutable toolchain-image digests, device authorization tuples, and the
SHA-256s of the binaries used in device acceptance. The build recipe
authenticates the whole lockfile before reading it.

| Component | Exact source | Pluto modification |
| --- | --- | --- |
| XOVI | `asivery/xovi` at `0c8d5269b55c851901d4e4a754dc2d7deab40b17` (`v0.3.3`) | None |
| QRR and setup scripts | `asivery/rm-xovi-extensions` at `7874154dba6793cc68a15fae0fb9dd272c4ed20a` (`v19-23052026`) | None |
| qmldiff | `asivery/qmldiff` at `25681c3cc7addb93fdbb41ceac1f1bdce8b2625d` | None |
| AppLoad for firmware 3.27 | `asivery/rm-appload` at `5bb34a362f09f753f18bd6261558f8e2737aacdb` (`v0.5.3`) | `patches/appload-3.27-pluto.patch` |
| AppLoad for firmware 3.28 | `asivery/rm-appload` at `40506d47427123f07030bb2e83453a43d035b16a` | `patches/appload-3.28-performance.patch`, then `patches/appload-3.28-pluto.patch` |

The Pluto patches add the authenticated local control protocol and the
dirty-region fixes needed for responsive ink. They are ordinary reviewable Git
patches, not generated binary deltas.

All listed upstream projects and Pluto's derivative patches are distributed
under `GPL-3.0-only`. The complete license text is in
[`LICENSE.GPL-3.0`](LICENSE.GPL-3.0). Source trees materialized by the recipe
also retain every upstream license file.

## Verify and rebuild

The lightweight integrity check performs no network access:

```sh
bash tools/integration/build-armv7-integration.sh --verify-inputs
```

A clean rebuild fetches only the locked commits, verifies every patch before
applying it, and authenticates reMarkable's official 4.4.128 SDK installer
before running it in a digest-pinned Linux builder. That older supported
sysroot is deliberate: it keeps every shipped ELF within the shared GLIBC 2.35
ceiling. Rust is pinned to 1.82.0; Cargo verifies registry sources through the
upstream `Cargo.lock`.

```sh
bash tools/integration/build-armv7-integration.sh
```

Prepared corresponding source is written to
`.pluto-cache/integration/prepared`; rebuilt files go to
`.pluto-cache/integration/output`. Source preparation can be audited without
running a compiler:

```sh
bash tools/integration/build-armv7-integration.sh --prepare-only
```

For an air-gapped rebuild, pre-populate Git repositories containing the locked
objects and the cached, checksum-verified `rustup-init`, Cargo registry, and
builder image, then pass `--offline` plus the four `--*-repo` paths. The
command fails rather than falling back to another commit or toolchain.

The recorded local binaries can be checked independently:

```sh
bash tools/integration/build-armv7-integration.sh --verify-reference
```

This check requires both the locked SHA-256 and the conservative ARMv7 ABI
ceiling. A hash match is not sufficient: the currently recorded
`19a9d2...`/`4eab5f...` QTFB shim pair imports GLIBC 2.38, so reference
verification and default payload assembly intentionally reject it.

The locked old-SDK recipe deterministically produces the pending replacement
pair below, both within GLIBC 2.34, GLIBCXX 3.4.22, and CXXABI 1.3.9:

- `qtfb-shim-32bit.so`:
  `ef3621b8ec0e6d183b27f7f63aeedbaa9dcd6ed8412a424a009f73e54f26b479`
- `qtfb-shim.so`:
  `fb79605599ed41c3f6ffb65787cbc7ee630d16ef920add67f95192f3afdec1e9`

These are candidate hashes, not accepted defaults. Assemble them only with
`--candidate-integration --appload-shims <old-sdk-output>/shims`; the assembler
reports their exact hashes and retains every ELF/ABI gate. Update
`sources.lock` and promote them only after live acceptance on both ARMv7
devices.

`--require-reference-hashes` requires a rebuild to be bit-identical to the
device-accepted files. `--promote` implies that gate and is the only recipe mode
that updates the payload assembler's default inputs. A normal rebuild never
overwrites validated artifacts.

To assemble from an unpromoted output, pass it explicitly:

```sh
bash tools/build/assemble-appload-arm-payload.sh \
  --candidate-integration \
  --xovi-root "$PWD/.pluto-cache/integration/output/xovi" \
  --appload-extension-3.27 \
    "$PWD/.pluto-cache/integration/output/appload-3.27/appload.so" \
  --appload-extension-3.28 \
    "$PWD/.pluto-cache/integration/output/appload-3.28/appload.so" \
  --appload-shims "$PWD/.pluto-cache/integration/output/shims"
```

## Firmware-bound QRR hashtabs

QRR hashtabs are data derived from the exact stock UI binary, not portable
upstream artifacts. Pluto authorizes them only as part of the complete model,
semantic firmware, build ID, and stock-UI SHA-256 tuple in `sources.lock`.
Provisioning selects the matching profile and refuses an unknown tuple. A new
firmware therefore requires a newly captured hashtab, a reviewed profile, and
fresh device acceptance; it must never reuse the nearest version.

The accepted QRR is SHA-256
`3850e3ceca1a22dd19d0ded854719c45cf553415f909e3cf5aa0e17efab2dbac`
and imports at most GLIBC 2.34. That exact file was observed mapped into the
running stock UI process on both tested ARMv7 devices. The upstream v19 release
binary `d96530...` imports the weak Rust-stdlib symbols `pidfd_spawnp` and
`pidfd_getpid` at GLIBC 2.39; it is intentionally neither accepted nor used as
the payload reference, even though the currently tested firmware happens to
provide GLIBC 2.39. The historical accepted build used Rust 1.82.0; its
intermediate `libqmldiff.a` identity is retained in `sources.lock` as provenance
only. A fresh deterministic old-SDK output remains unpromoted until it passes
the same live acceptance on both devices.

Run the contract test after changing this directory:

```sh
bash tools/integration/test/build-armv7-integration-test.sh
```
