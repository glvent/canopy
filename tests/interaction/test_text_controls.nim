## TextInput and TextArea: rendering, scrolling, cursor, keys from real parser bytes, paste,
## pointer, read-only, disabled, masks and keymap overrides.
import std/[unittest, options]

import canopy/runtime/terminal/parser
import canopy/ui/controls/index
import ../support/interaction_support

proc parse(bytes: string): seq[Event] =
  var p = initInputParser()
  p.feed(bytes)
  p.finishEscape()
  p.drain()

proc focusedOn(fm: var FocusManager, ids: openArray[ControlId], text: openArray[bool] = []) =
  fm.beginFrame()
  for i, c in ids: fm.register(c, initRect(0, i, 10, 1), textEntry = i >= text.len or text[i])
  discard fm.endFrame()
  fm.focus(ids[0])

proc send(fm: var FocusManager, s: var TextInputState, events: openArray[Event]): EventResult =
  for e in events: result.add s.handle(fm.route(e))

suite "TextInput rendering":
  test "scrolls wide text and blanks clusters cut by the left edge":
    var s = initTextInputState(id("t"), "ab世界cd")
    var buf = initBuffer(initRect(0, 0, 5, 1))
    initTextInput().render(buf.area, buf, s, focused = true)
    # Text is 8 cells wide plus the end cursor: scroll = 9-5 = 4.
    check s.scroll == 4
    check buf.rowText(0) == "界cd "
    check s.cursor == some(initPosition(4, 0))
    s.editor.moveHome()
    s.editor.moveRight(); s.editor.moveRight(); s.editor.moveRight()
    buf = initBuffer(initRect(0, 0, 5, 1))
    initTextInput().render(buf.area, buf, s, focused = true)
    check s.scroll == 2 # cursor at column 4 with margin 2
    check buf.rowText(0) == "世界c"
    s.scroll = 3
    s.editor.moveEnd()
    s.editor.moveLeft(); s.editor.moveLeft(); s.editor.moveLeft()
    buf = initBuffer(initRect(0, 0, 5, 1))
    initTextInput().withScrollMargin(0).render(buf.area, buf, s, focused = true)
    check s.scroll == 3
    check buf.rowText(0) == " 界cd" # the right half of 世 is blank

  test "placeholder, mask, read-only and disabled":
    var s = initTextInputState(id("t"))
    var buf = initBuffer(initRect(0, 0, 8, 1))
    initTextInput("Name…").render(buf.area, buf, s, focused = true)
    check buf.rowText(0) == "Name…   "
    check s.cursor == some(initPosition(0, 0))
    var pw = initTextInputState(id("p"), "sécret", mask = "•")
    buf = initBuffer(initRect(0, 0, 8, 1))
    initTextInput().render(buf.area, buf, pw, focused = true)
    check buf.rowText(0) == "••••••  "
    var ro = initTextInputState(id("r"), "fixed", readOnly = true)
    initTextInput().render(buf.area, buf, ro, focused = true)
    check ro.cursor.isNone
    check buf[0, 0].modifiers.contains(Modifier.Italic)
    var off = initTextInputState(id("d"), "off", enabled = false)
    initTextInput().render(buf.area, buf, off, focused = false)
    check buf[0, 0].modifiers.contains(Modifier.Dim)

  test "selection is shown only while focused":
    var s = initTextInputState(id("t"), "hello")
    s.editor.moveWordLeft(extend = true)
    var buf = initBuffer(initRect(0, 0, 8, 1))
    initTextInput().render(buf.area, buf, s, focused = true)
    check buf[0, 0].modifiers.contains(Modifier.Reversed)
    buf = initBuffer(initRect(0, 0, 8, 1))
    initTextInput().render(buf.area, buf, s, focused = false)
    check not buf[0, 0].modifiers.contains(Modifier.Reversed)

