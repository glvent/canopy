## Interaction layer over the native Windows console: key records injected with
## WriteConsoleInputW are read by `Input`, routed to controls, and rendered through the ANSI
## backend on CONOUT$.
import std/unittest

when defined(windows):
  import std/[options, unicode, winlean]
  import canopy
  import canopy/runtime/terminal/input
  import canopy/ui/controls/index

  type
    NativeKeyEvent {.importc: "KEY_EVENT_RECORD", header: "<windows.h>".} = object
      keyDown {.importc: "bKeyDown".}: WINBOOL
      repeatCount {.importc: "wRepeatCount".}: uint16
      virtualKeyCode {.importc: "wVirtualKeyCode".}: uint16
      virtualScanCode {.importc: "wVirtualScanCode".}: uint16
      unicodeChar {.importc: "uChar.UnicodeChar".}: uint16
      controlKeyState {.importc: "dwControlKeyState".}: uint32
    NativeInputRecord {.importc: "INPUT_RECORD", header: "<windows.h>".} = object
      eventType {.importc: "EventType".}: uint16
      keyEvent {.importc: "Event.KeyEvent".}: NativeKeyEvent
    ConsoleFixture = object
      input, output: File
      allocated: bool

  const KeyEventRecord = 0x0001'u16

  proc allocConsole(): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "AllocConsole".}
  proc freeConsole(): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "FreeConsole".}
  proc getOsHandle(fd: cint): Handle
    {.importc: "_get_osfhandle", header: "<io.h>".}
  proc writeConsoleInput(handle: Handle, records: ptr NativeInputRecord,
                         count: uint32, written: ptr uint32): WINBOOL
    {.stdcall, dynlib: "kernel32", importc: "WriteConsoleInputW".}

  proc osHandle(file: File): Handle = getOsHandle(cint(file.getFileHandle))

  proc openConsole(): ConsoleFixture =
    if not open(result.input, "CONIN$", fmReadWriteExisting) or
        not open(result.output, "CONOUT$", fmReadWriteExisting):
      if result.input != nil: close(result.input)
      if result.output != nil: close(result.output)
      if allocConsole() == 0:
        raise newException(IOError, "AllocConsole failed: " & $getLastError())
      result.allocated = true
      if not open(result.input, "CONIN$", fmReadWriteExisting) or
          not open(result.output, "CONOUT$", fmReadWriteExisting):
        if result.input != nil: close(result.input)
        if result.output != nil: close(result.output)
        discard freeConsole()
        raise newException(IOError, "opening CONIN$/CONOUT$ failed")

  proc close(console: var ConsoleFixture) =
    if console.input != nil: close(console.input)
    if console.output != nil: close(console.output)
    if console.allocated: discard freeConsole()

  proc inject(console: ConsoleFixture, text: string) =
    ## One key-down record per UTF-16 code unit (the inputs here are all in the BMP).
    var records: seq[NativeInputRecord]
    for r in text.runes:
      var record: NativeInputRecord
      record.eventType = KeyEventRecord
      record.keyEvent.keyDown = 1
      record.keyEvent.repeatCount = 1
      record.keyEvent.unicodeChar = uint16(r.int)
      records.add record
    var written: uint32
    require writeConsoleInput(console.input.osHandle, addr records[0],
      uint32(records.len), addr written) != 0
    require written == uint32(records.len)

  proc pollAll(source: var Input, expected: int): seq[input.Event] =
    ## Collects key events until `expected` arrived or the console stays quiet.
    var quiet = 0
    while result.len < expected and quiet < 10:
      let e = source.poll(100)
      if e.isNone: inc quiet
      elif e.get.kind == EventKind.Key: result.add e.get

  suite "interaction over the Windows console":
    test "injected keys route through real input, focus, modals and rendering":
      var console = openConsole()
      defer: console.close()
      var source = initInput(console.input, console.output, InputCapabilities(),
        rawMode = true)
      source.init()
      defer: source.restore()
      var term = initTerminal(initAnsiBackend(console.output, console.input,
        alternateScreen = false, rawMode = false))
      defer: term.restore()
      var fm = initFocusManager()
      var name = initTextInputState(controlId("name"))
      var other = initTextInputState(controlId("other"))
      var dialog = initDialogState(controlId("confirm"), [dialogButton("ok", "OK",
        actionId("ok")), dialogButton("cancel", "Cancel", actionId("cancel"))])
      proc draw() =
        discard term.drawInteractive(fm, frame):
          let w = min(20, frame.area.width)
          frame.renderControl(fm, initTextInput("name"), initRect(0, 0, w, 1), name)
          frame.renderControl(fm, initTextInput("other"), initRect(0, 1, w, 1), other)
          frame.renderControl(fm, initDialog("Confirm", "Proceed?"), frame.area, dialog)
      proc dispatch(e: input.Event): EventResult =
        let route = fm.route(e)
        result = dialog.handle(fm, route)
        if not result.consumed and route.allowsApplication:
          result = name.handle(route)
          if not result.consumed: result = other.handle(route)
        if not result.consumed: result = fm.handleTraversal(route)

      fm.focus(name.id)
      draw()
      check fm.focused == some(name.id)
      # Typed text including Latin-1 and CJK, then DEL as Backspace, then Tab to the next field.
      console.inject("Zoë 界x\x7f\tok")
      for e in source.pollAll(10): discard dispatch(e)
      check name.text == "Zoë 界"
      check other.text == "ok"
      check fm.focused == some(other.id)
      draw()
      check name.cursor.isNone and other.cursor.isSome

      # A dialog opened between frames owns keys before its first frame.
      dialog.open(fm)
      console.inject("q\r")
      var results: seq[EventResult]
      for e in source.pollAll(2): results.add dispatch(e)
      check other.text == "ok"
      check results.len == 2 and results[^1].action == some(actionId("ok"))
      check not dialog.isOpen and fm.focused == some(other.id)
      draw()

else:
  suite "interaction over the Windows console":
    test "not applicable": check true
