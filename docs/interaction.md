# Interaction layer (Canopy extension)

Focus management, keybindings, text controls, forms, a command palette, a tree
and dialogs. These are Canopy extensions, not Ratatui compatibility claims.
`import canopy` is unchanged: the layer is opt-in.

```nim
import canopy
import canopy/runtime/terminal/input
import canopy/ui/interaction/index as interaction  # ids, focus, keymaps, routing
import canopy/ui/controls/index as controls        # controls; re-exports interaction
```

The layer has no global focus state, threads, timers or event loop. The
application owns every state object, the loop, the terminal and input
lifecycle. Nothing here reads input or draws on its own.

## Modules

| Module | Contents |
| --- | --- |
| `ui/interaction/ids` | `ControlId`, `ActionId` |
| `ui/interaction/focus` | `FocusManager`: per-frame registration, scopes, modals, traversal, hit testing |
| `ui/interaction/keymap` | `KeyChord`, `Keymap`, contexts, standard actions and defaults |
| `ui/interaction/routing` | `Route`, `EventResult`, `route`, `handleTraversal` |
| `ui/controls/editing` | Grapheme boundaries, word classes, input sanitizing, undo history |
| `ui/controls/textinput`, `textarea` | Single-line and multiline editors |
| `ui/controls/common` | `ControlTheme`, `drawInteractive`, `Button` |
| `ui/controls/form` | Labeled fields, validation, submit/reset |
| `ui/controls/palette` | Command registry, fuzzy ranking, modal palette |
| `ui/controls/tree` | Application-owned tree data, tree state and view |
| `ui/controls/dialog` | Modal dialog shell |

Interaction modules import only events, geometry and the standard library.
Controls import interaction, rendering, widgets and the terminal `Frame`.

## Identity and ownership

`ControlId` and `ActionId` are distinct strings supplied by the caller.
`controlId("")` raises `ValueError`. IDs must stay stable across frames; they
are the only link between a control's state, its registration and its focus.

Each control has a state object (`TextInputState`, `TreeState`, ...) created
with its ID and owned by the application. A control's widget value
(`TextInput`, `TreeView`, ...) is rebuilt each frame and holds configuration
only. Compound controls own their children: a `FormState` owns its field
editors, a `PaletteState` owns its query input. Data the application already
owns is passed in, never copied into hidden storage: the palette receives a
`CommandRegistry`, the tree receives `openArray[TreeItem]`.

## Frame registration

`terminal.drawInteractive(fm, frame): body` renders one frame like
`Terminal.draw`, but inlines `body` so it can use `var` state without a
closure. It calls `fm.beginFrame()` before the body and `fm.endFrame()` after,
and renders once more (at most one extra pass) when reconciliation moved focus.

```nim
discard terminal.drawInteractive(fm, frame):
  frame.renderControl(fm, initTextInput("Name"), nameArea, nameState)
  frame.renderControl(fm, initDialog("Quit?", "Unsaved changes."), frame.area, quit)
```

An application with its own draw procedure calls `fm.beginFrame()` and
`fm.endFrame()` around its rendering and redraws when `endFrame` returns
`true`. A frame that raises before `endFrame` is discarded at the next
`beginFrame`.

Between the two calls, every focusable control rendered this frame calls
`fm.register(id, area, enabled, tabStop, textEntry)`. `renderControl` does this
for built-in controls. Registration order is traversal order and paint order:
later registrations are on top for hit testing. Registering the same ID twice
in one frame raises `ValueError`. Hidden controls are not registered; an empty
or clipped area only removes a control from hit testing.

`endFrame` replaces the previous frame's registrations: a control that was not
registered no longer exists. A disabled control keeps its identity but cannot
take focus or pointer input. `endFrame` then reconciles focus (below) and
returns `true` when the focused control changed.

Scopes group registrations: `fm.beginScope(id, area, modal)` and
`fm.endScope()`, or the `withScope` template. A scope's area clips the hit
areas of everything inside it. Unbalanced scopes raise `ValueError` at
`endFrame`. A registration records its enclosing scopes innermost first in
`Registration.scopes`, which `route.scopes` copies.

## Focus

Focus is one `ControlId` or none, stored in the `FocusManager`. Nothing is
focused until the application calls `focus`, `focusFirst`, `focusNext`, opens a
modal, or the user clicks a control. Logical focus is independent of terminal
`FocusGained`/`FocusLost`; those events only update `fm.terminalFocused`.

- `fm.focus(id)` sets focus immediately. An ID unknown to the last frame stays
  pending and is validated at the next `endFrame`. Focusing a known control
  outside the active modal is refused and returns `false`. `fm.clearFocus()`
  removes focus.
