## Modal dialog shell with title, body and buttons (Canopy extension).
import std/options

import "../widgets/block"
import ../widgets/paragraph
import ./common
export common, `block`, paragraph

type
  DialogButton* = object
    state*: ButtonState ## ID `<dialog>/<name>`.
    label*: string
    action*: ActionId
  DialogState* = object
    id*: ControlId
    buttons*: seq[DialogButton]
    accept*, cancel*: int ## Button indexes for Enter and Escape; -1 disables that key.
    dismissOnOutside*: bool ## A press outside cancels; otherwise it is swallowed.
    isOpen: bool
  Dialog* = object
    title*: string
    body*: Text
    theme*: ControlTheme
    width*, height*: int ## 0 sizes to the content.
    backdrop*: bool ## Dims everything outside the dialog.
    reveal*: float
      ## Opening progress in 0..1, such as a `Tween[float]` value with the `Decorative` role so
      ## reduced motion completes it at once. Default 1.

func dialogButton*(name, label: string, action: ActionId): tuple[name, label: string,
    action: ActionId] = (name, label, action)

func initDialogState*(id: ControlId, buttons: openArray[tuple[name, label: string,
    action: ActionId]], accept = 0, cancel = -1, dismissOnOutside = false): DialogState =
  ## `cancel = -1` picks the last button when there are several.
  result = DialogState(id: id, accept: accept, dismissOnOutside: dismissOnOutside)
  for b in buttons:
    result.buttons.add DialogButton(state: initButtonState(id.child(b.name)), label: b.label,
      action: b.action)
  result.cancel = if cancel >= 0: cancel elif buttons.len > 1: buttons.len-1 else: -1
  if result.accept >= buttons.len: result.accept = -1

func isOpen*(s: DialogState): bool = s.isOpen
func buttonId*(s: DialogState, i: int): ControlId = s.buttons[i].state.id

proc open*(s: var DialogState, fm: var FocusManager, initialFocus = none(ControlId)) =
  ## Opens the dialog as the top modal. Focus goes to `initialFocus`, else the accept button.
  s.isOpen = true
  let first = if initialFocus.isSome: initialFocus
    elif s.accept >= 0: some(s.buttonId(s.accept))
    else: none(ControlId)
  fm.openModal(s.id, first)

proc close*(s: var DialogState, fm: var FocusManager) =
  s.isOpen = false
  fm.closeModal(s.id)

func initDialog*(title: string, body: Text, theme = defaultTheme()): Dialog =
  Dialog(title: title, body: body, theme: theme, backdrop: true, reveal: 1.0)

func initDialog*(title, body: string, theme = defaultTheme()): Dialog =
  initDialog(title, initText(body), theme)

func withSize*(d: Dialog, width, height: int): Dialog =
  result = d
  result.width = width
  result.height = height

func withReveal*(d: Dialog, progress: float): Dialog =
  result = d
  result.reveal = clamp(progress, 0.0, 1.0)

func withBackdrop*(d: Dialog, enabled: bool): Dialog =
  result = d
  result.backdrop = enabled

func buttonsWidth(s: DialogState): int =
  for i, b in s.buttons: result += displayWidth(b.label)+4+(if i > 0: 2 else: 0)

func wrappedHeight(text: Text, width: int): int =
  for line in text.lines:
    let w = line.width
    result += max(1, (w+max(1, width)-1) div max(1, width))

func dialogArea*(d: Dialog, s: DialogState, area: Rect, bodyRows = 0): Rect =
  ## Outer rectangle, centered and clipped to `area`. `bodyRows` reserves extra body rows for
  ## controls rendered between `beginDialog` and `endDialog`.
  var width = if d.width > 0: d.width
    else: max(max(displayWidth(d.title)+6, s.buttonsWidth+4), min(56, d.body.width+4))
  width = min(width, area.width)
  let innerWidth = max(1, width-4)
  var height = if d.height > 0: d.height
    else: d.body.wrappedHeight(innerWidth)+bodyRows+(if s.buttons.len > 0: 2 else: 0)+2
  height = min(height, area.height)
  height = min(height, max(min(3, height), int(float(height)*d.reveal+0.5)))
  initRect(area.x+(area.width-width) div 2, area.y+(area.height-height) div 2, width, height)