suite "TextInput events":
  test "keys decoded from terminal bytes":
    var fm = initFocusManager()
    var s = initTextInputState(id("t"), "one two")
    fm.focusedOn([s.id])
    # Ctrl+Left (xterm), Alt+Backspace (ESC DEL), typed UTF-8, Home, Ctrl+Right (Kitty CSI u
    # is not used for arrows; xterm form again), End.
    check fm.send(s, parse("\e[1;5D")).consumed
    check s.editor.cursor == pos(0, 4)
    discard fm.send(s, parse("\e\x7f"))
    check s.text == "two"
    discard fm.send(s, parse("é🙂"))
    check s.text == "é🙂two"
    discard fm.send(s, parse("\e[H"))
    check s.editor.cursor == pos(0, 0)
    discard fm.send(s, parse("\e[1;5C"))
    check s.editor.cursor == pos(0, 2) # é is a word run; 🙂 starts a punctuation run

  test "bracketed paste is sanitized and newline policy applies":
    var fm = initFocusManager()
    var s = initTextInputState(id("t"))
    fm.focusedOn([s.id])
    let r = fm.send(s, parse("\e[200~a\tb\r\nc\x1b[31m\e[201~"))
    check r.changed
    check s.text == "a    b c[31m"
    var first = initTextInputState(id("f"), newlinePolicy = NewlinePolicy.FirstLine)
    var fm2 = initFocusManager()
    fm2.focusedOn([first.id])
    discard fm2.send(first, [paste("top\nrest")])
    check first.text == "top"

  test "unbound keys, Tab, Escape and release events are not consumed":
    var fm = initFocusManager()
    var s = initTextInputState(id("t"), "x")
    fm.focusedOn([s.id])
    check not fm.send(s, [key(KeyCode.Tab)]).consumed
    check not fm.send(s, [key(KeyCode.Escape)]).consumed
    check not fm.send(s, [ch("q", ctrl)]).consumed
    check not fm.send(s, [keyEvent(KeyCode.Character, "z", kind = KeyEventKind.Release)]).consumed
    check s.text == "x"
    check fm.send(s, [keyEvent(KeyCode.Character, "z", kind = KeyEventKind.Repeat)]).changed
    let submit = fm.send(s, [key(KeyCode.Enter)])
    check submit.action == some(TextSubmit) and submit.subject == "t"

  test "copy, cut and internal paste":
    var fm = initFocusManager()
    var s = initTextInputState(id("t"), "copy me")
    fm.focusedOn([s.id])
    discard fm.send(s, [key(KeyCode.Left, ctrl+shift)])
    check fm.send(s, [key(KeyCode.Insert, ctrl)]).action == some(TextCopy)
    check s.clipboard == "me"
    check fm.send(s, [ch("x", ctrl)]).action == some(TextCut)
    check s.text == "copy "
    discard fm.send(s, [key(KeyCode.Insert, shift), key(KeyCode.Insert, shift)])
    check s.text == "copy meme"
    var pw = initTextInputState(id("p"), "secret", mask = "*")
    var fm2 = initFocusManager()
    fm2.focusedOn([pw.id])
    pw.editor.selectAll()
    discard fm2.send(pw, [key(KeyCode.Insert, ctrl)])
    check pw.clipboard == ""

  test "only the routed target acts; disabled and read-only behave":
    var fm = initFocusManager()
    var a = initTextInputState(id("a"))
    var b = initTextInputState(id("b"))
    var ro = initTextInputState(id("ro"), "keep", readOnly = true)
    fm.focusedOn([a.id, b.id, ro.id], [true, true, false])
    let r = fm.route(ch("k"))
    discard a.handle(r)
    discard b.handle(r)
    check a.text == "k" and b.text == ""
    fm.focus(ro.id)
    let typed = fm.route(ch("z"))
    check not typed.textEntry
    check not ro.handle(typed).consumed # left to application shortcuts
    check ro.handle(fm.route(key(KeyCode.Backspace))).consumed
    check ro.handle(fm.route(paste("x"))).consumed
    check ro.text == "keep"
    check ro.handle(fm.route(key(KeyCode.Left))).redraw

  test "pointer click and drag select by cluster":
    var fm = initFocusManager()
    var s = initTextInputState(id("t"), "a世b")
    var buf = initBuffer(initRect(0, 0, 10, 1))
    fm.beginFrame()
    fm.register(s.id, buf.area, textEntry = true)
    discard fm.endFrame()
    initTextInput().render(buf.area, buf, s, focused = true)
    discard s.handle(fm.route(mouse(MouseEventKind.Down, 1, 0)))
    check s.editor.cursor == pos(0, 1)
    check fm.focused == some(s.id)
    discard s.handle(fm.route(mouse(MouseEventKind.Drag, 3, 0)))
    check s.editor.selectedText == "世"
    discard s.handle(fm.route(mouse(MouseEventKind.Up, 3, 0)))

  test "per-control keymap override and application remapping":
    var fm = initFocusManager()
    var s = initTextInputState(id("t"), "abc")
    fm.focusedOn([s.id])
    s.keymap.bindKey(TextContext, "ctrl+b", TextHome)
    s.keymap.disableKey(TextContext, "ctrl+w")
    discard s.handle(fm.route(ch("b", ctrl)))
    check s.editor.cursor == pos(0, 0)
    s.editor.moveEnd()
    check not s.handle(fm.route(ch("w", ctrl))).consumed
    var keys = defaultKeymap()
    keys.unbindAction(TextContext, TextBackspace)
    keys.bindKey(TextContext, "ctrl+h", TextBackspace)
    check not s.handle(fm.route(key(KeyCode.Backspace)), keys).consumed
    check s.handle(fm.route(ch("h", ctrl)), keys).changed
    check s.text == "ab"

