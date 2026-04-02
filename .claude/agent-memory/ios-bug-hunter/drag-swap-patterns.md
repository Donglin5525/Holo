# Drag & Swap Bug Patterns

## Pattern 1: dragOffset Reset Causes Bouncing (Fixed 2026-03-28)

**File**: HomeView.swift
**Symptom**: When dragging an icon near another during pentagon layout reorder, both icons jump violently.
**Root cause**: `checkAndSwapPosition()` called `dragOffset = .zero` after `swapAt()`, but `DragGesture.onChanged` continues firing with its original cumulative `translation`. This creates a feedback loop:
1. Swap fires, offset reset to zero -> icon snaps to new position
2. Next frame, DragGesture sends old translation -> icon jumps away
3. Icon is now near the other position again -> triggers another swap
4. Repeat = visual bouncing

**Fix (v1, superseded by Pattern 3)**: Instead of resetting `dragOffset`, compensate it by the anchor position delta.

**Key insight**: SwiftUI `DragGesture.translation` is always relative to the gesture's start point. You cannot "reset" it by zeroing a derived offset.

## Pattern 2: Repository onChange Fires During Drag (Fixed 2026-03-28)

**File**: HomeView.swift
**Symptom**: During drag, `iconRepository.visibleConfigs` change triggers `loadFeatureItemsFromRepository()`, which rebuilds `featureItems` from scratch, destroying the drag-in-progress state.
**Fix**: Guard the onChange handler with `if draggingItem == nil`.

## Pattern 3: Stale Closure index + dragOffset Overwritten Each Frame (Fixed 2026-03-28)

**File**: HomeView.swift
**Symptom**: After Pattern 1 fix, dragged icon flies far away from finger after first swap. The icon does not follow the finger.
**Root cause**: Two related bugs in the drag compensation:

1. **Stale closure index**: `onChanged` used `positions[index]` to compute `currentPosition`, but `index` is the closure-captured original index. After swap, the dragged item has moved to a new index, so `positions[index]` points to the wrong pentagon slot. This made `checkAndSwapPosition` calculate incorrect screen positions.

2. **dragOffset overwritten each frame**: Every `onChanged` frame executes `dragOffset = value.translation`, overwriting the compensation done during swap. The compensation `dragOffset -= anchorDelta` applied inside `checkAndSwapPosition` was immediately lost on the next frame when `dragOffset = value.translation` ran again.

**Fix**: Introduced `anchorTotalShift` (cumulative anchor displacement from drag start):
- `anchorTotalShift` accumulates every time a swap occurs: `+= (newAnchor - oldAnchor)`
- `dragOffset = value.translation - anchorTotalShift` (computed AFTER swap, so it uses the latest shift)
- `currentScreenPos = dragAnchorPosition + value.translation - anchorTotalShift`
- This decouples the one-way-growing `translation` from the swap-aware `dragOffset`

**Key insight**: When `DragGesture.translation` is cumulative and you need to compensate for discrete anchor changes across multiple swaps, track the *total* accumulated shift as a separate state variable. Compute the display offset as `translation - totalShift` each frame, and compute it AFTER potential swaps so the latest shift is included.

**Ordering matters**: In `onChanged`, call `checkAndSwapPosition()` first, then compute `dragOffset`. If reversed, the dragOffset uses a stale `anchorTotalShift`.
