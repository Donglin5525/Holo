# Weekly Observation Blocking State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the HoloAI weekly-observation card close and retry reliably, expose progress and useful failures, and distinguish empty AI responses from malformed payloads.

**Architecture:** Add a small value-type UI state model owned by `ChatView`, so dismissal and retry feedback are explicit SwiftUI dependencies. Extend the existing parser with a diagnostic result while preserving its current optional-returning API for existing callers.

**Tech Stack:** Swift 5, SwiftUI, XCTest, Core Data repository, Xcode build/test.

---

## File map

- Create `Holo/Holo APP/Holo/Holo/Views/Chat/WeeklyObservationCardState.swift`: pure, testable local interaction state.
- Create `Holo/Holo APP/Holo/HoloTests/Views/Chat/WeeklyObservationCardStateTests.swift`: dismissal and retry transition tests.
- Modify `Holo/Holo APP/Holo/Holo/Views/Chat/WeeklyObservationCard.swift`: loading/error presentation and injected display dependencies.
- Modify `Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift`: own state, handle retry without swallowed errors, and refresh explicitly.
- Modify `Holo/Holo APP/Holo/Holo/Services/AI/MemoryInsightResponseParser.swift`: diagnostic parse result.
- Create `Holo/Holo APP/Holo/HoloTests/Services/AI/MemoryInsightResponseParserTests.swift`: parser classification regression tests.
- Modify `Holo/Holo APP/Holo/Holo/Services/AI/MemoryInsightService.swift`: save classified, user-readable parse failures.

### Task 1: Test and implement the interaction state

**Files:**
- Create: `Holo/Holo APP/Holo/HoloTests/Views/Chat/WeeklyObservationCardStateTests.swift`
- Create: `Holo/Holo APP/Holo/Holo/Views/Chat/WeeklyObservationCardState.swift`

- [ ] **Step 1: Write the failing state tests**

```swift
import XCTest
@testable import Holo

final class WeeklyObservationCardStateTests: XCTestCase {
    func testDismissHidesCardImmediately() {
        var state = WeeklyObservationCardState()
        state.dismiss()
        XCTAssertTrue(state.isDismissed)
        XCTAssertFalse(state.shouldDisplay(persistedDecision: true))
    }

    func testBeginRetryRejectsDuplicateAttempt() {
        var state = WeeklyObservationCardState()
        XCTAssertTrue(state.beginRetry())
        XCTAssertFalse(state.beginRetry())
        XCTAssertTrue(state.isRetrying)
    }

    func testSuccessfulRetryRestoresDisplayAndIncrementsRevision() {
        var state = WeeklyObservationCardState(isDismissed: true)
        XCTAssertTrue(state.beginRetry())
        state.finishRetry(errorMessage: nil)
        XCTAssertFalse(state.isDismissed)
        XCTAssertFalse(state.isRetrying)
        XCTAssertNil(state.errorMessage)
        XCTAssertEqual(state.revision, 1)
    }

    func testFailedRetryRemainsRetryableAndExposesError() {
        var state = WeeklyObservationCardState()
        XCTAssertTrue(state.beginRetry())
        state.finishRetry(errorMessage: "AI 服务未返回内容，请稍后重试。")
        XCTAssertFalse(state.isRetrying)
        XCTAssertEqual(state.errorMessage, "AI 服务未返回内容，请稍后重试。")
        XCTAssertTrue(state.beginRetry())
    }
}
```

- [ ] **Step 2: Run the targeted tests and verify RED**

Run:

```bash
xcodebuild test -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:HoloTests/WeeklyObservationCardStateTests
```

Expected: build failure because `WeeklyObservationCardState` does not exist.

- [ ] **Step 3: Add the minimal state model**

```swift
import Foundation

struct WeeklyObservationCardState: Equatable {
    private(set) var isDismissed = false
    private(set) var isRetrying = false
    private(set) var errorMessage: String?
    private(set) var revision = 0

    init(isDismissed: Bool = false) {
        self.isDismissed = isDismissed
    }

    func shouldDisplay(persistedDecision: Bool) -> Bool {
        !isDismissed && persistedDecision
    }

    mutating func dismiss() {
        isDismissed = true
    }

    @discardableResult
    mutating func beginRetry() -> Bool {
        guard !isRetrying else { return false }
        isRetrying = true
        errorMessage = nil
        return true
    }

    mutating func finishRetry(errorMessage: String?) {
        isRetrying = false
        self.errorMessage = errorMessage
        if errorMessage == nil {
            isDismissed = false
            revision += 1
        }
    }
}
```

