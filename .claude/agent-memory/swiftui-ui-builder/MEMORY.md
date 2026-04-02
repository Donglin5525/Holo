# HOLO SwiftUI UI Builder - Agent Memory

## Project Structure
- Xcode project path: `/Users/tangyuxuan/Desktop/Claude/HOLO/Holo/Holo APP/Holo/Holo.xcodeproj`
- Scheme: `Holo`
- Available iPhone simulator: iPhone 17 Pro (iOS 26.3.1, id: `2F63C1D8-E4DF-48AC-A6A0-503D9C72E1D8`)
- No iPhone 16 Pro simulator available; project uses iOS 26 SDK

## Calendar Module
- `Views/Calendar/WeekView.swift` - Week view with swipe gesture navigation
- `Views/Calendar/DayCellView.swift` - Shared day cell for week/calendar/popup, uses `DayCellStyle` enum
- `Views/Calendar/ExpandedCalendarView.swift` - Full month calendar
- `Views/Calendar/PopupCalendarSheet.swift` - Popup calendar sheet

## Key Patterns
- `DayCellView` is reused across 3 contexts via `DayCellStyle` enum (`.week`, `.calendar`)
- Finance module uses `CalendarState` (ObservedObject) for date navigation
- Color tokens: `.holoPrimary`, `.holoBackground`, `.holoTextPrimary`, `.holoTextSecondary`, `.holoError`
- `CalendarDateFormatter.compactAmount()` formats expense amounts
- `DailySummary.hasTransactions` checks if a day has records

## Build Warnings (pre-existing, not from our changes)
- `UIScreen.main` deprecated in iOS 26 (used in WeekView, FinanceView, etc.)
- Several `??` with non-optional left side warnings
- `retroactive` attribute warnings in Swift 6 mode
