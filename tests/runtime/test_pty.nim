## PTY-backed terminal integration smoke tests.
import std/[options, os, posix, unittest]

when defined(posix):
  import posix/termios
  import canopy/runtime/terminal/input
  import canopy/runtime/backends/ansi

  when defined(macosx):
    proc openpty(master, slave: ptr cint, name: pointer, term: pointer, size: pointer): cint {.importc, header: "<util.h>".}
  else:
    proc openpty(master, slave: ptr cint, name: pointer, term: pointer, size: pointer): cint {.importc, header: "<pty.h>".}
  var TIOCSWINSZ {.importc, header: "<sys/ioctl.h>".}: culong

  type Pty = object
    master, slave: File

  proc initPty(width = 80, height = 24): Pty =
    var masterFd, slaveFd: cint; var dimensions = IOctl_WinSize(ws_col: cushort(width), ws_row: cushort(height))
    check openpty(addr masterFd, addr slaveFd, nil, nil, addr dimensions) == 0
    check open(result.master, FileHandle(masterFd), fmReadWrite)
    check open(result.slave, FileHandle(slaveFd), fmReadWrite)

  proc close(pty: var Pty) = close(pty.master); close(pty.slave)

  suite "POSIX pseudo-terminal integration":
    test "raw mode is applied and restored exactly":
      var pty = initPty(); defer: pty.close()
      var original: Termios; check tcGetAttr(cint(pty.slave.getFileHandle), addr original) == 0
      var backend = initAnsiBackend(pty.slave, pty.slave, false, true); backend.init()
      var raw: Termios; check tcGetAttr(cint(pty.slave.getFileHandle), addr raw) == 0
      check (raw.c_lflag and (ICANON or ECHO)) == 0
      backend.restore(); var restored: Termios; check tcGetAttr(cint(pty.slave.getFileHandle), addr restored) == 0
      when defined(macosx):
        # PENDIN is kernel-owned state and is set when canonical processing is
        # restored. All application-controlled flags still round-trip exactly.
        const PendIn = Cflag(0x20000000'u32)
        check (restored.c_lflag and not PendIn) == (original.c_lflag and not PendIn)
      else: check restored.c_lflag == original.c_lflag
      check restored.c_iflag == original.c_iflag and restored.c_oflag == original.c_oflag and restored.c_cflag == original.c_cflag

    test "cursor position and character window size come from the terminal":
      var pty = initPty(93, 31); defer: pty.close()
      var backend = initAnsiBackend(pty.slave, pty.slave, false, true); backend.init(); defer: backend.restore()
      pty.master.write("\e[7;12R"); pty.master.flushFile()
      check backend.getCursorPosition == initPosition(11, 6)
      check backend.windowSize.columnsRows == initSize(93, 31)

    test "cursor query preserves unrelated input bytes":
      var pty = initPty(); defer: pty.close()
      var backend = initAnsiBackend(pty.slave, pty.slave, false, true); backend.init(); defer: backend.restore()
      pty.master.write("x\e[7;12Ry"); pty.master.flushFile()
      check backend.getCursorPosition == initPosition(11, 6)
      var source = initInput(pty.slave, pty.slave, InputCapabilities(), false); source.init(); defer: source.restore()
      let x = source.poll(0); let y = source.poll(0)
      check x.isSome and x.get.key.text == "x"
      check y.isSome and y.get.key.text == "y"

    test "partial backend initialization restores raw mode":
      var pty = initPty(); defer: pty.close()
      var original: Termios; check tcGetAttr(cint(pty.slave.getFileHandle), addr original) == 0
      let path = getTempDir()/"canopy-pty-read-only-output.tmp"; var output: File
      writeFile(path, "")
      check open(output, path, fmRead)
      defer: removeFile(path)
      defer: close(output)
      var backend = initAnsiBackend(output, pty.slave, true, true)
      expect IOError: backend.init()
      var restored: Termios; check tcGetAttr(cint(pty.slave.getFileHandle), addr restored) == 0
      when defined(macosx):
        const PendIn = Cflag(0x20000000'u32)
        check (restored.c_lflag and not PendIn) == (original.c_lflag and not PendIn)
      else: check restored.c_lflag == original.c_lflag
      check restored.c_iflag == original.c_iflag and restored.c_oflag == original.c_oflag and restored.c_cflag == original.c_cflag

    test "partial input initialization restores raw mode":
      var pty = initPty(); defer: pty.close()
      var original: Termios; check tcGetAttr(cint(pty.slave.getFileHandle), addr original) == 0
      let path = getTempDir()/"canopy-pty-read-only-input-output.tmp"; var output: File
      writeFile(path, "")
      check open(output, path, fmRead)
      defer: removeFile(path)
      defer: close(output)
      var source = initInput(pty.slave, output, defaultInputCapabilities(), true)
      expect IOError: source.init()
      var restored: Termios; check tcGetAttr(cint(pty.slave.getFileHandle), addr restored) == 0
      when defined(macosx):
        const PendIn = Cflag(0x20000000'u32)
        check (restored.c_lflag and not PendIn) == (original.c_lflag and not PendIn)
      else: check restored.c_lflag == original.c_lflag
      check restored.c_iflag == original.c_iflag and restored.c_oflag == original.c_oflag and restored.c_cflag == original.c_cflag

    test "timed polling reads fragmented terminal input":
      var pty = initPty(); defer: pty.close()
      var source = initInput(pty.slave, pty.slave, InputCapabilities(), true); source.init(); defer: source.restore()
      pty.master.write("\e["); pty.master.flushFile(); check source.poll(0).isNone
      pty.master.write("A界"); pty.master.flushFile()
      let up = source.poll(100); check up.isSome and up.get.key.code == KeyCode.Up
      let wide = source.poll(0); check wide.isSome and wide.get.key.text == "界"

    test "standalone escape is resolved after timeout":
      var pty = initPty(); defer: pty.close()
      var source = initInput(pty.slave, pty.slave, InputCapabilities(), true); source.init(); defer: source.restore()
      pty.master.write("\e"); pty.master.flushFile()
      let event = source.poll(50); check event.isSome and event.get.key.code == KeyCode.Escape

    test "zero timeout never waits for escape disambiguation":
      var pty = initPty(); defer: pty.close()
      var source = initInput(pty.slave, pty.slave, InputCapabilities(), true); source.init(); defer: source.restore()
      pty.master.write("\e"); pty.master.flushFile()
      check source.poll(0).isNone
      sleep(30)
      let event = source.poll(0); check event.isSome and event.get.key.code == KeyCode.Escape

    test "terminal resize becomes an event":
      var pty = initPty(80, 24); defer: pty.close()
      var source = initInput(pty.slave, pty.slave, InputCapabilities(), false); source.init(); defer: source.restore()
      var dimensions = IOctl_WinSize(ws_col: cushort(101), ws_row: cushort(37))
      check ioctl(cint(pty.slave.getFileHandle), TIOCSWINSZ, addr dimensions) == 0
      let event = source.poll(0); check event.isSome and event.get.kind == EventKind.Resize
      check event.get.width == 101 and event.get.height == 37

    test "hangup becomes EOF instead of an infinite poll":
      var descriptors: array[2, cint]
      check posix.pipe(descriptors) == 0
      var reader, writer: File
      check open(reader, FileHandle(descriptors[0]), fmRead)
      check open(writer, FileHandle(descriptors[1]), fmWrite)
      close(writer); defer: close(reader)
      var source = initInput(reader, stdout, InputCapabilities(), false); source.init(); defer: source.restore()
      check source.poll(50).isNone and source.eof
      expect EOFError: discard source.read()

else:
  suite "POSIX pseudo-terminal integration":
    test "not applicable": check true
