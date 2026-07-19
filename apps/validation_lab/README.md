# Validation Lab

A Flutter app that exercises every capability of the Pluto e-ink renderer with
**reproducible, scripted scenes**, so camera recordings of the panel can be compared
across renderer builds. It is the vehicle for on-device renderer validation.

Every scene's **content** is deterministic: fixed strings, fixed timer periods,
constant velocities, and pseudo-content that is a pure function of a step
counter, so two recordings of the same build show the same pixels at the same
scene-relative times. Scene **pacing** is wall-clock by design: dwell and rest
phases are timer-driven and fire on elapsed real time, so the loop advances at
its nominal durations regardless of the device frame rate.

Validation Lab follows the same responsive contract as every Pluto app. Its
manifest keeps `display.scale: auto`, and widgets consume the live Flutter
constraints and `MediaQuery` metrics reported by the selected presenter. Scene
measurements are logical design units, not a fixed Move-sized viewport. Layout
or input changes must be exercised at every tested viewport family so controls,
content, and pointer coordinates remain valid across supported tablets.

## Scene loop

Each scene dwells for its nominal duration and is then held frozen for a
**2.5 s rest beacon** before the next scene: the scene's timers and tickers are
cancelled so it freezes in its final static state, the HUD clock stops, and the
banner is untouched — the app paints nothing, letting the renderer's quiescence
settles fire and clear ghost debt between scenes. One full cycle is
**184 s dwell + 10 × 2.5 s rest = 209 s** (≥ 3 min, matching the device
restart-safety discipline). Scenes in loop order (dwell excludes the rest beacon):

| # | Scene id | Dwell | Content | Exercises | Expected e-ink behavior |
|---|----------|-------|---------|-----------|-------------------------|
| 1 | `static-text` | 20 s (+2.5 s rest) | Dense typographic page: 10–40 px, weights 300–900, mono block | Settle quality, text clarity | One high-quality settle after entry, then zero activity; crisp glyph edges, no halo |
| 2 | `counter-tick` | 16 s (+2.5 s rest) | 140 px counter at 2 Hz + 12-spoke stepping spinner | Partial updates | Small damage rectangles around counter/spinner only; rest of page untouched |
| 3 | `scroll-list` | 20 s (+2.5 s rest) | 400-row list auto-scrolling at 240 px/s for 6 s, then 4 s stop (repeats) | Renderer motion (`MOVE`) class + settle after motion; `MOVE` is a refresh classification, not the Paper Pro Move model | Fast low-fidelity updates while moving; a sharpening settle within the 4 s hold; bounded ghosting |
| 4 | `page-turn` | 16 s (+2.5 s rest) | Full-content layout swap every 2 s (text article A ↔ inverted grid B) | Flash policy on near-total damage | Policy decision visible: either clean flash per turn or ghost-free fast path; no partial residue of the previous page |
| 5 | `color-swatches` | 16 s (+2.5 s rest) | Saturated + pastel patches, colored text; 4 blink tiles toggle every 2 s | Chroma settles ("color is a settled state") | Patches appear monochrome-fast, then develop color while idle; blink tiles never smear neighbors |
| 6 | `gradient-ramps` | 16 s (+2.5 s rest) | Smooth gray ramp, 16-step gray bar, R/G/B ramps, vertical hue sweep (static) | Dithering quality, banding | Single settle; judge dither texture and step uniformity on footage; no re-updates after settle |
| 7 | `animation-stress` | 20 s (+2.5 s rest) | Bouncing ball + rotating square + progress bar for 8 s, then 4 s rest (repeats) | Refresh-class behavior under sustained motion, then sharpen | Stable fast cadence with no flashes during motion; one regional sharpen during rest |
| 8 | `ghost-torture` | 20 s (+2.5 s rest) | Checkerboard inverting at 1.25 Hz + inverse text rows for 8 s, then 4 s full white (repeats) | Ghost visibility, debt-driven clears | Ghost level on the white hold is the metric (GhostScore ΔL*); scheduler should spend clears there |
| 9 | `pen-scribble` | 20 s (+2.5 s rest) | Fullscreen freehand canvas (any pointer/stylus), CLEAR button bottom-right; after 3 s with no pointer input a deterministic zigzag + spiral draws itself at ~480 px/s (25 Hz samples), so unattended recordings still exercise ink. Live pointer input pre-empts and permanently stops the script | Pen latency, stroke clarity | Ink follows the pen (or script) with minimal lag; stroke settles/sharpens after pen-up without app involvement |
| 10 | `concurrent-regions` | 20 s (+2.5 s rest) | Left: 4 Hz tick counter + sliding block. Right: deterministic "photo" re-rendered every 5 s | Concurrent independent region updates | The headline: fast region never stalls while the HQ image settles next to it, and vice versa |

The rest beacon applies to `auto` mode only; `manual` and `single` modes never
rest (a scene under manual inspection keeps animating).

## Chrome for footage alignment

- **Scene banner** (bottom-left, ink-on-black): `S<index>/<total> <scene-id>`, a
  monotonic scene counter `N=NNNN` that never resets, cycle count `C=CC`, and an
  8-bit binary strip encoding `N % 256` (MSB first, filled = 1) so footage can be
  indexed by machine without OCR. The banner updates **once at scene start
  only** — it is untouched during the dwell and the rest beacon.
