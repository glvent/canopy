# Canopy

Native Nim immediate-mode terminal UI library targeting Ratatui 0.30.2 logical-cell compatibility. **Development release: consult [parity status](docs/parity.md) before relying on stable parity.**

Requires Nim 2.2.0 or newer. Runtime and normal tests require Nim only. Rust is used solely to regenerate the pinned compatibility fixtures.

```sh
nimble install
nimble test
nimble examples
```

`import canopy` provides rendering, geometry, styles, text, buffers, widgets, terminal management and backends. Import `canopy/runtime/terminal/input` explicitly for input; applications own their event loop. Focused imports such as `canopy/core/layout/index` and `canopy/core/rendering/buffer` are supported.

Import `canopy/ui/animation/index` for the native [animation toolkit](docs/animation.md): typed tweens, easing, timelines, springs, buffer transitions and shared reduced motion.

Import `canopy/ui/controls/index` for the opt-in [interaction layer](docs/interaction.md): focus management, configurable keymaps, Unicode text input and text areas, forms, a command palette, a tree and dialogs. It is a Canopy extension, not part of Ratatui compatibility, and applications still own every state value and the event loop.

See the [milestone checklist](docs/planning/milestones.md), [shared interfaces](docs/interfaces.md), [reference generation](docs/reference.md), [upstream inventory](docs/planning/upstream-inventory.md), and [validation record](docs/validation/README.md). API documentation: `nimble docs`.

Start with the [usage guide](docs/guide.md) and [Ratatui migration guide](docs/migration.md). Run `nim r examples/showcase/showcase.nim` in a terminal of at least 80×24 for an interactive tour of every widget, styling, layout, animation, input and interactive control feature. `nimble bench` runs the recorded benchmark workloads.

Canopy is MIT licensed. Ported algorithms and data retain their upstream notices under `licenses/`; Nimble installations include `canopy/THIRD_PARTY_NOTICES.txt`.
