# Pinned Flutter engine artifacts

This directory contains the small, clone-ready subset of Flutter engine
artifacts that Pluto cannot obtain as a published release embedder bundle.
Artifacts are keyed by the exact engine commit from
`tools/pluto/pins/engine.version`:

```text
<engine-hash>/
  linux-arm64-release/
    libflutter_engine.so
    gen_snapshot
    icudtl.dat
    LICENSE.*.md
    CHECKSUMS.txt
  linux-arm64-profile/
    libflutter_engine.so
    gen_snapshot
    icudtl.dat
    LICENSE.*.md
    CHECKSUMS.txt
```

The runtime libraries are Pluto's source-built plain AArch64 release/profile
embedders. The mode-matched `gen_snapshot` tools and ICU data are
revision-matched official Flutter artifacts. Together they let a fresh clone
build and run AOT apps without compiling Flutter itself.

`CHECKSUMS.txt` is authoritative: setup and CLI code validate its Flutter
version, engine commit, target, mode, and SHA-256 records before use. Never
replace one payload file independently; engine, snapshotter, ICU data, pin,
and manifest must move together.

Downloaded archives, source checkouts, debug/JIT engines, and build output do
not belong here. They remain in ignored caches. See `tools/engine/README.md`
for the reproducible maintainer build and promotion workflow.
