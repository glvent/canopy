## Labeled form fields with validation, submit and reset (Canopy extension).
import std/[options, strutils]

import ./[common, textinput, textarea]
export common, textinput, textarea

type
  ValidationTiming* {.pure.} = enum
    OnChange ## Validate on every edit.
    OnBlur ## Validate when focus leaves a field, then on every edit of a touched field.
    OnSubmit ## Validate only when submitting, then on every edit after a failed submit.
  Validator* = proc(value: string): string {.closure.}
    ## Returns an error message, or "" when the value is valid.
  FormIssue* = object
    field*: Option[ControlId] ## None for a form-level error.
    message*: string
  FormValidator* = proc(form: FormState): seq[FormIssue] {.closure.}
  FieldKind* {.pure.} = enum Input, Area
  FormField* = object
    id*: ControlId
    label*, help*: string
    required*: bool
    validators*: seq[Validator]
    case kind*: FieldKind
    of FieldKind.Input: input*: TextInputState
    of FieldKind.Area:
      area*: TextAreaState
      rows*: int
    initial*: string
    error*: string ## Result of the last validation.
    externalError*: string ## Set by the application, for example from a server response.
    touched*: bool ## Focus has left the field at least once.
  FormState* = object
    id*: ControlId
    fields*: seq[FormField]
    timing*: ValidationTiming
    validators*: seq[FormValidator]
    formErrors*: seq[string]
    submitAttempted*: bool
    submit*, reset*: ButtonState ## IDs `<form>/submit` and `<form>/reset`.
    showReset*: bool
    offset*: int ## First visible row when the form is taller than its area.
    lastFocus: Option[ControlId]
  Form* = object
    theme*: ControlTheme
    submitLabel*, resetLabel*: string
    labelWidth*: int ## 0 puts labels above fields; otherwise beside them in this many cells.

func nonEmpty*(message = "Required"): Validator =
  result = proc(value: string): string =
    if value.strip.len == 0: message else: ""

func minGraphemes*(n: int, message = ""): Validator =
  let text = if message.len > 0: message else: "Use at least " & $n & " characters"
  result = proc(value: string): string =
    if value.len > 0 and clusterCount(value) < n: text else: ""

func initFormState*(id: ControlId, timing = ValidationTiming.OnBlur,
    showReset = true): FormState =
  FormState(id: id, timing: timing, showReset: showReset,
    submit: initButtonState(id.child("submit")), reset: initButtonState(id.child("reset")))

proc addField*(form: var FormState, id: ControlId, label: string, initial = "", help = "",
    required = false, validators: openArray[Validator] = [], mask = "", readOnly = false) =
  ## Adds a single-line field. Raises `ValueError` for a duplicate ID.
  for f in form.fields:
    if f.id == id: raise newException(ValueError, "Duplicate field ID: " & $id)
  form.fields.add FormField(id: id, label: label, help: help, required: required,
    validators: @validators, kind: FieldKind.Input, initial: initial,
    input: initTextInputState(id, initial, readOnly = readOnly, mask = mask))

proc addAreaField*(form: var FormState, id: ControlId, label: string, initial = "",
    help = "", required = false, validators: openArray[Validator] = [], rows = 3) =
  for f in form.fields:
    if f.id == id: raise newException(ValueError, "Duplicate field ID: " & $id)
  form.fields.add FormField(id: id, label: label, help: help, required: required,
    validators: @validators, kind: FieldKind.Area, initial: initial, rows: max(1, rows),
    area: initTextAreaState(id, initial))

func fieldIndex(form: FormState, id: ControlId): int =
  for i, f in form.fields:
    if f.id == id: return i
  -1

proc addValidator*(form: var FormState, id: ControlId, validator: Validator) =
  ## Appends a field validator; a plain `proc(value: string): string` converts implicitly here.
  let i = form.fieldIndex(id)
  if i < 0: raise newException(KeyError, "Unknown field: " & $id)
  form.fields[i].validators.add validator

proc addValidator*(form: var FormState, validator: FormValidator) =
  form.validators.add validator

func value*(f: FormField): string =
  if f.kind == FieldKind.Input: f.input.text else: f.area.text

func value*(form: FormState, id: ControlId): string =
  let i = form.fieldIndex(id)
  if i < 0: raise newException(KeyError, "Unknown field: " & $id)
  form.fields[i].value

proc setValue*(form: var FormState, id: ControlId, value: string) =
  let i = form.fieldIndex(id)
  if i < 0: raise newException(KeyError, "Unknown field: " & $id)
  if form.fields[i].kind == FieldKind.Input: form.fields[i].input.setText(value)
  else: form.fields[i].area.setText(value)

func isDirty*(f: FormField): bool = f.value != f.initial
func isDirty*(form: FormState): bool =
  for f in form.fields:
    if f.isDirty: return true

