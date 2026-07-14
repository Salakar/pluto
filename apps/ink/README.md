# Ink

Ink (`paper_ink`, app id `dev.pluto.ink`) is Pluto's flagship drawing
application on supported reMarkable tablets: a real canvas you pan, zoom, and
rotate with touch, a movable collapsible bench toolbar, 16 brushes, 10
interaction tools, layers, and color where the physical panel supports it.
The same app and release package also run on monochrome panels; device identity
and display capabilities select the palette and presentation internally.

This README is the implementor's quick reference for the app.

## Status

Feature-complete through the primary drawing, tool, layer, and export surface
and deployed to device. Remaining work is integration QA, golden completion,
CI wiring, device-QA rounds, and polish, plus optional embedder-liaison items.

| Area | State |
|---|---|
| Canvas engine (tiles, pan/zoom/rotate, PalmGuard) | done |
| 16 brushes + erasers + brush panel | done |
| 10 tools (selection/wand, transform, fill, shapes, text, eyedropper, guides, reference, crop) | done |
| Layers + color + canvas ops | done |
| Bench (side/top collapsible dock), status chrome, gallery, settings | done |
| Import/export (PNG 1×/2×, `.inkpack`), thumbnails | done |
| Golden inventory, CI, device-QA polish | WP9 (in progress) |

## What the display constrains (read before touching rendering)

Ink targets GPU-less e-ink displays; the engine and UI are shaped by them.
The 954×1696 measurements are reference design units, not a required
viewport. Widgets derive their live bounds and scale from Flutter constraints
so wider and taller panels use their available space without clipping. The
renderer uses Skia software raster, auto-classified refresh, and a color-native
document model that presents in grayscale on monochrome film. Two rules that
bite: the
`EinkRefreshRegion` hint API is dead plumbing (only
`pluto/refresh.requestFullRefresh` works), and a commit must render before the
pen-up settle or the glass can revert to the retained ledger.

## Layout

```
lib/
  main.dart            # entrypoint + INK_PROBE / INK_TUNE mode switch
  src/
    ui/                # app shell, editor page, bench + dock, panels, gallery, settings, glyphs
    model/             # app/gallery/settings/tool view-models
    engine/            # brush engine, stroke pipeline, compositor, tile cache, raster worker
    tools/             # the 10 interaction tools + engine adapter
    document/          # document model, tile store, .tile + manifest IO, undo journal, export
    input/             # pen router, PalmGuard, gesture arbitration
    probe/             # on-device instrumentation page (INK_PROBE)
    services.dart      # AppPaths, DocumentStore wiring, presenterDrivesColor
test/                  # 54 unit + widget test files
test_goldens/          # 24 golden scenes + /30 lattice review twins (goldens/, goldens/lattice/)
```

## Entrypoint modes

`main.dart` runs one of three roots by `--dart-define`:

- default → `InkApp` (gallery + editor).
- `--dart-define=INK_PROBE=1` → `InkProbeApp`, the device instrumentation page
  (pointer rate, raster cost, touch/barrel caps).
- `--dart-define=INK_TUNE=1` → `InkProofSheetApp`, the brush proof sheet.

## Toolchain

Use the project-pinned SDK — the global `flutter` on `PATH` is the wrong version
and fails the workspace `^3.12.0` pin:

```sh
export PATH="$HOME/.pluto/sdk/3.44.4/bin:$HOME/.pluto/sdk/3.44.4/bin/cache/dart-sdk/bin:$PATH"
```

## Build & deploy

```sh
cd apps/ink
DEVICE=root@10.11.99.1  # or this tablet's USB/Wi-Fi SSH endpoint
~/.pluto/bin/pluto build package --device "$DEVICE" --release
~/.pluto/bin/pluto install --device "$DEVICE" --release --force build/pluto/app.plap
~/.pluto/bin/pluto run --device "$DEVICE" --release dev.pluto.ink
```

Do not copy bundles, edit lifecycle manifests, or restart the display service
by hand. The common CLI probes the device, selects the matching target and
integration, validates the package, and performs the transactional install.

## Test & gates

```sh
cd apps/ink
dart analyze --fatal-infos .
dart format --set-exit-if-changed .
flutter test                                        # unit + widget (test/)
flutter test test_goldens/ink_goldens_test.dart     # goldens (NOT run by the default command)
flutter test --update-goldens test_goldens/ink_goldens_test.dart   # regenerate goldens
```

Notes for contributors:

- Run only **one** `flutter test` at a time — concurrent runs race on the
  flutter_tools temp dir and produce spurious `PathNotFoundException` failures.
- A widget that does real `ui.Image` decode / `getNextFrame` / PNG encode hangs
  under flutter_test's fake-async; inject a synchronous seam or wrap in
  `tester.runAsync()`. The `CanvasView`/`EditorPage` widget tests that spawn the
  real `RasterWorker` isolate are `skip`ped for this reason and covered by unit
  tests + device QA.
- Dispose any `tester.ensureSemantics()` handle **in-body** (`semantics.dispose()`
  before the test ends) — `addTearDown` runs after the end-of-test semantics
  check and fails the test.
- Build golden scenes widget-based and bounded (see `g06`/`g14`); the
  full-bleed `LayoutBuilder` + `StackFit.expand` overlay pattern renders blank
  in the harness.
