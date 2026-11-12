## Single-line Unicode text input (Canopy extension).
import std/[options, unicode]

import "../widgets/block"
import ./[common, editing]
export common, editing, `block`

type
  TextInputState* = object
    ## Application-owned editor state. `enabled`, `readOnly` and `mask` affect behavior, so they
    ## live here rather than on the widget. Fields after `clipboard` are written by rendering.
    id*: ControlId
    editor*: Editor
    enabled*, readOnly*: bool
    mask*: string ## Shown in place of every cluster when not empty (passwords).
    keymap*: Keymap ## Override layer searched before the keymap passed to `handle`.
    clipboard*: string ## Internal clipboard filled by copy and cut.
    scroll*: int ## Horizontal scroll in cells.
    area*: Rect ## Text area of the last render, for pointer mapping.
    cursor*: Option[Position] ## Terminal cursor after the last render, when editable and focused.
  TextInput* = object
    placeholder*: string
    theme*: ControlTheme
    invalid*: bool
    scrollMargin*: int ## Cells kept visible around the cursor when scrolling. Default 2.
    blk*: Option[Block]

func initTextInputState*(id: ControlId, text = "", enabled = true, readOnly = false,
    mask = "", undoLimit = 100, tabWidth = 4, newlinePolicy = NewlinePolicy.Space,
    maxGraphemes = 0): TextInputState =
  TextInputState(id: id, enabled: enabled, readOnly: readOnly, mask: mask,
    editor: initEditor(text, false, undoLimit, tabWidth, newlinePolicy, maxGraphemes))

func text*(s: TextInputState): string = s.editor.text
proc setText*(s: var TextInputState, text: string) = s.editor.setText(text)
proc insertText*(s: var TextInputState, text: string): bool {.discardable.} =
  ## Inserts text as a paste would, for example from a system clipboard the application reads.
  if s.readOnly: return false
  s.editor.insertText(text)

func initTextInput*(placeholder = "", theme = defaultTheme()): TextInput =
  TextInput(placeholder: placeholder, theme: theme, scrollMargin: 2)
func withPlaceholder*(w: TextInput, text: string): TextInput =
  result = w
  result.placeholder = text
func withTheme*(w: TextInput, theme: ControlTheme): TextInput =
  result = w
  result.theme = theme
func withInvalid*(w: TextInput, invalid = true): TextInput =
  result = w
  result.invalid = invalid
func withBlock*(w: TextInput, b: Block): TextInput =
  result = w
  result.blk = some(b)
func withScrollMargin*(w: TextInput, margin: int): TextInput =
  result = w
  result.scrollMargin = max(0, margin)

# Shared editing logic for TextInput and TextArea.

func isPrivateUse(text: string): bool =
  ## Kitty reports some functional keys as private-use code points; they are not text.
  if text.len == 0: return false
  let r = text.runeAt(0).int32
  r in 0xE000..0xF8FF

