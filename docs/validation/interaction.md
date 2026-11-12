# Interaction layer validation

The interaction layer is a Canopy extension, so this record does not change
Ratatui parity. Its contracts are in [interaction](../interaction.md). The
record lists only checks that actually ran on branch `claude/interaction-layer`.

## Native CI matrix

GitHub Actions run 43131953551 (2026-11-12, commit `c545cd7`) passed all 12 jobs:
`ubuntu-latest`, `macos-latest` and `windows-latest`, with Nim 2.2.0 and
2.2.10, under ARC and ORC. Each job ran all 32 `tests/**/test_*.nim` files
through `tools/tester.nim` and compiled the showcase.

The Windows jobs ran the interaction suites natively, not only the C
generation. `tests/interaction/test_interaction_windows.nim` opens `CONIN$` and
`CONOUT$` like [Windows validation](windows.md). It injects
`KEY_EVENT_RECORD`s with `WriteConsoleInputW`: Latin-1 and CJK text, DEL as
Backspace, Tab, and then `q` and Enter while a dialog is open. It reads them
with `Input.poll` in raw mode, routes them through `FocusManager`, a
`TextInput` pair and a `Dialog`, and renders with the ANSI backend on
`CONOUT$`. The test checks the edited text and the focus movement. It also
checks that keys drained before a newly opened dialog's first frame never
reach the field behind it, and that Enter accepts and restores focus. This
test passed in all four Windows jobs.

Scope: the Windows evidence covers the console key-record path (characters,
DEL, Tab, CR) and ANSI output. It does not cover mouse records, bracketed
paste, resize records, or rendering fidelity in a real console window.

`ubuntu-latest` moved to Ubuntu 26.04 between the last `main` run and this
branch. Its GCC rejects the PTY tests' typed `openpty` declaration
(`-Wincompatible-pointer-types` is an error), so `tests/runtime/test_pty.nim`
and the new PTY test now declare the `termios` and `winsize` arguments as
`pointer`. Behavior is unchanged.

## Local checks

These checks ran on 2026-11-11 on macOS 27.3 (Apple M4), Nim 2.2.10:

- `nim r --mm:arc tools/tester.nim` and `nim r --mm:orc tools/tester.nim`
  passed. An independent verifier repeated both runs, plus
  `tools/tester.nim examples`, `nimble docs` (no warnings from the new
  modules), `nimble bench` and `nim check --warnings:on` on every new module
  (no warnings).
- `import canopy` alone does not expose `initFocusManager`, and `src/canopy.nim`
  is unchanged.
- `tests/interaction/test_interaction_pty.nim` writes bytes to a POSIX
  pseudo-terminal: UTF-8 text, an arrow key, DEL, a bracketed paste with a
  newline, Tab and Enter. They are read by `Input`, routed to a `TextInput`
  and a `Dialog`, and rendered through the ANSI backend. The test checks the
  edited text, the shown cursor, modal ownership before the first frame, and
  Tab between dialog buttons after it. It also passed on the Linux and macOS
  CI jobs.
- A tmux session (110×32) drove the showcase Controls page: Enter to focus,
  Unicode typing, Tab with on-blur validation, Ctrl+P with a fuzzy query,
  executing a command, a confirmation dialog, Escape back out, and `q` to
  quit. The terminal was restored on exit.
- `python3 tools/animation/pty_smoke.py build/2.2.10-orc` passed against the
  final showcase binary. This optional harness needs Python. Before this
  branch it already failed on `main`, because expectations went stale in the
  #5/#7 restyle; those expectations are now updated. It now also covers the
  Controls page: Enter to focus, Unicode typing, blur validation, the rule
  that focused fields own `q` and digits, the Ctrl+P palette, a confirmation
  dialog, Escape, and a click on a tree expander. Running it also exposed a
  regression from the seventh tab: at 120 columns the header dropped every
  stat, including the theme and reduced-motion state. The header now drops
  stats by priority and then shortens its brand.
- `tools/package_smoke.nim` now edits and renders a `TextInput` too. It passed
  against an offline `nimble install` into an isolated Nimble directory,
  compiled with `--skipParentCfg --skipUserCfg`. The compiler resolved
  `canopy/ui/controls` from the installed package, not the repository.
- An independent review found five defects. All are fixed, each with a
  regression test that failed before the fix: a cursor left inside a cluster
  after typing before a combining mark, palette result clicks stealing query
  focus, tree rendering undoing wheel scroll, a stale pointer capture after
  resize, and `OnSubmit` validation running after blur.

## Benchmarks

One `nimble bench` run (release, ORC, Nim 2.2.10, macOS arm64), in
microseconds per iteration. A single run on a laptop is noisy, so use these
numbers for orders of magnitude only:

| Workload | µs |
| --- | ---: |
| 200 registrations, `endFrame`, Tab route and click hit test | 18.2 |
| Type into a 2,000-cluster `TextInput`, then render 80 cells | 679 |
| Move and render a 10,000-line `TextArea` in a 100×40 viewport | 375 |
| Insert a line into a 10,000-line `TextArea` | 1.2 |
| Rank 2,000 commands for `"otf"` | 1,103 |
| Flatten a fully expanded 11,110-node tree | 515 |

Reproduce with `nimble bench` or
`nim c -r -d:release --path:src benchmarks/interaction_benchmarks.nim`.
