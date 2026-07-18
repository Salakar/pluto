# Device compatibility

Pluto exposes one device workflow across supported reMarkable tablets.
`pluto devices --probe` verifies hardware identity, and every device-facing
command uses that identity to select the correct release target, display path,
and lifecycle integration internally.

The table below is the compatibility contract. Recognition by the CLI is not
the same as tested support, and success on one firmware must not be generalized
to another firmware without validation.

## Tested hardware and firmware

| Device | Codename | Tested reMarkable OS | CPU / target | Native panel path | Validation status |
| --- | --- | --- | --- | --- | --- |
| reMarkable Paper Pro Move | `chiappa` | 3.28.0.162 | AArch64 / `linux-arm64` | Native Gallery3/DRM + SWTCON | ✅ Reference device; release platform, Ink, and Codex validated |
| reMarkable 2 | `zero-sugar` | 3.28.0.162 | ARMv7l / `linux-arm` | Native LCDIF/TCON | 🧪 Final release deployment, app switching, Ink stroke, screenshots, and camera acceptance required |
| reMarkable 1 | `zero-gravitas` | 3.27.3.0 | ARMv7l / `linux-arm` | Native MXCFB/EPDC | 🧪 Final release deployment, app switching, Ink stroke, screenshots, and camera acceptance required |
| reMarkable Paper Pro | `ferrari` | Not tested | Not assigned | Not assigned | 🚧 Not yet verified |
| reMarkable Paper Pure | `tatsu` | Not tested | Not assigned | Not assigned | 🚧 Not yet verified |

The two newly brought-up devices are not marked complete merely because the
embedder starts. Their final acceptance requires the normal CLI workflow,
visible Home and supported-app behavior, app switching, a deterministic Ink
stroke, launch and return behavior, logs, screenshots, and measured
responsiveness on the physical panel.

## One responsive application surface

Home, Ink, and target-compatible Pluto applications are not device-specific
ports. Every backend reports its actual surface dimensions and device pixel
ratio to Flutter. App manifests keep `display.scale: auto` (also the default
when omitted), and widgets lay out from live `MediaQuery` and parent
constraints just as they do on other Flutter platforms.

Numeric manifest scales are rejected. The `scale` field may only be omitted or
set to `auto`. Likewise, 954 x 1696 values in design systems, golden tests,
document presets, or Move renderer research are reference coordinates with an
explicit scope; they do not define the runtime viewport on another tablet.
Compatibility acceptance therefore checks full-surface use, reflow, reachable
controls, pen/touch coordinate mapping, and screenshots at the native metrics
of each tested device.

The generated exact-device profiles define these presenter metrics. Move, RM1,
and RM2 have reported their rows from a running native embedder. RM2's run was
an intermediate bring-up, not final compatibility acceptance:

| Device | Native panel surface | Flutter device pixel ratio |
| --- | ---: | ---: |
| reMarkable Paper Pro Move | 954 x 1696 | 1.65 |
| reMarkable 2 | 1404 x 1872 | 1.4125 |
| reMarkable 1 | 1404 x 1872 | 1.4125 |

Those are inputs to Flutter's normal logical-pixel model, not three separately
authored app canvases. The same release Home, shared application, and Ink
layouts reflow from the resulting constraints. An intermediate release
rendered Home and Ink on the physical RM2 before a later switch failed closed
on retained PMIC fault telemetry. The corrected frozen release must repeat the
complete optical and lifecycle gate.

## One public workflow

For a prepared release checkout, users do not choose an integration:

```bash
DEVICE=root@10.11.99.1  # or this tablet's USB/Wi-Fi SSH endpoint

pluto devices --device "$DEVICE" --probe
pluto provision --device "$DEVICE"
pluto install --device "$DEVICE" --release --force build/pluto/app.plap
pluto run --device "$DEVICE" --release <app-id>
pluto logs --device "$DEVICE"
pluto screenshot --device "$DEVICE" -o shot.png
pluto uninstall --device "$DEVICE" <app-id>
```

Probe output includes the verified native target and supported build modes, but
keeps backend names as an implementation detail.

The same recovery commands apply everywhere:

```bash
pluto provision --device "$DEVICE" --status
pluto provision --device "$DEVICE" --restore-remarkable
pluto provision --device "$DEVICE" --uninstall
```

