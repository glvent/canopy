## Tree view over application-owned data (Canopy extension).
import std/[options, sets, strutils]

import "../widgets/block"
import ./common
export common, sets, `block`

type
  TreeItem* = object
    ## Application-owned node. IDs must be unique within the tree.
    id*: ControlId
    label*: string
    children*: seq[TreeItem]
  TreeRow* = object
    id*: ControlId
    label*: string
    depth*: int
    hasChildren*, expanded*: bool
    parent*: Option[ControlId]
  TreeState* = object
    id*: ControlId
    enabled*: bool
    expanded*: HashSet[ControlId]
    selected*: Option[ControlId]
    offset*: int ## First visible row.
    keymap*: Keymap
    area*: Rect ## Rows area of the last render.
    rows: seq[TreeRow]
    selectedIndex: int
    reveal: bool ## Scroll to the selection at the next render; wheel scrolling clears it.
    markerWidth, indent: int
  TreeView* = object
    theme*: ControlTheme
    indent*: int ## Cells per depth level. Default 2.
    blk*: Option[Block]

func treeItem*(id: string, label: string, children: openArray[TreeItem] = []): TreeItem =
  TreeItem(id: controlId(id), label: label, children: @children)

func initTreeState*(id: ControlId, enabled = true): TreeState =
  TreeState(id: id, enabled: enabled, reveal: true)

func initTreeView*(theme = defaultTheme()): TreeView = TreeView(theme: theme, indent: 2)
func withBlock*(w: TreeView, b: Block): TreeView =
  result = w
  result.blk = some(b)

proc flatten(items: openArray[TreeItem], expanded: HashSet[ControlId], depth: int,
    parent: Option[ControlId], rows: var seq[TreeRow]) =
  for item in items:
    let open = item.id in expanded and item.children.len > 0
    rows.add TreeRow(id: item.id, label: item.label, depth: depth,
      hasChildren: item.children.len > 0, expanded: open, parent: parent)
    if open: flatten(item.children, expanded, depth+1, some(item.id), rows)

proc findPath(items: openArray[TreeItem], id: ControlId, path: var seq[ControlId]): bool =
  for item in items:
    path.add item.id
    if item.id == id or findPath(item.children, id, path): return true
    path.setLen(path.len-1)

func rows*(state: TreeState): lent seq[TreeRow] = state.rows
  ## Visible rows computed by the last `sync`.

func rowIndex(state: TreeState, id: ControlId): int =
  for i, row in state.rows:
    if row.id == id: return i
  -1

proc sync*(state: var TreeState, items: openArray[TreeItem]) =
  ## Recomputes visible rows and repairs the selection: a node hidden by a collapsed ancestor
  ## selects that ancestor; a removed node selects the row that took its index (clamped).
  ## Called by `render` and `handle`; call it after changing the data between frames.
  state.rows.setLen(0)
  flatten(items, state.expanded, 0, none(ControlId), state.rows)
  if state.rows.len == 0:
    state.selected = none(ControlId)
    state.selectedIndex = 0
    return
  var index = if state.selected.isSome: state.rowIndex(state.selected.get) else: -1
  if index < 0 and state.selected.isSome:
    var path: seq[ControlId]
    if findPath(items, state.selected.get, path):
      for i in countdown(path.high, 0):
        index = state.rowIndex(path[i])
        if index >= 0: break
  if index < 0: index = clamp(state.selectedIndex, 0, state.rows.high)
  if index != state.selectedIndex or state.selected != some(state.rows[index].id):
    state.reveal = true
  state.selectedIndex = index
  state.selected = some(state.rows[index].id)

proc select(state: var TreeState, index: int) =
  if state.rows.len == 0: return
  state.selectedIndex = clamp(index, 0, state.rows.high)
  state.selected = some(state.rows[state.selectedIndex].id)
  state.reveal = true

proc expand*(state: var TreeState, id: ControlId) = state.expanded.incl id
proc collapse*(state: var TreeState, id: ControlId) = state.expanded.excl id
proc toggle*(state: var TreeState, id: ControlId) =
  if id in state.expanded: state.expanded.excl id else: state.expanded.incl id

proc ensureVisible(state: var TreeState, height: int) =
  if height <= 0: return
  if state.selectedIndex < state.offset: state.offset = state.selectedIndex
  elif state.selectedIndex >= state.offset+height:
    state.offset = state.selectedIndex-height+1
  state.offset = clamp(state.offset, 0, max(0, state.rows.len-height))

