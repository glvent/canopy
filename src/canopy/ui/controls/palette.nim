## Command registry, fuzzy ranking and a modal command palette (Canopy extension).
import std/[algorithm, options, strutils, unicode]

import "../widgets/block"
import ./[common, textinput]
export common, textinput

type
  Command* = object
    id*: ControlId
    label*, description*: string
    shortcut*: string ## Hint text, such as `$chord`; display only.
    enabled*: bool
    action*: ActionId
  CommandRegistry* = object
    commands: seq[Command]
    revision: int
  PaletteMatch* = object
    index*: int ## Position in the registry.
    score*: int
    positions*: seq[int] ## Matched label cluster indices.
  PaletteState* = object
    id*: ControlId
    query*: TextInputState ## ID `<palette>/query`.
    selected*: int
    offset*: int
    keymap*: Keymap
    isOpen: bool
    matches: seq[PaletteMatch]
    seenQuery, seenRegistry: int
    area: Rect
  Palette* = object
    title*: string
    placeholder*: string
    theme*: ControlTheme
    maxRows*: int ## Result rows shown at most. Default 10.
    width*: int ## Popup width; 0 picks up to 64 cells.

func command*(id: string, label: string, action: ActionId, description = "", shortcut = "",
    enabled = true): Command =
  Command(id: controlId(id), label: label, description: description, shortcut: shortcut,
    enabled: enabled, action: action)

func initCommandRegistry*(commands: openArray[Command] = []): CommandRegistry =
  for c in commands:
    for existing in result.commands:
      if existing.id == c.id: raise newException(ValueError, "Duplicate command ID: " & $c.id)
    result.commands.add c

proc add*(r: var CommandRegistry, c: Command) =
  ## Raises `ValueError` for a duplicate command ID.
  for existing in r.commands:
    if existing.id == c.id: raise newException(ValueError, "Duplicate command ID: " & $c.id)
  r.commands.add c
  inc r.revision

proc setEnabled*(r: var CommandRegistry, id: ControlId, enabled: bool) =
  for c in r.commands.mitems:
    if c.id == id:
      c.enabled = enabled
      inc r.revision

func len*(r: CommandRegistry): int = r.commands.len
func `[]`*(r: CommandRegistry, i: int): Command = r.commands[i]
iterator items*(r: CommandRegistry): Command =
  for c in r.commands: yield c

# Ranking.

func fold(cluster: string): string = unicode.toLower(cluster)

func isWordChar(cluster: string): bool =
  if cluster.len == 0: return false
  let r = cluster.runeAt(0)
  r.isAlpha or cluster[0] in {'0'..'9'}

func isWordStart(clusters: seq[string], i: int): bool =
  if i == 0: return true
  if not clusters[i-1].isWordChar: return true
  let a = clusters[i-1].runeAt(0)
  let b = clusters[i].runeAt(0)
  a.isLower and b.isUpper

func fuzzyMatch*(query, label: string): Option[PaletteMatch] =
  ## Case-insensitive grapheme subsequence match; whitespace in the query is ignored.
  ## Every label position matching the first query cluster is tried as a start, the rest is
  ## matched greedily, and the best score wins (ties: earliest start). For matched cluster
  ## indices p1..pk the score sums, per match, 1, plus 6 when p is 0, plus 3 at a word start,
  ## plus 4 when p directly follows the previous match; then subtracts the unmatched clusters
  ## between p1 and pk. A word start follows a non-alphanumeric
  ## cluster or is an uppercase letter after a lowercase one.
  var q: seq[string]
  for cluster in graphemes(query):
    if cluster.len > 0 and not cluster.runeAt(0).isWhiteSpace: q.add fold(cluster)
  if q.len == 0: return some(PaletteMatch())
  var ascii = true
  for c in label:
    if c < ' ' or c > '~': ascii = false; break
  var clusters, folded: seq[string]
  if ascii:
    # Fast path: each printable ASCII byte is one cluster.
    clusters = newSeq[string](label.len)
    folded = newSeq[string](label.len)
    for i, c in label:
      clusters[i] = $c
      folded[i] = $toLowerAscii(c)
  else:
    clusters = graphemes(label)
    folded = newSeq[string](clusters.len)
    for i, c in clusters: folded[i] = fold(c)
  # Cheap rejection before scoring every start.
  var k = 0
  for f in folded:
    if k < q.len and f == q[k]: inc k
  if k < q.len: return none(PaletteMatch)
  var best = none(PaletteMatch)
  for start in 0..clusters.high:
    if folded[start] != q[0]: continue
    var positions = @[start]
    var j = start+1
    for k in 1..q.high:
      while j < folded.len and folded[j] != q[k]: inc j
      if j >= folded.len: break
      positions.add j
      inc j
    if positions.len < q.len: break # later starts cannot match more
    var score = 0
    for n, p in positions:
      score += 1
      if p == 0: score += 6
      if clusters.isWordStart(p): score += 3
      if n > 0 and p == positions[n-1]+1: score += 4
    score -= positions[^1]-positions[0]+1-positions.len
    if best.isNone or score > best.get.score:
      best = some(PaletteMatch(score: score, positions: positions))
  best

