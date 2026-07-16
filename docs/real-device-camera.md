# Real-device camera capture

Some behavior can only be verified by looking at the physical panel: e-ink
refresh timing, ghosting, partial-update artifacts, standby/wake, and
real-glass text legibility. A renderer screenshot (`pluto screenshot`) proves
the requested logical or post-dither software surface existed, not what the
pigment actually did. For those checks, point a camera at the screen and
capture a still or a short clip.

`tools/setup/camera/capture.sh` wraps this and can persist a camera plus
screen-only crop for every numbered device in a local rig. Captured media is
verification evidence, not source: keep it out of the repository (write it
under the git-ignored `analysis/` tree or a scratch directory). The full agent
interface is documented in [`tools/setup/camera/README.md`](../tools/setup/camera/README.md).

## Quick start

The one-time `configure` command sends temporary camera frames and crop
previews to the OpenAI Codex service; those frames can include the surrounding
room. Later capture commands stay local.

```sh
# One time after arranging/moving the camera or devices. Put a unique red !N
# label next to every device before running this.
tools/setup/camera/capture.sh configure \
  --device-profile 1=move \
  --device-profile 2=rm1 \
  --device-profile 3=rm2

# Red device regions plus green final-capture footprints for the whole rig.
tools/setup/camera/capture.sh identify --output /tmp/devices.jpg

# Cropped still and ten-second clip of device 1.
tools/setup/camera/capture.sh image --device 1 --output /tmp/panel.jpg
tools/setup/camera/capture.sh video \
  --device 1 --seconds 10 --output /tmp/panel.mp4
```

`configure` automatically samples the available physical cameras, uses Codex
vision to find the red-numbered rig and each outer planar device face, then uses
expanded close views plus a local per-edge RGB fit to follow every current
active-display/bezel transition. It verifies both complete upright portraits
and the exact green raw-camera capture footprints, adds only a narrow
inner-bezel safety guard, and atomically writes the git-ignored
`.pluto-devices.json`. Each device is independent, so one rig may mix different
screen sizes and aspect ratios. Every detected number must be assigned exactly
one `rm1`, `rm2`, or `move` profile with `--device-profile NUMBER=PROFILE`.
The config stores that binding, each device's base, fine, and total signed
fractional clockwise rotation corrections, physical-boundary fit, per-device
coverage, diagnostic content-line evidence, plus both corner transforms. Candidate frames and
crop previews are sent to the OpenAI Codex service during that one-time
command. Later `identify`, `image`, and `video` commands are local-only FFmpeg
captures and do not invoke a model.

## Finding the camera

Ordinarily `configure` finds the correct camera itself. For manual diagnosis,
list capture devices with:

- macOS (AVFoundation): `ffmpeg -f avfoundation -list_devices true -i ""`
- Linux (v4l2): `v4l2-ctl --list-devices`

To restrict configuration to a known camera, pass its index/path with
`configure --camera ID_OR_PATH`. On macOS, the tool uses a video-only input so
no microphone permission prompt appears. If no camera is listed, grant camera
access to the terminal application in the OS privacy settings, then reopen the
terminal and list again.

## Still vs. video

- **Still**: static UI states, before/after comparisons, launcher layout,
  icon checks, and anything where text legibility is the assertion.
- **Video**: motion or timing — launch sequences, app switching, pen/touch
  interaction, animation loops, refresh behavior, ghosting, or visible
  latency. Use the shortest clip that proves the behavior (roughly 5 s for a
  single transition, 10 s for navigation or a short interaction, 20 s or more
  for repeated redraws and delayed ghosting). For an interaction clip, start
  recording before the action and keep recording for at least two seconds
  after the final visible refresh settles. Every configured clip has a black
  footer outside the screen with frame-burned elapsed time in
  `HH:MM:SS.mmm`, so extracted frames retain precise video timing.

## Framing checklist

A screen-only `image` or `video` capture only counts as evidence when:

- the reMarkable screen is the subject, not another device;
- the whole active screen is visible without clipped display edges;
- the screen fills the crop and configure's corrected result is upright and
  portrait-oriented;
- no broad bezel, outer glass/chassis rim, or background remains in a
  screen-only capture (a narrow inner-bezel safety guard is valid);
- the text and icons the assertion depends on are readable;
- there is no major glare, reflection, or light streak across the content;
- the camera and device are stable before capture begins; and
- hands, cables, or stands do not cover the UI being checked.

Use `identify` when the evidence also needs the bezel, physical orientation,
red label, or other devices. It returns the uncropped rig view with red device
regions and `DEVICE N` overlays. A bright-green quadrilateral inside each red
region marks the exact guarded source footprint that becomes the final
rotation-, perspective-, and bezel-corrected `image` or `video` output. It is
rendered as a solid lime stroke with a dark inner keyline so every edge remains
visible even on a pale screen.

Screen-only `image` and `video` captures apply the stored arbitrary-angle and
perspective correction, including small non-quarter-turn tilt, to produce an
upright portrait result. Videos then append the external timestamp footer
without covering or rescaling that result. The config records the derived
`rotation_degrees_clockwise` value for inspection. `identify` deliberately
preserves the camera's full physical view so its device boxes and label overlays
remain useful. Its green footprint therefore follows the raw physical tilt and
usually is not level. Even so, every green side must follow the adjacent
physical active-display side; a differing slope is a bad calibration, not an
expected perspective effect. When they align, assess the resulting upright
rotation from the rectified `image` or `video`.

## Troubleshooting

- `Could not lock device for configuration`: another process holds the
  camera, or two captures are running at once. Close other camera apps and
  retry one capture at a time.
- Camera not listed: camera permission is missing for the terminal, or the
  command is running in a sandbox without camera access.
- Frame too dark or soft: the default waits 1.5 seconds for autofocus. Try a
  different `configure --size WIDTHxHEIGHT`, increase `configure --settle 2.5`,
  add diffuse room light, and avoid glossy reflections.
  The command path has limited focus control, so fix softness physically
  (adjust distance and angle) rather than in software.
- Wrong camera used: current captures remap reordered AVFoundation indices by
  camera name. If names are duplicated or the wrong physical camera was
  configured, rerun `configure --camera ID_OR_PATH`.