- [ ] **Step 4: Re-run the targeted tests and verify GREEN**

Expected: four tests pass with non-zero executed test count.

- [ ] **Step 5: Commit this isolated unit**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Chat/WeeklyObservationCardState.swift" "Holo/Holo APP/Holo/HoloTests/Views/Chat/WeeklyObservationCardStateTests.swift"
git commit -m "test(iOS): define weekly observation interaction state"
```

### Task 2: Classify response parsing failures

**Files:**
- Create: `Holo/Holo APP/Holo/HoloTests/Services/AI/MemoryInsightResponseParserTests.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/MemoryInsightResponseParser.swift`

- [ ] **Step 1: Write failing parser classification tests**

```swift
import XCTest
@testable import Holo

final class MemoryInsightResponseParserTests: XCTestCase {
    func testEmptyResponseIsClassifiedSeparately() {
        XCTAssertEqual(MemoryInsightResponseParser.parseResult(" \n "), .failure(.emptyResponse))
    }

    func testMalformedJSONIsInvalidJSON() {
        XCTAssertEqual(MemoryInsightResponseParser.parseResult("not-json"), .failure(.invalidJSON))
    }

    func testDecodablePayloadWithInvalidSchemaIsInvalidSchema() {
        let raw = #"{"title":"","summary":"x","cards":[]}"#
        XCTAssertEqual(MemoryInsightResponseParser.parseResult(raw), .failure(.invalidSchema))
    }
}
```

- [ ] **Step 2: Run only the parser tests and verify RED**

Use the same `xcodebuild test` command with `-only-testing:HoloTests/MemoryInsightResponseParserTests`.

Expected: build failure because `parseResult` and its error types do not exist.

- [ ] **Step 3: Add diagnostic result without breaking existing callers**

Add:

```swift
enum MemoryInsightParseFailure: Error, Equatable {
    case emptyResponse
    case invalidJSON
    case invalidSchema

    var userMessage: String {
        switch self {
        case .emptyResponse: return "AI 服务未返回内容，请稍后重试。"
        case .invalidJSON: return "AI 返回格式异常，请重试。"
        case .invalidSchema: return "AI 返回内容不完整，请重试。"
        }
    }
}

static func parseResult(_ raw: String) -> Result<MemoryInsightPayload, MemoryInsightParseFailure> {
    guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        return .failure(.emptyResponse)
    }
    for candidate in parseCandidates(raw) {
        if let payload = tryParse(candidate) {
            return validate(payload) ? .success(payload) : .failure(.invalidSchema)
        }
    }
    return .failure(.invalidJSON)
}

static func parse(_ raw: String) -> MemoryInsightPayload? {
    try? parseResult(raw).get()
}
```

Extract the current direct, fenced, and brace strings into `parseCandidates(_:)`, preserving their order.

- [ ] **Step 4: Run parser tests and existing insight-related tests**

Expected: new classification tests pass and existing callers compile.

- [ ] **Step 5: Commit the parser unit**

```bash
git add "Holo/Holo APP/Holo/Holo/Services/AI/MemoryInsightResponseParser.swift" "Holo/Holo APP/Holo/HoloTests/Services/AI/MemoryInsightResponseParserTests.swift"
git commit -m "fix(iOS): classify memory insight parse failures"
```

### Task 3: Wire reliable close and retry behavior

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/WeeklyObservationCard.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/MemoryInsightService.swift`

- [ ] **Step 1: Make card feedback explicit**

Add `let isRetrying: Bool` and `let retryErrorMessage: String?` to `WeeklyObservationCard`. In the failed content, prefer `retryErrorMessage` over the persisted error. Render the action as:

```swift
if isRetrying {
    HStack {
        ProgressView()
        Text("正在重新生成…")
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 10)
} else {
    primaryButton("重试", action: onRetry)
}
```

Set `.disabled(isRetrying)` on the retry action.

