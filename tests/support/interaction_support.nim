## Helpers for interaction and control tests.
import std/options

import canopy/ui/controls/index

proc id*(name: string): ControlId = controlId(name)

proc rowText*(buf: Buffer, y: int): string =
  ## Row symbols; the trailing cells of wide clusters print as nothing.
  var skip = 0
  for x in buf.area.x..<buf.area.right:
    if skip > 0:
      dec skip
      continue
    let s = buf[x, y].symbol
    result.add s
    skip = max(0, cellWidth(s)-1)

proc rows*(buf: Buffer): seq[string] =
  for y in buf.area.y..<buf.area.bottom: result.add buf.rowText(y)

proc key*(code: KeyCode, mods: KeyModifiers = {}): Event = keyEvent(code, modifiers = mods)
proc ch*(text: string, mods: KeyModifiers = {}): Event =
  keyEvent(KeyCode.Character, text, mods)
proc paste*(text: string): Event = Event(kind: EventKind.Paste, text: text)
proc mouse*(kind: MouseEventKind, x, y: int, button = some(MouseButton.Left),
    mods: KeyModifiers = {}): Event =
  Event(kind: EventKind.Mouse, mouse: MouseEvent(kind: kind, column: x, row: y, button: button,
    modifiers: mods))

const
  ctrl* = {KeyModifier.Control}
  shift* = {KeyModifier.Shift}
  alt* = {KeyModifier.Alt}
