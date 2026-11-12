## Application-owned focus: per-frame registration, scopes, modals, traversal and hit testing
## (Canopy extension). See `docs/interaction.md` for the full contract.
import std/[options, tables]

import ../../core/layout/geometry
import ./ids
export geometry, ids, options

type
  Registration* = object
    ## One control as registered in a completed frame. `hitArea` is `area` clipped by every
    ## enclosing scope; `modal` is the innermost enclosing modal scope, empty for the base layer.
    id*: ControlId
    area*, hitArea*: Rect
    scopes*: seq[ControlId] ## Enclosing scopes, innermost first.
    modal*: ControlId
    enabled*, tabStop*, textEntry*: bool
  ScopeRecord = object
    id: ControlId
    parent: int
    modal: bool
    area, clip: Rect
    modalScope: ControlId
  ModalEntry = object
    scope: ControlId
    returnFocus: ControlId
    initialFocus: ControlId
    entered: bool
  FocusManager* = object
    ## Holds focus and the last completed frame's registrations. Copying it copies all state;
    ## keep one per independent UI surface.
    focusedId: ControlId
    registrations, building: seq[Registration]
    scopes, buildingScopes: seq[ScopeRecord]
    scopeStack: seq[int]
    index, buildIndex: Table[ControlId, int]
    modals: seq[ModalEntry]
    inFrame: bool
    stale: bool
    captured: ControlId
    terminalFocused*: bool
      ## Last terminal `FocusGained`/`FocusLost` report; independent of logical focus.

const Unbounded = Rect(x: 0, y: 0, width: MaxCoordinate, height: MaxCoordinate)

func initFocusManager*(): FocusManager = FocusManager(terminalFocused: true)

func activeModal*(fm: FocusManager): Option[ControlId] =
  ## The top open modal scope, which owns keyboard, traversal and pointer input.
  if fm.modals.len > 0: some(fm.modals[^1].scope) else: none(ControlId)

func activeDomain(fm: FocusManager): ControlId =
  if fm.modals.len > 0: fm.modals[^1].scope else: ControlId("")

func modalStack*(fm: FocusManager): seq[ControlId] =
  for entry in fm.modals: result.add entry.scope

func isModalOpen*(fm: FocusManager, scope: ControlId): bool =
  for entry in fm.modals:
    if entry.scope == scope: return true

func registrations*(fm: FocusManager): lent seq[Registration] = fm.registrations
  ## The last completed frame's registrations in traversal order.

func registration*(fm: FocusManager, id: ControlId): Option[Registration] =
  if id in fm.index: some(fm.registrations[fm.index[id]]) else: none(Registration)

func areaOf*(fm: FocusManager, id: ControlId): Option[Rect] =
  ## Rendered area of a control or scope in the last completed frame.
  if id in fm.index: return some(fm.registrations[fm.index[id]].area)
  for scope in fm.scopes:
    if scope.id == id: return some(scope.area)

func inFrame*(fm: FocusManager): bool = fm.inFrame
func geometryStale*(fm: FocusManager): bool = fm.stale
  ## True after a resize until the next `endFrame`; pointer hit testing is disabled meanwhile.
proc markGeometryStale*(fm: var FocusManager) = fm.stale = true

func canFocus(r: Registration): bool = r.enabled

func validIn(fm: FocusManager, id: ControlId, domain: ControlId): bool =
  if id.len == 0 or id notin fm.index: return false
  let r = fm.registrations[fm.index[id]]
  r.canFocus and r.modal == domain

func targetable*(fm: FocusManager, id: ControlId): bool =
  ## Whether `id` may receive keyboard input: enabled in the active domain, or not yet
  ## registered (pending until the next `endFrame`).
  id.len > 0 and (id notin fm.index or fm.validIn(id, fm.activeDomain))

func focused*(fm: FocusManager): Option[ControlId] =
  if fm.targetable(fm.focusedId): some(fm.focusedId) else: none(ControlId)

func isFocused*(fm: FocusManager, id: ControlId): bool =
  fm.focusedId == id and fm.targetable(id)

func captured*(fm: FocusManager): Option[ControlId] =
  ## Control receiving drag and release events until the pointer button is released.
  if fm.captured.len > 0: some(fm.captured) else: none(ControlId)

proc setCapture*(fm: var FocusManager, id: Option[ControlId]) =
  fm.captured = if id.isSome: id.get else: ControlId("")

proc focus*(fm: var FocusManager, id: ControlId): bool {.discardable.} =
  ## Focuses `id` now. A control known to the last frame must be enabled and in the
  ## active domain, otherwise focus is unchanged and the result is false. Unknown IDs are kept
  ## pending and validated by the next `endFrame`.
  if id.len == 0: return false
  if id in fm.index and not fm.validIn(id, fm.activeDomain): return false
  fm.focusedId = id
  true

