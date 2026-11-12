## Interaction layer over a real POSIX pseudo-terminal: bytes written to the master are read
## by `Input`, routed to controls, and rendered through the ANSI backend.
import std/[options, posix, strutils, unittest]

when defined(posix):
  import posix/termios
  import canopy
  import canopy/runtime/terminal/input
  import canopy/ui/controls/index

  when defined(macosx):
    proc openpty(master, slave: ptr cint, name: pointer, term: ptr Termios,
        size: ptr IOctl_WinSize): cint {.importc, header: "<util.h>".}
  else:
    proc openpty(master, slave: ptr cint, name: pointer, term: ptr Termios,
        size: ptr IOctl_WinSize): cint {.importc, header: "<pty.h>".}

  type Pty = object
    master, slave: File

  proc initPty(width = 40, height = 10): Pty =
    var masterFd, slaveFd: cint
    var dimensions = IOctl_WinSize(ws_col: cushort(width), ws_row: cushort(height))
    check openpty(addr masterFd, addr slaveFd, nil, nil, addr dimensions) == 0
    check open(result.master, FileHandle(masterFd), fmReadWrite)
    check open(result.slave, FileHandle(slaveFd), fmReadWrite)

  proc close(pty: var Pty) = close(pty.master); close(pty.slave)

  proc readAvailable(f: File): string =
    ## Reads what the master side has buffered without blocking.
    let fd = cint(f.getFileHandle)
    var buffer: array[4096, char]
    while true:
      var fds = [TPollfd(fd: fd, events: POLLIN)]
      if posix.poll(addr fds[0], 1, 20) <= 0: break
      let n = posix.read(fd, addr buffer[0], buffer.len)
      if n <= 0: break
      for i in 0..<n: result.add buffer[i]

  proc pollAll(source: var Input): seq[input.Event] =
    while true:
      let e = source.poll(30)
      if e.isNone: break
      result.add e.get

  suite "interaction over a pseudo-terminal":
    test "typed bytes, paste and modals route through real input and rendering":
      var pty = initPty(); defer: pty.close()
      var caps = InputCapabilities(bracketedPaste: true)
      var source = initInput(pty.slave, pty.slave, caps, true); source.init()
      defer: source.restore()
      var term = initTerminal(initAnsiBackend(pty.slave, pty.slave, false, false))
      defer: term.restore()
      var fm = initFocusManager()
      var name = initTextInputState(controlId("name"))
      var dialog = initDialogState(controlId("confirm"), [dialogButton("ok", "OK",
        actionId("ok")), dialogButton("cancel", "Cancel", actionId("cancel"))])
      proc draw() =
        discard term.drawInteractive(fm, frame):
          frame.renderControl(fm, initTextInput("name"), initRect(1, 1, 20, 1), name)
          frame.renderControl(fm, initDialog("Confirm", "Proceed?"), frame.area, dialog)
      proc dispatch(e: input.Event): EventResult =
        let route = fm.route(e)
        result = dialog.handle(fm, route)
        if not result.consumed and route.allowsApplication: result = name.handle(route)
        if not result.consumed: result = fm.handleTraversal(route)
      fm.focus(name.id)
      draw()
      discard pty.master.readAvailable()
      check fm.focused == some(name.id)
      pty.master.write("Zoë 界\e[D\x7f\e[200~ ok\r\n\e[201~")
      pty.master.flushFile()
      for e in source.pollAll: discard dispatch(e)
      check name.text == "Zoë ok 界"
      draw()
      let screen = pty.master.readAvailable()
      check "Zo" in screen and "ok" in screen
      check "\e[?25h" in screen # the cursor is shown for the focused input
      # A dialog opened between frames owns keys drained before its first frame: typed text
      # never reaches the field behind it, and Enter accepts.
      dialog.open(fm)
      pty.master.write("x\t\r")
      pty.master.flushFile()
      var results: seq[EventResult]
      for e in source.pollAll: results.add dispatch(e)
      check name.text == "Zoë ok 界"
      check results[^1].action == some(actionId("ok"))
      check not dialog.isOpen and fm.focused == some(name.id)
      # Once rendered, Tab moves between its buttons.
      dialog.open(fm)
      draw()
      check "Proceed" in pty.master.readAvailable()
      pty.master.write("\t\r")
      pty.master.flushFile()
      results.setLen(0)
      for e in source.pollAll: results.add dispatch(e)
      check results[^1].action == some(actionId("cancel"))
      check fm.focused == some(name.id)
      draw()
      check "Proceed" notin pty.master.readAvailable()

else:
  suite "interaction over a pseudo-terminal":
    test "not applicable": check true
