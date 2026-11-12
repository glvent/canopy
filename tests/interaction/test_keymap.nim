## Key chord normalization, bindings, precedence, conflicts and repeats.
import std/[unittest, options]

import canopy/ui/interaction/index

const
  ctrl = {KeyModifier.Control}
  shift = {KeyModifier.Shift}
  alt = {KeyModifier.Alt}

proc key(text: string, mods: KeyModifiers = {}, kind = KeyEventKind.Press): Event =
  keyEvent(KeyCode.Character, text, mods, kind)

suite "key chords":
  test "parse and format":
    check $parseChord("ctrl+shift+left") == "Ctrl+Shift+Left"
    check $parseChord("Ctrl+P") == "Ctrl+P"
    check $parseChord("shift+a") == "Shift+A"
    check $parseChord("f12") == "F12"
    check $parseChord("alt+space") == "Alt+Space"
    check $parseChord("plus") == "+"
    check $parseChord("?") == "?"
    check parseChord("pgdn") == chord(KeyCode.PageDown)
    for bad in ["", "ctrl+", "hyperx+a", "ctrl+nope", "f0"]:
      expect ValueError: discard parseChord(bad)

  test "normalization folds encodings that terminals report differently":
    # Legacy Ctrl+Shift+A cannot be told from Ctrl+A; Kitty reports a lowercase letter + Shift.
    check chordOf(key("a", ctrl+shift).key) == parseChord("ctrl+shift+a")
    check chordOf(key("A", ctrl).key) == parseChord("ctrl+shift+a")
    check chordOf(key("A").key) == parseChord("shift+a")
    check chordOf(key("?", shift).key) == parseChord("?")
    check chordOf(keyEvent(KeyCode.BackTab, modifiers = shift).key) == parseChord("shift+tab")
    check chordOf(keyEvent(KeyCode.Tab, modifiers = shift).key) == parseChord("shift+tab")
    check chordOf(keyEvent(KeyCode.Left, modifiers = ctrl+{KeyModifier.CapsLock,
      KeyModifier.NumLock}).key) == parseChord("ctrl+left")
    # Alt-prefixed control bytes.
    check chordOf(key("\x7f", alt).key) == parseChord("alt+backspace")
    check chordOf(key("\r", alt).key) == parseChord("alt+enter")
    check chordOf(key("\x01", alt).key) == parseChord("ctrl+alt+a")
    check chordOf(key(" ", ctrl).key) == parseChord("ctrl+space")

suite "keymaps":
  test "defaults resolve per context":
    let keys = defaultKeymap()
    check keys.lookup(TextContext, keyEvent(KeyCode.Left, modifiers = ctrl)) == some(TextWordLeft)
    check keys.lookup(FocusContext, keyEvent(KeyCode.BackTab, modifiers = shift)) ==
      some(FocusPrevious)
    check keys.lookup(ListContext, keyEvent(KeyCode.Left)).isNone
    check keys.chordsFor(TextContext, TextUndo) == @[parseChord("ctrl+z")]

  test "press, repeat and release":
    var keys = initKeymap()
    keys.bindKey("app", "ctrl+s", actionId("save"))
    keys.bindKey("app", "down", actionId("move"), repeat = true)
    check keys.lookup("app", key("s", ctrl)) == some(actionId("save"))
    check keys.lookup("app", key("s", ctrl, KeyEventKind.Repeat)).isNone
    check keys.lookup("app", key("s", ctrl, KeyEventKind.Release)).isNone
    let down = keyEvent(KeyCode.Down, kind = KeyEventKind.Repeat)
    check keys.lookup("app", down) == some(actionId("move"))

  test "conflicts raise unless replaced; same action is idempotent":
    var keys = initKeymap()
    keys.bindKey("app", "ctrl+s", actionId("save"))
    keys.bindKey("app", "ctrl+s", actionId("save"))
    check keys.len == 1
    expect KeymapConflictError: keys.bindKey("app", "ctrl+s", actionId("other"))
    keys.bindKey("app", "ctrl+s", actionId("other"), replace = true)
    check keys.lookup("app", key("s", ctrl)) == some(actionId("other"))
    keys.bindKey("global", "ctrl+s", actionId("save"))
    let found = keys.conflicts(["global", "app"])
    check found.len == 1 and found[0].bindings.len == 2
    check keys.unbindKey("app", "ctrl+s")
    check not keys.unbindKey("app", "ctrl+s")
    keys.bindKey("global", "f2", actionId("save"))
    check keys.unbindAction("global", actionId("save")) == 2
    check keys.len == 0

  test "override layers take precedence and can disable a lower binding":
    let app = defaultKeymap()
    var control = initKeymap()
    control.bindKey(TextContext, "ctrl+a", TextHome)
    control.disableKey(TextContext, "ctrl+w")
    check resolve([control, app], [TextContext], key("a", ctrl)) == some(TextHome)
    check resolve([control, app], [TextContext], key("w", ctrl)).isNone
    check resolve([control, app], [TextContext], key("z", ctrl)) == some(TextUndo)
    check resolve([app], [TextAreaContext, TextContext], keyEvent(KeyCode.Enter)) ==
      some(TextNewline)

  test "text entry never turns printable characters or paste into shortcuts":
    var keys = initKeymap()
    keys.bindKey("app", "q", actionId("quit"))
    keys.bindKey("app", "alt+q", actionId("altquit"))
    check keys.lookup("app", key("q")) == some(actionId("quit"))
    check keys.lookup("app", key("q"), textEntry = true).isNone
    check keys.lookup("app", key("q", alt), textEntry = true) == some(actionId("altquit"))
    check keys.lookup("app", Event(kind: EventKind.Paste, text: "q")).isNone