suite "TextArea":
  test "newline, vertical movement, page and scrolling":
    var fm = initFocusManager()
    var s = initTextAreaState(id("area"), "first\nsecond")
    var buf = initBuffer(initRect(0, 0, 7, 3))
    fm.beginFrame(); fm.register(s.id, buf.area, textEntry = true); discard fm.endFrame()
    fm.focus(s.id)
    initTextArea().render(buf.area, buf, s, true)
    check buf.rows == @["first  ", "second ", "       "]
    for e in [key(KeyCode.Enter), ch("t"), key(KeyCode.Enter), ch("u"), key(KeyCode.Enter)]:
      discard s.handle(fm.route(e))
    check s.text == "first\nsecond\nt\nu\n"
    buf = initBuffer(initRect(0, 0, 7, 3))
    initTextArea().render(buf.area, buf, s, true)
    check s.top == 2
    check buf.rows == @["t      ", "u      ", "       "]
    check s.cursor == some(initPosition(0, 2))
    discard s.handle(fm.route(key(KeyCode.PageUp)))
    check s.editor.cursor.line == 2
    discard s.handle(fm.route(key(KeyCode.Home, ctrl)))
    check s.editor.cursor == pos(0, 0)
    check not s.handle(fm.route(key(KeyCode.Tab))).consumed

  test "wheel scrolls without moving the cursor; typing reveals it again":
    var fm = initFocusManager()
    var text = ""
    for i in 0..19: text.add "line " & $i & "\n"
    var s = initTextAreaState(id("area"), text)
    var buf = initBuffer(initRect(0, 0, 10, 4))
    fm.beginFrame(); fm.register(s.id, buf.area, textEntry = true); discard fm.endFrame()
    fm.focus(s.id)
    initTextArea().render(buf.area, buf, s, true)
    check s.top == 17
    discard s.handle(fm.route(mouse(MouseEventKind.ScrollUp, 1, 1, none(MouseButton))))
    initTextArea().render(buf.area, buf, s, true)
    check s.top == 14 and s.cursor.isNone
    discard s.handle(fm.route(ch("x")))
    initTextArea().render(buf.area, buf, s, true)
    check s.top == 17 and s.cursor.isSome

  test "multiline selection renders across lines, including the line break":
    var s = initTextAreaState(id("area"), "ab\ncd")
    s.editor.moveTo(pos(0, 1))
    s.editor.moveTo(pos(1, 1), extend = true)
    var buf = initBuffer(initRect(0, 0, 4, 2))
    initTextArea().render(buf.area, buf, s, true)
    check not buf[0, 0].modifiers.contains(Modifier.Reversed)
    check buf[1, 0].modifiers.contains(Modifier.Reversed)
    check buf[2, 0].modifiers.contains(Modifier.Reversed) # selected line break
    check buf[0, 1].modifiers.contains(Modifier.Reversed)
    check not buf[1, 1].modifiers.contains(Modifier.Reversed)

  test "click maps rows and columns through scroll":
    var fm = initFocusManager()
    var s = initTextAreaState(id("area"), "abc\n世界x\nz")
    var buf = initBuffer(initRect(2, 1, 6, 3))
    fm.beginFrame(); fm.register(s.id, buf.area, textEntry = true); discard fm.endFrame()
    initTextArea().render(buf.area, buf, s, false)
    discard s.handle(fm.route(mouse(MouseEventKind.Down, 5, 2)))
    check s.editor.cursor == pos(1, 6)
    discard s.handle(fm.route(mouse(MouseEventKind.Down, 7, 3)))
    check s.editor.cursor.line == 2