proc applyTextAction*(e: var Editor, action: ActionId, readOnly: bool, clipboard: var string,
    id: ControlId, page: int, mask: string): EventResult =
  ## Applies a standard text action. Used by `TextInput` and `TextArea`.
  template moved(body: untyped) =
    let before = (e.cursor, e.anchor)
    body
    return consumed(before != (e.cursor, e.anchor))
  template edited(body: untyped) =
    if readOnly: return consumed(false)
    let changed = body
    return EventResult(consumed: true, redraw: changed, changed: changed)
  if action == TextLeft: moved(e.moveLeft())
  elif action == TextRight: moved(e.moveRight())
  elif action == TextWordLeft: moved(e.moveWordLeft())
  elif action == TextWordRight: moved(e.moveWordRight())
  elif action == TextHome: moved(e.moveHome())
  elif action == TextEnd: moved(e.moveEnd())
  elif action == TextUp: moved(e.moveLines(-1, mask = mask))
  elif action == TextDown: moved(e.moveLines(1, mask = mask))
  elif action == TextPageUp: moved(e.moveLines(-max(1, page-1), mask = mask))
  elif action == TextPageDown: moved(e.moveLines(max(1, page-1), mask = mask))
  elif action == TextDocumentStart: moved(e.moveDocumentStart())
  elif action == TextDocumentEnd: moved(e.moveDocumentEnd())
  elif action == TextSelectLeft: moved(e.moveLeft(true))
  elif action == TextSelectRight: moved(e.moveRight(true))
  elif action == TextSelectWordLeft: moved(e.moveWordLeft(true))
  elif action == TextSelectWordRight: moved(e.moveWordRight(true))
  elif action == TextSelectHome: moved(e.moveHome(true))
  elif action == TextSelectEnd: moved(e.moveEnd(true))
  elif action == TextSelectUp: moved(e.moveLines(-1, true, mask))
  elif action == TextSelectDown: moved(e.moveLines(1, true, mask))
  elif action == TextSelectDocumentStart: moved(e.moveDocumentStart(true))
  elif action == TextSelectDocumentEnd: moved(e.moveDocumentEnd(true))
  elif action == TextSelectAll: moved(e.selectAll())
  elif action == TextBackspace: edited(e.backspace())
  elif action == TextDelete: edited(e.deleteForward())
  elif action == TextDeleteWordLeft: edited(e.deleteWordLeft())
  elif action == TextDeleteWordRight: edited(e.deleteWordRight())
  elif action == TextUndo: edited(e.undo())
  elif action == TextRedo: edited(e.redo())
  elif action == TextNewline: edited(e.insertText("\n"))
  elif action == TextPaste: edited(e.insertText(clipboard))
  elif action == TextCopy:
    # A masked field never exposes its text through copy or cut.
    if not e.hasSelection or mask.len > 0: return consumed(false)
    clipboard = e.selectedText
    return emitted(TextCopy, $id)
  elif action == TextCut:
    if not e.hasSelection or mask.len > 0: return consumed(false)
    if readOnly: return consumed(false)
    clipboard = e.selectedText
    discard e.deleteSelection()
    result = emitted(TextCut, $id, changed = true)
  elif action == TextSubmit: return emitted(TextSubmit, $id)

proc handleText*(e: var Editor, route: Route, contexts: openArray[string],
    layers: openArray[Keymap], readOnly: bool, clipboard: var string, id: ControlId,
    page: int, mask: string): EventResult =
  ## Keyboard and paste handling shared by text controls; pointer events are handled by each.
  let event = route.event
  case event.kind
  of EventKind.Paste:
    if readOnly: return consumed(false)
    let changed = e.insertText(event.text)
    return EventResult(consumed: true, redraw: changed, changed: changed)
  of EventKind.Key:
    if not event.isPress: return
    let action = resolve(layers, contexts, event, textEntry = not readOnly)
    if action.isSome:
      return applyTextAction(e, action.get, readOnly, clipboard, id, page, mask)
    let chord = chordOf(event.key)
    if chord.isPrintable and not readOnly and not event.key.text.isPrivateUse:
      let changed = e.typeText(event.key.text)
      return EventResult(consumed: true, redraw: changed, changed: changed)
  else: discard

proc renderTextLine*(buf: var Buffer, x, y, width: int, line: string, scroll: int,
    selFrom, selTo: int, trailingSelected: bool, mask: string, style, selection: Style) =
  ## Draws the cells of `line` from display column `scroll`. Clusters cut by an edge render
  ## as blank cells so wide glyphs never straddle the area.
  if width <= 0: return
  var col = 0
  var offset = 0
  let right = scroll+width
  for cluster in graphemes(line):
    let w = cellsOf(cluster, mask)
    let selected = offset >= selFrom and offset < selTo
    let s = if selected: style.patch(selection) else: style
    if w > 0 and col+w > scroll and col < right:
      if col >= scroll and col+w <= right:
        buf.setStringn(x+col-scroll, y, if mask.len > 0: mask else: cluster, w, s)
      else:
        for c in max(col, scroll)..<min(col+w, right):
          buf[x+c-scroll, y].setSymbol(" ")
          buf[x+c-scroll, y].setStyle(s)
    col += w
    offset += cluster.len
    if col >= right: break
  if trailingSelected and col >= scroll and col < right:
    buf[x+col-scroll, y].setSymbol(" ")
    buf[x+col-scroll, y].setStyle(style.patch(selection))

