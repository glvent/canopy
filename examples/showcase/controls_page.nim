## Interactive controls: a validated form, a tree, a command palette and a dialog, all driven by
## the opt-in interaction layer. The page owns its focus manager and routes every event itself.
import std/[monotimes, options, strutils]

import canopy
import canopy/runtime/terminal/input
import canopy/ui/controls/index as controls
import common

const help* = "Enter: start · Esc: leave · Ctrl+P: commands"

let
  openPalette = actionId("showcase.palette")
  cmdFocusForm = actionId("showcase.focus-form")
  cmdFocusTree = actionId("showcase.focus-tree")
  cmdExpand = actionId("showcase.expand-all")
  cmdCollapse = actionId("showcase.collapse-all")
  cmdReset = actionId("showcase.reset")
  cmdAbout = actionId("showcase.about")
  confirmReset = actionId("showcase.confirm-reset")
  closeDialog = actionId("showcase.close-dialog")

var
  fm = initFocusManager()
  keys = block:
    var k = defaultKeymap()
    k.bindKey(GlobalContext, "ctrl+p", openPalette)
    k
  form = block:
    var f = initFormState(controlId("profile"))
    f.addField(controlId("name"), "Name", required = true, help = "Unicode is fine: Zoë, 世界, 👋")
    f.addField(controlId("email"), "Email", required = true)
    f.addValidator(controlId("email"), proc(v: string): string =
      if v.len > 0 and ('@' notin v or v.endsWith("@")): "Use an address like ada@example.com"
      else: "")
    f.addField(controlId("password"), "Password", mask = "•",
      validators = [minGraphemes(8)], help = "At least 8 characters; copy is disabled")
    f.addAreaField(controlId("bio"), "Bio", rows = 3, help = "Enter adds a line")
    f
  tree = initTreeState(controlId("files"))
  items = @[
    treeItem("src", "src", [treeItem("core", "core", [treeItem("buffer", "buffer.nim"),
      treeItem("layout", "layout.nim")]), treeItem("ui", "ui", [treeItem("controls",
      "controls", [treeItem("textinput", "textinput.nim"), treeItem("palette", "palette.nim")]),
      treeItem("widgets", "widgets")])]),
    treeItem("docs", "docs", [treeItem("interaction", "interaction.md"),
      treeItem("input", "input.md")]),
    treeItem("readme", "README.md")]
  palette = initPaletteState(controlId("palette"))
  registry = initCommandRegistry([
    command("focus-form", "Focus form", cmdFocusForm),
    command("focus-tree", "Focus file tree", cmdFocusTree),
    command("expand", "Expand all folders", cmdExpand),
    command("collapse", "Collapse all folders", cmdCollapse),
    command("reset", "Reset form…", cmdReset, description = "asks first"),
    command("about", "About the interaction layer", cmdAbout)])
  dialog = initDialogState(controlId("dialog"), [dialogButton("ok", "OK", closeDialog)])
  dialogTitle, dialogBody: string
  status = "Nothing yet"
  redraw = false

proc theme(): ControlTheme =
  result = defaultTheme()
  result.focusedBorder = accent()
  result.highlight = highlight()
  result.match = accent().bold().underlined()
  result.label = initStyle().bold()

proc showDialog(title, body: string, buttons: openArray[tuple[name, label: string,
    action: ActionId]]) =
  dialogTitle = title
  dialogBody = body
  dialog = initDialogState(controlId("dialog"), buttons)
  dialog.open(fm)

proc expandAll(list: openArray[TreeItem]) =
  for item in list:
    if item.children.len > 0:
      tree.expand(item.id)
      expandAll(item.children)

