## Unicode-aware text editing model shared by `TextInput` and `TextArea` (Canopy extension).
##
## Text is stored as UTF-8 lines. Positions are byte offsets that always sit on extended
## grapheme cluster boundaries; display cells are derived only for rendering and vertical
## movement. Undo history stores edit deltas, not snapshots.
import std/[strutils, unicode]

import ../../core/text/unicode as canopyUnicode

type
  TextPos* = object
    line*, col*: int ## Line index and byte offset within it.
  NewlinePolicy* {.pure.} = enum
    Space ## Each line break becomes one space.
    Strip ## Line breaks are removed.
    FirstLine ## Only the text before the first line break is kept.
  EditKind = enum ekOther, ekInsert, ekBackspace, ekDelete
  Edit = object
    kind: EditKind
    start: TextPos
    removed, inserted: string
    before, beforeAnchor, after: TextPos
  Editor* = object
    ## Lines, cursor, selection anchor and undo history. The selection is the range between
    ## `anchor` and `cursor`; it is empty when they are equal.
    lines: seq[string]
    cursor, anchor: TextPos
    multiline: bool
    undoStack, redoStack: seq[Edit]
    sealed: bool
    preferred: int
    revision: int
    undoLimit*: int ## Maximum undo steps; the oldest are dropped. Default 100.
    tabWidth*: int ## Spaces per inserted tab. Default 4.
    newlinePolicy*: NewlinePolicy ## How a single-line editor treats inserted line breaks.
    maxGraphemes*: int ## Maximum clusters per editor; 0 means unlimited.

func `<`*(a, b: TextPos): bool = a.line < b.line or (a.line == b.line and a.col < b.col)
func `<=`*(a, b: TextPos): bool = not (b < a)
func pos*(line, col: int): TextPos = TextPos(line: line, col: col)

# UTF-8 sanitizing.

func utf8Length(s: string, i: int): int =
  ## Length of the valid UTF-8 sequence at `i`, or 0 when the bytes there are invalid
  ## (overlong forms, surrogates and values above U+10FFFF are invalid).
  let b0 = ord(s[i])
  template cont(k: int): bool = i+k < s.len and (ord(s[i+k]) and 0xC0) == 0x80
  if b0 < 0x80: return 1
  if b0 in 0xC2..0xDF: return (if cont(1): 2 else: 0)
  if b0 in 0xE0..0xEF:
    if not (cont(1) and cont(2)): return 0
    let b1 = ord(s[i+1])
    if b0 == 0xE0 and b1 < 0xA0: return 0
    if b0 == 0xED and b1 > 0x9F: return 0
    return 3
  if b0 in 0xF0..0xF4:
    if not (cont(1) and cont(2) and cont(3)): return 0
    let b1 = ord(s[i+1])
    if b0 == 0xF0 and b1 < 0x90: return 0
    if b0 == 0xF4 and b1 > 0x8F: return 0
    return 4
  0

func sanitize*(text: string, tabWidth = 4, multiline = true,
    policy = NewlinePolicy.Space): string =
  ## Makes text safe to insert: invalid UTF-8 bytes become U+FFFD, tabs become `tabWidth`
  ## spaces, CRLF and CR become LF, and other C0/C1 controls and DEL are removed. For a
  ## single-line editor, line breaks then follow `policy`.
  var i = 0
  while i < text.len:
    let n = utf8Length(text, i)
    if n == 0:
      result.add "\u{FFFD}"
      inc i
      continue
    let c = text[i]
    if n == 1:
      case c
      of '\r':
        result.add '\n'
        if i+1 < text.len and text[i+1] == '\n': inc i
      of '\n': result.add '\n'
      of '\t': result.add spaces(max(0, tabWidth))
      of '\0'..'\x08', '\x0b'..'\x0c', '\x0e'..'\x1f', '\x7f': discard
      else: result.add c
    elif n == 2 and c == '\xC2' and ord(text[i+1]) in 0x80..0x9F: discard # C1 controls
    else: result.add text[i..<i+n]
    i += n
  if not multiline:
    case policy
    of NewlinePolicy.Space: result = result.replace('\n', ' ')
    of NewlinePolicy.Strip: result = result.replace("\n", "")
    of NewlinePolicy.FirstLine:
      let cut = result.find('\n')
      if cut >= 0: result.setLen(cut)

# Grapheme boundaries and word classes.