- `fm.focusNext()` and `fm.focusPrevious()` move through the active domain in
  registration order, skipping disabled and non-tab-stop controls, and wrap.
  With no focus, next selects the first control and previous the last.
- A left button press on a focusable control focuses it (`route`).
- The *active domain* is the top modal's controls when a modal is open, and
  otherwise every control outside modal scopes. Controls in nested non-modal
  scopes belong to the enclosing domain.

At `endFrame`, if the focused control is missing, disabled or outside the
active domain, focus falls back in this order: the nearest following focusable
control from the previous frame's order that still exists in the domain; else
the nearest preceding one; else the first focusable control in the domain when
the ID was never registered (pending programmatic focus); else none.
Traversal in an empty modal domain consumes Tab so it cannot escape; in an
empty base domain it is not consumed.

## Modals

A modal scope traps traversal, keyboard routing and pointer input.
`fm.openModal(scope, initialFocus)` is the only way to open one, so routing
changes before the modal's first frame and keys drained in the same batch
cannot leak to the controls behind it. Rendering `beginScope(..., modal =
true)` for a modal that is not open raises `ValueError`. Opening records the
focused control for restoration and moves focus to `initialFocus` (pending if
not yet registered) or, at the next `endFrame`, to the modal's first focusable
control. Until that first frame, Tab inside the modal is consumed without
moving because the modal has no registrations yet.

Modals stack in opening order and only the top one is active.
`fm.closeModal(scope)` removes it and, if it was on top, restores the recorded
focus immediately (`endFrame` applies the fallback if that control is no longer
focusable). Closing a lower modal hands its recorded focus to the modal opened
above it. `endFrame` never opens or closes modals: a modal that is not rendered
stays open and keeps trapping input, so the state object (`DialogState`,
`PaletteState`) and the focus manager cannot disagree.

## Routing

`let route = fm.route(event)` is called once per event before any control
handler. It never invokes handlers; the application dispatches in this order
and stops as soon as a result is consumed:

1. Open modal controls (palette, dialog). They check `route.modal` and act only
   on their own scope.
2. Other controls, only when `route.allowsApplication` is true. Each acts only
   when `route.targets(id)`, so only the focused or hit control responds.
   Compound controls (form) dispatch to their children first, so the innermost
   handler wins; `route.scopes` lists the target's scopes innermost first.
3. `fm.handleTraversal(route, keymap)` for focus movement.
4. Application bindings: `keymap.resolveApplication(route)`, which only
   matches the `global` context while a modal is open.

```nim
let route = fm.route(event)
var r = dialog.handle(fm, route, keys)
if not r.consumed and route.allowsApplication: r = nameState.handle(route, keys)
if not r.consumed: r = fm.handleTraversal(route, keys)
if not r.consumed:
  let action = keys.resolveApplication(route)
```

Raw application handlers that read `Event` values directly must also check
`route.allowsApplication`, or they will see keys meant for a modal.

`route` computes:

- Key and paste: `target` is the focused control in the active domain.
  `textEntry` is true when that control registered with `textEntry = true`.
- Mouse: hit testing uses the last completed frame, topmost first, within the
  active domain and clipped by scopes. A left press focuses the hit control
  (`focusChanged`) and captures the pointer; drag and release go to the
  captured control until release. Wheel and motion go to the control under the
  pointer. With a modal open, a press outside it has no target, so the modal
  can swallow or dismiss it.
- Resize marks geometry stale. Until the next `endFrame`, pointer events have
  no target, while keys still follow focus. Focus and terminal-focus events have
  no target.

`EventResult` has `consumed`, `redraw`, `changed`, `action: Option[ActionId]`
and `subject` (the ID the action concerns: a command, tree node, button, form or
dialog). `result.add(other)` merges results. Release key events are never
consumed by built-in controls.

A control that closes a modal returns a consumed result. Because the route was
computed before closing, the restored control does not match `route.target`,
so the same event never reaches it.

## Keymaps

`KeyChord` names a key code or produced character plus modifiers. `Keymap`
maps `(context, chord)` to an `ActionId`. `defaultKeymap()` contains the
standard bindings, and `standardKeymap` is a shared immutable copy. Controls
look up their context in their optional per-state override keymap first, then
in the keymap passed to `handle` (normally the application's copy of the
defaults). Applications customize with `bindKey`, `unbindKey` and
`unbindAction`. Binding a chord that is already bound to a different action in
the same context raises `KeymapConflictError` unless `replace = true`;
`keymap.conflicts(contexts)` lists chords bound in more than one of the given
contexts.

Matching rules:

