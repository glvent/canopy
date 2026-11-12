## Forms, palette, tree, dialog, buttons and drawInteractive against the test backend.
import std/[unittest, options, strutils]

import canopy
import canopy/ui/controls/index
import ../support/interaction_support

type App = object
  fm: FocusManager
  form: FormState
  palette: PaletteState
  registry: CommandRegistry
  dialog: DialogState
  tree: TreeState
  items: seq[TreeItem]

proc draw(term: var Terminal[TestBackend], app: var App): CompletedFrame =
  term.drawInteractive(app.fm, frame):
    let area = frame.area
    let halves = horizontal([percentage(50), percentage(50)]).split(area)
    frame.renderControl(app.fm, initForm(), halves[0], app.form)
    frame.renderControl(app.fm, initTreeView(), halves[1], app.tree, app.items)
    frame.renderControl(app.fm, initPalette(), area, app.palette, app.registry)
    frame.renderControl(app.fm, initDialog("Quit?", "Unsaved changes will be lost."), area,
      app.dialog)

proc dispatch(app: var App, event: Event): EventResult =
  let route = app.fm.route(event)
  result = app.palette.handle(app.registry, app.fm, route)
  if not result.consumed: result = app.dialog.handle(app.fm, route)
  if not result.consumed and route.allowsApplication:
    result = app.form.handle(app.fm, route)
    if not result.consumed: result = app.tree.handle(app.items, route)
  if not result.consumed: result = app.fm.handleTraversal(route)

proc initApp(): App =
  result.fm = initFocusManager()
  result.form = initFormState(id("signup"))
  result.form.addField(id("name"), "Name", required = true, help = "Shown publicly")
  result.form.addField(id("email"), "Email")
  result.form.addValidator(id("email"), proc(v: string): string =
    if v.len > 0 and '@' notin v: "Needs an @" else: "")
  result.form.addField(id("code"), "Code", validators = [minGraphemes(3)])
  result.palette = initPaletteState(id("palette"))
  result.registry = initCommandRegistry([
    command("open", "Open File", actionId("file.open"), shortcut = "Ctrl+O"),
    command("save", "Save File", actionId("file.save")),
    command("theme", "Toggle Theme", actionId("view.theme"), enabled = false)])
  result.dialog = initDialogState(id("quit"), [dialogButton("yes", "Quit", actionId("quit")),
    dialogButton("no", "Cancel", actionId("stay"))])
  result.tree = initTreeState(id("tree"))
  result.items = @[treeItem("src", "src", [treeItem("a", "a.nim"), treeItem("b", "b.nim")]),
    treeItem("docs", "docs", [treeItem("guide", "guide.md")]), treeItem("readme", "README")]

proc typeText(app: var App, text: string) =
  for c in text: discard app.dispatch(ch($c))

suite "drawInteractive":
  test "re-renders once when reconciliation moves focus and sets the cursor":
    var term = initTerminal(initTestBackend(60, 16))
    var app = initApp()
    app.fm.focus(id("gone"))
    discard term.draw(app)
    check app.fm.focused == some(id("name")) # pending focus fell back to the first control
    check term.backend.cursorVisible
    check term.backend.cursor == initPosition(0, 1)
    let text = term.backend.buffer.rows.join("\n")
    check "Name *" in text and "Shown publicly" in text and "[ Submit ]" in text
    check "▸ src" in text