func isPlainAscii(line: string): bool =
  ## Printable ASCII only: every byte is its own one-cell cluster.
  for c in line:
    if c < ' ' or c > '~': return false
  true

func boundaries*(line: string): seq[int] =
  ## Byte offsets of every cluster boundary, including 0 and `line.len`.
  if line.isPlainAscii:
    result = newSeq[int](line.len+1)
    for i in 0..line.len: result[i] = i
    return
  result = @[0]
  var offset = 0
  for cluster in canopyUnicode.graphemes(line):
    offset += cluster.len
    result.add offset

func clusterCount*(line: string): int =
  if line.isPlainAscii: line.len else: canopyUnicode.graphemes(line).len

func prevBoundary*(line: string, col: int): int =
  result = 0
  for b in boundaries(line):
    if b >= col: break
    result = b

func nextBoundary*(line: string, col: int): int =
  for b in boundaries(line):
    if b > col: return b
  line.len

func snapBoundary(line: string, col: int): int =
  ## Nearest boundary at or before `col`.
  result = 0
  for b in boundaries(line):
    if b > col: break
    result = b

type WordClass = enum wcSpace, wcWord, wcPunct

func classOf(cluster: string): WordClass =
  ## Readline-style class of a cluster from its first code point.
  if cluster.len == 0: return wcSpace
  let r = cluster.runeAt(0)
  if r.isWhiteSpace: wcSpace
  elif r.isAlpha or cluster[0] in {'0'..'9', '_'}: wcWord
  else: wcPunct

func clustersWithOffsets(line: string): seq[tuple[start: int, text: string]] =
  if line.isPlainAscii:
    result = newSeq[tuple[start: int, text: string]](line.len)
    for i, c in line: result[i] = (i, $c)
    return
  var offset = 0
  for cluster in canopyUnicode.graphemes(line):
    result.add (offset, cluster)
    offset += cluster.len

func wordLeftCol*(line: string, col: int): int =
  ## Start of the run before `col`: skip spaces, then one word or punctuation run.
  let clusters = clustersWithOffsets(line)
  var i = clusters.high
  while i >= 0 and clusters[i].start >= col: dec i
  while i >= 0 and classOf(clusters[i].text) == wcSpace: dec i
  if i < 0: return 0
  let cls = classOf(clusters[i].text)
  while i > 0 and classOf(clusters[i-1].text) == cls: dec i
  clusters[i].start

func wordRightCol*(line: string, col: int): int =
  ## End of the run after `col`: skip spaces, then one word or punctuation run.
  let clusters = clustersWithOffsets(line)
  var i = 0
  while i < clusters.len and clusters[i].start < col: inc i
  while i < clusters.len and classOf(clusters[i].text) == wcSpace: inc i
  if i >= clusters.len: return line.len
  let cls = classOf(clusters[i].text)
  while i < clusters.len and classOf(clusters[i].text) == cls: inc i
  if i >= clusters.len: line.len else: clusters[i].start

# Display cells.

func cellsOf*(cluster: string, mask = ""): int =
  if mask.len > 0: canopyUnicode.cellWidth(mask) else: canopyUnicode.cellWidth(cluster)

func columnOf*(line: string, col: int, mask = ""): int =
  ## Display cells before byte offset `col`.
  if line.isPlainAscii:
    let n = clamp(col, 0, line.len)
    return if mask.len > 0: n*canopyUnicode.cellWidth(mask) else: n
  for (start, cluster) in clustersWithOffsets(line):
    if start >= col: break
    result += cellsOf(cluster, mask)

func colAtColumn*(line: string, column: int, mask = ""): int =
  ## Byte offset of the boundary nearest to display `column`; a click on the right half of a
  ## wide cluster lands after it.
  if line.isPlainAscii and mask.len == 0: return clamp(column, 0, line.len)
  var x = 0
  for (start, cluster) in clustersWithOffsets(line):
    let w = cellsOf(cluster, mask)
    if column < x + (w+1) div 2: return start
    x += w
  line.len

# Editor.

func initEditor*(text = "", multiline = false, undoLimit = 100, tabWidth = 4,
    newlinePolicy = NewlinePolicy.Space, maxGraphemes = 0): Editor =
  result = Editor(multiline: multiline, undoLimit: undoLimit, tabWidth: tabWidth,
    newlinePolicy: newlinePolicy, maxGraphemes: maxGraphemes, preferred: -1, sealed: true)
  let clean = sanitize(text, tabWidth, multiline, newlinePolicy)
  result.lines = clean.split('\n')
  result.cursor = pos(result.lines.high, result.lines[^1].len)
  result.anchor = result.cursor