- Bindings fire on press. A binding with `repeat = true` (editing and
  navigation defaults) also fires on repeat. Release never matches.
- Lock modifiers are ignored. `BackTab` matches Shift+Tab.
- Character chords match the produced text. Shift is meaningful only through
  letter case: Shift+`a` and `A` are the same chord, and Shift on other
  characters is ignored because legacy terminals do not report it.
- With `textEntry`, printable characters without Control, Alt, Super, Hyper or
  Meta never match a binding. Paste never matches a binding.
- Legacy encodings cannot distinguish Ctrl+H from Backspace, Ctrl+I from Tab,
  Ctrl+M or Ctrl+J from Enter, Ctrl+[ from Escape, or Ctrl+Shift+letter from
  Ctrl+letter. The Kitty enhanced keyboard capability removes most of these
  limits, and the defaults avoid relying on them.

- Alt followed by a legacy control byte (ESC DEL, ESC BS, ESC Ctrl+letter) is
  normalized to Alt plus the key, so Alt+Backspace matches on every terminal.
- `disableKey(context, chord)` in an override keymap hides a lower layer's
  binding without replacing it.

Key sequences (chords of chords) and configuration files are not supported.
`parseChord("ctrl+shift+left")` and `$chord` exist for code and hints.

### Default bindings

`text` bindings also apply in text areas, after `textarea`. The palette also
uses `list` navigation. Editing and navigation bindings repeat.

| Context | Action | Keys |
| --- | --- | --- |
| `focus` | `focus.next` | `Tab` |
| `focus` | `focus.previous` | `Shift+Tab` |
| `text` | `text.left` | `Left` |
| `text` | `text.right` | `Right` |
| `text` | `text.wordLeft` | `Ctrl+Left`, `Alt+Left`, `Alt+B` |
| `text` | `text.wordRight` | `Ctrl+Right`, `Alt+Right`, `Alt+F` |
| `text` | `text.home` | `Home` |
| `text` | `text.end` | `End`, `Ctrl+E` |
| `text` | `text.selectLeft` | `Shift+Left` |
| `text` | `text.selectRight` | `Shift+Right` |
| `text` | `text.selectWordLeft` | `Ctrl+Shift+Left` |
| `text` | `text.selectWordRight` | `Ctrl+Shift+Right` |
| `text` | `text.selectHome` | `Shift+Home` |
| `text` | `text.selectEnd` | `Shift+End` |
| `text` | `text.selectAll` | `Ctrl+A` |
| `text` | `text.backspace` | `Backspace` |
| `text` | `text.delete` | `Delete`, `Ctrl+D` |
| `text` | `text.deleteWordLeft` | `Ctrl+W`, `Alt+Backspace` |
| `text` | `text.deleteWordRight` | `Ctrl+Delete`, `Alt+D` |
| `text` | `text.undo` | `Ctrl+Z` |
| `text` | `text.redo` | `Ctrl+Y`, `Ctrl+Shift+Z` |
| `text` | `text.copy` | `Ctrl+Insert` |
| `text` | `text.cut` | `Ctrl+X` |
| `text` | `text.paste` | `Shift+Insert` |
| `text` | `text.submit` | `Enter` |
| `textarea` | `text.newline` | `Enter` |
| `textarea` | `text.up` | `Up` |
| `textarea` | `text.down` | `Down` |
| `textarea` | `text.selectUp` | `Shift+Up` |
| `textarea` | `text.selectDown` | `Shift+Down` |
| `textarea` | `text.pageUp` | `PageUp` |
| `textarea` | `text.pageDown` | `PageDown` |
| `textarea` | `text.documentStart` | `Ctrl+Home` |
| `textarea` | `text.documentEnd` | `Ctrl+End` |
| `textarea` | `text.selectDocumentStart` | `Ctrl+Shift+Home` |
| `textarea` | `text.selectDocumentEnd` | `Ctrl+Shift+End` |
| `list` | `list.previous` | `Up`, `Ctrl+P` |
| `list` | `list.next` | `Down`, `Ctrl+N` |
| `list` | `list.first` | `Home` |
| `list` | `list.last` | `End` |
| `list` | `list.pageUp` | `PageUp` |
| `list` | `list.pageDown` | `PageDown` |
| `list` | `list.activate` | `Enter` |
| `tree` | `tree.expand` | `Right` |
| `tree` | `tree.collapse` | `Left` |
| `tree` | `tree.toggle` | `Space` |
| `palette` | `palette.execute` | `Enter` |
| `palette` | `palette.dismiss` | `Esc` |
| `dialog` | `dialog.accept` | `Enter` |
| `dialog` | `dialog.cancel` | `Esc` |
| `dialog` | `focus.previous` | `Left` |
| `dialog` | `focus.next` | `Right` |
| `button` | `button.press` | `Enter`, `Space` |
| `form` | `form.submit` | `Enter` |

## Text controls

Text is UTF-8. Three units stay distinct: byte offsets (storage and cursor),
grapheme clusters (movement, deletion, selection) and terminal cells
(rendering, scrolling, preferred column). The cursor and selection anchor are
always byte offsets on grapheme boundaries.

- Words: readline style. A word is a run of clusters whose first code point is a
  letter, digit or `_`. Other non-space clusters form punctuation runs.
  Ctrl+Left moves to the start of the previous run; Ctrl+Right moves to the end
  of the next run.
- Inserted and pasted text: invalid UTF-8 bytes become U+FFFD, tabs become
  `tabWidth` spaces (default 4), other C0/C1 controls and DEL are removed, and
  CRLF or CR become LF. `TextInput` applies its `NewlinePolicy` (`Space`
  default, `Strip`, `FirstLine`); `TextArea` keeps LF.
- Undo: consecutive typed insertions within one word merge, as do consecutive
  deletions in one direction. Paste, cut, newline, selection replacement and
  any cursor movement start a new step. The history keeps `undoLimit` steps
  (default 100) as edit deltas, not snapshots.
- Rendering: horizontal scrolling keeps the cursor visible with
  `scrollMargin`; a wide cluster cut by the left edge renders as blank cells.
  `state.cursor` holds the terminal cursor after rendering when focused and
  editable. Placeholder, read-only, disabled and invalid states each have a
  style. Invalid also adds a marker glyph so it never relies only on color.
- `TextArea` keeps a preferred display column for vertical movement and
  scrolls vertically and horizontally.
- No clipboard dependency: copy and cut store text in `state.clipboard` and
  raise the `text.copy`/`text.cut` action; paste comes from bracketed `Paste`
  events or `state.insertText`.

## Compound controls

- **Form** (`FormState`, `Form`): labels, help, required markers (`*`),
  synchronous field validators (`nonEmpty`, `minGraphemes`, or any
  `proc(value: string): string` added with `addValidator`), form-level
  validators returning `FormIssue` values, and external errors set with
  `setExternalError` (cleared when the field is edited). Validation timing is
  `OnChange`, `OnBlur` (default) or `OnSubmit`. Errors show after blur or a
  submit attempt and always start with `✗`. Enter in a single-line field moves
  to the next field and submits from the last. Submit validates everything and
  focuses the first invalid field; a success returns `form.submit`. Reset
  restores initial values and clears touched state and errors.
- **Palette** (`PaletteState`, `CommandRegistry`, `Palette`): a modal query
  input over commands with stable IDs, labels, descriptions, optional shortcut
  hints and an enabled flag. `fuzzyMatch` is a case-insensitive grapheme
  subsequence match on the label; its scoring is documented on the proc.
  `rank` sorts by score, then label length in clusters, then registration
  order. Enter or a click on an enabled command closes the palette and returns
  the command's action once, with the command ID as subject; Escape or a press
  outside returns `palette.dismiss`. Focus returns to the control focused
  before opening.
- **Tree** (`TreeState`, `TreeView`, `TreeItem`): application-owned data with
  unique node IDs; only expanded nodes' children are visited. Up/Down,
  Home/End and PageUp/PageDown move; Right expands or enters; Left collapses or
  selects the parent; Space toggles; Enter or a click on the selected row
  returns `list.activate` with the node ID. Selection follows a collapsed
  ancestor and, when its node disappears, moves to the row that took its index.
- **Dialog** (`DialogState`, `Dialog`): a centered, clipped rounded block with
  title, body, buttons and an optional dimmed backdrop in a modal scope.
  `beginDialog`/`endDialog` render extra controls inside the body. Enter and
  Escape map to the `accept` and `cancel` buttons; Left/Right move between
  buttons. A press outside is swallowed, or cancels with `dismissOnOutside`.
  Opening animation is the caller-supplied `reveal` progress, normally a
  `Tween[float]` value with the `Decorative` role so reduced motion completes
  it at once.
- **Button** (`ButtonState`, `Button`): Enter, Space, or a left click released
  over it returns `button.press`. Focus shows `▸ label ◂`, not only color.

## Limitations

- No IME composition events: the parser delivers committed text only.
- No system clipboard; copy and cut use `state.clipboard`. Masked fields never
  copy or cut.
- Validators are synchronous. Async checks set `setExternalError` later.
- Text areas do not soft-wrap; long lines scroll horizontally.
- Keymaps have no multi-chord sequences or configuration file format.