- [ ] **Step 2: Replace the unused revision integer with explicit state**

In `ChatView`:

```swift
@State private var weeklyObservationCardState = WeeklyObservationCardState()
```

Render with:

```swift
if weeklyObservationCardState.shouldDisplay(
    persistedDecision: WeeklyObservationCard.shouldDisplay
) {
    WeeklyObservationCard(
        isRetrying: weeklyObservationCardState.isRetrying,
        retryErrorMessage: weeklyObservationCardState.errorMessage,
        // existing callbacks
    )
    .id(weeklyObservationCardState.revision)
}
```

Close with:

```swift
weeklyObservationCardState.dismiss()
WeeklyObservationCard.hideForToday()
```

- [ ] **Step 3: Replace swallowed retry errors with a structured handler**

Add a `@MainActor` method on `ChatView`:

```swift
private func retryWeeklyObservation() {
    guard weeklyObservationCardState.beginRetry() else { return }
    Task { @MainActor in
        do {
            await EffectiveRecordDayService.shared.refreshAndWait()
            let stage: MemoryInsightObservationStage =
                EffectiveRecordDayService.shared.currentResult?.eligibility == .lightReady
                ? .light3d : .full7d
            let range = MemoryInsightContextBuilder.periodRange(
                periodType: .weekly,
                referenceDate: Date()
            )
            _ = try await MemoryInsightService.shared.generateInsight(
                periodType: .weekly,
                start: range.start,
                end: range.end,
                forceRefresh: true,
                observationStage: stage
            )
            weeklyObservationCardState.finishRetry(errorMessage: nil)
        } catch is CancellationError {
            weeklyObservationCardState.finishRetry(errorMessage: nil)
        } catch {
            weeklyObservationCardState.finishRetry(errorMessage: error.localizedDescription)
        }
    }
}
```

Use `onRetry: retryWeeklyObservation`.

- [ ] **Step 4: Save classified parser errors**

Replace the optional parser guard in `MemoryInsightService` with:

```swift
let payload: MemoryInsightPayload
switch MemoryInsightResponseParser.parseResult(generationResult.rawResponse) {
case .success(let parsed):
    payload = parsed
case .failure(let failure):
    try? repository.saveFailed(insight: insight, errorMessage: failure.userMessage)
    throw failure
}
```

- [ ] **Step 5: Run both new test classes**

Expected: all new tests pass with non-zero executed counts.

- [ ] **Step 6: Build the app**

```bash
xcodebuild build -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit only task files**

```bash
git add "Holo/Holo APP/Holo/Holo/Views/Chat/WeeklyObservationCard.swift" "Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift" "Holo/Holo APP/Holo/Holo/Services/AI/MemoryInsightService.swift"
git commit -m "fix(iOS): make weekly observation recovery responsive"
```

### Task 4: Audit comparable blocking interactions and verify scope

**Files:**
- Inspect: `Holo/Holo APP/Holo/Holo/Views/Chat/*.swift`
- Modify only if an interaction matches all risk criteria in the design.

- [ ] **Step 1: Locate swallowed user-triggered async errors**

```bash
rg -n -U "Button[\\s\\S]{0,500}Task[\\s\\S]{0,500}(try\\?|catch\\s*\\{\\s*\\})" "Holo/Holo APP/Holo/Holo/Views/Chat"
```

- [ ] **Step 2: Classify each hit**

Record whether it is user-triggered, can block a primary interaction, has loading feedback, and exposes failure. Do not change background-only refreshes.

- [ ] **Step 3: If a qualifying hit exists, add one failing regression test before its minimal fix**

The test must assert the exact missing state transition or error feedback. Run it RED, apply one fix, then run GREEN.

- [ ] **Step 4: Run all targeted tests and a clean build**

Expected: tests execute and pass; build succeeds.

- [ ] **Step 5: Confirm the final diff excludes existing Memory Gallery work**

```bash
git status --short
git diff --stat HEAD~3..HEAD
git diff --name-only HEAD~3..HEAD
```

The task commits must not include `MemoryInsightCardView.swift`, `MemoryInsightHeroCard.swift`, `MemoryGalleryView.swift`, `MemoryInsightActionPromptBuilder.swift`, or its tests.
