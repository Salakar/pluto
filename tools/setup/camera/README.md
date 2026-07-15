# Pluto device camera tool

`capture.sh` gives agents a stable shell interface for photographing or
recording the physical screens in a multi-device rig. Configuration is a
one-time operation after the camera or devices are added, removed, or moved.
Normal captures are local, fast FFmpeg commands and do not invoke a model.

## Physical setup

Place a red label next to every device. Each label must contain a large red
exclamation mark and a unique integer, for example `!1`, `!2`, and `!7`. Keep
the entire active screen and its label visible. The camera and devices must not
move after configuration. Devices may have different physical sizes and aspect
ratios; every numbered screen is calibrated independently.

Requirements:

- macOS with an AVFoundation camera, or Linux with a v4l2 camera;
- `ffmpeg` and `ffprobe` (with `crop`, `perspective`, `scale`, `drawbox`,
  `drawtext`, and H.264);
- a logged-in `codex` CLI for `configure`; and
- Python 3.10 or newer.

Camera access belongs to the terminal/agent process that launches the command.
On macOS, grant that application access under System Settings > Privacy &
Security > Camera.

An agent sandbox may block both host camera access and the network used by the
nested Codex vision calls. If camera enumeration or Codex DNS/connectivity is
denied, the calling agent must rerun the same command with approved host access.
`configure` needs camera plus network access; later captures need camera access
but no network.

Some managed agent hosts prohibit exporting live camera frames even after the
user approves it. That policy cannot be bypassed by this tool. In that case the
user must run `capture.sh configure` directly in a trusted terminal, then the
agent can use and inspect the local `.pluto-devices.json` without any further
network access.

## Quick start

From the repository root:

`configure` sends temporary camera frames (which can include the room around
the devices) to the OpenAI Codex service. The later capture commands stay
local.

```sh
# One time, and again whenever the rig moves.
tools/setup/camera/capture.sh configure

# Full rig view: red device regions and bright-green final capture footprints.
tools/setup/camera/capture.sh identify --output /tmp/pluto-devices.jpg

# One screen, automatically rectified into an upright portrait crop.
tools/setup/camera/capture.sh image \
  --device 2 --output /tmp/device-2.jpg

# A cropped ten-second clip with a millisecond elapsed-time footer.
tools/setup/camera/capture.sh video \
  --device 2 --seconds 10 --output /tmp/device-2.mp4
```

For the release hardware smoke, use the stage hook to capture every foreground
app, the real switcher selection, and the completed Ink stroke automatically:

```sh
export PLUTO_CAMERA_RIG=2
export PLUTO_CAMERA_ACCEPTANCE_DIR="$PWD/analysis/native-cutover/final-acceptance/rm1/camera"
export PLUTO_ACCEPTANCE_SCREENSHOT_DIR="$PWD/analysis/native-cutover/final-acceptance/rm1/screenshots"
export PLUTO_ACCEPTANCE_STAGE_HOOK="$PWD/tools/setup/camera/capture-acceptance-stage.sh"
export PLUTO_ACCEPTANCE_STAGE_DELAY=1
export PLUTO_ACCEPTANCE_CODEX_REQUEST=1
export PLUTO_ACCEPTANCE_SSH_TARGET=root@127.0.0.1
export PLUTO_ACCEPTANCE_SSH_PORT=22202

tools/device/test/release-aot-hardware-smoke.sh root@127.0.0.1:22202
```

Use the correct SSH target and configured rig number for each tablet. The hook
writes numbered JPEGs plus `stages.tsv`, which binds every label and filename to
the image SHA-256. When `PLUTO_ACCEPTANCE_SCREENSHOT_DIR` is set, the smoke also
writes a native PNG and digest record for every identical stage. Camera glass
remains authoritative; the paired PNG proves which settled framebuffer Pluto
reported. A capture failure fails the smoke run instead of silently leaving an
evidence gap.

Every successful command prints the absolute output/config path as the final
stdout line. Parent directories for capture outputs are created automatically.
Use `/tmp` or the git-ignored `analysis/` tree for captures.

## What configure does

`configure` performs four fast, structured vision stages:

1. It enumerates physical cameras and takes one settled still from each,
   sequentially to avoid camera-lock contention.
2. It asks Codex to select the view containing physical devices with adjacent
   red numbered exclamation labels, then asks for each outer planar device face
   and its four perspective-reference corners in the desired upright order.
3. It renders a slightly expanded, roughly rectified calibration crop for each
   device. Codex supplies approximate inner active-pixel corners, then a local
   RGB fitter searches near those priors for each continuous physical
   display/bezel transition. Top, bottom, left, and right are fit independently,
   so keystone and partial-degree rotation come from the current physical edges,
   not a manual offset or the orientation of UI content. Per-device geometry and
   coverage checks never assume two devices share a size or aspect ratio.
