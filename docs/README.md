# Pluto documentation

Start here, then dive into the topic you need.

- [Getting started](GETTING_STARTED.md) — the common discover, provision,
  install, run, inspect, and recovery workflow.
- [Device compatibility](device-compatibility.md) — tested hardware and
  firmware, acceptance status, internal backend selection, ABI ceilings, and
  recovery guarantees.
- [../AGENTS.md](../AGENTS.md) — the full engineering playbook: toolchain,
  device workflow, tests, benchmarks, AOT vs. JIT, hot reload, and the `pluto`
  CLI reference.
- [../CONTRIBUTING.md](../CONTRIBUTING.md) — development workflow, quality
  gates, and project rules.

## Runtime and rendering

- [aot-runtime.md](aot-runtime.md) — portable release AOT, native targets,
  pinned engines, build modes, and artifact identity.
- [app-pause-resume.md](app-pause-resume.md) — app lifecycle, warm resume, the
  running-app switcher, Home/standby gestures, and bezel redraw.
- [pen-fast-render.md](pen-fast-render.md) — pen-aware fast rendering: hover
  readiness, preview, and the immediate truth chase.
- [auto-ghostbuster.md](auto-ghostbuster.md) — automatic full-screen ghost
  maintenance policy and its gates.
- [optimise.md](optimise.md) — the renderer optimisation log and method.

## Design and verification

- [icon-design-style.md](icon-design-style.md) — the app-icon field-mark
  language and launcher rendering contract.
- [real-device-camera.md](real-device-camera.md) — capturing the physical panel
  for visual verification.

## Component references

- [../tools/build/README.md](../tools/build/README.md) — host and device
  embedder builds; the release payload assembler.
- [../tools/device/README.md](../tools/device/README.md) — on-device runtime
  layout, backend implementations, standby/suspend, and recovery.
- [../tools/engine/README.md](../tools/engine/README.md) — Flutter engine
  rebuild and promotion (pin maintainers only).