proc clearFocus*(fm: var FocusManager) = fm.focusedId = ControlId("")

proc traversable(fm: FocusManager, i: int, domain: ControlId): bool =
  let r = fm.registrations[i]
  r.canFocus and r.tabStop and r.modal == domain

proc step(fm: var FocusManager, forward: bool): bool =
  let domain = fm.activeDomain
  var any = false
  for i in 0..fm.registrations.high:
    if fm.traversable(i, domain): any = true; break
  if not any: return false
  let n = fm.registrations.len
  var start = -1
  if fm.focusedId in fm.index and fm.registrations[fm.index[fm.focusedId]].modal == domain:
    start = fm.index[fm.focusedId]
  var i = start
  for _ in 0..<n:
    if i < 0: i = (if forward: 0 else: n-1)
    else: i = (if forward: (i+1) mod n else: (i-1+n) mod n)
    if fm.traversable(i, domain):
      fm.focusedId = fm.registrations[i].id
      return true
  false

proc focusNext*(fm: var FocusManager): bool {.discardable.} =
  ## Moves to the next tab stop in the active domain, wrapping. Returns false for an empty domain.
  fm.step(true)

proc focusPrevious*(fm: var FocusManager): bool {.discardable.} = fm.step(false)

proc focusFirst*(fm: var FocusManager, scope: Option[ControlId] = none(ControlId)): bool {.discardable.} =
  ## Focuses the first tab stop of the active domain, or of `scope` within it.
  let domain = fm.activeDomain
  for i, r in fm.registrations:
    if not fm.traversable(i, domain): continue
    if scope.isSome and scope.get notin r.scopes: continue
    fm.focusedId = r.id
    return true
  false

func hitTest*(fm: FocusManager, position: Position): Option[Registration] =
  ## Topmost control in the active domain whose clipped area contains `position`,
  ## using the last completed frame. Disabled controls are returned so they occlude what is
  ## beneath them. None while geometry is stale.
  if fm.stale: return
  let domain = fm.activeDomain
  for i in countdown(fm.registrations.high, 0):
    let r = fm.registrations[i]
    if r.modal == domain and r.hitArea.contains(position): return some(r)

func insideModal*(fm: FocusManager, position: Position): bool =
  ## Whether `position` lies in the active modal scope's area.
  if fm.modals.len == 0 or fm.stale: return false
  for scope in fm.scopes:
    if scope.id == fm.modals[^1].scope and scope.clip.contains(position): return true

# Frame registration.

proc beginFrame*(fm: var FocusManager) =
  ## Starts collecting registrations. Uncommitted registrations from a frame that raised before
  ## `endFrame` are discarded.
  fm.inFrame = true
  fm.building.setLen(0)
  fm.buildingScopes.setLen(0)
  fm.scopeStack.setLen(0)
  fm.buildIndex.clear()

proc requireFrame(fm: FocusManager) =
  if not fm.inFrame: raise newException(ValueError, "Registration outside beginFrame/endFrame")

proc register*(fm: var FocusManager, id: ControlId, area: Rect, enabled = true,
    tabStop = true, textEntry = false) =
  ## Registers a control rendered this frame. Hidden controls are simply not registered; an
  ## empty or clipped area only removes the control from hit testing. Raises `ValueError` for a
  ## duplicate ID.
  fm.requireFrame()
  if id.len == 0: raise newException(ValueError, "Control IDs cannot be empty")
  if id in fm.buildIndex: raise newException(ValueError, "Duplicate control ID in frame: " & $id)
  var r = Registration(id: id, area: area, hitArea: area, enabled: enabled, tabStop: tabStop,
    textEntry: textEntry)
  if fm.scopeStack.len > 0:
    let scope = fm.buildingScopes[fm.scopeStack[^1]]
    for i in countdown(fm.scopeStack.high, 0): r.scopes.add fm.buildingScopes[fm.scopeStack[i]].id
    r.modal = scope.modalScope
    r.hitArea = area.intersection(scope.clip)
  fm.buildIndex[id] = fm.building.len
  fm.building.add r

proc beginScope*(fm: var FocusManager, id: ControlId, area = Unbounded, modal = false) =
  ## Opens a scope that clips its children's hit areas. A modal scope must already be open
  ## (`openModal`) so that routing changed before its first frame. Raises `ValueError` for a
  ## duplicate scope ID or a modal scope that is not open.
  fm.requireFrame()
  if modal and not fm.isModalOpen(id):
    raise newException(ValueError, "Modal scope rendered before openModal: " & $id)
  for scope in fm.buildingScopes:
    if scope.id == id: raise newException(ValueError, "Duplicate scope ID in frame: " & $id)
  let parent = if fm.scopeStack.len > 0: fm.scopeStack[^1] else: -1
  var record = ScopeRecord(id: id, parent: parent, modal: modal, area: area, clip: area)
  if parent >= 0:
    record.clip = area.intersection(fm.buildingScopes[parent].clip)
    record.modalScope = fm.buildingScopes[parent].modalScope
  if modal: record.modalScope = id
  fm.scopeStack.add fm.buildingScopes.len
  fm.buildingScopes.add record