proc render*(w: TreeView, area: Rect, buf: var Buffer, state: var TreeState,
    items: openArray[TreeItem], focused = false) =
  ## Rows show `▸`/`▾` for collapsible nodes; the selected row carries the theme marker so
  ## selection is not shown by color alone.
  state.sync(items)
  var inner = area
  if w.blk.isSome:
    var b = w.blk.get
    if focused: b = b.withBorderStyle(w.theme.focusedBorder)
    b.render(area, buf)
    inner = b.inner(area)
  state.area = inner
  inner = inner.intersection(buf.area)
  if inner.isEmpty: return
  if state.reveal:
    state.ensureVisible(inner.height)
    state.reveal = false
  state.offset = clamp(state.offset, 0, max(0, state.rows.len-inner.height))
  let markerWidth = displayWidth(w.theme.marker)
  state.markerWidth = markerWidth
  state.indent = w.indent
  for row in 0..<inner.height:
    let i = state.offset+row
    if i >= state.rows.len: break
    let r = state.rows[i]
    let selected = i == state.selectedIndex
    var style = if state.enabled: w.theme.text else: w.theme.disabled
    if selected and focused: style = style.patch(w.theme.highlight)
    let y = inner.y+row
    buf.setStyle(initRect(inner.x, y, inner.width, 1), style)
    var x = inner.x
    let marker = if selected: w.theme.marker else: spaces(markerWidth)
    x += buf.writeClipped(x, y, marker, inner.right-x, style)
    x = min(inner.right, x+r.depth*w.indent)
    let glyph = if not r.hasChildren: "  " elif r.expanded: "▾ " else: "▸ "
    x += buf.writeClipped(x, y, glyph, inner.right-x, style)
    buf.writeClipped(x, y, clipText(r.label, inner.right-x), inner.right-x, style)

proc renderControl*(frame: var Frame, fm: var FocusManager, w: TreeView, area: Rect,
    state: var TreeState, items: openArray[TreeItem]) =
  fm.register(state.id, area, state.enabled)
  w.render(area, frame.buffer[], state, items, fm.isFocused(state.id))

proc handle*(state: var TreeState, items: openArray[TreeItem], route: Route,
    keymap: Keymap = standardKeymap): EventResult =
  ## Up/Down/Home/End/PageUp/PageDown move, Right expands or enters, Left collapses or goes to
  ## the parent, Space toggles. Enter or a click on a selected row emits `list.activate` with
  ## the node ID as subject. Clicking the expander glyph toggles.
  if not route.targets(state.id) or not state.enabled: return
  state.sync(items)
  if state.rows.len == 0: return
  let page = max(1, state.area.height)
  let before = state.selectedIndex
  let event = route.event
  case event.kind
  of EventKind.Key:
    if not event.isPress: return
    let action = resolve([state.keymap, keymap], [TreeContext, ListContext], event)
    if action.isNone: return
    let a = action.get
    let row = state.rows[state.selectedIndex]
    if a == ListPrevious: state.select(state.selectedIndex-1)
    elif a == ListNext: state.select(state.selectedIndex+1)
    elif a == ListFirst: state.select(0)
    elif a == ListLast: state.select(state.rows.high)
    elif a == ListPageUp: state.select(state.selectedIndex-page)
    elif a == ListPageDown: state.select(state.selectedIndex+page)
    elif a == TreeExpand:
      if row.hasChildren and not row.expanded:
        state.expand(row.id)
        state.sync(items)
        return EventResult(consumed: true, redraw: true, changed: true)
      elif row.expanded: state.select(state.selectedIndex+1)
    elif a == TreeCollapse:
      if row.expanded:
        state.collapse(row.id)
        state.sync(items)
        return EventResult(consumed: true, redraw: true, changed: true)
      elif row.parent.isSome: state.select(state.rowIndex(row.parent.get))
    elif a == TreeToggle:
      if not row.hasChildren: return consumed(false)
      state.toggle(row.id)
      state.sync(items)
      return EventResult(consumed: true, redraw: true, changed: true)
    elif a == ListActivate: return emitted(ListActivate, $row.id)
    else: return
    state.ensureVisible(page)
    return consumed(state.selectedIndex != before)
  of EventKind.Mouse:
    let m = event.mouse
    case m.kind
    of MouseEventKind.ScrollUp:
      state.offset = max(0, state.offset-3); return consumed()
    of MouseEventKind.ScrollDown:
      state.offset = clamp(state.offset+3, 0, max(0, state.rows.len-page)); return consumed()
    of MouseEventKind.Down:
      if m.button != some(MouseButton.Left): return
      let i = state.offset+m.row-state.area.y
      if i < 0 or i >= state.rows.len: return consumed(false)
      let r = state.rows[i]
      let wasSelected = i == state.selectedIndex
      state.select(i)
      let glyphX = state.area.x+state.markerWidth+r.depth*state.indent
      if r.hasChildren and m.column in glyphX..glyphX+1:
        state.toggle(r.id)
        state.sync(items)
        return EventResult(consumed: true, redraw: true, changed: true)
      if wasSelected: return emitted(ListActivate, $r.id)
      return consumed()
    else: discard
  else: discard
