# Paper Codex

A port of [paper-codex](../../../paper-codex) to Pluto: an intelligent paper
notebook, driven by the OpenAI Codex CLI running on-device.

The page is the product. Conversation lives on ruled paper: your words in blue
Caveat handwriting, Codex's replies in EB Garamond ink that writes itself onto
the page like the Marauder's Map. No chrome, no bubbles, no toolbars — every
control is a hand-drawn mark in the margins.

## Design language (inherited from paper-codex, normative)

- Page lattice: 954×1696 is the reference authoring grid, with a 56 px rule
  pitch, first rule at y=150, and reference content column x 44..910. It is not
  a required device size. `PageScale` derives scale and usable bounds from
  the live Flutter viewport so wider panel shapes expand rather than clip.
- Palette (`lib/src/paper/theme.dart`): cream paper, near-black ink, gray
  soft-ink, khaki rules — and **blue means your ink and nothing else**.
- Every glyph is procedural (`lib/src/paper/glyphs.dart`): the sine-wobble
  `soft_line`, seeded per-key jitter, spiral/chevron speaker marks, checkbox +
  margin bracket, wavy rule, sun-of-rays settings mark, send flourish.
- Typography: EB Garamond (Codex, wordmark, key labels), Caveat (user ink,
  titles, notes), JetBrains Mono (code blocks). Bundled in `assets/fonts/`.

## E-ink discipline

- Never request `full`; screen changes are `text`, small updates `fast`/`ui`
  (`EinkRefreshRegion.request`). Animations are small-region and quantized;
  when they finish the app goes quiet so the renderer's idle settle sharpens
  the page ("the ink dries").
- The quill reveal (`lib/src/paper/quill_reveal.dart`) uncovers Codex's reply a
  few words per tick with a leading nib dot, then settles. Cadence and batch
  size are tunable in `RevealSpec`.

## Codex integration

`lib/src/codex/` spawns `codex exec --json` (JSONL events on stdout) and
`codex exec resume <threadId> --json` for follow-up turns; see
`codex_events.dart` for the event model. Handwriting turns attach the page as
a PNG (`-i`) and use the TRANSCRIPTION:/ANSWER: two-section contract from
paper-codex. Timeouts: soft 120 s ("still thinking…" note), hard 600 s (kill).
Failures classify to paper-native margin notes (offline / sign-in / timeout /
missing binary) with a retry mark on the tail turn.

The Codex binary is looked up via `$PAPER_CODEX_BIN`, `/home/root/bin/codex`,
`/home/root/.local/bin/codex`, then `codex` on PATH. Auth lives in
`~/.codex/auth.json`; it is user-provided and never embedded in a Pluto payload
or logged by this app.

`PAPER_CODEX_FAKE=1` selects the scripted bridge for automated tests only. A
release payload never sets it, and fake output never counts as device
acceptance.

## Dev workflow

```sh
~/.pluto/sdk/3.44.4/bin/flutter test                    # unit + widget tests
~/.pluto/sdk/3.44.4/bin/flutter test test_goldens/      # reference-fixture goldens (954×1696 @ DPR 2.0)
~/.pluto/sdk/3.44.4/bin/flutter test --update-goldens test_goldens/
DEVICE=root@10.11.99.1  # or this tablet's USB/Wi-Fi SSH endpoint
pluto build package --device "$DEVICE" --release
pluto install --device "$DEVICE" --release --force --launch build/pluto/app.plap
```
