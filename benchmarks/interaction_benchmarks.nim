## Interaction layer workloads: registration and routing, typing, large text areas, palette
## ranking and tree flattening. Run a release build; an optional argument scales iterations.
import std/[monotimes, times, strformat, strutils, os, options]

import canopy
import canopy/ui/controls/index

let scale = if paramCount() == 0: 1 else: parseInt(paramStr(1))
if scale < 1 or scale > 100: quit("Scale must be between 1 and 100", 1)
const manager = when defined(gcOrc): "orc" elif defined(gcArc): "arc" else: "other"
echo &"Nim {NimVersion}; {hostOS}/{hostCPU}; mm={manager}; scale={scale}"
var checksum = 0'u64

template measure(name: string, count: int, body: untyped) =
  block:
    let iterations = count * scale
    let started = getMonoTime()
    for iteration {.inject.} in 0..<iterations: body
    let milliseconds = float64((getMonoTime() - started).inNanoseconds) / 1_000_000.0
    echo name, ": iterations=", iterations, "; elapsed_ms=", milliseconds.formatFloat(ffDecimal, 3),
      "; us_per_iteration=", (milliseconds * 1000 / float64(iterations)).formatFloat(ffDecimal, 3)

# 200 registrations per frame plus Tab routing and a click hit test.
var ids: seq[ControlId]
for i in 0..<200: ids.add controlId("c" & $i)
var fm = initFocusManager()
let tab = keyEvent(KeyCode.Tab)
let click = Event(kind: EventKind.Mouse, mouse: MouseEvent(kind: MouseEventKind.Down,
  button: some(MouseButton.Left), column: 5, row: 150))
measure("focus frame (200 controls) + Tab + click", 2000):
  fm.beginFrame()
  for i, id in ids: fm.register(id, initRect(0, i, 40, 1), textEntry = i mod 2 == 0)
  discard fm.endFrame()
  discard fm.handleTraversal(fm.route(tab))
  discard fm.route(click)
  checksum += uint64(($fm.focused.get).len)

# Typing into a single-line input that already holds 2000 clusters, with rendering.
var input = initTextInputState(controlId("input"), repeat("café 世界 ", 250))
var inputBuffer = initBuffer(initRect(0, 0, 80, 1))
let widget = initTextInput()
measure("text input type + render (2000 clusters, 80 cells)", 2000):
  discard input.editor.typeText("x")
  if iteration mod 10 == 9: discard input.editor.backspace()
  widget.render(inputBuffer.area, inputBuffer, input, true)
  checksum += uint64(input.scroll)

# A 10000-line text area: cursor movement and rendering a 100x40 viewport.
var lines: seq[string]
for i in 0..<10_000: lines.add "line " & $i & " Unicode 世界 👩‍👩‍👧 and some trailing words"
var area = initTextAreaState(controlId("area"), lines.join("\n"))
var areaBuffer = initBuffer(initRect(0, 0, 100, 40))
let areaWidget = initTextArea()
measure("text area move + render (10000 lines, 100x40)", 2000):
  area.editor.moveLines(if iteration mod 400 < 200: -7 else: 7)
  areaWidget.render(areaBuffer.area, areaBuffer, area, true)
  checksum += uint64(area.top)
measure("text area insert line (10000 lines)", 1000):
  discard area.editor.insertText("\n")
  checksum += uint64(area.editor.lineCount)

# Ranking 2000 commands.
var commands: seq[Command]
let verbs = ["Open", "Close", "Toggle", "Format", "Go to", "Show", "Rename", "Delete"]
let nouns = ["File", "Folder", "Terminal", "Panel", "Symbol", "Settings", "Theme", "Selection"]
for i in 0..<2000:
  commands.add command("cmd" & $i, verbs[i mod 8] & " " & nouns[(i div 8) mod 8] & " " & $i,
    actionId("a"))
let registry = initCommandRegistry(commands)
measure("palette rank (2000 commands, query \"otf\")", 200):
  checksum += uint64(registry.rank("otf").len)

# Flattening a fully expanded tree of 10000 nodes.
proc build(depth, width: int, prefix: string): seq[TreeItem] =
  for i in 0..<width:
    let id = prefix & "." & $i
    result.add treeItem(id, "node " & id, if depth > 0: build(depth-1, width, id) else: @[])
let items = build(3, 10, "n")
var tree = initTreeState(controlId("tree"))
proc expandAll(list: openArray[TreeItem]) =
  for item in list:
    if item.children.len > 0:
      tree.expand(item.id)
      expandAll(item.children)
expandAll(items)
measure("tree sync (11110 visible nodes)", 100):
  tree.sync(items)
  checksum += uint64(tree.rows.len)

echo "checksum=", checksum
