"""Optional POSIX runtime smoke test; normal Nim tests do not require Python.

Compile examples first, then run: python3 tools/animation/pty_smoke.py build/2.2.10-orc
"""
import fcntl
import os
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time


class Session:
    def __init__(self, name, *args):
        self.name = name
        self.master, self.slave = pty.openpty()
        self.resize(120, 40)
        self.original = termios.tcgetattr(self.slave)
        self.raw = b""
        self.child = subprocess.Popen(
            [os.path.join(sys.argv[1], name), *args],
            stdin=self.slave, stdout=self.slave, stderr=self.slave,
        )

    def resize(self, width, height):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", height, width, 0, 0))

    def pump(self, duration=0.1):
        end = time.monotonic() + duration
        while time.monotonic() < end:
            if select.select([self.master], [], [], 0.02)[0]:
                chunk = os.read(self.master, 65536)
                self.raw += chunk
                if b"\x1b[6n" in chunk:
                    os.write(self.master, b"\x1b[1;1R")

    def screen(self):
        cells = [[" "] * 120 for _ in range(40)]
        x = y = 0
        data = self.raw.decode("utf-8", errors="ignore")
        index = 0
        while index < len(data):
            if data[index] == "\x1b":
                match = re.match(r"\x1b\[([0-9;?<>]*)([@-~])", data[index:])
                if not match:
                    index += 1
                    continue
                args, command = match.groups()
                if command == "H":
                    values = [int(v or "1") for v in args.split(";")]
                    y, x = values[0] - 1, (values[1] - 1 if len(values) > 1 else 0)
                elif command == "J" and args == "2":
                    cells = [[" "] * 120 for _ in range(40)]
                index += len(match.group())
            else:
                char = data[index]
                if char == "\r":
                    x = 0
                elif char == "\n":
                    y += 1
                else:
                    if 0 <= y < 40 and 0 <= x < 120:
                        cells[y][x] = char
                    x += 1
                index += 1
        # Assertions use ASCII UI labels; Unicode cell correctness is tested in Nim.
        return "\n".join("".join(row).rstrip() for row in cells)

    def expect_compact(self, text, duration=3):
        """Like `expect`, ignoring spaces: this screen model gives wide glyphs one cell."""
        end = time.monotonic() + duration
        while time.monotonic() < end:
            self.pump(0.05)
            if text.replace(" ", "") in self.screen().replace(" ", ""):
                return
        raise AssertionError(f"{self.name}: {text!r} missing:\n{self.screen()}")

    def expect(self, text, duration=3):
        end = time.monotonic() + duration
        while time.monotonic() < end:
            self.pump(0.05)
            if text in self.screen():
                return
        raise AssertionError(f"{self.name}: {text!r} missing:\n{self.screen()}")

    def send(self, keys):
        os.write(self.master, keys)
        self.pump()

    def idle(self):
        self.pump(0.3)
        before = len(self.raw)
        self.pump(0.3)
        assert len(self.raw) == before, f"{self.name}: unexpected idle output"

    def close(self):
        try:
            self.send(b"\x03")
            assert self.child.wait(timeout=2) == 0, self.raw[-1000:]
            self.pump()
            restored = termios.tcgetattr(self.slave)
            for value in (self.original, restored):
                value[3] &= ~getattr(termios, "PENDIN", 0)
            assert restored == self.original, "terminal modes not restored"
            for cleanup in (b"\x1b[?1006l", b"\x1b[?1003l", b"\x1b[?25h", b"\x1b[?1049l"):
                assert cleanup in self.raw, f"missing cleanup {cleanup!r}"
        finally:
            if self.child.poll() is None:
                self.child.kill()
                self.child.wait()
            os.close(self.master)
            os.close(self.slave)


