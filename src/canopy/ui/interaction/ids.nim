## Caller-supplied identities for controls and semantic actions (Canopy extension).
import std/hashes

type
  ControlId* = distinct string
    ## Stable identity of a control, scope, command, tree node or button. The application
    ## chooses it and must keep it unchanged across frames.
  ActionId* = distinct string
    ## Name of a semantic action, such as `text.left` or an application command.

func `==`*(a, b: ControlId): bool {.borrow.}
func `$`*(id: ControlId): string {.borrow.}
func len*(id: ControlId): int {.borrow.}
func hash*(id: ControlId): Hash {.borrow.}
func `==`*(a, b: ActionId): bool {.borrow.}
func `$`*(id: ActionId): string {.borrow.}
func len*(id: ActionId): int {.borrow.}
func hash*(id: ActionId): Hash {.borrow.}

func controlId*(name: string): ControlId =
  ## Raises `ValueError` for an empty name, which is reserved for "no control".
  if name.len == 0: raise newException(ValueError, "Control IDs cannot be empty")
  ControlId(name)

func actionId*(name: string): ActionId =
  if name.len == 0: raise newException(ValueError, "Action IDs cannot be empty")
  ActionId(name)

func child*(parent: ControlId, name: string): ControlId =
  ## Derives a stable ID for a part of a compound control, such as a dialog button.
  controlId($parent & "/" & name)
