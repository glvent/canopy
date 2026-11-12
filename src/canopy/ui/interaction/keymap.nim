## Typed key chords mapped to semantic actions per context (Canopy extension).
##
## A `Keymap` is a plain value: copy `defaultKeymap()` and edit it to customize bindings.
## Matching normalizes the terminal's report so equivalent encodings compare equal; see
## `docs/interaction.md` for the rules and legacy-terminal limits.
import std/[options, sequtils, strutils, unicode]

import ../../runtime/terminal/events
import ./ids
export events, ids, options

type
  KeyChord* = object
    ## A key plus modifiers. `text` is used only by `Character` chords and `functionKey` only by
    ## `Function` chords. Construct with `chord`, `functionChord` or `parseChord`.
    code*: KeyCode
    text*: string
    functionKey*: int
    modifiers*: KeyModifiers
  Binding* = object
    context*: string
    chord*: KeyChord
    action*: ActionId
    repeat*: bool ## Also fire on key-repeat events.
  Keymap* = object
    bindings: seq[Binding]
  KeymapConflictError* = object of ValueError
    ## Raised by `bindKey` when the chord already maps to another action in the context.

const
  FocusContext* = "focus"
  TextContext* = "text"
  TextAreaContext* = "textarea"
  ListContext* = "list"
  TreeContext* = "tree"
  PaletteContext* = "palette"
  DialogContext* = "dialog"
  ButtonContext* = "button"
  FormContext* = "form"
  GlobalContext* = "global"
    ## Application bindings that stay active while a modal is open.
  AppContext* = "app"
    ## Application bindings that a modal blocks.

  SignificantModifiers = {KeyModifier.Shift, KeyModifier.Control, KeyModifier.Alt,
    KeyModifier.Super, KeyModifier.Hyper, KeyModifier.Meta}
  CommandModifiers = {KeyModifier.Control, KeyModifier.Alt, KeyModifier.Super,
    KeyModifier.Hyper, KeyModifier.Meta}

func isAsciiLetter(s: string): bool = s.len == 1 and s[0] in {'a'..'z', 'A'..'Z'}

func normalized*(c: KeyChord): KeyChord =
  ## Canonical form used for comparison: lock modifiers dropped, BackTab as Shift+Tab, and Shift
  ## folded into letter case (it is ignored on other characters).
  result = c
  result.modifiers = c.modifiers * SignificantModifiers
  # Alt-prefixed legacy bytes arrive as Character text holding a C0 control or DEL.
  if result.code == KeyCode.Character and result.text.len == 1 and
      result.text[0] in {'\0'..'\x1f', '\x7f'}:
    let b = ord(result.text[0])
    result.text = ""
    case b
    of 8, 127: result.code = KeyCode.Backspace
    of 9: result.code = KeyCode.Tab
    of 10, 13: result.code = KeyCode.Enter
    of 27: result.code = KeyCode.Escape
    of 0: result.text = " "; result.modifiers.incl KeyModifier.Control
    of 1..7, 11, 12, 14..26:
      result.text = $char(ord('a')+b-1); result.modifiers.incl KeyModifier.Control
    else: result.text = $char(b)
  if result.code == KeyCode.BackTab:
    result.code = KeyCode.Tab
    result.modifiers.incl KeyModifier.Shift
  if result.code == KeyCode.Character:
    if result.text.isAsciiLetter and KeyModifier.Shift in result.modifiers:
      result.text = result.text.toUpperAscii
    result.modifiers.excl KeyModifier.Shift
  else: result.text = ""
  if result.code != KeyCode.Function: result.functionKey = 0

func chord*(code: KeyCode, modifiers: KeyModifiers = {}): KeyChord =
  if code == KeyCode.Character: raise newException(ValueError, "Character chords need text")
  if code == KeyCode.Function: raise newException(ValueError, "Use functionChord")
  normalized(KeyChord(code: code, modifiers: modifiers))

func chord*(text: string, modifiers: KeyModifiers = {}): KeyChord =
  ## A chord for the character `text` produces, such as `chord("p", {KeyModifier.Control})`.
  if text.len == 0: raise newException(ValueError, "Character chords need text")
  normalized(KeyChord(code: KeyCode.Character, text: text, modifiers: modifiers))