proc beginDialog*(frame: var Frame, fm: var FocusManager, d: Dialog, area: Rect,
    state: DialogState, bodyRows = 0): Rect =
  ## Draws the backdrop, frame and body text and opens the modal scope. Returns the free body
  ## area below the text for extra controls. Must be paired with `endDialog`.
  let outer = d.dialogArea(state, area, bodyRows)
  if d.backdrop: frame.buffer[].setStyle(area, d.theme.backdrop)
  frame.buffer[].clearArea(outer)
  let outline = borderedBlock().withBorderType(BorderType.Rounded)
    .withTitle(" " & d.title & " ").withBorderStyle(d.theme.focusedBorder)
    .withTitleStyle(d.theme.label).withPadding(horizontalPadding(1))
  outline.render(outer, frame.buffer[])
  let inner = outline.inner(outer)
  fm.beginScope(state.id, outer, true)
  let textRows = min(inner.height, d.body.wrappedHeight(max(1, inner.width)))
  initParagraph(d.body).withWrap(initWrap(trim = true)).render(
    initRect(inner.x, inner.y, inner.width, textRows), frame.buffer[])
  let buttonRows = if state.buttons.len > 0: 2 else: 0
  initRect(inner.x, inner.y+textRows, inner.width,
    max(0, inner.height-textRows-buttonRows))

proc endDialog*(frame: var Frame, fm: var FocusManager, d: Dialog, area: Rect,
    state: var DialogState, bodyRows = 0) =
  ## Renders and registers the buttons right-aligned on the last row, then closes the scope.
  let outer = d.dialogArea(state, area, bodyRows)
  let inner = initRect(outer.x+2, outer.y+1, max(0, outer.width-4), max(0, outer.height-2))
  if state.buttons.len > 0 and inner.height > 0:
    let y = inner.bottom-1
    var x = max(inner.x, inner.right-state.buttonsWidth)
    for i in 0..state.buttons.high:
      let b = initButton(state.buttons[i].label, d.theme)
      let w = min(b.width, max(0, inner.right-x))
      frame.renderControl(fm, b, initRect(x, y, w, 1), state.buttons[i].state)
      x += w+2
  fm.endScope()

proc renderControl*(frame: var Frame, fm: var FocusManager, d: Dialog, area: Rect,
    state: var DialogState) =
  ## Renders an open dialog over `area`; does nothing when closed.
  if not state.isOpen: return
  discard frame.beginDialog(fm, d, area, state)
  frame.endDialog(fm, d, area, state)

proc finish(state: var DialogState, fm: var FocusManager, index: int): EventResult =
  let action = state.buttons[index].action
  state.close(fm)
  emitted(action, $state.id)

proc handle*(state: var DialogState, fm: var FocusManager, route: Route,
    keymap: Keymap = standardKeymap): EventResult =
  ## Dispatch after controls inside the dialog. A button press, Enter (accept) or Escape
  ## (cancel) closes the dialog and returns that button's action with the dialog ID as
  ## subject. Left/Right move between buttons.
  if not state.isOpen or route.modal != some(state.id): return
  let event = route.event
  for i in 0..state.buttons.high:
    if route.targets(state.buttons[i].state.id):
      let pressed = state.buttons[i].state.handle(route, keymap)
      if pressed.action == some(ButtonPress): return state.finish(fm, i)
      if pressed.consumed: return pressed
  case event.kind
  of EventKind.Mouse:
    if not route.insideModal and event.mouse.kind == MouseEventKind.Down:
      if state.dismissOnOutside and state.cancel >= 0: return state.finish(fm, state.cancel)
      return consumed(false)
  of EventKind.Key:
    if not event.isPress: return
    let action = keymap.lookup(DialogContext, event, route.textEntry)
    if action == some(DialogCancel) and state.cancel >= 0: return state.finish(fm, state.cancel)
    if action == some(DialogAccept) and state.accept >= 0: return state.finish(fm, state.accept)
    var onButton = false
    for b in state.buttons:
      if route.targets(b.state.id): onButton = true
    if onButton and action == some(FocusPrevious): return consumed(fm.focusPrevious())
    if onButton and action == some(FocusNext): return consumed(fm.focusNext())
  else: discard
