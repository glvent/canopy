## Event routing and handler results (Canopy extension).
##
## `route` decides once per event which control may act; it never calls handlers. The
## application dispatches: the target control, then enclosing compound controls innermost
## first (`route.scopes`), then `handleTraversal`, then `resolveApplication`, stopping at the
## first consumed result.
import std/options

import ../../runtime/terminal/events
import ./[ids, focus, keymap]
export events, ids, focus, keymap, options

type
  Route* = object
    event*: Event
    target*: Option[ControlId]
      ## The only control that should act on this event.
    scopes*: seq[ControlId]
      ## Scopes enclosing the target, innermost first; dispatch compound handlers in this order.
    modal*: Option[ControlId]
      ## Active modal. While set, controls and application handlers outside it must not act.
    textEntry*: bool
      ## The target accepts text, so printable characters must not trigger shortcuts.
    focusChanged*: bool
      ## A pointer press moved focus while routing.
    insideModal*: bool
      ## Pointer events: the position lies inside the active modal's scope.
  EventResult* = object
    consumed*: bool ## Stop dispatching this event.
    redraw*: bool ## Visible state changed.
    changed*: bool ## The control's value changed (text, selection, expansion).
    action*: Option[ActionId] ## Semantic action for the application to perform.
    subject*: string ## ID the action concerns: command, node, button, form or dialog.

func ignored*(): EventResult = EventResult()
func consumed*(redraw = true): EventResult = EventResult(consumed: true, redraw: redraw)
func emitted*(action: ActionId, subject = "", changed = false): EventResult =
  EventResult(consumed: true, redraw: true, changed: changed, action: some(action),
    subject: subject)

proc add*(result: var EventResult, other: EventResult) =
  ## Merges `other`; a later action replaces an earlier one.
  result.consumed = result.consumed or other.consumed
  result.redraw = result.redraw or other.redraw
  result.changed = result.changed or other.changed
  if other.action.isSome:
    result.action = other.action
    result.subject = other.subject

func targets*(route: Route, id: ControlId): bool =
  route.target.isSome and route.target.get == id

func within*(route: Route, scope: ControlId): bool =
  ## The target is inside `scope`, or `scope` is the active modal.
  scope in route.scopes or route.modal == some(scope)

func allowsApplication*(route: Route): bool =
  ## False while a modal is open: raw application handlers for the base layer must not act.
  route.modal.isNone

func isPress*(event: Event): bool =
  ## Key press or repeat; release events are ignored by built-in controls.
  event.kind == EventKind.Key and event.key.kind != KeyEventKind.Release

func mousePosition*(event: Event): Position =
  initPosition(event.mouse.column, event.mouse.row)

proc route*(fm: var FocusManager, event: Event): Route =
  ## Resolves the target for one event using the last completed frame. Updates pointer capture,
  ## click-to-focus, geometry staleness after resize, and terminal focus.
  result.event = event
  result.modal = fm.activeModal
  var target = none(ControlId)
  case event.kind
  of EventKind.Key, EventKind.Paste:
    target = fm.focused
  of EventKind.Mouse:
    let position = event.mousePosition
    result.insideModal = fm.insideModal(position)
    let hit = fm.hitTest(position)
    case event.mouse.kind
    of MouseEventKind.Down:
      if hit.isSome and hit.get.enabled:
        target = some(hit.get.id)
        fm.setCapture(target)
        if event.mouse.button == some(MouseButton.Left) and not fm.isFocused(hit.get.id):
          result.focusChanged = fm.focus(hit.get.id)
      else: fm.setCapture(none(ControlId))
    of MouseEventKind.Drag, MouseEventKind.Up:
      target = fm.captured
      if target.isNone and hit.isSome and hit.get.enabled: target = some(hit.get.id)
      if event.mouse.kind == MouseEventKind.Up: fm.setCapture(none(ControlId))
    else:
      if hit.isSome and hit.get.enabled: target = some(hit.get.id)
  of EventKind.Resize:
    fm.markGeometryStale()
  of EventKind.FocusGained: fm.terminalFocused = true
  of EventKind.FocusLost: fm.terminalFocused = false
  of EventKind.Unsupported: discard
  result.target = target
  if target.isSome:
    let registration = fm.registration(target.get)
    if registration.isSome:
      result.scopes = registration.get.scopes
      result.textEntry = registration.get.textEntry

proc handleTraversal*(fm: var FocusManager, route: Route,
    keymap: Keymap = standardKeymap): EventResult =
  ## Tab and Shift+Tab (the `focus` context). In an open modal, traversal is always consumed
  ## so it cannot escape, even when the modal has no focusable controls.
  let action = keymap.lookup(FocusContext, route.event)
  if action.isNone: return
  let moved = if action.get == FocusNext: fm.focusNext()
    elif action.get == FocusPrevious: fm.focusPrevious()
    else: false
  if moved or route.modal.isSome: result = consumed(moved)

func resolveApplication*(keymap: Keymap, route: Route): Option[ActionId] =
  ## Application bindings: `global` always, `app` only without a modal. Printable characters
  ## never match while the target accepts text.
  if route.modal.isSome: keymap.lookup(GlobalContext, route.event, route.textEntry)
  else: resolve([keymap], [GlobalContext, AppContext], route.event, route.textEntry)
