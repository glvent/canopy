## Multiline Unicode text area with vertical and horizontal scrolling (Canopy extension).
import std/options

import ./[common, editing, textinput]
export common, editing, textinput

type
  TextAreaState* = object
    id*: ControlId
    editor*: Editor
    enabled*, readOnly*: bool
    keymap*: Keymap ## Override layer searched before the keymap passed to `handle`.
    clipboard*: string
    top*: int ## First visible line.
    scroll*: int ## Horizontal scroll in cells.
    area*: Rect ## Text area of the last render.
    cursor*: Option[Position]
    reveal: bool
    seenRevision: int
    seenCursor: TextPos
  TextArea* = object
    placeholder*: string
    theme*: ControlTheme
    invalid*: bool
    scrollMargin*: int
    blk*: Option[Block]

func initTextAreaState*(id: ControlId, text = "", enabled = true, readOnly = false,
    undoLimit = 100, tabWidth = 4, maxGraphemes = 0): TextAreaState =
  TextAreaState(id: id, enabled: enabled, readOnly: readOnly, reveal: true, seenRevision: -1,
    editor: initEditor(text, true, undoLimit, tabWidth, maxGraphemes = maxGraphemes))

func text*(s: TextAreaState): string = s.editor.text
proc setText*(s: var TextAreaState, text: string) =
  s.editor.setText(text)
  s.reveal = true

proc insertText*(s: var TextAreaState, text: string): bool {.discardable.} =
  if s.readOnly: return false
  s.reveal = true
  s.editor.insertText(text)

func initTextArea*(placeholder = "", theme = defaultTheme()): TextArea =
  TextArea(placeholder: placeholder, theme: theme, scrollMargin: 2)

func withPlaceholder*(w: TextArea, text: string): TextArea =
  result = w
  result.placeholder = text

func withTheme*(w: TextArea, theme: ControlTheme): TextArea =
  result = w
  result.theme = theme

func withInvalid*(w: TextArea, invalid = true): TextArea =
  result = w
  result.invalid = invalid

func withBlock*(w: TextArea, b: Block): TextArea =
  result = w
  result.blk = some(b)

proc render*(w: TextArea, area: Rect, buf: var Buffer, state: var TextAreaState,
    focused = false) =
  ## Scrolls to the cursor after it moved or the text changed; otherwise keeps the wheel
  ## position.
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
  buf.setStyle(inner, style)
  template e: untyped = state.editor
  let cursor = e.cursor
  if e.revision != state.seenRevision or cursor != state.seenCursor: state.reveal = true
  state.seenRevision = e.revision
  state.seenCursor = cursor
  let line = e.line(cursor.line)
  let cursorColumn = columnOf(line, cursor.col)
  if state.reveal:
    if cursor.line < state.top: state.top = cursor.line
    elif cursor.line >= state.top+inner.height: state.top = cursor.line-inner.height+1
    state.scroll = followCursor(state.scroll, cursorColumn, columnOf(line, line.len),
      inner.width, w.scrollMargin)
    state.reveal = false
  state.top = clamp(state.top, 0, max(0, e.lineCount-inner.height))
  if e.isEmpty and w.placeholder.len > 0:
    buf.writeClipped(inner.x, inner.y, w.placeholder, inner.width,
      style.patch(w.theme.placeholder))
  else:
    let (a, b) = e.selection
    let selecting = focused and a != b
    for row in 0..<inner.height:
      let i = state.top+row
      if i >= e.lineCount: break
      var selFrom, selTo = -1
      var trailing = false
      if selecting and i >= a.line and i <= b.line:
        selFrom = if i == a.line: a.col else: 0
        selTo = if i == b.line: b.col else: e.line(i).len
        trailing = i < b.line
      renderTextLine(buf, inner.x, inner.y+row, inner.width, e.line(i), state.scroll, selFrom,
        selTo, trailing, "", style, w.theme.selection)
  let visible = cursor.line >= state.top and cursor.line < state.top+inner.height and
    cursorColumn >= state.scroll and cursorColumn < state.scroll+inner.width
  if focused and state.enabled and not state.readOnly and visible:
    state.cursor = some(initPosition(inner.x+cursorColumn-state.scroll,
      inner.y+cursor.line-state.top))

proc renderControl*(frame: var Frame, fm: var FocusManager, w: TextArea, area: Rect,
    state: var TextAreaState) =
  fm.register(state.id, area, state.enabled, textEntry = state.enabled and not state.readOnly)
  w.render(area, frame.buffer[], state, fm.isFocused(state.id))
  if state.cursor.isSome: frame.setCursorPosition(state.cursor.get)

proc scrollBy*(state: var TextAreaState, lines: int) =
  ## Scrolls the view without moving the cursor; rendering clamps the result.
  state.top = max(0, state.top+lines)

proc handle*(state: var TextAreaState, route: Route,
    keymap: Keymap = standardKeymap): EventResult =
  ## Enter inserts a line break; Tab is never consumed so focus traversal keeps working.
  ## The wheel scrolls three lines.
  if not route.targets(state.id) or not state.enabled: return
  let event = route.event
  if event.kind == EventKind.Mouse:
    let m = event.mouse
    case m.kind
    of MouseEventKind.ScrollUp: state.scrollBy(-3); return consumed()
    of MouseEventKind.ScrollDown: state.scrollBy(3); return consumed()
    of MouseEventKind.Down, MouseEventKind.Drag:
      if m.button != some(MouseButton.Left): return
      let row = clamp(state.top+m.row-state.area.y, 0, state.editor.lineCount-1)
      let column = max(0, state.scroll+m.column-state.area.x)
      let extend = m.kind == MouseEventKind.Drag or KeyModifier.Shift in m.modifiers
      state.editor.moveTo(pos(row, colAtColumn(state.editor.line(row), column)), extend)
      return consumed()
    else: return
  handleText(state.editor, route, [TextAreaContext, TextContext], [state.keymap, keymap],
    state.readOnly, state.clipboard, state.id, max(1, state.area.height), "")