4. It adds a small proportional outward safety guard, renders the final portrait,
   and asks Codex to verify that it is complete and upright with only a narrow
   strip of inner bezel. Verification also receives the full-rig red/green footprint
   preview, so it checks the exact source quadrilateral that capture will use
   against the physical edges. A rejected refinement is rendered again before
   it can be accepted; at most two correction rounds are allowed. A tilt-only
   model objection is resolved by three or more strong continuous physical-edge
   fits, including on a blank screen where UI-line evidence does not exist.
   A crop with fewer than three independently confirmed physical edges is corrected
   or rejected even if the model considers it plausible. Once a rendered transform
   with all four physical edges confirmed passes, that exact geometry remains
   accepted while another device is corrected instead of being re-litigated by a
   later non-deterministic verdict.

The normal path makes four Codex calls. Each rejected crop adds one refinement
call and one bounded re-verification. An accepted preview is saved exactly as
rendered; coordinate re-estimation in an accepted response cannot create an
unverified crop.

Candidate frames, the selected rig frame, and crop previews are sent to the
OpenAI Codex service. They may include the camera's surroundings. The command
prints a notice immediately before each upload. `identify`, `image`, `video`,
and the legacy capture form never call Codex.

The normal path uses `gpt-5.6-luna` with low reasoning for quick camera and
full-rig detection, then `gpt-5.4` with low reasoning for the close-up geometry
and final verification where pixel accuracy matters more. If either is not
available, the tool falls back to `gpt-5.4-mini` and then to the account
default. An explicit override applies to both stages:

```sh
tools/setup/camera/capture.sh configure --model MODEL_NAME
PLUTO_CAMERA_MODEL=MODEL_NAME tools/setup/camera/capture.sh configure
```

The model runs through `codex exec` in ephemeral, read-only, no-approval mode
from a temporary directory. Shell/unified-exec tools are disabled, and every
call gets a disposable Codex state directory whose temporary auth copy is
removed immediately afterward. This keeps image content in the role of
untrusted visual data instead of giving it a path to read local files.

Only a fully verified result atomically replaces the config. A failed
configuration preserves the previous config and keeps its diagnostic directory
under the system temporary directory. Use `--artifacts DIR` to keep generated
frames and structured results at a chosen location, or `--keep-artifacts` to
keep the default temporary directory after success.

## Local config

The default config is the repository-root `.pluto-devices.json`; it is ignored
by Git. Schema 6 records:

- the selected backend, camera index/path and diagnostic name;
- capture resolution, frame rate, pixel format, and settle delay;
- the number of configured devices;
- each red label number;
- normalized and pixel screen/label boxes;
- ordered normalized/pixel screen corners, an expanded intermediate transform,
  the model's active-display prior, the locally fitted physical boundaries,
  per-edge evidence, per-device coverage and outward guard, diagnostic
  content-line evidence, portrait output dimensions, and
  independent base/fine/total signed fractional rotation corrections for every
  device; and
- the Codex detection/geometry models and crop-verification result.

The total `rotation_degrees_clockwise` value is not limited to quarter turns.
For example, `1.264` means the captured screen needed a 1.264-degree clockwise
correction; a negative value means counterclockwise. Capture composes the stored
rig transform with a second per-screen active-display transform, removing all
but a deliberately narrow bezel guard, arbitrary tilt, and camera perspective. Every
`image` and `video` result is therefore complete, upright, and
portrait-oriented. `identify` remains an unmodified full-rig view so its
overlays still line up with physical labels.

Use another config without changing the repository-local default:

```sh
tools/setup/camera/capture.sh configure --config /tmp/rig-a.json
tools/setup/camera/capture.sh image \
  --config /tmp/rig-a.json --device 2 --output /tmp/device-2.jpg
```

`PLUTO_CAMERA_CONFIG` provides the same override. The explicit `--config` flag
wins.

## Finding a numbered device

Run `identify` when an agent knows what is currently rendered on a screen but
does not yet know its rig number:

```sh
# First render a unique state/token on the target through Pluto, then:
tools/setup/camera/capture.sh identify --output /tmp/which-device.jpg
```

The returned full-camera image preserves current screen contents, draws each
stored device region in red, and places a large `DEVICE N` marker at the
physical label. Inside each red region, a solid bright-lime perspective
quadrilateral with a dark inner keyline shows the exact guarded source pixels
that `image` and `video` rectify into the final portrait result. It includes the
saved arbitrary-angle rotation, perspective correction, active-display
boundary, and narrow bezel safety guard; it is not merely an approximate
axis-aligned box. Stroke widths are compensated independently for each device
and edge direction, so narrow or differently sized screens do not produce
dotted sub-pixel sides.