func errorOf*(f: FormField): string =
  if f.externalError.len > 0: f.externalError else: f.error

func showsError*(form: FormState, f: FormField): bool =
  ## Whether the field's error is visible: external errors always; validation errors after the
  ## field was touched or a submit was attempted (only after submit for `OnSubmit`).
  if f.externalError.len > 0: return true
  if f.error.len == 0: return false
  case form.timing
  of ValidationTiming.OnChange: true
  of ValidationTiming.OnBlur: f.touched or form.submitAttempted
  of ValidationTiming.OnSubmit: form.submitAttempted

proc setExternalError*(form: var FormState, id: ControlId, message: string) =
  let i = form.fieldIndex(id)
  if i >= 0: form.fields[i].externalError = message

proc clearExternalErrors*(form: var FormState) =
  for f in form.fields.mitems: f.externalError = ""

proc validateField(form: var FormState, i: int) =
  var f = addr form.fields[i]
  f.error = ""
  let v = f[].value
  if f.required and v.strip.len == 0:
    f.error = "Required"
    return
  for validator in f.validators:
    let message = validator(v)
    if message.len > 0:
      f.error = message
      return

proc validate*(form: var FormState): bool =
  ## Runs every field and form validator; returns whether all passed (external errors count).
  form.formErrors.setLen(0)
  for i in 0..form.fields.high: form.validateField(i)
  for validator in form.validators:
    for e in validator(form):
      if e.field.isSome:
        let i = form.fieldIndex(e.field.get)
        if i >= 0 and form.fields[i].error.len == 0: form.fields[i].error = e.message
      else: form.formErrors.add e.message
  result = form.formErrors.len == 0
  for f in form.fields:
    if f.errorOf.len > 0: result = false

proc submitForm*(form: var FormState, fm: var FocusManager): bool =
  ## Validates everything and marks the submit attempt. On failure focuses the first invalid
  ## field and returns false.
  form.submitAttempted = true
  result = form.validate()
  if not result:
    for f in form.fields:
      if f.errorOf.len > 0:
        discard fm.focus(f.id)
        break

proc resetForm*(form: var FormState) =
  ## Restores initial values and clears errors and touched state.
  for f in form.fields.mitems:
    if f.kind == FieldKind.Input: f.input.setText(f.initial)
    else: f.area.setText(f.initial)
    f.error = ""
    f.externalError = ""
    f.touched = false
  form.formErrors.setLen(0)
  form.submitAttempted = false

proc revalidate(form: var FormState, i: int) =
  let due = case form.timing
    of ValidationTiming.OnChange: true
    of ValidationTiming.OnBlur: form.fields[i].touched or form.submitAttempted
    of ValidationTiming.OnSubmit: form.submitAttempted
  if due: form.validateField(i)

proc syncFocus*(form: var FormState, fm: FocusManager) =
  ## Marks the field focus left as touched and validates it for `OnBlur`. Called by
  ## `renderControl` and `handle`.
  let now = fm.focused
  if now == form.lastFocus: return
  if form.lastFocus.isSome:
    let i = form.fieldIndex(form.lastFocus.get)
    if i >= 0:
      form.fields[i].touched = true
      if form.timing != ValidationTiming.OnSubmit: form.validateField(i)
  form.lastFocus = now

# Rendering.

func initForm*(theme = defaultTheme(), submitLabel = "Submit", resetLabel = "Reset"): Form =
  Form(theme: theme, submitLabel: submitLabel, resetLabel: resetLabel)

func fieldHeight(form: FormState, w: Form, f: FormField): int =
  let control = if f.kind == FieldKind.Input: 1 else: f.rows
  let label = if w.labelWidth > 0: 0 else: 1
  let note = if form.showsError(f) or f.help.len > 0: 1 else: 0
  label+control+note+1

func contentHeight*(form: FormState, w: Form): int =
  for f in form.fields: result += form.fieldHeight(w, f)
  result += form.formErrors.len+1

