## Focus registration, traversal, fallback, scopes and modals.
import std/[unittest, options]

import canopy/ui/interaction/index

proc id(name: string): ControlId = controlId(name)

proc frame(fm: var FocusManager, names: openArray[string], disabled: openArray[string] = [],
    skipTab: openArray[string] = []): bool =
  fm.beginFrame()
  for i, name in names:
    fm.register(id(name), initRect(0, i, 10, 1), enabled = name notin disabled,
      tabStop = name notin skipTab)
  fm.endFrame()

suite "focus traversal":
  test "Tab order follows registration and wraps; empty focus starts at either end":
    var fm = initFocusManager()
    discard fm.frame(["a", "b", "c"])
    check fm.focused.isNone
    check fm.focusNext() and fm.focused == some(id("a"))
    check fm.focusNext() and fm.focused == some(id("b"))
    check fm.focusNext() and fm.focusNext() and fm.focused == some(id("a"))
    fm.clearFocus()
    check fm.focusPrevious() and fm.focused == some(id("c"))
    check fm.focusPrevious() and fm.focused == some(id("b"))

  test "disabled and non-tab-stop controls are skipped; disabled cannot be focused":
    var fm = initFocusManager()
    discard fm.frame(["a", "b", "c", "d"], disabled = ["b"], skipTab = ["c"])
    fm.focusNext(); fm.focusNext()
    check fm.focused == some(id("d"))
    check not fm.focus(id("b"))
    check fm.focused == some(id("d"))
    check fm.focus(id("c")) # programmatic focus ignores tabStop
    check fm.focusNext() and fm.focused == some(id("d"))

  test "empty domain reports no movement":
    var fm = initFocusManager()
    discard fm.frame([])
    check not fm.focusNext()
    check not fm.focusPrevious()
    check fm.focused.isNone

  test "duplicate IDs and misuse raise":
    var fm = initFocusManager()
    fm.beginFrame()
    fm.register(id("a"), initRect(0, 0, 1, 1))
    expect ValueError: fm.register(id("a"), initRect(0, 1, 1, 1))
    discard fm.endFrame()
    expect ValueError: fm.register(id("b"), initRect(0, 0, 1, 1))
    expect ValueError: discard fm.endFrame()
    expect ValueError: discard controlId("")
    fm.beginFrame()
    fm.beginScope(id("s"))
    expect ValueError: discard fm.endFrame()

  test "an aborted frame is discarded by the next beginFrame":
    var fm = initFocusManager()
    fm.beginFrame()
    fm.register(id("a"), initRect(0, 0, 1, 1))
    fm.beginScope(id("s"))
    fm.beginFrame()
    fm.register(id("a"), initRect(0, 0, 1, 1))
    discard fm.endFrame()
    check fm.registrations.len == 1

suite "focus fallback and dynamic registration":
  test "disappearing control moves to the following survivor, then the preceding one":
    var fm = initFocusManager()
    discard fm.frame(["a", "b", "c", "d"])
    check fm.focus(id("b"))
    check fm.frame(["a", "c", "d"])
    check fm.focused == some(id("c"))
    check fm.frame(["a", "x", "c"]) == false
    check fm.focus(id("c"))
    check fm.frame(["a", "x"])
    check fm.focused == some(id("x")) # c was last: x precedes it in the old order
    check fm.frame(["y"])
    check fm.focused == some(id("y")) # nothing from the old order survives
    check fm.frame([])
    check fm.focused.isNone

  test "a control that becomes disabled loses focus to its neighbour":
    var fm = initFocusManager()
    discard fm.frame(["a", "b", "c"])
    fm.focus(id("b"))
    check fm.frame(["a", "b", "c"], disabled = ["b"])
    check fm.focused == some(id("c"))

  test "pending programmatic focus is validated by endFrame":
    var fm = initFocusManager()
    check fm.focus(id("later"))
    check fm.isFocused(id("later"))
    check not fm.frame(["first", "later"])
    check fm.focused == some(id("later"))
    check fm.focus(id("missing"))
    check fm.frame(["first", "later"])
    check fm.focused == some(id("first"))

  test "zero-area controls keep focus but leave hit testing":
    var fm = initFocusManager()
    fm.beginFrame(); fm.register(id("a"), initRect(0, 0, 0, 0)); discard fm.endFrame()
    check fm.focus(id("a"))
    check fm.hitTest(initPosition(0, 0)).isNone
    fm.beginFrame(); fm.register(id("a"), initRect(0, 0, 0, 0)); discard fm.endFrame()
    check fm.focused == some(id("a"))