func lines*(e: Editor): lent seq[string] = e.lines
func lineCount*(e: Editor): int = e.lines.len
func line*(e: Editor, i: int): string = e.lines[i]
func text*(e: Editor): string = e.lines.join("\n")
func len*(e: Editor): int =
  ## Bytes in the text, counting line breaks.
  result = e.lines.len-1
  for line in e.lines: result += line.len

func isEmpty*(e: Editor): bool = e.lines.len == 1 and e.lines[0].len == 0
func cursor*(e: Editor): TextPos = e.cursor
func anchor*(e: Editor): TextPos = e.anchor
func revision*(e: Editor): int = e.revision
  ## Increments on every text change; use it to detect edits cheaply.
func multiline*(e: Editor): bool = e.multiline
func hasSelection*(e: Editor): bool = e.cursor != e.anchor
func selection*(e: Editor): tuple[first, last: TextPos] =
  if e.anchor < e.cursor: (e.anchor, e.cursor) else: (e.cursor, e.anchor)

func canUndo*(e: Editor): bool = e.undoStack.len > 0
func canRedo*(e: Editor): bool = e.redoStack.len > 0
func undoDepth*(e: Editor): int = e.undoStack.len

func offsetOf*(e: Editor, p: TextPos): int =
  ## Byte offset of `p` in `text`.
  for i in 0..<p.line: result += e.lines[i].len+1
  result += p.col

func posAt*(e: Editor, offset: int): TextPos =
  ## Position of a byte offset in `text`, snapped to a cluster boundary.
  var rest = max(0, offset)
  for i, line in e.lines:
    if rest <= line.len: return pos(i, snapBoundary(line, rest))
    rest -= line.len+1
  pos(e.lines.high, e.lines[^1].len)

func textBetween*(e: Editor, a, b: TextPos): string =
  if a.line == b.line: return e.lines[a.line][a.col..<b.col]
  result = e.lines[a.line][a.col..^1]
  for i in a.line+1..<b.line: result.add "\n" & e.lines[i]
  result.add "\n" & e.lines[b.line][0..<b.col]

func selectedText*(e: Editor): string =
  let (a, b) = e.selection
  e.textBetween(a, b)

func clusterTotal(e: Editor): int =
  for line in e.lines: result += clusterCount(line)
  result += e.lines.len-1

func endOf(start: TextPos, text: string): TextPos =
  let breaks = text.count('\n')
  if breaks == 0: pos(start.line, start.col+text.len)
  else: pos(start.line+breaks, text.len-text.rfind('\n')-1)

proc replaceRange(e: var Editor, a, b: TextPos, text: string): TextPos =
  ## Replaces `a..b` with already-sanitized `text`; returns the end of the inserted text.
  let head = e.lines[a.line][0..<a.col]
  let tail = e.lines[b.line][b.col..^1]
  let pieces = text.split('\n')
  var replacement = newSeq[string](pieces.len)
  for i, piece in pieces: replacement[i] = piece
  replacement[0] = head & replacement[0]
  result = pos(a.line+pieces.high, replacement[^1].len)
  replacement[^1].add tail
  e.lines[a.line..b.line] = replacement
  inc e.revision

func settle(e: Editor, p: TextPos): TextPos =
  ## Moves `p` forward to the next cluster boundary. An insertion can merge with the cluster
  ## after it (a letter before a combining mark), leaving its raw end inside that cluster.
  let bounds = boundaries(e.lines[p.line])
  for b in bounds:
    if b >= p.col: return pos(p.line, b)
  pos(p.line, e.lines[p.line].len)

proc setCursorRaw(e: var Editor, p: TextPos, extend: bool) =
  e.cursor = p
  if not extend: e.anchor = p

proc record(e: var Editor, edit: Edit) =
  e.redoStack.setLen(0)
  e.undoStack.add edit
  if e.undoLimit >= 0 and e.undoStack.len > e.undoLimit:
    e.undoStack = e.undoStack[e.undoStack.len-e.undoLimit..^1]
  e.sealed = edit.kind == ekOther

