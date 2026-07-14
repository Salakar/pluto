# Pluto app icon design style

## The field-mark family

Pluto app icons are **field marks**: compact black-ink diagrams that could
have been drawn in the margin of an engineer's paper notebook. They should
feel human without looking casual, and technical without looking sterile.
The launcher supplies the outer square frame, pin dog-ear, pressed inversion,
and app label; an icon supplies only the symbol inside that frame.

The family is deliberately monochrome. This makes the marks clear on both
Gallery 3 color glass and monochrome panels, keeps pressed-state inversion
reliable, and prevents color from becoming the only way to identify an app.

## Shared construction

- Canvas: 256 x 256 PNG with a transparent background.
- Safe area: keep visible ink inside x/y 38..218. Nothing touches the canvas
  edge or the launcher's enclosing frame.
- Optical size: the main symbol should occupy about 65 percent of the canvas;
  all family members should feel equally large even when their bounds differ.
- Ink: solid black alpha artwork. The launcher recolors the alpha mask to the
  current foreground color, including the inverted pressed state.
- Stroke: rounded caps and joins, normally 9-14 px at source size. Small marks
  may be heavier, but no structural detail should become thinner than 8 px.
  This deliberately survives the 256-to-88 px launcher reduction and e-ink
  quantization instead of relying on desktop-density antialiasing.
- Shape language: long confident curves, short registration strokes, circular
  dots, and a controlled hand-drawn wobble. Curves may be organic; alignments
  and spacing remain deliberate.
- Density: prefer one continuous idea and at most three small secondary marks.
  Avoid large filled regions, tiny hatching, gradients, shadows, text, letters,
  numbers, app-store gloss, and a second outer frame.
- Recognition test: each mark must remain identifiable when displayed inside
  an 88 x 88 logical-pixel icon well and when reduced to a one-bit preview.

## App marks

### Paper Codex

A single page with a folded corner contains an inward thought spiral. The page
anchors the app in writing; the continuous spiral conveys an active line of
reasoning without using a chat bubble, robot, or vendor logo.

### Motion Lab

An elliptical orbit carries three staggered registration dots and one forward
sweep. The open orbit suggests sampled movement rather than endless loading.

### Ink Lab

A fountain-pen nib touches down into one flowing baseline. The contact point is
important: it makes the icon about live ink and pen input rather than generic
writing or editing.

### Ink

An outlined ink drop opens directly into one continuous flowing stroke. The
drop names the medium while the open tail makes the mark about finished,
expressive drawing rather than Ink Lab's input instrumentation.

### Validation Lab

Four open calibration corners surround a precise check and one registration
dot. The broken outer boundary distinguishes a measurement target from the
launcher's solid app frame.

### Counter

Four upright notebook tallies are crossed by one decisive fifth stroke. The
cluster communicates accumulated counting without a numeral, letter, plus
sign, or another enclosing app frame.

## Launcher rendering contract

The app manifest's `icon` path is authoritative. Provisioning places that file
beside the installed manifest, the launcher repository reads it from the
installed app directory, and `AppTile` paints it as a foreground-colored alpha
mask. Missing or undecodable artwork falls back to the existing two-letter
monogram; it must never prevent an otherwise healthy app from launching.

Icons are verified in two contexts:

1. an icon-family golden showing all six marks at launcher scale; and
2. the full Move-reference 954 x 1696 launcher-grid golden, including labels,
   app frames, pin/broken affordances, spacing, and the stock reMarkable tile.

That second image is a deterministic reference fixture, not the launcher's
runtime viewport contract. The launcher also has responsive layout coverage at
the native metrics of the other tested tablets.

## Review checklist

- Are all six marks obviously part of one family before reading the labels?
- Is every symbol distinct at a glance and semantically appropriate?
- Do stroke weight, corner radius, dot size, padding, and optical scale agree?
- Does any detail disappear at launcher size or after one-bit quantization?
- Is the symbol still clear when recolored for the pressed/inverted state?
- Is the launcher frame the only enclosing app frame?
- Are the source PNG, manifest path, installed layout, and rendered golden all
  exercising the same asset rather than a test-only substitute?