suite "form":
  test "blur validation, submit focuses the first invalid field, reset restores":
    var term = initTerminal(initTestBackend(60, 16))
    var app = initApp()
    discard term.draw(app)
    app.fm.focus(id("name"))
    discard app.dispatch(key(KeyCode.Tab))
    discard term.draw(app)
    check app.form.fields[0].touched
    check app.form.showsError(app.form.fields[0])
    check "✗ Name *" in term.backend.buffer.rows.join("\n")
    check "✗ Required" in term.backend.buffer.rows.join("\n")
    app.typeText("bad")
    check app.form.fields[1].error == ""
    discard app.dispatch(key(KeyCode.Tab))
    discard term.draw(app)
    check app.form.fields[1].error == "Needs an @"
    # Enter on the last field submits; failure focuses the first invalid field.
    app.fm.focus(id("code"))
    let r = app.dispatch(key(KeyCode.Enter))
    check r.action.isNone and app.form.submitAttempted
    check app.fm.focused == some(id("name"))
    app.typeText("Ada")
    check app.form.fields[0].error == ""
    discard app.dispatch(key(KeyCode.Enter)) # moves to the next field
    check app.fm.focused == some(id("email"))
    discard app.dispatch(ch("@"))
    discard term.draw(app)
    app.fm.focus(app.form.submit.id)
    let ok = app.dispatch(key(KeyCode.Enter))
    check ok.action == some(FormSubmit) and ok.subject == "signup"
    check app.form.value(id("email")) == "bad@"
    check app.form.isDirty
    app.form.setExternalError(id("email"), "Already registered")
    check not app.form.validate()
    app.fm.focus(app.form.reset.id)
    check app.dispatch(key(KeyCode.Enter)).action == some(FormReset)
    check app.form.value(id("name")) == "" and not app.form.isDirty
    check not app.form.fields[0].touched and app.form.fields[1].externalError == ""

  test "form validators and timing":
    var fm = initFocusManager()
    var form = initFormState(id("f"), ValidationTiming.OnSubmit)
    form.addField(id("a"), "A")
    form.addField(id("b"), "B")
    form.addValidator proc(f: FormState): seq[FormIssue] =
      if f.value(id("a")) != f.value(id("b")):
        result.add FormIssue(field: some(id("b")), message: "Must match")
        result.add FormIssue(message: "Fix the highlighted fields")
    form.setValue(id("a"), "x")
    check not form.submitForm(fm)
    check form.fields[1].error == "Must match" and form.formErrors.len == 1
    form.setValue(id("b"), "x")
    check form.submitForm(fm)
    expect ValueError: form.addField(id("a"), "Again")

suite "palette":
  test "ranking is deterministic":
    let registry = initCommandRegistry([command("a", "Open File", actionId("a")),
      command("b", "Open Folder", actionId("b")), command("c", "Format Document",
      actionId("c")), command("d", "Go to File", actionId("d"))])
    check registry.rank("").len == 4
    let f = registry.rank("of")
    check f.len == 3 # Format Document has no o after f
    check registry[f[0].index].label == "Open File"
    check f[0].positions == @[0, 5]
    let file = registry.rank("FILE")
    check registry[file[0].index].label == "Open File" # shorter than Go to File, same score
    check fuzzyMatch("zz", "Open").isNone
    check fuzzyMatch("é", "Écrire").isSome
    expect ValueError: discard initCommandRegistry([command("a", "x", actionId("a")),
      command("a", "y", actionId("b"))])

  test "open, filter, navigate, execute once, and dismiss restores focus":
    var term = initTerminal(initTestBackend(60, 16))
    var app = initApp()
    discard term.draw(app)
    app.fm.focus(id("email"))
    app.palette.open(app.fm)
    # Keys typed before the palette's first frame reach its query.
    app.typeText("fi")
    check app.palette.query.text == "fi"
    discard term.draw(app)
    check app.fm.activeModal == some(id("palette"))
    check "Open File" in term.backend.buffer.rows.join("\n")
    check app.form.value(id("email")) == ""
    discard app.dispatch(key(KeyCode.Down))
    check app.palette.selected == 1
    let r = app.dispatch(key(KeyCode.Enter))
    check r.action == some(actionId("file.save")) and r.subject == "save"
    check not app.palette.isOpen
    check app.fm.focused == some(id("email"))
    app.palette.open(app.fm)
    discard term.draw(app)
    app.typeText("theme")
    check app.dispatch(key(KeyCode.Enter)).action.isNone # disabled command
    check app.dispatch(key(KeyCode.Escape)).action == some(PaletteDismiss)
    check app.fm.activeModal.isNone
    discard term.draw(app)
    check "Toggle Theme" notin term.backend.buffer.rows.join("\n")

  test "pointer: click a result executes, outside dismisses":
    var term = initTerminal(initTestBackend(60, 16))
    var app = initApp()
    discard term.draw(app)
    app.palette.open(app.fm)
    discard term.draw(app)
    let rows = app.fm.areaOf(app.palette.resultsId).get
    let r = app.dispatch(mouse(MouseEventKind.Down, rows.x+3, rows.y+1))
    check r.action == some(actionId("file.save"))
    app.palette.open(app.fm)
    discard term.draw(app)
    check app.dispatch(mouse(MouseEventKind.Down, 0, 15)).action == some(PaletteDismiss)