func functionChord*(number: int, modifiers: KeyModifiers = {}): KeyChord =
  if number < 1: raise newException(ValueError, "Function keys start at 1")
  normalized(KeyChord(code: KeyCode.Function, functionKey: number, modifiers: modifiers))

func chordOf*(key: KeyEvent): KeyChord =
  normalized(KeyChord(code: key.code, text: key.text, functionKey: key.functionKey,
    modifiers: key.modifiers))

func isPrintable*(c: KeyChord): bool =
  ## Plain text a text control must receive instead of a shortcut.
  let n = normalized(c)
  n.code == KeyCode.Character and (n.modifiers * CommandModifiers) == {}

func `==`*(a, b: KeyChord): bool =
  let x = normalized(a)
  let y = normalized(b)
  x.code == y.code and x.text == y.text and x.functionKey == y.functionKey and
    x.modifiers == y.modifiers

const keyNames = [
  ("enter", KeyCode.Enter), ("return", KeyCode.Enter), ("esc", KeyCode.Escape),
  ("escape", KeyCode.Escape), ("tab", KeyCode.Tab), ("backtab", KeyCode.BackTab),
  ("backspace", KeyCode.Backspace), ("delete", KeyCode.Delete), ("del", KeyCode.Delete),
  ("insert", KeyCode.Insert), ("ins", KeyCode.Insert), ("left", KeyCode.Left),
  ("right", KeyCode.Right), ("up", KeyCode.Up), ("down", KeyCode.Down),
  ("home", KeyCode.Home), ("end", KeyCode.End), ("pageup", KeyCode.PageUp),
  ("pgup", KeyCode.PageUp), ("pagedown", KeyCode.PageDown), ("pgdn", KeyCode.PageDown)]

func parseChord*(spec: string): KeyChord =
  ## Parses `ctrl+shift+left`, `alt+x`, `f5`, `space` or `plus`. Names are case-insensitive;
  ## a single character other than a letter is taken literally. Raises `ValueError`.
  let parts = spec.split('+')
  if spec.len == 0 or parts.anyIt(it.len == 0) and spec != "+":
    raise newException(ValueError, "Invalid key chord: " & spec)
  if spec == "+": return chord("+")
  var modifiers: KeyModifiers
  for i in 0..<parts.high:
    case parts[i].toLowerAscii
    of "ctrl", "control": modifiers.incl KeyModifier.Control
    of "alt", "option", "opt": modifiers.incl KeyModifier.Alt
    of "shift": modifiers.incl KeyModifier.Shift
    of "super", "cmd", "command", "win": modifiers.incl KeyModifier.Super
    of "hyper": modifiers.incl KeyModifier.Hyper
    of "meta": modifiers.incl KeyModifier.Meta
    else: raise newException(ValueError, "Unknown modifier in key chord: " & spec)
  let key = parts[^1]
  let lower = key.toLowerAscii
  for (name, code) in keyNames:
    if lower == name: return chord(code, modifiers)
  if lower == "space": return chord(" ", modifiers)
  if lower == "plus": return chord("+", modifiers)
  if lower.len >= 2 and lower[0] == 'f' and lower[1..^1].allCharsInSet(Digits):
    return functionChord(parseInt(lower[1..^1]), modifiers)
  if key.runeLen == 1:
    return chord(if key.isAsciiLetter: lower else: key, modifiers)
  raise newException(ValueError, "Unknown key in key chord: " & spec)

func `$`*(c: KeyChord): string =
  ## Hint text such as `Ctrl+Shift+Left`, `Ctrl+P`, `Shift+A` or `F5`.
  let n = normalized(c)
  var parts: seq[string]
  if KeyModifier.Control in n.modifiers: parts.add "Ctrl"
  if KeyModifier.Alt in n.modifiers: parts.add "Alt"
  if KeyModifier.Super in n.modifiers: parts.add "Super"
  if KeyModifier.Hyper in n.modifiers: parts.add "Hyper"
  if KeyModifier.Meta in n.modifiers: parts.add "Meta"
  case n.code
  of KeyCode.Character:
    if n.text.isAsciiLetter and n.text[0] in {'A'..'Z'}: parts.add "Shift"
    if KeyModifier.Shift in n.modifiers: parts.add "Shift"
    parts.add(if n.text == " ": "Space" elif n.text.isAsciiLetter: n.text.toUpperAscii
      else: n.text)
  of KeyCode.Function:
    if KeyModifier.Shift in n.modifiers: parts.add "Shift"
    parts.add "F" & $n.functionKey
  else:
    if KeyModifier.Shift in n.modifiers: parts.add "Shift"
    parts.add(case n.code
      of KeyCode.PageUp: "PageUp"
      of KeyCode.PageDown: "PageDown"
      of KeyCode.Escape: "Esc"
      else: $n.code)
  parts.join("+")

