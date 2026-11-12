## Event routing: targets, pointer capture, modal isolation, resize staleness and terminal focus.
import std/[unittest, options]

import canopy/ui/interaction/index

proc id(name: string): ControlId = controlId(name)

proc mouse(kind: MouseEventKind, x, y: int, button = some(MouseButton.Left)): Event =
  Event(kind: EventKind.Mouse, mouse: MouseEvent(kind: kind, column: x, row: y, button: button))

proc layout(fm: var FocusManager, dialog = false) =
  fm.beginFrame()
  fm.register(id("name"), initRect(0, 0, 10, 1), textEntry = true)
  fm.register(id("list"), initRect(0, 1, 10, 5))
  fm.register(id("off"), initRect(0, 6, 10, 1), enabled = false)
  if dialog:
    fm.withScope(id("dialog"), initRect(20, 0, 10, 4), true):
      fm.register(id("ok"), initRect(21, 2, 4, 1))
  discard fm.endFrame()

suite "routing":
  test "keys and paste follow focus; text entry is reported":
    var fm = initFocusManager()
    fm.layout()
    check fm.route(keyEvent(KeyCode.Character, "x")).target.isNone
    fm.focus(id("name"))
    let r = fm.route(Event(kind: EventKind.Paste, text: "hi"))
    check r.targets(id("name")) and r.textEntry and r.allowsApplication
    check standardKeymap.resolveApplication(fm.route(keyEvent(KeyCode.Character, "q"))).isNone

  test "click focuses, captures drag and release, and ignores disabled controls":
    var fm = initFocusManager()
    fm.layout()
    let down = fm.route(mouse(MouseEventKind.Down, 3, 2))
    check down.targets(id("list")) and down.focusChanged
    check fm.focused == some(id("list"))
    check fm.route(mouse(MouseEventKind.Drag, 3, 0)).targets(id("list"))
    check fm.route(mouse(MouseEventKind.Up, 3, 0)).targets(id("list"))
    check fm.captured.isNone
    check fm.route(mouse(MouseEventKind.Up, 3, 0)).targets(id("name"))
    let disabled = fm.route(mouse(MouseEventKind.Down, 3, 6))
    check disabled.target.isNone and not disabled.focusChanged
    check fm.focused == some(id("list"))
    let right = fm.route(mouse(MouseEventKind.Down, 1, 0, some(MouseButton.Right)))
    check right.targets(id("name")) and fm.focused == some(id("list"))
    check fm.route(mouse(MouseEventKind.ScrollDown, 1, 3, none(MouseButton))).targets(id("list"))

  test "resize makes pointer routing stale until the next frame":
    var fm = initFocusManager()
    fm.layout()
    fm.focus(id("name"))
    discard fm.route(resizeEvent(40, 10))
    check fm.geometryStale
    check fm.route(mouse(MouseEventKind.Down, 3, 2)).target.isNone
    check fm.route(keyEvent(KeyCode.Character, "a")).targets(id("name"))
    fm.layout()
    check fm.route(mouse(MouseEventKind.Down, 3, 2)).targets(id("list"))

  test "terminal focus does not change logical focus":
    var fm = initFocusManager()
    fm.layout()
    fm.focus(id("name"))
    discard fm.route(Event(kind: EventKind.FocusLost))
    check not fm.terminalFocused and fm.focused == some(id("name"))
    discard fm.route(Event(kind: EventKind.FocusGained))
    check fm.terminalFocused

  test "modal isolation: outside pointer and keys never reach base controls":
    var fm = initFocusManager()
    fm.layout()
    fm.focus(id("name"))
    fm.openModal(id("dialog"))
    fm.layout(dialog = true)
    let outside = fm.route(mouse(MouseEventKind.Down, 1, 0))
    check outside.target.isNone and not outside.insideModal and not outside.allowsApplication
    check fm.focused == some(id("ok"))
    let inside = fm.route(mouse(MouseEventKind.Down, 22, 2))
    check inside.targets(id("ok")) and inside.insideModal and inside.within(id("dialog"))
    var keys = defaultKeymap()
    keys.bindKey(AppContext, "q", actionId("quit"))
    keys.bindKey(GlobalContext, "ctrl+c", actionId("exit"))
    check keys.resolveApplication(fm.route(keyEvent(KeyCode.Character, "q"))).isNone
    check keys.resolveApplication(fm.route(keyEvent(KeyCode.Character, "c",
      {KeyModifier.Control}))) == some(actionId("exit"))

  test "the event that closes a modal does not target the restored control":
    var fm = initFocusManager()
    fm.layout()
    fm.focus(id("name"))
    fm.openModal(id("dialog"))
    fm.layout(dialog = true)
    let escape = fm.route(keyEvent(KeyCode.Escape))
    check escape.targets(id("ok"))
    fm.closeModal(id("dialog"))
    check fm.focused == some(id("name"))
    check not escape.targets(id("name"))

  test "traversal is consumed inside an empty modal but not in an empty base layer":
    var fm = initFocusManager()
    fm.beginFrame(); discard fm.endFrame()
    check not fm.handleTraversal(fm.route(keyEvent(KeyCode.Tab))).consumed
    fm.openModal(id("m"))
    fm.beginFrame()
    fm.withScope(id("m"), initRect(0, 0, 5, 5), true): discard
    discard fm.endFrame()
    check fm.handleTraversal(fm.route(keyEvent(KeyCode.Tab))).consumed

  test "pending initial focus receives keys typed before the modal's first frame":
    var fm = initFocusManager()
    fm.layout()
    fm.focus(id("list"))
    fm.openModal(id("palette"), some(id("query")))
    check fm.route(keyEvent(KeyCode.Character, "a")).targets(id("query"))
    check fm.route(mouse(MouseEventKind.Down, 3, 2)).target.isNone

  test "results merge":
    var r = ignored()
    r.add consumed(redraw = false)
    r.add emitted(actionId("x"), "subject", changed = true)
    check r.consumed and r.redraw and r.changed and r.action == some(actionId("x")) and
      r.subject == "subject"

suite "pointer capture after resize":
  test "a release after resize does not reach the captured control":
    var fm = initFocusManager()
    fm.beginFrame()
    fm.register(controlId("a"), initRect(0, 0, 10, 1))
    discard fm.endFrame()
    let down = Event(kind: EventKind.Mouse, mouse: MouseEvent(kind: MouseEventKind.Down,
      button: some(MouseButton.Left), column: 1, row: 0))
    check fm.route(down).target == some(controlId("a"))
    discard fm.route(Event(kind: EventKind.Resize, width: 5, height: 5))
    var up = down
    up.mouse.kind = MouseEventKind.Up
    check fm.route(up).target.isNone
    check fm.captured.isNone