- **Stats HUD** (top-right, toggleable, default on): `F=<frames produced>` and
  `T=<scene seconds>`, sampled at 1 Hz. The 1 Hz sampling doubles as a heartbeat
  frame. The clock is cancelled during the rest beacon, so the HUD freezes on
  its last readout and paints nothing while the renderer settles. **Toggle the
  HUD off (HUD button) when a scene must be fully idle even while live**, e.g.
  when verifying zero panel activity on `static-text` or `gradient-ramps`.

## Modes

| Mode | Behavior |
|------|----------|
| `auto` (default) | Runs the full loop and repeats forever |
| `manual` | Tap right half = next scene, left half = previous. Corner chrome zones are excluded from navigation taps |
| `single` | Pins one scene forever |

Selecting a single scene without a mode implies `single`.

### Via `--dart-define` (baked in when the bundle is built)

Defines are compiled into the release AOT snapshot by the pinned SDK:

```sh
cd apps/validation_lab
DEVICE=root@10.11.99.1  # or this tablet's USB/Wi-Fi SSH endpoint
pluto build package --device "$DEVICE" --release \
  --dart-define=VALIDATION_SCENE=ghost-torture
pluto build package --device "$DEVICE" --release \
  --dart-define=VALIDATION_MODE=manual
pluto build package --device "$DEVICE" --release \
  --dart-define=VALIDATION_MODE=auto \
  --dart-define=VALIDATION_SCENE=color-swatches
pluto build package --device "$DEVICE" --release \
  --dart-define=VALIDATION_HUD=off
```

`pluto run` launches an already installed app; bake defines into the package
and reinstall it before launching.

## Running on device

For a normal single-app update, let the public CLI identify the tablet and use
the same release-AOT workflow on every supported device:

```sh
cd apps/validation_lab
DEVICE=root@10.11.99.1  # or this tablet's USB/Wi-Fi SSH endpoint
pluto devices --device "$DEVICE" --probe
pluto build package --device "$DEVICE" --release \
  --dart-define=VALIDATION_MODE=auto
pluto install --device "$DEVICE" --release --force build/pluto/app.plap
pluto run --device "$DEVICE" --release dev.pluto.validation_lab
```

If the platform runtime itself needs refreshing, use the same provision command;
it probes the device and selects the prepared, target-correct payload
internally. Validation Lab can still be installed separately with the commands
above when it is not part of that target's standard payload.

```sh
pluto provision --device "$DEVICE"
pluto provision --device "$DEVICE" --status
```

Build, install, and provision reject kernels, non-product `app.so` files,
mismatched pins, and wrong-target native binaries before changing device files.
Useful diagnostics use that same device endpoint:

```sh
pluto devices --device "$DEVICE" --probe
pluto logs --device "$DEVICE"
pluto screenshot --device "$DEVICE" -o validation-lab.png
```

## Recording protocol (camera rig)

Use the configured numbered camera rig so each differently sized tablet keeps
its own verified crop and perspective transform:

```sh
RIG_DEVICE=2
tools/setup/camera/capture.sh video \
  --device "$RIG_DEVICE" --seconds 210 \
  --output "/tmp/validation-device-${RIG_DEVICE}.mp4"
```

- Fixed jig, locked exposure and focus; log office lux and panel temperature bin
  (hwmon) before and after each run.
- Let the loop run **at least one full cycle (209 s)** per recording; ≥ 3 runs per
  scene for calibrated metrics.
- Align recordings by the banner: `N` is monotonic across the whole session, so
  any two recordings of the same build can be registered scene-by-scene; the
  binary strip makes this scriptable.
- Record the **same build twice** before comparing two builds — the delta between
  identical runs bounds rig noise.
- Archive footage plus a ledger line (scene, commit, flags, temp bin, lux) under
  `analysis/validation/<date>/`, per the archival-first rule.

## Development

Pinned SDK (do not use the system Flutter):

```sh
SDK="${PLUTO_SDK:-$HOME/.pluto/sdk/3.44.4}"
"$SDK/bin/flutter" pub get
"$SDK/bin/cache/dart-sdk/bin/dart" format --set-exit-if-changed lib test
"$SDK/bin/flutter" analyze
"$SDK/bin/flutter" test
```

Tests are golden-free and fully deterministic (fake-async: `tester.pump`
advances the test clock, so wall-clock timers are exercised without real
waiting): they pump fixed durations and assert scene state (counter values,
page alternation, scroll offsets, stroke counts, auto-scribble behavior),
rest-beacon freezing per scene, plus SceneRunner sequencing (wall-clock
auto-advance, rest beacon, wrap, manual navigation, single-scene pinning, HUD
toggling/freezing) and config parsing.

### Adding a scene

1. Create `lib/src/scenes/<name>_scene.dart` — a self-contained widget. All
   timers/controllers must be owned by the scene and cancelled in `dispose`.
   Content must be a pure function of elapsed scene time or a step counter.
2. If the scene animates, mix `SceneRestFreeze` into its `State` and cancel
   every timer/ticker in `freezeForRest()`, so the runner's rest beacon can
   freeze it (see `lib/src/scene.dart`).
3. Register it in `lib/src/scenes.dart` with a kebab-case id and a dwell time
   (keep the full loop ≥ 3 min).
4. Add a deterministic widget test in `test/scenes_test.dart` (including a
   rest-beacon freeze assertion for animated scenes) and a row to the scene
   table above.