func matchesEvent(binding: Binding, key: KeyEvent, textEntry: bool): bool =
  case key.kind
  of KeyEventKind.Release: return false
  of KeyEventKind.Repeat:
    if not binding.repeat: return false
  of KeyEventKind.Press: discard
  let pressed = chordOf(key)
  if textEntry and pressed.isPrintable: return false
  binding.chord == pressed

func initKeymap*(): Keymap = Keymap()

iterator items*(keymap: Keymap): Binding =
  for binding in keymap.bindings: yield binding

func len*(keymap: Keymap): int = keymap.bindings.len

proc bindKey*(keymap: var Keymap, context: string, chord: KeyChord, action: ActionId,
    repeat = false, replace = false) =
  ## Adds a binding. The same chord, context and action is updated in place. A different
  ## action for the same chord and context raises `KeymapConflictError` unless `replace`.
  let key = normalized(chord)
  for binding in keymap.bindings.mitems:
    if binding.context == context and binding.chord == key:
      if binding.action != action and not replace:
        raise newException(KeymapConflictError, "Key " & $key & " in context '" & context &
          "' is already bound to " & $binding.action)
      binding.action = action
      binding.repeat = repeat
      return
  keymap.bindings.add Binding(context: context, chord: key, action: action, repeat: repeat)

proc bindKey*(keymap: var Keymap, context, chord: string, action: ActionId, repeat = false,
    replace = false) =
  keymap.bindKey(context, parseChord(chord), action, repeat, replace)

proc unbindKey*(keymap: var Keymap, context: string, chord: KeyChord): bool {.discardable.} =
  ## Removes the binding for a chord; returns whether one existed.
  for i, binding in keymap.bindings:
    if binding.context == context and binding.chord == chord:
      keymap.bindings.delete(i)
      return true

proc unbindKey*(keymap: var Keymap, context, chord: string): bool {.discardable.} =
  keymap.unbindKey(context, parseChord(chord))

proc unbindAction*(keymap: var Keymap, context: string, action: ActionId): int {.discardable.} =
  ## Removes every chord for `action` in `context`; returns how many were removed.
  var kept: seq[Binding]
  for binding in keymap.bindings:
    if binding.context == context and binding.action == action: inc result
    else: kept.add binding
  keymap.bindings = kept

const Disabled* = ActionId("canopy.disabled")
  ## Binding a chord to `Disabled` in an override layer hides lower layers' binding for it.

proc disableKey*(keymap: var Keymap, context: string, chord: KeyChord) =
  ## Makes `resolve` stop at this layer with no action for `chord` in `context`.
  keymap.bindKey(context, chord, Disabled, repeat = true, replace = true)

proc disableKey*(keymap: var Keymap, context, chord: string) =
  keymap.disableKey(context, parseChord(chord))

func lookupBinding(keymap: Keymap, context: string, event: Event,
    textEntry: bool): Option[ActionId] =
  if event.kind != EventKind.Key: return
  for binding in keymap.bindings:
    if binding.context == context and binding.matchesEvent(event.key, textEntry):
      return some(binding.action)

func lookup*(keymap: Keymap, context: string, event: Event,
    textEntry = false): Option[ActionId] =
  ## The action bound to a key event in one context. Paste and non-key events never match.
  result = keymap.lookupBinding(context, event, textEntry)
  if result == some(Disabled): result = none(ActionId)