func rank*(registry: CommandRegistry, query: string): seq[PaletteMatch] =
  ## Matching commands by score, then label length in clusters, then registration order. An
  ## empty query lists every command in registration order.
  var keyed: seq[tuple[score, length, index: int, match: PaletteMatch]]
  for i, c in registry.commands:
    var m = fuzzyMatch(query, c.label)
    if m.isNone: continue
    m.get.index = i
    keyed.add (-m.get.score, clusterCount(c.label), i, m.get)
  keyed.sort(proc(a, b: auto): int = cmp((a.score, a.length, a.index),
    (b.score, b.length, b.index)))
  for k in keyed: result.add k.match

# State.

func initPaletteState*(id: ControlId): PaletteState =
  PaletteState(id: id, query: initTextInputState(id.child("query")), seenQuery: -1,
    seenRegistry: -1)

func isOpen*(s: PaletteState): bool = s.isOpen
func resultsId*(s: PaletteState): ControlId = s.id.child("results")

proc open*(s: var PaletteState, fm: var FocusManager) =
  ## Clears the query and opens the palette as the top modal with the query focused.
  s.isOpen = true
  s.query.setText("")
  s.selected = 0
  s.offset = 0
  s.seenQuery = -1
  fm.openModal(s.id, some(s.query.id))

proc close*(s: var PaletteState, fm: var FocusManager) =
  s.isOpen = false
  fm.closeModal(s.id)

proc refresh(s: var PaletteState, registry: CommandRegistry) =
  if s.seenQuery == s.query.editor.revision and s.seenRegistry == registry.revision: return
  let queryChanged = s.seenQuery != s.query.editor.revision
  s.matches = registry.rank(s.query.text)
  s.seenQuery = s.query.editor.revision
  s.seenRegistry = registry.revision
  if queryChanged: s.selected = 0; s.offset = 0
  s.selected = clamp(s.selected, 0, max(0, s.matches.high))

proc matches*(s: var PaletteState, registry: CommandRegistry): lent seq[PaletteMatch] =
  s.refresh(registry)
  s.matches

proc selectedCommand*(s: var PaletteState, registry: CommandRegistry): Option[Command] =
  s.refresh(registry)
  if s.selected in 0..s.matches.high: some(registry[s.matches[s.selected].index])
  else: none(Command)

# Widget.

func initPalette*(title = "Commands", placeholder = "Type a command",
    theme = defaultTheme()): Palette =
  Palette(title: title, placeholder: placeholder, theme: theme, maxRows: 10)

func popupArea*(p: Palette, area: Rect, rows: int): Rect =
  let width = min(area.width, if p.width > 0: p.width else: min(64, max(20, area.width-8)))
  let height = min(area.height, 3+max(1, min(rows, p.maxRows)))
  let x = area.x+(area.width-width) div 2
  let y = area.y+max(0, min((area.height-height) div 3, 4))
  initRect(x, y, width, height)

