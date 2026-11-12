## Shared control styling, frame integration and the push button (Canopy extension).
import std/options

import ../../core/layout/geometry
import ../../core/rendering/buffer
import ../../core/styling/style
import ../../core/text/index as text
import ../../core/text/unicode
import ../../runtime/terminal/index as terminal
import ../interaction/index as interaction
export geometry, buffer, style, text, unicode, interaction, terminal

type
  ControlTheme* = object
    ## Styles shared by the built-in controls. State is never shown by color alone: focus also
    ## shows a cursor or marker, errors a `✗` glyph, disabled controls dim text.
    text*, focused*, placeholder*, selection*, disabled*, readOnly*, invalid*: Style
    border*, focusedBorder*, label*, help*, error*, highlight*, shortcut*, backdrop*: Style
    match*: Style ## Matched characters in palette results.
    marker*: string ## Prefix of the focused or selected row in lists and trees.

func defaultTheme*(): ControlTheme =
  ControlTheme(
    text: initStyle(),
    focused: initStyle().withAddModifier(Modifier.Bold),
    placeholder: initStyle().withFg(ColorKind.DarkGray),
    selection: initStyle().withAddModifier(Modifier.Reversed),
    disabled: initStyle().withFg(ColorKind.DarkGray).withAddModifier(Modifier.Dim),
    readOnly: initStyle().withAddModifier(Modifier.Italic),
    invalid: initStyle().withFg(ColorKind.LightRed),
    border: initStyle().withFg(ColorKind.DarkGray),
    focusedBorder: initStyle().withFg(ColorKind.Cyan),
    label: initStyle().withAddModifier(Modifier.Bold),
    help: initStyle().withFg(ColorKind.DarkGray),
    error: initStyle().withFg(ColorKind.LightRed),
    highlight: initStyle().withAddModifier(Modifier.Reversed),
    shortcut: initStyle().withFg(ColorKind.DarkGray),
    backdrop: initStyle().withAddModifier(Modifier.Dim),
    match: initStyle().withFg(ColorKind.Yellow).withAddModifier(Modifier.Bold),
    marker: "> ")

template drawInteractive*[B](terminal: var Terminal[B], fm: var FocusManager,
    frame, body: untyped): CompletedFrame =
  ## Renders a frame like `Terminal.draw`, inlining `body` so it can use `var` state without a
  ## closure. Runs `fm.beginFrame`/`endFrame` around `body` and renders once more when
  ## reconciliation moved focus (at most one extra pass). Any failure invalidates the terminal.
  block:
    var completedFrame: CompletedFrame
    if not terminal.initialized: raise newException(IOError, "Terminal is not initialized")
    try:
      for pass in 0..1:
        terminal.autoresize()
        terminal.currentBufferMut.reset()
        var frame = terminal.getFrame()
        fm.beginFrame()
        body
        if not fm.endFrame() or pass == 1:
          completedFrame = terminal.applyBufferWithCursor(frame.cursorPosition)
          break
    except CatchableError:
      terminal.invalidate()
      raise
    completedFrame

proc clearArea*(buf: var Buffer, area: Rect, style = initStyle()) =
  for p in buf.area.intersection(area).positions:
    buf[p].reset()
    buf[p].setStyle(style)

proc writeClipped*(buf: var Buffer, x, y: int, text: string, maxWidth: int,
    style = initStyle()): int {.discardable.} =
  ## Writes `text` within `maxWidth` cells; returns the cells used.
  if maxWidth <= 0: return 0
  buf.setStringn(x, y, text, maxWidth, style).x - x

func clipText*(text: string, width: int, ellipsis = "…"): string =
  ## Fits `text` in `width` cells, ending in `ellipsis` when cut.
  if displayWidth(text) <= width: return text
  if width <= displayWidth(ellipsis): return truncateWidth(text, width)
  truncateWidth(text, width-displayWidth(ellipsis)) & ellipsis

# Button.

type
  ButtonState* = object
    id*: ControlId
    enabled*: bool
    area*: Rect ## Rendered area, for pointer release checks.
  Button* = object
    label*: string
    theme*: ControlTheme

func initButtonState*(id: ControlId, enabled = true): ButtonState =
  ButtonState(id: id, enabled: enabled)
func initButton*(label: string, theme = defaultTheme()): Button =
  Button(label: label, theme: theme)
func width*(b: Button): int = displayWidth(b.label)+4

proc render*(b: Button, area: Rect, buf: var Buffer, state: var ButtonState, focused = false) =
  ## Renders `[ label ]`, or `[>label<]`-style brackets when focused so focus is not color-only.
  state.area = area
  if area.isEmpty: return
  let style = if not state.enabled: b.theme.disabled
    elif focused: b.theme.highlight else: b.theme.text
  let text = if focused: "▸ " & b.label & " ◂" else: "[ " & b.label & " ]"
  buf.writeClipped(area.x, area.y, clipText(text, area.width), area.width, style)

proc renderControl*(frame: var Frame, fm: var FocusManager, b: Button, area: Rect,
    state: var ButtonState) =
  fm.register(state.id, area, state.enabled)
  b.render(area, frame.buffer[], state, fm.isFocused(state.id))

proc handle*(state: var ButtonState, route: Route,
    keymap: Keymap = standardKeymap): EventResult =
  ## Enter or Space, or a left click released over the button, emits `button.press`.
  if not route.targets(state.id) or not state.enabled: return
  let event = route.event
  case event.kind
  of EventKind.Key:
    if keymap.lookup(ButtonContext, event) == some(ButtonPress):
      return emitted(ButtonPress, $state.id)
  of EventKind.Mouse:
    if event.mouse.button == some(MouseButton.Left):
      if event.mouse.kind == MouseEventKind.Up and
          state.area.contains(event.mousePosition):
        return emitted(ButtonPress, $state.id)
      if event.mouse.kind == MouseEventKind.Down: return consumed()
  else: discard