`identify` is deliberately a raw camera view. The green quadrilateral follows
the physical screen and will normally look tilted when the device is tilted;
that alone is not residual output rotation. Its four edges must still track the
corresponding physical active-display edges. A visibly different slope means
the saved calibration is wrong. The rectified `image` or `video` must then make
those edges upright. The agent can match a unique rendered state to the
overlay, confirm what will actually be captured, then use the number with
`image` or `video`. This path is deterministic and model-free.

## Video timestamps

Every configured `video` output keeps the rectified screen unchanged and adds
a black footer below it. The footer burns the clip's elapsed presentation time
as `HH:MM:SS.mmm` into every encoded frame, starting at `00:00:00.000`. Because
the timestamp is part of the pixels rather than container metadata, it remains
visible when an agent or another tool extracts individual frames. The footer is
outside the captured screen, so it never covers device content. Stills do not
receive a footer.

## Configure options

The automatic defaults favor a quick 1280x720, 30 fps setup and wait 1.5 seconds
after opening a camera so USB autofocus can settle. The saved delay is reused by
`identify`, `image`, and `video`; video timestamps still begin at
`00:00:00.000` after warm-up. Useful overrides:

```sh
# Higher-resolution crops/evidence; useful when UI text must be readable.
tools/setup/camera/capture.sh configure --size 1920x1080

# After installing a 4K camera, request and persist its 4K capture mode.
tools/setup/camera/capture.sh configure --size 3840x2160

# Give a camera with slower autofocus more time before calibration/capture.
tools/setup/camera/capture.sh configure --settle 2.5

# Restrict setup to a known AVFoundation index or /dev/video path.
tools/setup/camera/capture.sh configure --camera 0

# Include OBS/other virtual cameras, which are skipped by default.
tools/setup/camera/capture.sh configure --include-virtual

# Give a slow camera more startup time or a remote model more response time.
tools/setup/camera/capture.sh configure \
  --camera-timeout 20 --codex-timeout 180
```

On macOS, screen-capture sources are always excluded. AVFoundation indices can
reorder, so every capture re-enumerates cameras and resolves the stored camera
by name. If that name is duplicated and its last index no longer identifies it,
the command fails clearly and requires `configure --camera INDEX` instead of
silently capturing the wrong view.

## Troubleshooting

- `camera is already in use`: wait for the other `capture.sh` command to
  finish. This tool serializes its own access; close FaceTime, OBS, browsers,
  or other camera clients if the lock comes from elsewhere.
- `Could not lock device for configuration`: another application owns the
  camera. Close it and retry.
- no cameras: grant camera permission to the launching terminal/agent process.
  A sandbox can also hide host cameras.
- no valid labeled view: make every `!N` label large, red, readable, and close
  to its device; remove glare; keep every screen edge in frame; then rerun.
- crop verification failed: use the printed artifact directory and inspect the
  newest `verification-N/device-X.jpg` beside
  `crop-verification-N.result.json`; the expanded source is under
  `refinement/device-X-expanded.jpg`. Change the rig only when that crop or its
  notes show clipping, wrong labels, glare, or ambiguity. If the crop is good,
  retry once; repeated failures usually need higher resolution, better light,
  or a different model. The previous config remains intact.
- wrong region or stale crop: the camera/device physically moved. Capture
  commands remap reordered AVFoundation indices, but deliberately skip an
  LLM/layout check for speed, so they cannot detect physical movement. Rerun
  `configure` before trusting evidence.
- green footprint looks tilted: raw tilt is expected, but each green side must
  follow the physical active-display side beside it. If their partial-degree
  slopes differ, inspect retained `rig-capture-footprints.jpg` and rerun
  `configure`; this is never repaired with a saved manual angle. If they align,
  check the rectified `image` or `video`, which must be upright.
- dark/soft first frame: increase `--settle 2.5`, add diffuse light, or adjust
  camera distance/focus physically.

Failure artifacts and directories explicitly retained with `--artifacts` or
`--keep-artifacts` are not deleted automatically. Their `camera-N.jpg` files
can include the surrounding room; remove the retained directory after
diagnosis when it is no longer needed.

For backward compatibility, `capture.sh OUTPUT.jpg` and
`capture.sh OUTPUT.mp4 --seconds 10` still perform an unconfigured full-camera
capture using `CAMERA_DEVICE`, `CAMERA_SIZE`, and `CAMERA_INPUT`. New agent
workflows should use the configured subcommands above.