proc renderControl*(frame: var Frame, fm: var FocusManager, p: Palette, area: Rect,
    state: var PaletteState, registry: CommandRegistry) =
  ## Renders the open palette over `area` inside its modal scope; does nothing when closed.
  if not state.isOpen: return
  state.refresh(registry)
  var buf = addr frame.buffer[]
  let popup = p.popupArea(area, state.matches.len)
  buf[].clearArea(popup)
  let outline = borderedBlock().withBorderType(BorderType.Rounded).withTitle(" " & p.title & " ")
    .withBorderStyle(p.theme.focusedBorder)
  outline.render(popup, buf[])
  let inner = outline.inner(popup)
  fm.withScope(state.id, popup, true):
    if inner.height > 0:
      let prompt = "› "
      let used = buf[].writeClipped(inner.x, inner.y, prompt, inner.width, p.theme.focusedBorder)
      frame.renderControl(fm, initTextInput(p.placeholder, p.theme),
        initRect(inner.x+used, inner.y, max(0, inner.width-used), 1), state.query)
    let rows = initRect(inner.x, inner.y+1, inner.width, max(0, inner.height-1))
    state.area = rows
    fm.register(state.resultsId, rows, tabStop = false)
    if state.matches.len == 0 and rows.height > 0:
      buf[].writeClipped(rows.x+2, rows.y, "No matching commands", rows.width-2, p.theme.help)
    if state.selected < state.offset: state.offset = state.selected
    elif state.selected >= state.offset+rows.height:
      state.offset = state.selected-rows.height+1
    state.offset = clamp(state.offset, 0, max(0, state.matches.len-rows.height))
    for row in 0..<rows.height:
      let i = state.offset+row
      if i >= state.matches.len: break
      let m = state.matches[i]
      let c = registry[m.index]
      let y = rows.y+row
      let selected = i == state.selected
      var base = if c.enabled: p.theme.text else: p.theme.disabled
      if selected: base = base.patch(p.theme.highlight)
      buf[].setStyle(initRect(rows.x, y, rows.width, 1), base)
      var x = rows.x+buf[].writeClipped(rows.x, y, if selected: p.theme.marker else: "  ",
        rows.width, base)
      let hint = if not c.enabled: "unavailable" else: c.shortcut
      let hintWidth = if hint.len > 0: displayWidth(hint)+1 else: 0
      let labelRight = rows.right-hintWidth
      var cluster = 0
      var mi = 0
      for g in graphemes(c.label):
        let w = cellWidth(g)
        if x+w > labelRight: break
        var s = base
        if mi < m.positions.len and m.positions[mi] == cluster:
          s = s.patch(p.theme.match)
          inc mi
        buf[].setStringn(x, y, g, w, s)
        x += w
        inc cluster
      if c.description.len > 0 and x+3 < labelRight:
        x += 2
        buf[].writeClipped(x, y, clipText(c.description, labelRight-x), labelRight-x,
          base.patch(p.theme.help))
      if hintWidth > 0 and hintWidth < rows.width:
        buf[].writeClipped(rows.right-hintWidth+1, y, hint, hintWidth-1,
          base.patch(p.theme.shortcut))

proc execute(s: var PaletteState, registry: CommandRegistry, fm: var FocusManager): EventResult =
  let c = s.selectedCommand(registry)
  if c.isNone or not c.get.enabled: return consumed(false)
  s.close(fm)
  emitted(c.get.action, $c.get.id)

proc handle*(state: var PaletteState, registry: CommandRegistry, fm: var FocusManager,
    route: Route, keymap: Keymap = standardKeymap): EventResult =
  ## While open, the palette owns every event routed inside it. Enter on an enabled command
  ## closes the palette and returns the command's action with its ID as subject; Escape or a
  ## press outside returns `palette.dismiss`. Up/Down/PageUp/PageDown and Ctrl+P/Ctrl+N move
  ## through results; other keys edit the query.
  if not state.isOpen or route.modal != some(state.id): return
  state.refresh(registry)
  let event = route.event
  let page = max(1, state.area.height)
  case event.kind
  of EventKind.Mouse:
    let m = event.mouse
    if not route.insideModal:
      if m.kind == MouseEventKind.Down:
        state.close(fm)
        return emitted(PaletteDismiss, $state.id)
      return consumed(false)
    if route.targets(state.resultsId):
      case m.kind
      of MouseEventKind.ScrollUp: state.selected = max(0, state.selected-1); return consumed()
      of MouseEventKind.ScrollDown:
        state.selected = clamp(state.selected+1, 0, max(0, state.matches.high))
        return consumed()
      of MouseEventKind.Down:
        # The results list is never a typing target: keep the query focused.
        discard fm.focus(state.query.id)
        let i = state.offset+m.row-state.area.y
        if m.button != some(MouseButton.Left) or i notin 0..state.matches.high:
          return consumed(false)
        state.selected = i
        return state.execute(registry, fm)
      else: return consumed(false)
    result = state.query.handle(route, keymap)
    if not result.consumed: result = consumed(false)
  of EventKind.Key:
    if not event.isPress: return
    let own = resolve([state.keymap, keymap], [PaletteContext], event, textEntry = true)
    if own == some(PaletteDismiss):
      state.close(fm)
      return emitted(PaletteDismiss, $state.id)
    if own == some(PaletteExecute): return state.execute(registry, fm)
    let nav = resolve([state.keymap, keymap], [ListContext], event, textEntry = true)
    if nav.isSome and nav.get in [ListPrevious, ListNext, ListPageUp, ListPageDown]:
      let before = state.selected
      let delta = if nav.get == ListPrevious: -1 elif nav.get == ListNext: 1
        elif nav.get == ListPageUp: -page else: page
      state.selected = clamp(state.selected+delta, 0, max(0, state.matches.high))
      return consumed(before != state.selected)
    if route.targets(state.query.id):
      result = state.query.handle(route, keymap)
      if result.changed: state.refresh(registry)
  of EventKind.Paste:
    if route.targets(state.query.id):
      result = state.query.handle(route, keymap)
      if result.changed: state.refresh(registry)
  else: discard