proc render*(frame: var Frame, area: Rect) =
  ## Registration runs inside the showcase's normal draw; a focus change found while committing
  ## the frame asks for one more redraw through `update`.
  let t = theme()
  fm.beginFrame()
  let columns = horizontal([fill(), length(34)]).split(area)
  let formBlock = panel("Profile")
  frame.renderWidget(formBlock, columns[0])
  frame.renderControl(fm, initForm(t, submitLabel = "Save"), formBlock.inner(columns[0]), form)
  let side = vertical([fill(), length(4)]).split(columns[1])
  var treeBlock = panel("Files")
  if fm.isFocused(tree.id): treeBlock = treeBlock.withBorderStyle(accent())
  frame.renderControl(fm, initTreeView(t).withBlock(treeBlock), side[0], tree, items)
  frame.renderWidget(initParagraph(initText([initLine(initSpan(status, accent())),
    initLine(initSpan(if fm.focused.isSome: "Focus: " & $fm.focused.get else:
    "Press Enter or click a field", muted()))])).withWrap(true).withBlock(panel("Last action")),
    side[1])
  frame.renderControl(fm, initPalette(theme = t), area, palette, registry)
  frame.renderControl(fm, initDialog(dialogTitle, dialogBody, t), area, dialog)
  if fm.endFrame(): redraw = true

proc perform(r: EventResult) =
  if r.action.isNone: return
  let a = r.action.get
  if a == FormSubmit:
    status = "Saved " & form.value(controlId("name"))
    showDialog("Saved", "Profile for " & form.value(controlId("name")) & " saved.",
      [dialogButton("ok", "OK", closeDialog)])
  elif a == FormReset: status = "Form reset"
  elif a == ListActivate: status = "Opened " & r.subject
  elif a == cmdFocusForm: fm.focus(form.fields[0].id); status = "Focused the form"
  elif a == cmdFocusTree: fm.focus(tree.id); status = "Focused the tree"
  elif a == cmdExpand: expandAll(items); status = "Expanded all folders"
  elif a == cmdCollapse: tree.expanded.clear(); status = "Collapsed all folders"
  elif a == cmdReset:
    showDialog("Reset form?", "All fields return to their initial values.",
      [dialogButton("reset", "Reset", confirmReset), dialogButton("keep", "Keep", closeDialog)])
  elif a == confirmReset: form.resetForm(); status = "Form reset"
  elif a == cmdAbout:
    showDialog("Interaction layer", "Focus, keymaps, text editing, forms, palette, tree and " &
      "dialogs are opt-in: import canopy/ui/controls/index. The app owns every state value.",
      [dialogButton("ok", "OK", closeDialog)])
  elif a == PaletteDismiss: status = "Palette dismissed"

proc handle*(event: input.Event): bool =
  ## Returns true when the page consumed the event, so showcase shortcuts see only the rest.
  if event.kind == input.EventKind.Resize: fm.markGeometryStale()
  let route = fm.route(event)
  var r = palette.handle(registry, fm, route, keys)
  if not r.consumed: r = dialog.handle(fm, route, keys)
  if not r.consumed and route.allowsApplication:
    r = form.handle(fm, route, keys)
    if not r.consumed: r = tree.handle(items, route, keys)
  if not r.consumed: r = fm.handleTraversal(route, keys)
  if not r.consumed:
    let action = keys.resolveApplication(route)
    if action == some(openPalette):
      palette.open(fm)
      return true
  perform(r)
  if r.consumed: return true
  if not routing.isPress(event) or route.modal.isSome: return route.modal.isSome
  # Keyboard entry and exit: Enter starts at the first field, Escape leaves the controls so
  # Tab and the number keys switch pages again.
  if event.key.code == KeyCode.Enter and fm.focused.isNone:
    fm.focusFirst()
    return true
  if event.key.code == KeyCode.Escape and fm.focused.isSome:
    fm.clearFocus()
    return true
  # While a control has focus, plain characters belong to it, not to showcase shortcuts.
  fm.focused.isSome and event.key.text.len > 0 and
    (event.key.modifiers * {KeyModifier.Control, KeyModifier.Alt}) == {}

proc update*(now: MonoTime, active: bool): int =
  if active and redraw:
    redraw = false
    return 0
  -1