proc applyEdit(e: var Editor, kind: EditKind, a, b: TextPos, text: string): bool =
  ## Replaces `a..b` with `text`, merging into the previous undo step when `kind` continues it.
  let removed = e.textBetween(a, b)
  if removed.len == 0 and text.len == 0: return false
  let before = e.cursor
  let beforeAnchor = e.anchor
  let after = e.replaceRange(a, b, text)
  e.cursor = e.settle(after)
  e.anchor = e.cursor
  e.preferred = -1
  if not e.sealed and e.undoStack.len > 0:
    var last = addr e.undoStack[^1]
    case kind
    of ekInsert:
      let breaksWord = text.len > 0 and text[0] == ' ' and last.inserted.len > 0 and
        last.inserted[^1] != ' '
      if last.kind == ekInsert and removed.len == 0 and last.after == a and not breaksWord:
        last.inserted.add text
        last.after = after
        e.redoStack.setLen(0)
        return true
    of ekBackspace:
      if last.kind == ekBackspace and last.start == b:
        last.removed = removed & last.removed
        last.start = a
        last.after = after
        e.redoStack.setLen(0)
        return true
    of ekDelete:
      if last.kind == ekDelete and last.start == a:
        last.removed.add removed
        e.redoStack.setLen(0)
        return true
    of ekOther: discard
  e.record Edit(kind: kind, start: a, removed: removed, inserted: text, before: before,
    beforeAnchor: beforeAnchor, after: after)
  true

proc seal*(e: var Editor) =
  ## Ends the current undo group; the next edit starts a new step.
  e.sealed = true

proc limitInsert(e: Editor, text: string, replaced: string): string =
  if e.maxGraphemes <= 0: return text
  let available = e.maxGraphemes - e.clusterTotal + clusterCount(replaced.replace("\n", " "))
  if available <= 0: return ""
  var count = 0
  for cluster in canopyUnicode.graphemes(text):
    if count >= available: break
    result.add cluster
    inc count

proc insertWith(e: var Editor, text: string, kind: EditKind): bool =
  var clean = sanitize(text, e.tabWidth, e.multiline, e.newlinePolicy)
  let (a, b) = e.selection
  clean = e.limitInsert(clean, e.textBetween(a, b))
  let k = if a != b: ekOther else: kind
  if clean.len == 0 and a == b: return false
  # A selection replacement or a newline always forms its own step.
  if k == ekOther: e.sealed = true
  result = e.applyEdit(k, a, b, clean)
  if '\n' in clean: e.sealed = true

proc typeText*(e: var Editor, text: string): bool {.discardable.} =
  ## Inserts typed text, replacing the selection. Consecutive typing within a word merges into
  ## one undo step. Returns whether the text changed.
  e.insertWith(text, ekInsert)

proc insertText*(e: var Editor, text: string): bool {.discardable.} =
  ## Inserts text (paste or programmatic) as its own undo step, replacing the selection.
  e.sealed = true
  result = e.insertWith(text, ekOther)
  e.sealed = true

proc deleteSelection*(e: var Editor): bool {.discardable.} =
  if not e.hasSelection: return false
  let (a, b) = e.selection
  e.sealed = true
  result = e.applyEdit(ekOther, a, b, "")
  e.sealed = true

proc prevPos(e: Editor, p: TextPos): TextPos =
  if p.col > 0: pos(p.line, prevBoundary(e.lines[p.line], p.col))
  elif p.line > 0: pos(p.line-1, e.lines[p.line-1].len)
  else: p

proc nextPos(e: Editor, p: TextPos): TextPos =
  if p.col < e.lines[p.line].len: pos(p.line, nextBoundary(e.lines[p.line], p.col))
  elif p.line < e.lines.high: pos(p.line+1, 0)
  else: p

proc wordLeftPos(e: Editor, p: TextPos): TextPos =
  if p.col == 0: return e.prevPos(p)
  pos(p.line, wordLeftCol(e.lines[p.line], p.col))

proc wordRightPos(e: Editor, p: TextPos): TextPos =
  if p.col >= e.lines[p.line].len: return e.nextPos(p)
  pos(p.line, wordRightCol(e.lines[p.line], p.col))

proc backspace*(e: var Editor): bool {.discardable.} =
  ## Deletes the selection or the cluster before the cursor.
  if e.hasSelection: return e.deleteSelection()
  let a = e.prevPos(e.cursor)
  if a == e.cursor: return false
  e.applyEdit(ekBackspace, a, e.cursor, "")

proc deleteForward*(e: var Editor): bool {.discardable.} =
  if e.hasSelection: return e.deleteSelection()
  let b = e.nextPos(e.cursor)
  if b == e.cursor: return false
  e.applyEdit(ekDelete, e.cursor, b, "")