Provisioning probes before writing, integrity-checks the universal release
manifest, selects its matching slice, verifies every deployable file and pinned
engine checksum, and activates it transactionally. Checkout pins and committed
engine checksum metadata remain the local trust anchors. Supplying
`--payload-dir` names another complete release-set root and never overrides
hardware identity; missing, contradictory, hybrid, or tampered content is
rejected before device files change. A profile whose persistent boot-default
recovery gate is closed uses the same supervisor in a transient current-boot
session; stock remains the next-boot default without creating a second app,
setup, or document workflow.

## Native hardware boundary

The common CLI and on-device supervisor are shared by every supported tablet.
After exact profile matching, the embedder selects only the hardware-specific
panel implementation: Gallery3/DRM on Move, LCDIF/TCON on reMarkable 2, or
MXCFB/EPDC on reMarkable 1. Applications use the same Flutter engine pin,
manifest, package integrity contract, responsive UI rules, lifecycle markers,
and device commands. There is no stock-UI child launcher or alternate install
flow.

The `linux-arm` runtime is currently release AOT only. The `linux-arm64`
runtime additionally supports profile AOT and explicitly requested debug/JIT.
An unavailable development mode is rejected as a capability mismatch; normal
release install, launch, inspection, and removal remain the same workflow.

Application availability is also declared, not inferred from a model name.
Home, Counter, Motion Lab, Ink Lab, Validation Lab, and Ink support both
targets. Paper Codex declares `linux-arm64` only because upstream Codex has no
native ARMv7 release. Pluto does not build or ship a custom ARMv7 Codex port;
the ARM standard release omits it and an explicit ARM build request fails
before compilation. This is one target-capability branch inside the same
manifest, build, release, provision, launcher, and documentation flow.

## Release artifact targeting

Every application layout and `.plap` records exactly one target. The normal
build command probes the same device and selects that target automatically:

```bash
pluto build package --device "$DEVICE" --release
```

Release automation may use `--target-platform linux-arm64` or
`--target-platform linux-arm` as an advanced offline override. If `--device`
is also present, a contradictory override is rejected. Install/provision
validate the recorded target; the CLI never relabels, translates, or attempts
to run an architecture-mismatched package.

## ARMv7 ABI ceiling

Both exact firmware tuples used for acceptance currently expose the following
system-library symbol versions:

| Tested device and firmware | Available GLIBC | Available GLIBCXX | Available CXXABI |
| --- | ---: | ---: | ---: |
| reMarkable 1 on 3.27.3.0, build `20260612085811` | 2.39 | 3.4.32 | 1.3.14 |
| reMarkable 2 on 3.28.0.162, build `20260629074044` | 2.39 | 3.4.32 | 1.3.14 |

Those observations do not define Pluto's compatibility baseline. Every shared
`linux-arm` release binary is intentionally held to the more conservative
upper limits GLIBC **2.35**, GLIBCXX **3.4.29**, and CXXABI **1.3.13**. It must
also be ELF32 `EM_ARM`, EABI5, hard-float. This leaves compatibility margin for
supported ARMv7 installations instead of allowing a build host or one newer
firmware image to raise the runtime requirement silently.

## Firmware-sensitive native profile

Display registers, waveform data, framebuffer geometry, input nodes, and boot
recovery topology vary by exact hardware and firmware. Pluto code-generates
one profile table and fails closed when immutable identity, semantic firmware,
build id, architecture, or required artifacts do not match an accepted tuple.

A firmware update must repeat at least:

1. immutable device and firmware probing;
2. target and ABI validation of every native binary;
3. native panel initialization, waveform/LUT, input, and control checks;
4. transactional boot activation with stock fallback available;
5. Home, switching, the target-supported app set, and deterministic Ink runs
   through the public CLI; additionally test native Codex on `linux-arm64`;
6. logs, screenshots, camera evidence, and responsiveness measurements;
7. restore and full-uninstall recovery checks.

Only after those checks pass should the tested matrix gain the new firmware.

## Safety and recovery internals

Pluto never intentionally leaves a tablet without a working UI. The native
runtime uses one transactional boot installer, owned fallback service, bounded
recovery receipts, and a verified stock peer root. Provisioning failure rolls
back to stock; full uninstall restores stock before deleting the runtime.

When developing a native panel implementation:

- keep the tablet unlocked and tethered during activation;
- never bypass target, checksum, firmware-table, or peer-credential gates;
- reset a failed `xochitl.service` before a controlled restart, keep at least
  three minutes between restart experiments, and batch changes;
- verify both logs and the physical panel;
- use the public restore/uninstall commands for the final recovery test.

The [reMarkable developer links](https://developer.remarkable.com/links)
publish the official SDK/toolchain used to keep native binaries compatible
with the tested firmware.