suite "scopes and modals":
  test "nested scopes clip hit areas and topmost registration wins":
    var fm = initFocusManager()
    fm.beginFrame()
    fm.register(id("under"), initRect(0, 0, 10, 10))
    fm.withScope(id("panel"), initRect(2, 2, 4, 4), false):
      fm.withScope(id("inner"), initRect(3, 3, 10, 10), false):
        fm.register(id("over"), initRect(0, 0, 10, 10))
    discard fm.endFrame()
    check fm.hitTest(initPosition(1, 1)).get.id == id("under")
    check fm.hitTest(initPosition(4, 4)).get.id == id("over")
    check fm.hitTest(initPosition(7, 7)).get.id == id("under")
    check fm.registration(id("over")).get.scopes == @[id("inner"), id("panel")]
    check fm.registration(id("over")).get.hitArea == initRect(3, 3, 3, 3)
    check fm.focusFirst(some(id("panel"))) and fm.focused == some(id("over"))
    # Non-modal scopes belong to the enclosing domain.
    check fm.focusNext() and fm.focused == some(id("under"))

  test "modal traps traversal, refuses outside focus and restores on close":
    var fm = initFocusManager()
    discard fm.frame(["a", "b"])
    fm.focus(id("b"))
    fm.openModal(id("dialog"))
    check fm.activeModal == some(id("dialog"))
    check fm.focused.isNone
    fm.beginFrame()
    fm.register(id("a"), initRect(0, 0, 10, 1))
    fm.register(id("b"), initRect(0, 1, 10, 1))
    fm.withScope(id("dialog"), initRect(0, 5, 10, 3), true):
      fm.register(id("ok"), initRect(0, 5, 5, 1))
      fm.register(id("cancel"), initRect(5, 5, 5, 1))
    check fm.endFrame()
    check fm.focused == some(id("ok"))
    check fm.focusNext() and fm.focused == some(id("cancel"))
    check fm.focusNext() and fm.focused == some(id("ok"))
    check not fm.focus(id("a"))
    check fm.hitTest(initPosition(0, 0)).isNone
    check fm.closeModal(id("dialog"))
    check fm.focused == some(id("b"))
    check not fm.closeModal(id("dialog"))

  test "initial focus, empty modal and rendering an unopened modal":
    var fm = initFocusManager()
    fm.openModal(id("m"), some(id("second")))
    check fm.focused == some(id("second")) # pending until rendered
    fm.beginFrame()
    fm.withScope(id("m"), initRect(0, 0, 10, 10), true):
      fm.register(id("first"), initRect(0, 0, 1, 1))
      fm.register(id("second"), initRect(0, 1, 1, 1))
    check not fm.endFrame()
    check fm.focused == some(id("second"))
    fm.closeModal(id("m"))
    fm.openModal(id("empty"))
    fm.beginFrame()
    fm.withScope(id("empty"), initRect(0, 0, 1, 1), true): discard
    discard fm.endFrame()
    check fm.focused.isNone and not fm.focusNext()
    fm.closeModal(id("empty"))
    fm.beginFrame()
    expect ValueError: fm.beginScope(id("never"), initRect(0, 0, 1, 1), true)

  test "stacked modals: only the top is active; closing a lower one hands over restoration":
    var fm = initFocusManager()
    discard fm.frame(["base"])
    fm.focus(id("base"))
    proc render(fm: var FocusManager, withB: bool) =
      fm.beginFrame()
      fm.register(id("base"), initRect(0, 0, 1, 1))
      fm.withScope(id("A"), initRect(0, 0, 10, 10), true):
        fm.register(id("a1"), initRect(1, 1, 1, 1))
      if withB:
        fm.withScope(id("B"), initRect(0, 0, 10, 10), true):
          fm.register(id("b1"), initRect(2, 2, 1, 1))
      discard fm.endFrame()
    fm.openModal(id("A"))
    fm.render(false)
    check fm.focused == some(id("a1"))
    fm.openModal(id("B"))
    fm.render(true)
    check fm.focused == some(id("b1"))
    check fm.modalStack == @[id("A"), id("B")]
    check not fm.focus(id("a1"))
    fm.closeModal(id("A"))
    check fm.activeModal == some(id("B"))
    fm.closeModal(id("B"))
    check fm.focused == some(id("base"))

  test "open modals stay open when a frame skips rendering them":
    var fm = initFocusManager()
    fm.openModal(id("m"))
    discard fm.frame(["a"])
    check fm.activeModal == some(id("m"))
    check fm.focused.isNone