suite "tree":
  test "keyboard navigation, expansion and activation":
    var term = initTerminal(initTestBackend(60, 16))
    var app = initApp()
    discard term.draw(app)
    app.fm.focus(id("tree"))
    discard term.draw(app)
    check app.tree.selected == some(id("src"))
    discard app.dispatch(key(KeyCode.Right))
    check id("src") in app.tree.expanded
    discard app.dispatch(key(KeyCode.Right))
    check app.tree.selected == some(id("a"))
    discard app.dispatch(key(KeyCode.Down))
    discard app.dispatch(key(KeyCode.Down))
    check app.tree.selected == some(id("docs"))
    discard app.dispatch(key(KeyCode.Up))
    discard app.dispatch(key(KeyCode.Left))
    check app.tree.selected == some(id("src"))
    discard app.dispatch(key(KeyCode.End))
    check app.tree.selected == some(id("readme"))
    let r = app.dispatch(key(KeyCode.Enter))
    check r.action == some(ListActivate) and r.subject == "readme"
    discard term.draw(app)
    check "▾ src" in term.backend.buffer.rows.join("\n")

  test "selection repair when nodes collapse or disappear":
    var state = initTreeState(id("t"))
    var items = @[treeItem("p", "p", [treeItem("c", "c")]), treeItem("q", "q"),
      treeItem("r", "r")]
    state.expand(id("p"))
    state.sync(items)
    state.selected = some(id("c"))
    state.sync(items)
    state.collapse(id("p"))
    state.sync(items)
    check state.selected == some(id("p"))
    state.selected = some(id("q"))
    state.sync(items)
    items.delete(1)
    state.sync(items)
    check state.selected == some(id("r"))
    items.setLen(1)
    state.sync(items)
    check state.selected == some(id("p"))
    items.setLen(0)
    state.sync(items)
    check state.selected.isNone

  test "click toggles on the expander and activates a selected row":
    var term = initTerminal(initTestBackend(60, 16))
    var app = initApp()
    discard term.draw(app)
    let area = app.fm.areaOf(id("tree")).get
    discard app.dispatch(mouse(MouseEventKind.Down, area.x+2, area.y))
    check id("src") in app.tree.expanded
    discard term.draw(app)
    discard app.dispatch(mouse(MouseEventKind.Down, area.x+6, area.y+1))
    check app.tree.selected == some(id("a"))
    check app.dispatch(mouse(MouseEventKind.Down, area.x+6, area.y+1)).subject == "a"

suite "dialog":
  test "traps focus, maps Escape and Enter, swallows outside clicks, restores focus":
    var term = initTerminal(initTestBackend(60, 16))
    var app = initApp()
    discard term.draw(app)
    app.fm.focus(id("email"))
    app.dialog.open(app.fm)
    discard term.draw(app)
    check app.fm.focused == some(app.dialog.buttonId(0))
    check "Unsaved changes" in term.backend.buffer.rows.join("\n")
    discard app.dispatch(key(KeyCode.Tab))
    check app.fm.focused == some(app.dialog.buttonId(1))
    discard app.dispatch(key(KeyCode.Tab))
    check app.fm.focused == some(app.dialog.buttonId(0))
    discard app.dispatch(key(KeyCode.Right))
    check app.fm.focused == some(app.dialog.buttonId(1))
    check app.dispatch(ch("x")).consumed == false
    check app.form.value(id("email")) == ""
    let outside = app.dispatch(mouse(MouseEventKind.Down, 0, 0))
    check outside.consumed and app.dialog.isOpen
    let r = app.dispatch(key(KeyCode.Escape))
    check r.action == some(actionId("stay")) and r.subject == "quit"
    check not app.dialog.isOpen and app.fm.focused == some(id("email"))
    # The closing Escape did not reach the restored field.
    check app.form.value(id("email")) == ""
    app.dialog.open(app.fm)
    discard term.draw(app)
    check app.dispatch(key(KeyCode.Enter)).action == some(actionId("quit"))

  test "button click requires release over the button":
    var term = initTerminal(initTestBackend(60, 16))
    var app = initApp()
    discard term.draw(app)
    app.dialog.open(app.fm)
    discard term.draw(app)
    let b = app.fm.areaOf(app.dialog.buttonId(1)).get
    check app.dispatch(mouse(MouseEventKind.Down, b.x+1, b.y)).action.isNone
    check app.dispatch(mouse(MouseEventKind.Up, b.x+1, b.y)).action == some(actionId("stay"))

  test "small terminals clip without crashing":
    var term = initTerminal(initTestBackend(12, 4))
    var app = initApp()
    app.dialog.open(app.fm)
    discard term.draw(app)
    app.dialog.close(app.fm)
    app.palette.open(app.fm)
    discard term.draw(app)
    var tiny = initTerminal(initTestBackend(1, 1))
    discard tiny.draw(app)
    check true
