# Canopy implementation checklist

Target: Ratatui 0.30.2; minimum Nim 2.2.0; native Nim runtime, optional input.

Milestones are gates, not claims of parity. Check a box only after its acceptance checks pass. `parity.md` records coverage and remaining gaps.

## 1. Compatibility foundation
- [x] Save plan, checklist, and shared interface contracts.
- [x] Package, licensing, documentation skeleton and CI.
- [x] Pinned Rust reference, lockfile, reproducible complete-cell fixtures.
- [x] Geometry, style/reset/JSON, text, buffer/clipping/diff.
- [x] Native Unicode segmentation/width with pinned tables and notices.
- [x] Foundation tests pass with ARC and ORC.

## 2. Layout and terminals
- [x] Constraint solver, all constraints/flex/spacing/margins/spacers/cache.
- [x] Exact layout fixtures including conflicts, overflow and rounding (upstream randomized alternatives retained; see `../tools/layout/README.md`).
- [x] Transactional double buffering, cursor, resize, clear/invalidation.
- [x] Test and ANSI backends, native POSIX/Windows lifecycle and scrolling implementation.
- [x] Fullscreen/fixed/inline viewports and insertion above; 204-case upstream oracle.
- [x] Lifecycle/failure checks on macOS/Linux; runnable keyboard example.
- [ ] Execute Windows lifecycle/failure checks (release gate; tests and CI implemented).

## 3. Widgets and supporting features
- [x] Block, Paragraph, List, Table, Tabs.
- [x] Gauge, LineGauge, BarChart, Sparkline, Scrollbar, Clear, Fill.
- [x] Chart, Canvas/shapes/markers, calendar, RatatuiLogo, Mascot.
- [x] Supporting state/configuration, symbols, styling and construction helpers.
- [x] Exact cell/style/state fixtures and edge cases for each widget.

## 4. Input, documentation and release
- [x] Optional incremental keyboard/mouse/resize/focus/paste input and capabilities.
- [x] Blocking/timed input; fragmented UTF-8 and escape tests.
- [x] API/migration documentation and complete examples/gallery.
- [x] Benchmarks recorded; Nim-only installation and test checks.
- [x] Configure macOS/Linux/Windows, Nim 2.2.0/2.2.10, ARC/ORC CI.
- [x] Execute macOS/Linux tests and compile examples with both Nim versions and managers.
- [x] Every stable upstream public operation mapped; evidence and limits recorded in parity matrix.
- [ ] Execute Windows tests/examples with both Nim versions and managers.
- [ ] Declare stable parity only after the remaining Windows release gate passes.

Implementation and available-platform validation cover the complete plan. The unchecked Windows gate is explicit; no Windows host or remote CI run was available in this workspace. This does not prevent reviewing the implemented library, but it prevents a stable-parity release claim.

## Ownership
- Lead: package, geometry, style, text, buffer, umbrella exports, terminal integration, documentation, CI, final validation.
- Unicode worker: `src/canopy/internal/unicode/`, `src/canopy/core/text/unicode.nim`, Unicode generation assets/tests/notices.
- Layout worker: `src/canopy/core/layout/index.nim`, `src/canopy/internal/layout/solver.nim`, layout tests.
- Reference worker: `tools/reference/`, `tests/fixtures/`, `tests/reference/test_reference.nim`, `docs/reference.md`, `docs/planning/upstream-inventory.md`.

Workers own only assigned paths. Reassignment is recorded here or in the worker message; shared API changes go through lead.

### Second assignments
- Unicode worker: Paragraph/reflow, List, Table/shared selection state and their compatibility tests.
- Layout worker: Canvas/Chart, shape data and compatibility tests.
- Reference worker: ANSI/POSIX/Windows backend, optional input, lifecycle/input platform tests and their documentation. Reference generator handed back to lead; Unicode worker owns `tests/reference/test_reference.nim` while completing text-widget adapters.

### Gate evidence
- Foundation: Nim 2.2.10 ARC + ORC; official Unicode17 766 grapheme and 36,001 width cases; complete-cell reference adapters.
- Layout: ARC + ORC; 391 upstream cases + 2,000 systematic cases + 18 reference cases. Five degenerate inputs have multiple upstream outputs due to randomized solver ordering. Native outputs occur among locked upstream outputs; sampled alternatives retained explicitly.
- Terminal: 204 upstream cases / 732 snapshots plus transactional errors and counter wrapping; native ANSI/input/PTY suites pass on macOS/Linux. Native Windows lifecycle/input tests are implemented and compile to C with correct Win32 field aliases; execution pending.
- Widgets: all 17 built-ins, state and supporting symbols have exact reference coverage. Final public-API audit added newline construction, ScrollbarSet interoperability, palette conversions, calendar dimensions and terminal apply-buffer APIs.
- Release: six examples, isolated Nimble installation/consumer, API docs and benchmarks are delivered. [Validation record](../validation/README.md) lists actual platform/compiler checks; [parity](../parity.md) records limits.

### Final assignments and handoff
- Unicode worker: Block/shadows/symbols, stable API audit, palette conversions and calendar metric regression cases; reviewed and integrated by lead.
- Layout worker: deterministic gallery and native benchmark workloads; reviewed and integrated by lead.
- Reference worker: 204-case terminal oracle and independent reproduction; reviewed and integrated by lead.
- Windows worker: native console mode/rollback/injected-key tests and explicit validation boundary; reviewed by lead.
- All runtime and public API ownership returns to lead after handoff. No workers edit shared files concurrently.
## Canopy animation extension

- [x] Contracts, easing, typed interpolation and tweens.
- [x] Monotonic scheduling, lifecycle/events, repetition, timelines and analytical springs.
- [x] Clipped Unicode-safe buffer transitions and shared reduced motion.
- [x] Interactive animation gallery, dashboard integration and separate API docs.
- [x] Native compiler/ARC/ORC matrix, PTY controls, recovery checks and measured benchmarks.
- [ ] Windows runtime acceptance remains open; C generation does not close this gate.

See [animation contracts](../animation.md) and the [executed validation record](../validation/animation.md).

## Canopy interaction extension

- [x] Contracts: identity, frame registration, focus, modals, routing, keymaps and text units.
- [x] Focus manager, scopes, modal stack, hit testing and pointer capture.
- [x] Configurable keymaps with contexts, override layers and legacy-encoding normalization.
- [x] Unicode-aware editing model, `TextInput` and `TextArea` with undo, selection and paste.
- [x] Forms with validation timing, command palette, tree view and dialogs.
- [x] Showcase Controls page, API docs, benchmarks, POSIX PTY and tmux checks.
- [x] Native Windows console acceptance: CI run 43131953551 passed on `windows-latest`.

See [interaction contracts](../interaction.md) and the [executed validation record](../validation/interaction.md).