proc deleteWordLeft*(e: var Editor): bool {.discardable.} =
  if e.hasSelection: return e.deleteSelection()
  let a = e.wordLeftPos(e.cursor)
  if a == e.cursor: return false
  e.sealed = true
  result = e.applyEdit(ekOther, a, e.cursor, "")

proc deleteWordRight*(e: var Editor): bool {.discardable.} =
  if e.hasSelection: return e.deleteSelection()
  let b = e.wordRightPos(e.cursor)
  if b == e.cursor: return false
  e.sealed = true
  result = e.applyEdit(ekOther, e.cursor, b, "")

proc moveTo*(e: var Editor, p: TextPos, extend = false) =
  ## Moves the cursor (clamped and snapped to a boundary); `extend` keeps the anchor.
  let line = clamp(p.line, 0, e.lines.high)
  let col = snapBoundary(e.lines[line], clamp(p.col, 0, e.lines[line].len))
  e.setCursorRaw(pos(line, col), extend)
  e.preferred = -1
  e.sealed = true

proc moveLeft*(e: var Editor, extend = false) =
  if e.hasSelection and not extend: e.moveTo(e.selection.first)
  else: e.moveTo(e.prevPos(e.cursor), extend)

proc moveRight*(e: var Editor, extend = false) =
  if e.hasSelection and not extend: e.moveTo(e.selection.last)
  else: e.moveTo(e.nextPos(e.cursor), extend)

proc moveWordLeft*(e: var Editor, extend = false) = e.moveTo(e.wordLeftPos(e.cursor), extend)
proc moveWordRight*(e: var Editor, extend = false) = e.moveTo(e.wordRightPos(e.cursor), extend)
proc moveHome*(e: var Editor, extend = false) = e.moveTo(pos(e.cursor.line, 0), extend)
proc moveEnd*(e: var Editor, extend = false) =
  e.moveTo(pos(e.cursor.line, e.lines[e.cursor.line].len), extend)

proc moveDocumentStart*(e: var Editor, extend = false) = e.moveTo(pos(0, 0), extend)
proc moveDocumentEnd*(e: var Editor, extend = false) =
  e.moveTo(pos(e.lines.high, e.lines[^1].len), extend)

proc moveLines*(e: var Editor, delta: int, extend = false, mask = "") =
  ## Moves vertically by `delta` lines, keeping the preferred display column across moves.
  ## At the first or last line the cursor goes to the start or end of that line.
  let column = if e.preferred >= 0: e.preferred else: columnOf(e.lines[e.cursor.line],
    e.cursor.col, mask)
  let target = e.cursor.line+delta
  if target < 0: e.moveTo(pos(0, 0), extend)
  elif target > e.lines.high: e.moveTo(pos(e.lines.high, e.lines[^1].len), extend)
  else:
    e.setCursorRaw(pos(target, colAtColumn(e.lines[target], column, mask)), extend)
    e.sealed = true
  e.preferred = column

proc selectAll*(e: var Editor) =
  e.anchor = pos(0, 0)
  e.cursor = pos(e.lines.high, e.lines[^1].len)
  e.preferred = -1
  e.sealed = true

proc setText*(e: var Editor, text: string) =
  ## Replaces the whole text, moves the cursor to the end and clears undo history.
  let clean = sanitize(text, e.tabWidth, e.multiline, e.newlinePolicy)
  e.lines = clean.split('\n')
  e.cursor = pos(e.lines.high, e.lines[^1].len)
  e.anchor = e.cursor
  e.undoStack.setLen(0)
  e.redoStack.setLen(0)
  e.sealed = true
  e.preferred = -1
  inc e.revision

proc undo*(e: var Editor): bool {.discardable.} =
  if e.undoStack.len == 0: return false
  let edit = e.undoStack.pop()
  discard e.replaceRange(edit.start, endOf(edit.start, edit.inserted), edit.removed)
  e.cursor = edit.before
  e.anchor = edit.beforeAnchor
  e.redoStack.add edit
  e.sealed = true
  e.preferred = -1
  true

proc redo*(e: var Editor): bool {.discardable.} =
  if e.redoStack.len == 0: return false
  let edit = e.redoStack.pop()
  discard e.replaceRange(edit.start, endOf(edit.start, edit.removed), edit.inserted)
  e.cursor = e.settle(edit.after)
  e.anchor = e.cursor
  e.undoStack.add edit
  e.sealed = true
  e.preferred = -1
  true