func followCursor*(scroll, cursorColumn, total, width, margin: int): int =
  ## Horizontal scroll that keeps `cursorColumn` visible with `margin` cells of context.
  if width <= 0: return 0
  let m = min(margin, max(0, (width-1) div 2))
  result = scroll
  if cursorColumn < result+m: result = cursorColumn-m
  elif cursorColumn > result+width-1-m: result = cursorColumn-(width-1-m)
  result = clamp(result, 0, max(0, total+1-width))

func controlStyle*(theme: ControlTheme, enabled, readOnly, invalid, focused: bool): Style =
  result = theme.text
  if focused: result = result.patch(theme.focused)
  if readOnly: result = result.patch(theme.readOnly)
  if invalid: result = result.patch(theme.invalid)
  if not enabled: result = theme.disabled

# TextInput.

proc render*(w: TextInput, area: Rect, buf: var Buffer, state: var TextInputState,
    focused = false) =
  var inner = area
  if w.blk.isSome:
    var b = w.blk.get
    if focused: b = b.withBorderStyle(w.theme.focusedBorder)
    elif w.invalid: b = b.withBorderStyle(w.theme.error)
    b.render(area, buf)
    inner = b.inner(area)
  state.area = inner
  state.cursor = none(Position)
  inner = inner.intersection(buf.area)
  if inner.isEmpty: return
  let style = controlStyle(w.theme, state.enabled, state.readOnly, w.invalid, focused)
  let row = initRect(inner.x, inner.y, inner.width, 1)
  buf.setStyle(row, style)
  template e: untyped = state.editor
  let line = e.line(0)
  let cursorColumn = columnOf(line, e.cursor.col, state.mask)
  let total = columnOf(line, line.len, state.mask)
  state.scroll = followCursor(state.scroll, cursorColumn, total, inner.width, w.scrollMargin)
  if e.isEmpty and w.placeholder.len > 0:
    buf.writeClipped(inner.x, inner.y, w.placeholder, inner.width,
      style.patch(w.theme.placeholder))
  else:
    let (a, b) = e.selection
    let selFrom = if focused and a != b: a.col else: -1
    let selTo = if focused and a != b: b.col else: -1
    renderTextLine(buf, inner.x, inner.y, inner.width, line, state.scroll, selFrom, selTo,
      false, state.mask, style, w.theme.selection)
  if focused and state.enabled and not state.readOnly:
    state.cursor = some(initPosition(inner.x+cursorColumn-state.scroll, inner.y))

proc renderControl*(frame: var Frame, fm: var FocusManager, w: TextInput, area: Rect,
    state: var TextInputState) =
  ## Registers the input and renders it; sets the frame cursor when it is focused.
  fm.register(state.id, area, state.enabled, textEntry = state.enabled and not state.readOnly)
  w.render(area, frame.buffer[], state, fm.isFocused(state.id))
  if state.cursor.isSome: frame.setCursorPosition(state.cursor.get)

proc handle*(state: var TextInputState, route: Route,
    keymap: Keymap = standardKeymap): EventResult =
  ## Handles events targeted at this input. Returns `text.submit` on Enter, and
  ## `text.copy`/`text.cut` after filling `state.clipboard`. Escape, Tab and unbound chords
  ## are not consumed.
  if not route.targets(state.id) or not state.enabled: return
  let event = route.event
  if event.kind == EventKind.Mouse:
    let m = event.mouse
    if m.button != some(MouseButton.Left) or m.kind notin {MouseEventKind.Down,
        MouseEventKind.Drag}: return
    let column = state.scroll+m.column-state.area.x
    let col = colAtColumn(state.editor.line(0), max(0, column), state.mask)
    let extend = m.kind == MouseEventKind.Drag or KeyModifier.Shift in m.modifiers
    state.editor.moveTo(pos(0, col), extend)
    return consumed()
  handleText(state.editor, route, [TextContext], [state.keymap, keymap], state.readOnly,
    state.clipboard, state.id, 1, state.mask)
