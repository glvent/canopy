## Unicode editing model: sanitizing, cluster boundaries, words, columns and undo.
import std/[unittest, strutils]

import canopy/ui/controls/editing

suite "sanitizing":
  test "invalid UTF-8, controls, tabs and line endings":
    check sanitize("a\tb", 2) == "a  b"
    check sanitize("x\r\ny\rz") == "x\ny\nz"
    check sanitize("\x00a\x07\x1b[31mb\x7f") == "a[31mb"
    check sanitize("c\xC2\x85d\xC2\xA0") == "cd\xC2\xA0" # C1 NEL dropped, NBSP kept
    check sanitize("\xff\xC0\xAF\xED\xA0\x80ok") == "\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}\u{FFFD}ok"
    check sanitize("\xF0\x9F\x98") == "\u{FFFD}\u{FFFD}\u{FFFD}"
    check sanitize("é👍") == "é👍"

  test "single-line newline policies":
    check sanitize("a\nb\r\nc", multiline = false) == "a b c"
    check sanitize("a\nb", multiline = false, policy = NewlinePolicy.Strip) == "ab"
    check sanitize("a\nb", multiline = false, policy = NewlinePolicy.FirstLine) == "a"

suite "clusters and words":
  const family = "👩‍👩‍👧"
  const flag = "🇯🇵"
  test "boundaries keep combining marks, ZWJ sequences, flags and Hangul together":
    check boundaries("e\u0301x") == @[0, 3, 4]
    check clusterCount(family & flag & "한") == 3
    check boundaries("ab") == @[0, 1, 2]
    check prevBoundary("e\u0301x", 3) == 0
    check nextBoundary("e\u0301x", 0) == 3

  test "word movement over runs":
    let s = "foo.bar  baz_1 世界"
    check wordRightCol(s, 0) == 3
    check wordRightCol(s, 3) == 4
    check wordRightCol(s, 4) == 7
    check wordRightCol(s, 7) == 14
    check wordLeftCol(s, s.len) == 15
    check wordLeftCol(s, 15) == 9
    check wordLeftCol(s, 9) == 4
    check wordLeftCol(s, 0) == 0

  test "display columns and click mapping with wide clusters":
    let s = "a世" & family & "b"
    check columnOf(s, s.len) == 6
    check columnOf(s, 1) == 1
    check colAtColumn(s, 1) == 1 # left half of 世
    check colAtColumn(s, 2) == 4 # right half lands after it
    check colAtColumn(s, 99) == s.len
    check columnOf("abc", 3, mask = "•") == 3

suite "editor":
  test "cursor and deletion move by cluster":
    var e = initEditor("ae\u0301" & "👍🏽z")
    e.moveLeft()
    e.backspace()
    check e.text == "ae\u0301z"
    e.backspace()
    check e.text == "az"
    e.moveHome()
    e.deleteForward()
    check e.text == "z"
    check not e.backspace() or e.text == "z"

  test "typing merges per word; movement, paste and newline start new steps":
    var e = initEditor("")
    for c in "hello world": e.typeText($c)
    check e.undoDepth == 2
    e.undo()
    check e.text == "hello"
    e.redo()
    check e.text == "hello world"
    e.moveLeft()
    e.typeText("X")
    check e.undoDepth == 3
    e.insertText("PASTE")
    e.typeText("y")
    check e.undoDepth == 5
    while e.undo(): discard
    check e.text == ""
    while e.redo(): discard
    check e.text == "hello worlXPASTEyd"

  test "consecutive deletions merge in one direction":
    var e = initEditor("abcdef")
    e.backspace(); e.backspace()
    check e.undoDepth == 1
    e.moveHome()
    e.deleteForward(); e.deleteForward()
    check e.undoDepth == 2
    check e.text == "cd"
    e.undo()
    check e.text == "abcd"
    check e.cursor == pos(0, 0)
    e.undo()
    check e.text == "abcdef"
    check e.cursor == pos(0, 6)

  test "selection replacement, word deletion and select all":
    var e = initEditor("one two three")
    e.moveWordLeft(extend = true)
    check e.selectedText == "three"
    e.typeText("3")
    check e.text == "one two 3"
    e.deleteWordLeft()
    check e.text == "one two "
    e.moveHome()
    e.deleteWordRight()
    check e.text == " two "
    e.selectAll()
    check e.selectedText == " two "
    e.moveLeft()
    check e.cursor == pos(0, 0) and not e.hasSelection

  test "undo limit drops the oldest steps; setText clears history":
    var e = initEditor("", undoLimit = 3)
    for word in ["a", " b", " c", " d", " e"]: e.insertText(word)
    check e.undoDepth == 3
    while e.undo(): discard
    check e.text == "a b"
    e.setText("fresh")
    check not e.canUndo and not e.canRedo

  test "grapheme limit truncates insertion":
    var e = initEditor("ab", maxGraphemes = 4)
    e.insertText("c👍🏽dd")
    check e.text == "abc👍🏽"
    check not e.typeText("x")

  test "multiline editing keeps the preferred column across short and wide lines":
    var e = initEditor("abcdef\nx\n世界世界", multiline = true)
    e.moveTo(pos(0, 5))
    e.moveLines(1)
    check e.cursor == pos(1, 1)
    e.moveLines(1)
    check e.cursor == pos(2, 9) # column 5 is the right half of the third 世: after it
    e.moveLines(-2)
    check e.cursor == pos(0, 5)
    e.moveLines(-1)
    check e.cursor == pos(0, 0)
    e.moveDocumentEnd()
    e.insertText("\nnew")
    check e.lineCount == 4 and e.cursor == pos(3, 3)
    e.moveTo(pos(1, 1))
    e.moveTo(pos(0, 3), extend = true)
    check e.selectedText == "def\nx"
    e.backspace()
    check e.text == "abc\n世界世界\nnew"
    e.moveTo(pos(1, 0))
    e.backspace()
    check e.text == "abc世界世界\nnew"
    e.undo(); e.undo()
    check e.text == "abcdef\nx\n世界世界\nnew"

  test "offsets round-trip through positions":
    var e = initEditor("ab\ncé\nd", multiline = true)
    check e.offsetOf(pos(1, 1)) == 4
    check e.posAt(4) == pos(1, 1)
    check e.posAt(5) == pos(1, 1) # inside é snaps back
    check e.posAt(99) == pos(2, 1)
    check e.len == "ab\ncé\nd".len

  test "large insertions stay linear enough":
    var e = initEditor("", multiline = true)
    e.insertText(repeat("line of text\n", 2000))
    check e.lineCount == 2001
    e.undo()
    check e.isEmpty
