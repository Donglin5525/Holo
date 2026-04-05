---
name: Swift Charts Degenerate Data Crash Pattern
description: EXC_BREAKPOINT in Charts framework when Y axis domain becomes 0...0 due to all-zero data
type: reference
---

# Swift Charts EXC_BREAKPOINT - Degenerate Data Pattern

Also see [MEMORY.md](./MEMORY.md) for the index.

This file documents the known crash pattern and all files that have been fixed.

## Crash Signature
- Exception: EXC_BREAKPOINT (SIGTRAP) in `_assertionFailure`
- All stack frames in `com.apple.Charts` during `CanvasDisplayList.updateValue()`
- Charts framework internal assertion fails during Y axis domain computation

## Root Cause
When ALL mark values in a Chart are zero, the Y axis domain degenerates to `0...0`,
which triggers an internal `_assertionFailure` in the Charts rendering pipeline.

## Fix Pattern
For every Chart view, add a computed property to detect all-zero data:

```swift
private var allValuesZero: Bool {
    data.allSatisfy { $0.value == 0 }
}
```

Then guard the chart rendering:

```swift
if data.isEmpty || allValuesZero {
    emptyChartView
} else {
    chartContent
}
```

## Specific Edge Cases
- **BarMark**: All bars with height 0 -> Y domain 0...0
- **LineMark + PointMark**: All Y values 0 -> Y domain 0...0
- **AreaMark**: yStart == yEnd for all points -> degenerate
- **SectorMark**: angle value 0 -> assertion failure
- **RectangleMark**: yStart == yEnd == 0 when used for highlight overlay -> guard with `if yEndValue > 0`

## Files Fixed
### Finance Charts (fixed 2026-04-05, first round)
- BarChartView.swift - allValuesZero guard
- LineChartView.swift - allValuesZero guard + RectangleMark yEnd > 0 check
- CategoryBarLineChartView.swift - allValuesZero guard
- PieChartView.swift - nonZeroAggregations filter for SectorMark
- HabitTrendChartView.swift - allValuesZero guard (even with fixed Y scale 0...100)

### Finance Charts NOT the crash source (fixed in first round but crash persisted)
These finance charts were fixed but the crash persisted because the actual crashing charts were elsewhere.

### Habit Charts (fixed 2026-04-05, second round)
- **HabitBarChartView.swift** - was MISSING allValuesZero guard. All BarMark values at 0 -> Y domain 0...0.
- **HabitLineChartView.swift** - already had allValuesZero guard from first round.

- **HabitTrendChartView.swift** - already had allValuesZero guard from first round.

### Health Charts (fixed 2026-04-05, second round)
- **HealthTrendChart.swift** - was MISSING allValuesZero guard. All BarMark values at 0 -> Y domain 0...0.

## Verification Status (2026-04-05)
All 8 Chart views confirmed to have allValuesZero guards. App builds and runs successfully
on iPhone 17 simulator (iOS 26.3.1) without any Charts crash at launch or navigation.

## Key Lessons
1. When fixing Charts crashes, grep for ALL Chart usages project-wide, not just the obvious module.
2. The first fix only addressed finance charts but the actual crash was in habit or health charts that lacked guards.
3. Charts are NOT in the initial view hierarchy (HomeView) -- they only render inside fullScreenCover destinations (FinanceView, HabitsView, HealthView).
4. If crash persists after all guards are in place, the problem may be elsewhere -- always verify by building and running.