func resolve*(layers: openArray[Keymap], contexts: openArray[string], event: Event,
    textEntry = false): Option[ActionId] =
  ## Searches layers in order (for example a control override, then the application keymap),
  ## and within each layer the contexts in order. The first match wins.
  for layer in layers:
    for context in contexts:
      result = layer.lookupBinding(context, event, textEntry)
      if result.isSome:
        if result.get == Disabled: result = none(ActionId)
        return

func chordsFor*(keymap: Keymap, context: string, action: ActionId): seq[KeyChord] =
  ## Chords bound to an action, in binding order; use the first as a shortcut hint.
  for binding in keymap.bindings:
    if binding.context == context and binding.action == action: result.add binding.chord

func conflicts*(keymap: Keymap, contexts: openArray[string]):
    seq[tuple[chord: KeyChord, bindings: seq[Binding]]] =
  ## Chords bound in more than one of `contexts`, which resolve by context order.
  for i, binding in keymap.bindings:
    if binding.context notin contexts: continue
    var seen = false
    for entry in result:
      if entry.chord == binding.chord: seen = true
    if seen: continue
    var group = @[binding]
    for j in i+1..keymap.bindings.high:
      let other = keymap.bindings[j]
      if other.context in contexts and other.context != binding.context and
          other.chord == binding.chord:
        group.add other
    if group.len > 1: result.add (binding.chord, group)

# Standard actions used by the built-in controls.

const
  FocusNext* = ActionId("focus.next")
  FocusPrevious* = ActionId("focus.previous")
  TextLeft* = ActionId("text.left")
  TextRight* = ActionId("text.right")
  TextWordLeft* = ActionId("text.wordLeft")
  TextWordRight* = ActionId("text.wordRight")
  TextHome* = ActionId("text.home")
  TextEnd* = ActionId("text.end")
  TextUp* = ActionId("text.up")
  TextDown* = ActionId("text.down")
  TextPageUp* = ActionId("text.pageUp")
  TextPageDown* = ActionId("text.pageDown")
  TextDocumentStart* = ActionId("text.documentStart")
  TextDocumentEnd* = ActionId("text.documentEnd")
  TextSelectLeft* = ActionId("text.selectLeft")
  TextSelectRight* = ActionId("text.selectRight")
  TextSelectWordLeft* = ActionId("text.selectWordLeft")
  TextSelectWordRight* = ActionId("text.selectWordRight")
  TextSelectHome* = ActionId("text.selectHome")
  TextSelectEnd* = ActionId("text.selectEnd")
  TextSelectUp* = ActionId("text.selectUp")
  TextSelectDown* = ActionId("text.selectDown")
  TextSelectDocumentStart* = ActionId("text.selectDocumentStart")
  TextSelectDocumentEnd* = ActionId("text.selectDocumentEnd")
  TextSelectAll* = ActionId("text.selectAll")
  TextBackspace* = ActionId("text.backspace")
  TextDelete* = ActionId("text.delete")
  TextDeleteWordLeft* = ActionId("text.deleteWordLeft")
  TextDeleteWordRight* = ActionId("text.deleteWordRight")
  TextUndo* = ActionId("text.undo")
  TextRedo* = ActionId("text.redo")
  TextCopy* = ActionId("text.copy")
  TextCut* = ActionId("text.cut")
  TextPaste* = ActionId("text.paste")
  TextSubmit* = ActionId("text.submit")
  TextNewline* = ActionId("text.newline")
  ListPrevious* = ActionId("list.previous")
  ListNext* = ActionId("list.next")
  ListFirst* = ActionId("list.first")
  ListLast* = ActionId("list.last")
  ListPageUp* = ActionId("list.pageUp")
  ListPageDown* = ActionId("list.pageDown")
  ListActivate* = ActionId("list.activate")
  TreeExpand* = ActionId("tree.expand")
  TreeCollapse* = ActionId("tree.collapse")
  TreeToggle* = ActionId("tree.toggle")
  PaletteExecute* = ActionId("palette.execute")
  PaletteDismiss* = ActionId("palette.dismiss")
  DialogAccept* = ActionId("dialog.accept")
  DialogCancel* = ActionId("dialog.cancel")
  ButtonPress* = ActionId("button.press")
  FormSubmit* = ActionId("form.submit")
  FormReset* = ActionId("form.reset")