app = Session("showcase")
try:
    app.expect("Canopy showcase")
    app.expect("List + Scrollbar")
    app.idle()
    app.send(b"\x1b[B")
    app.expect("Styled text with wrapping")
    app.send(b"p")
    app.expect("Popup")
    app.send(b"p")
    app.send(b"2")
    app.expect("Chart")
    app.send(b" ")  # Pausing live data lets the app idle.
    app.pump(0.4)
    app.idle()
    app.send(b"3")
    app.expect("Unicode widths")
    app.send(b"4")
    app.expect("Timeline · spring")
    app.send(b"\x1b[D")
    app.expect("Slide")
    app.send(b"d")
    app.expect("Direction: Right")
    app.send(b"m")
    app.expect("reduced motion")
    app.idle()
    app.send(b"5")
    app.expect("Settings")
    app.send(b"\r")
    app.expect("Status: Running")
    app.pump(0.5)
    app.send(b" ")
    app.expect("Status: Paused")
    assert "Progress: 0%" not in app.screen(), "reduced motion stopped job simulation"
    app.send(b"x")
    app.expect("Status: Ready")
    app.send(b"t")
    app.expect("Magenta · reduced motion")
    app.send(b"6")
    app.expect("Event log")
    app.send(b"z")
    app.expect('"z"')
    tab = app.screen().splitlines()[0].index("1 Widgets") + 1  # 1-based SGR column.
    app.send(b"\x1b[<0;%d;1M" % tab)  # Press the first page tab.
    app.expect("List + Scrollbar")
    # Controls: keyboard entry, Unicode typing, blur validation, palette, dialog and exit.
    app.send(b"7")
    app.expect("Press Enter or click a field")
    app.send(b"\r")
    app.expect("Focus: name")
    app.send("Zoë 世界".encode())
    app.expect_compact("Zoë 世界")  # The help text has a comma, so only the field matches.
    app.send(b"\tbad\t")
    app.expect("✗ Use an address like")
    app.send(b"q1")  # Focused fields own plain characters, so neither quits nor switches page.
    app.expect("Password")
    assert app.child.poll() is None, "q in a focused field quit the showcase"
    app.send(b"\x10")  # Ctrl+P opens the palette over the page.
    app.expect("Commands")
    app.send(b"reset")
    app.expect("Reset form")
    app.send(b"\r")
    app.expect("All fields return to their initial values.")
    app.send(b"\r")  # Reset is the focused button.
    app.expect("Form reset")
    assert "Zoë世界" not in app.screen().replace(" ", ""), "reset kept the old name"
    app.send(b"\x1b")  # Escape leaves the controls; page keys work again.
    app.expect("Press Enter or click a field")
    row = next(i for i, line in enumerate(app.screen().splitlines()) if "▸ docs" in line)
    column = app.screen().splitlines()[row].index("▸ docs") + 1
    app.send(b"\x1b[<0;%d;%dM\x1b[<0;%d;%dm" % (column, row + 1, column, row + 1))
    app.expect("▾ docs")  # A click on the expander toggles it and focuses the tree.
    app.expect("Focus: files")
    app.send(b"\x1b")
    app.send(b"6")
    app.expect("Event log")
    app.resize(12, 5)
    app.pump(0.2)
    assert app.child.poll() is None
    app.resize(120, 40)
    app.expect("Magenta · reduced motion")
    app.idle()
finally:
    app.close()
print("PASS showcase: pages, selection, popup, live data, transitions, jobs, theme, reduced motion, input log, mouse, controls, palette, dialog, idle, resize, cleanup")

inline = Session("showcase", "--inline")
try:
    end = time.monotonic() + 10
    while inline.child.poll() is None and time.monotonic() < end:
        inline.pump(0.05)  # Keeps answering cursor-position queries.
    assert inline.child.returncode == 0, inline.raw[-1000:]
    assert "Completed task 10" in inline.screen(), inline.screen()
    assert b"\x1b[?1049h" not in inline.raw, "inline mode switched to the alternate screen"
finally:
    if inline.child.poll() is None:
        inline.child.kill()
        inline.child.wait()
    os.close(inline.master)
    os.close(inline.slave)
print("PASS showcase --inline: inserted lines, progress viewport, no alternate screen")
