# Ratatui 0.30.2 parity

Status: **implementation complete; Windows runtime acceptance remains open. This is a development release, not a stable-parity declaration.**

Gates: [milestones](planning/milestones.md). Contracts: [interfaces](interfaces.md). Every stable operation is mapped in the [upstream inventory](planning/upstream-inventory.md); [API adaptations](planning/api-gaps.md) distinguish Nim equivalents from exclusions. The [validation record](validation/README.md) separates executed checks from configured CI.

| Area | Implementation | Exact compatibility evidence | Remaining acceptance |
| --- | --- | --- | --- |
| Geometry/style/text/buffer | complete | `test_foundation`, `test_reference`, `test_public_api`: complete cells/styles/diffs, clipping, wide overwrite, geometry, JSON, constructors | no known implementation gap |
| Unicode 17 | complete, native checked-in tables | all 766 official grapheme cases; 36,001 width cases; invalid UTF-8 and contextual clipping tests | finite sequence coverage |
| Layout/solver/cache | complete native Cassowary | 391 upstream examples, 2,000 systematic cases, 18 base reference cases; all constraints and seven flex modes | tied upstream solutions described below |
| Terminal/viewports | complete | 204 upstream cases / 732 full snapshots; fullscreen/fixed/inline, insertion, scrollback, clear, resize, cursor, manual/apply-buffer APIs; native transactional failure tests | actual terminal emulation remains platform-dependent |
| Backends | native ANSI/VT, POSIX and Windows; deterministic TestBackend | ANSI bytes and errors; real macOS/Linux PTYs; Windows native integration tests and generated-C validation | execute Windows matrix |
| Block and symbols | complete | 3,744 border, 864 title, 336 shadow cases; 991 symbol values and 53,067 merge combinations | finite configuration coverage |
| Paragraph/List/Table | complete | 648/360/420 matrix cases plus base fixtures; complete cells and resulting selections/offsets | upstream clipping quirk retained below |
| Remaining widgets | complete | 1,890 configurations for Tabs/Gauges/BarChart/Sparkline/Scrollbar/Monthly/Logo/Mascot; Clear/Fill base fixtures; 277 Canvas and 230 Chart cases; 384 calendar metrics | finite configuration coverage |
| Colors and supporting APIs | complete | 31,347 exact HSL/HSLuv RGB conversions plus five packed colors; style/theme JSON and public-construction tests | local-date helper is tested as an API mapping, not a fixed-date oracle |
| Optional input | complete | incremental Unicode/escape/paste/mouse/focus/enhanced-key parsing; blocking/timed/EOF/resize PTY checks; cleanup and partial-init failure tests | execute Windows console input tests |
| ANSI output efficiency, synchronized output and color depth (Canopy extension) | native | exact byte tests for cursor/SGR elision, DEC 2026 bracketing, downsampling and environment detection | not a Ratatui parity claim; terminal rendering of mode 2026 is emulator-dependent |
| Filled blocks (Canopy extension) | native | `test_block` checks body, edge, title and border-style colors | not a Ratatui parity claim; unfilled blocks keep the upstream matrix |
| Optional interaction layer (Canopy extension) | native | focus/keymap/routing/editing/control tests, POSIX PTY and native Windows console tests; see [interaction validation](validation/interaction.md) | not a Ratatui parity claim; Windows coverage is console key records only |
| Optional animation (Canopy extension) | native toolkit | deterministic tween/easing/spring/scheduling/ownership tests; complete-cell transition tests; see [animation validation](validation/animation.md) | not a Ratatui parity claim; Windows runtime gate remains open |
| Documentation/examples/package | complete | generated API docs, guide/migration, all-in-one interactive showcase compiled in CI and PTY smoke-tested, isolated Nimble consumer, recorded benchmarks | Windows example compilation remains in CI gate |

All comparisons use independently generated pinned upstream results. Runtime and ordinary tests use Nim only. Generator commands, versions and limitations are in [reference generation](reference.md).

## Known upstream behavior and evidence limits

- Kasuari's randomized row ordering can choose different tied optima. Five systematic inputs admit only alternatives observed in fresh locked upstream processes; arbitrary equivalent solutions are not accepted. See [layout validation](../tools/layout/README.md).
- Paragraph's wrapped mixed-width words can write one cell past the widget area while staying in the backing buffer. The reference cases preserve that behavior. Monthly's row check compares absolute `y` with buffer height, and BarChart group-label styling can extend below its widget area. These are pinned upstream behaviors, not silent native differences.
- Full-height inline insertion uses the same single-row VT scrolling region as upstream Crossterm. Some terminal emulators do not support that region. The logical TestBackend result is exact; font and emulator behavior is outside logical-cell parity.
- The Rust TestBackend panics for clearing one particular zero-height inline viewport at screen bottom. Its oracle excludes that panic sequence while covering zero-height draw, insertion and resize. Canopy clips the clear safely.
- Symbol values and the enumerated merge table are exhaustive for their finite inputs. Layouts, text sequences, floating-point drawing, styles and widget combinations are sampled. Non-finite Canvas/Chart JSON limits are documented in [chart validation](../tools/chart/README.md).
- Native Windows code and tests have passed semantic/generated-C checks, not execution on Windows. Do not close the release gate until all four Windows CI combinations pass. See [Windows validation](validation/windows.md).

Rust adapters map to native backend capabilities. Rust ABI/integrations, experimental APIs, embedded no_std and third-party widgets are excluded by the accepted plan.