proc endScope*(fm: var FocusManager) =
  fm.requireFrame()
  if fm.scopeStack.len == 0: raise newException(ValueError, "endScope without beginScope")
  fm.scopeStack.setLen(fm.scopeStack.len-1)

template withScope*(fm: var FocusManager, id: ControlId, area: Rect, modal: bool,
    body: untyped) =
  fm.beginScope(id, area, modal)
  try: body
  finally: fm.endScope()

# Modals.

proc enterTop(fm: var FocusManager) =
  let domain = fm.activeDomain
  let initial = fm.modals[^1].initialFocus
  fm.modals[^1].entered = true
  if fm.validIn(initial, domain): fm.focusedId = initial
  elif not fm.focusFirst(): fm.focusedId = ControlId("")

proc openModal*(fm: var FocusManager, scope: ControlId,
    initialFocus = none(ControlId)) =
  ## Opens a modal now, recording the focused control for restoration. Focus moves to
  ## `initialFocus` immediately (pending if not yet registered) or, at the next `endFrame`, to
  ## the modal's first focusable control. Opening an open modal does nothing.
  if fm.isModalOpen(scope): return
  var entry = ModalEntry(scope: scope, returnFocus: fm.focusedId)
  if initialFocus.isSome: entry.initialFocus = initialFocus.get
  fm.modals.add entry
  fm.setCapture(none(ControlId))
  if entry.initialFocus.len > 0 and (entry.initialFocus notin fm.index or
      fm.validIn(entry.initialFocus, scope)):
    fm.focusedId = entry.initialFocus
    fm.modals[^1].entered = entry.initialFocus in fm.index
  else:
    fm.focusedId = ControlId("")

proc closeAt(fm: var FocusManager, i: int) =
  let entry = fm.modals[i]
  let top = i == fm.modals.high
  fm.modals.delete(i)
  if top:
    fm.focusedId = entry.returnFocus
    fm.setCapture(none(ControlId))
  else:
    fm.modals[i].returnFocus = entry.returnFocus

proc closeModal*(fm: var FocusManager, scope: ControlId): bool {.discardable.} =
  ## Closes a modal. Closing the top modal restores its recorded focus now; `endFrame` applies
  ## the fallback if that control is no longer focusable.
  for i in countdown(fm.modals.high, 0):
    if fm.modals[i].scope == scope:
      fm.closeAt(i)
      return true

# Frame completion.

proc fallback(fm: FocusManager, old: seq[Registration], oldIndex: Table[ControlId, int],
    id: ControlId): ControlId =
  let domain = fm.activeDomain
  proc ok(candidate: ControlId): bool =
    candidate != id and fm.validIn(candidate, domain) and
      fm.registrations[fm.index[candidate]].tabStop
  if id in oldIndex:
    let k = oldIndex[id]
    for j in k+1..old.high:
      if ok(old[j].id): return old[j].id
    for j in countdown(k-1, 0):
      if ok(old[j].id): return old[j].id
  for r in fm.registrations:
    if ok(r.id): return r.id

proc endFrame*(fm: var FocusManager): bool {.discardable.} =
  ## Commits this frame's registrations and reconciles focus. Open modals stay open until
  ## `closeModal`, even when a frame does not render them. Returns true when focus changed, so
  ## the caller should render once more (`drawInteractive` does this).
  fm.requireFrame()
  fm.inFrame = false
  if fm.scopeStack.len > 0:
    raise newException(ValueError, "Unbalanced beginScope at endFrame")
  let before = fm.focusedId
  let old = move(fm.registrations)
  let oldIndex = move(fm.index)
  fm.registrations = move(fm.building)
  fm.index = move(fm.buildIndex)
  fm.scopes = move(fm.buildingScopes)
  fm.building = @[]
  fm.buildingScopes = @[]
  fm.buildIndex = initTable[ControlId, int]()
  fm.stale = false
  if fm.modals.len > 0 and not fm.modals[^1].entered:
    fm.enterTop()
  elif fm.focusedId.len > 0 and not fm.validIn(fm.focusedId, fm.activeDomain):
    fm.focusedId = fm.fallback(old, oldIndex, fm.focusedId)
  if fm.captured.len > 0 and fm.captured notin fm.index: fm.captured = ControlId("")
  fm.focusedId != before
