# iOS Bug Hunter - Agent Memory

## Project Structure
- Xcode project: `Holo/Holo.xcodeproj/project.pbxproj`
- App source root: `Holo/Holo/`
- Views: `Holo/Holo/Views/`
- Models: `Holo/Holo/Models/`
- Core Data models: Various `*+CoreDataClass.swift` files

## Key Crash Patterns Found

### PATTERN-001: Files exist on disk but not in Xcode compile target
- **When**: Clicking a feature causes immediate crash
- **Check**: Search `project.pbxproj` for the file name
- **Fix**: Add files to Xcode target via "Add Files" or check Target Membership
- **Date**: 2026-04-01

### PATTERN-002: NSPredicate using computed property instead of @NSManaged attribute
- **When**: Core Data fetch returns empty or throws at runtime
- **Example**: `transactionType` is computed, must use `type` (the stored property)
- **Also**: TransactionType is String enum, use `%@` not `%d` in predicates
- **File**: HighlightDetector.swift line 254-259
- **Date**: 2026-04-01

## Core Data Model Reference
- `Transaction.type` = String (stores "income"/"expense"), `transactionType` is computed
- `Transaction.amount` = NSDecimalNumber, `.decimalValue` for Decimal
- `TodoTask.priority` = Int16, `TaskPriority` enum rawValue is Int16
- `Habit.isArchived` = Bool, `Habit.type` = Int16, `habitType` is computed
- `HabitRecord.habitId` = UUID (not a relationship, stores UUID directly)

## Memory Gallery Architecture
- Entry: HomeView -> fullScreenCover -> MemoryGalleryView
- ViewModel: `MemoryGalleryViewModel` (@MainActor, @StateObject)
- Data flow: refresh() -> loadData() -> fetchAllMemoryItems() + HighlightDetector.detect() + MilestoneDetector.detect()
- Builder: `TimelineSectionBuilder.buildSection()` composes TimelineSection
- Node types: dailySummary, highlight, milestone
- See: [memory-gallery.md](memory-gallery.md) for details