proc defaultKeymap*(): Keymap =
  ## Standard bindings. Ctrl+C is left to the application. Copy is Ctrl+Insert, cut Ctrl+X,
  ## and paste of the internal clipboard Shift+Insert; terminal paste arrives as `Paste`.
  template add(context, spec: string, action: ActionId, repeat = false) =
    result.bindKey(context, spec, action, repeat)
  add FocusContext, "tab", FocusNext, true
  add FocusContext, "shift+tab", FocusPrevious, true
  add TextContext, "left", TextLeft, true
  add TextContext, "right", TextRight, true
  add TextContext, "ctrl+left", TextWordLeft, true
  add TextContext, "alt+left", TextWordLeft, true
  add TextContext, "alt+b", TextWordLeft, true
  add TextContext, "ctrl+right", TextWordRight, true
  add TextContext, "alt+right", TextWordRight, true
  add TextContext, "alt+f", TextWordRight, true
  add TextContext, "home", TextHome
  add TextContext, "end", TextEnd
  add TextContext, "ctrl+e", TextEnd
  add TextContext, "shift+left", TextSelectLeft, true
  add TextContext, "shift+right", TextSelectRight, true
  add TextContext, "ctrl+shift+left", TextSelectWordLeft, true
  add TextContext, "ctrl+shift+right", TextSelectWordRight, true
  add TextContext, "shift+home", TextSelectHome
  add TextContext, "shift+end", TextSelectEnd
  add TextContext, "ctrl+a", TextSelectAll
  add TextContext, "backspace", TextBackspace, true
  add TextContext, "delete", TextDelete, true
  add TextContext, "ctrl+d", TextDelete, true
  add TextContext, "ctrl+w", TextDeleteWordLeft, true
  add TextContext, "alt+backspace", TextDeleteWordLeft, true
  add TextContext, "ctrl+delete", TextDeleteWordRight, true
  add TextContext, "alt+d", TextDeleteWordRight, true
  add TextContext, "ctrl+z", TextUndo, true
  add TextContext, "ctrl+y", TextRedo, true
  add TextContext, "ctrl+shift+z", TextRedo, true
  add TextContext, "ctrl+insert", TextCopy
  add TextContext, "ctrl+x", TextCut
  add TextContext, "shift+insert", TextPaste
  add TextContext, "enter", TextSubmit
  add TextAreaContext, "enter", TextNewline, true
  add TextAreaContext, "up", TextUp, true
  add TextAreaContext, "down", TextDown, true
  add TextAreaContext, "shift+up", TextSelectUp, true
  add TextAreaContext, "shift+down", TextSelectDown, true
  add TextAreaContext, "pageup", TextPageUp, true
  add TextAreaContext, "pagedown", TextPageDown, true
  add TextAreaContext, "ctrl+home", TextDocumentStart
  add TextAreaContext, "ctrl+end", TextDocumentEnd
  add TextAreaContext, "ctrl+shift+home", TextSelectDocumentStart
  add TextAreaContext, "ctrl+shift+end", TextSelectDocumentEnd
  add ListContext, "up", ListPrevious, true
  add ListContext, "down", ListNext, true
  add ListContext, "ctrl+p", ListPrevious, true
  add ListContext, "ctrl+n", ListNext, true
  add ListContext, "home", ListFirst
  add ListContext, "end", ListLast
  add ListContext, "pageup", ListPageUp, true
  add ListContext, "pagedown", ListPageDown, true
  add ListContext, "enter", ListActivate
  add TreeContext, "right", TreeExpand, true
  add TreeContext, "left", TreeCollapse, true
  add TreeContext, "space", TreeToggle
  add PaletteContext, "enter", PaletteExecute
  add PaletteContext, "escape", PaletteDismiss
  add DialogContext, "enter", DialogAccept
  add DialogContext, "escape", DialogCancel
  add DialogContext, "left", FocusPrevious, true
  add DialogContext, "right", FocusNext, true
  add ButtonContext, "enter", ButtonPress
  add ButtonContext, "space", ButtonPress
  add FormContext, "enter", FormSubmit

let standardKeymap* = defaultKeymap()
  ## Shared default bindings. Copy it (`var keys = standardKeymap`) to customize.