proc renderControl*(frame: var Frame, fm: var FocusManager, w: Form, area: Rect,
    form: var FormState) =
  ## Fields stack vertically and scroll to keep the focused field visible. Labels of required
  ## fields end in `*`; shown errors start with `✗` and also restyle the field.
  form.syncFocus(fm)
  let buf = addr frame.buffer[]
  # Underlined fields stay visible when empty, without relying on color.
  var fieldTheme = w.theme
  fieldTheme.text = fieldTheme.text.patch(initStyle().withAddModifier(Modifier.Underlined))
  var tops: seq[int]
  var y = 0
  for f in form.fields:
    tops.add y
    y += form.fieldHeight(w, f)
  let total = y+form.formErrors.len+1
  let focusedIndex = block:
    var r = -1
    for i, f in form.fields:
      if fm.isFocused(f.id): r = i
    r
  if focusedIndex >= 0:
    let top = tops[focusedIndex]
    let bottom = top+form.fieldHeight(w, form.fields[focusedIndex])
    if top < form.offset: form.offset = top
    elif bottom > form.offset+area.height: form.offset = bottom-area.height
  elif fm.isFocused(form.submit.id) or fm.isFocused(form.reset.id):
    form.offset = total-area.height
  form.offset = clamp(form.offset, 0, max(0, total-area.height))
  fm.withScope(form.id, area, false):
    template visible(row: int): bool = row >= area.y and row < area.bottom
    for i in 0..form.fields.high:
      var f = addr form.fields[i]
      var row = area.y+tops[i]-form.offset
      let shown = form.showsError(f[])
      let labelText = (if shown: "✗ " else: "") & f.label & (if f.required: " *" else: "")
      let labelStyle = if shown: w.theme.label.patch(w.theme.error) else: w.theme.label
      var fieldX = area.x
      var fieldWidth = area.width
      if w.labelWidth > 0:
        if visible(row):
          buf[].writeClipped(area.x, row, clipText(labelText, w.labelWidth-1), w.labelWidth-1,
            labelStyle)
        fieldX = area.x+w.labelWidth
        fieldWidth = max(0, area.width-w.labelWidth)
      else:
        if visible(row): buf[].writeClipped(area.x, row, labelText, area.width, labelStyle)
        inc row
      let rows = if f.kind == FieldKind.Input: 1 else: f.rows
      let top = max(row, area.y)
      let bottom = min(row+rows, area.bottom)
      let fieldArea = initRect(fieldX, top, fieldWidth, max(0, bottom-top))
      if f.kind == FieldKind.Input:
        let input = initTextInput(theme = fieldTheme).withInvalid(shown)
        if fieldArea.height > 0: frame.renderControl(fm, input, fieldArea, f.input)
        else: fm.register(f.id, fieldArea, f.input.enabled, textEntry = true)
      else:
        let input = initTextArea(theme = fieldTheme).withInvalid(shown)
        if fieldArea.height > 0: frame.renderControl(fm, input, fieldArea, f.area)
        else: fm.register(f.id, fieldArea, f.area.enabled, textEntry = true)
      row += rows
      if visible(row):
        if shown:
          buf[].writeClipped(fieldX, row, "✗ " & f[].errorOf, fieldWidth, w.theme.error)
        elif f.help.len > 0:
          buf[].writeClipped(fieldX, row, f.help, fieldWidth, w.theme.help)
    var row = area.y+total-form.offset-form.formErrors.len-1
    for message in form.formErrors:
      if visible(row): buf[].writeClipped(area.x, row, "✗ " & message, area.width, w.theme.error)
      inc row
    if visible(row):
      let submit = initButton(w.submitLabel, w.theme)
      frame.renderControl(fm, submit, initRect(area.x, row, min(submit.width, area.width), 1),
        form.submit)
      if form.showReset:
        let reset = initButton(w.resetLabel, w.theme)
        let x = area.x+submit.width+2
        frame.renderControl(fm, reset, initRect(x, row, max(0, min(reset.width, area.right-x)),
          1), form.reset)
    else:
      fm.register(form.submit.id, initRect(area.x, area.y, 0, 0), form.submit.enabled)
      if form.showReset:
        fm.register(form.reset.id, initRect(area.x, area.y, 0, 0), form.reset.enabled)

proc handle*(form: var FormState, fm: var FocusManager, route: Route,
    keymap: Keymap = standardKeymap): EventResult =
  ## Routes events to the targeted field or button. Enter in a single-line field moves to the
  ## next field, and on the last field submits. A successful submit returns `form.submit`, a
  ## reset `form.reset`, both with the form ID as subject.
  form.syncFocus(fm)
  for i in 0..form.fields.high:
    if not route.targets(form.fields[i].id): continue
    result = if form.fields[i].kind == FieldKind.Input: form.fields[i].input.handle(route, keymap)
      else: form.fields[i].area.handle(route, keymap)
    if result.changed:
      form.fields[i].externalError = ""
      form.revalidate(i)
    if result.action == some(TextSubmit):
      if i < form.fields.high:
        discard fm.focus(form.fields[i+1].id)
        result = consumed()
      else:
        result = if form.submitForm(fm): emitted(FormSubmit, $form.id) else: consumed()
    form.syncFocus(fm)
    return
  if route.targets(form.submit.id):
    let pressed = form.submit.handle(route, keymap)
    if pressed.action == some(ButtonPress):
      return if form.submitForm(fm): emitted(FormSubmit, $form.id) else: consumed()
    return pressed
  if route.targets(form.reset.id):
    let pressed = form.reset.handle(route, keymap)
    if pressed.action == some(ButtonPress):
      form.resetForm()
      return emitted(FormReset, $form.id, changed = true)
    return pressed
