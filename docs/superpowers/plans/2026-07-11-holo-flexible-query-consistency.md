# HoloAI Flexible Query Consistency Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make explicit time queries produce one canonical date range and one exact result set across planning, aggregation, answer text, cards, and drill-down details.

**Architecture:** A deterministic time-range normalizer overrides conflicting LLM dates, and a strict date codec converts inclusive user dates to Core Data half-open bounds. Executor results persist exact aggregate metadata plus a full matched-ID snapshot while keeping evidence rows bounded for rendering; drill-down consumes that snapshot instead of re-running a keyword search.

**Tech Stack:** Swift 5, SwiftUI, Core Data, XCTest, Node.js/Hono backend, Docker Compose.

---

## File map

- Create `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryDateRange.swift`: strict ISO date codec, natural-language range resolver, plan date override.
- Modify `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryPlanner.swift`: normalize both deterministic and LLM plans before validation.
- Modify `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryModels.swift`: query-range metadata and optional complete matched-ID snapshot with backward-compatible decoding.
- Modify `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryExecutor.swift`: strict bounds, no 200-row aggregation cap, complete snapshot, bounded evidence preview.
- Modify `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryAnswerBuilder.swift`: show query range, never matched-data range as query scope.
- Modify `Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift`: carry query range and exact navigation IDs; safe legacy fallback.
- Create `Holo/Holo APP/Holo/Holo/Views/Finance/FlexibleQueryResultListView.swift`: exact snapshot result screen.
- Modify `Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift`: route “查看全部” to snapshot screen.
- Modify `Holo/Holo APP/Holo/Holo/Views/Chat/Cards/FlexibleQueryChatCard.swift`: truthful query-range and legacy button copy.
- Create `Holo/Holo APP/Holo/HoloTests/Services/AI/FlexibleQueryDateRangeTests.swift`: time semantics and invalid date coverage.
- Create `Holo/Holo APP/Holo/HoloTests/Services/AI/FlexibleQueryResultConsistencyTests.swift`: exact aggregate/snapshot/legacy JSON coverage.
- Modify `Holo/Holo APP/Holo/HoloTests/Models/AI/FlexibleQueryChatCardDataTests.swift`: card and navigation contract.
- Modify `Holo/Holo APP/Holo/HoloTests/Models/ChatMessageViewDataAgentResultTests.swift`: end-to-end answer assertions.
- Restore the verified backend files from `b801690`: dedicated Planner route, intent v23, planner v4, mock and tests.
- Modify `CHANGELOG.md`: record user-visible semantics and deployment.

### Task 1: Canonical time range and Planner override

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryDateRange.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryPlanner.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/FlexibleQueryDateRangeTests.swift`

- [ ] **Step 1: Write failing time semantics tests**

Add tests that fix a Gregorian calendar to Asia/Shanghai and assert:

```swift
func testRecentMonthMeansThirtyInclusiveCalendarDays() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
    let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 11, hour: 18)))

    let range = try XCTUnwrap(FlexibleQueryDateRangeResolver.resolve(
        text: "最近一个月吃了多少顿麦当劳",
        now: now,
        calendar: calendar
    ))

    XCTAssertEqual(range.startDate, "2026-06-12")
    XCTAssertEqual(range.endDate, "2026-07-11")
}
```

Also assert `近30天`, month-end crossing, year crossing, `本月`, and `上个月`. Add a test where an LLM plan says `2026-06-16` through `2026-06-16`; normalization for the original question must replace it with `2026-06-12` through `2026-07-11` while preserving every non-date filter.

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
xcodebuild test -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -derivedDataPath /private/tmp/holo-flex-query-tests -only-testing:HoloTests/FlexibleQueryDateRangeTests
```

Expected: compile failure because `FlexibleQueryDateRangeResolver` and plan normalization do not exist.

- [ ] **Step 3: Implement strict date value and resolver**

Implement:

```swift
nonisolated struct FlexibleQueryDateRange: Codable, Equatable, Sendable {
    let startDate: String
    let endDate: String

    func bounds(calendar: Calendar) throws -> (start: Date, endExclusive: Date) {
        let start = try FlexibleQueryDateCodec.parse(startDate, calendar: calendar)
        let end = try FlexibleQueryDateCodec.parse(endDate, calendar: calendar)
        guard start <= end,
              let endExclusive = calendar.date(byAdding: .day, value: 1, to: end) else {
            throw FlexibleQueryPlanValidationError.invalidDateRange
        }
        return (calendar.startOfDay(for: start), calendar.startOfDay(for: endExclusive))
    }
}
```

`FlexibleQueryDateCodec` must use `en_US_POSIX`, the supplied calendar/time zone, `yyyy-MM-dd`, `isLenient = false`, and round-trip formatting to reject impossible dates. `FlexibleQueryDateRangeResolver.resolve` must map recent-month phrases to the inclusive interval from `today - 29 days` through `today`, `本月` to month start through today, and `上个月` to the complete prior calendar month.

Add `FlexibleQueryPlanDateNormalizer.normalize(plan:userQuestion:now:calendar:)` that reconstructs `FinanceQueryFilters` with only `startDate`/`endDate` replaced when the resolver finds an explicit phrase.

- [ ] **Step 4: Normalize both Planner paths and validate**

Refactor `FlexibleQueryPlanner.plan` so deterministic and LLM results converge on one function:

```swift
let rawResult: FlexiblePlannerResult
if let deterministicPlan = MerchantAggregatePlanResolver.resolve(
    userQuestion: userQuestion,
    extractedData: extractedData
) {
    rawResult = FlexiblePlannerResult(status: .ready, clarificationQuestion: nil, plan: deterministicPlan)
} else {
    let prompt = try buildPlannerPrompt(userQuestion: userQuestion, extractedData: extractedData)
    let plannerJSON = try await requestPlannerCompletion(prompt: prompt, userContext: userContext)
    rawResult = try decodePlannerOutput(plannerJSON)
}

guard rawResult.status == .ready, let rawPlan = rawResult.plan else { return rawResult }
let plan = FlexibleQueryPlanDateNormalizer.normalize(plan: rawPlan, userQuestion: userQuestion)
try Self.validate(plan: plan)
return FlexiblePlannerResult(status: .ready, clarificationQuestion: nil, plan: plan)
```

Update validator to strictly parse each non-nil date and throw `invalidDateRange` for invalid format, impossible days, or start after end.

- [ ] **Step 5: Run test and verify GREEN**

Run the Task 1 command. Expected: all `FlexibleQueryDateRangeTests` pass.

- [ ] **Step 6: Commit Task 1**

```bash
git add 'Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryDateRange.swift' 'Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryPlanner.swift' 'Holo/Holo APP/Holo/HoloTests/Services/AI/FlexibleQueryDateRangeTests.swift'
git commit -m 'fix(iOS): normalize explicit flexible query date ranges'
```

### Task 2: Exact aggregation and complete result snapshot

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryModels.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryExecutor.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Services/AI/FlexibleQueryResultConsistencyTests.swift`

- [ ] **Step 1: Write failing result consistency tests**

Create 201 deterministic `FlexibleTransactionDTO` values and call a new internal `FlexibleQueryExecutor.buildResult(plan:rawResults:)`. Assert it returns `totalMatched == 201`, the exact sum and average, 20 evidence rows for `limit = 20`, and 201 IDs. Add a strict-bound test asserting `2026-06-12` includes the first day, `2026-07-11 23:59` includes the last day, and 5 May is excluded.

Add backward JSON coverage:

```swift
let decoded = try JSONDecoder().decode(FlexibleQueryResult.self, from: legacyJSON)
XCTAssertNil(decoded.allMatchedTransactionIDs)
XCTAssertNil(decoded.summary.queryDateRange)
```

- [ ] **Step 2: Run and verify RED**

Use the same xcodebuild destination with `-only-testing:HoloTests/FlexibleQueryResultConsistencyTests`.

Expected: compile failure because complete snapshot and query-range metadata do not exist.

- [ ] **Step 3: Extend result models compatibly**

Add optional properties so synthesized decoding keeps old messages valid:

```swift
struct FlexibleQueryResult: Codable, Equatable, Sendable {
    let plan: FlexibleQueryPlan
    let status: FlexibleQueryStatus
    let summary: FlexibleQuerySummary
    let matchedTransactions: [FlexibleTransactionEvidence]
    let allMatchedTransactionIDs: [String]?
    let calculationResult: FlexibleCalculationResult?
    let emptyReason: String?
    let followUpSuggestion: FlexibleQueryFollowUp?
}

struct FlexibleQuerySummary: Codable, Equatable, Sendable {
    let totalMatched: Int
    let totalAmount: Decimal?
    let queryDateRange: String?
    let dateRange: String? // legacy matched-data min/max
    let topCategory: String?
}
```

Add explicit `init(from:)` implementations using `decodeIfPresent` for the two new fields, and explicit memberwise initializers whose new parameters default to `nil`. This makes the old-message compatibility contract visible rather than dependent on synthesis details.

- [ ] **Step 4: Make Executor exact**

Delete `request.fetchLimit = 200`. Parse date strings through `FlexibleQueryDateCodec`; if parsing fails, throw `invalidDateRange` rather than skipping a predicate. Add internal `FlexibleQueryExecutor.buildResult(plan:rawResults:)`, sort the complete matched collection there, compute summary/calculation from it, store every UUID string in `allMatchedTransactionIDs`, and apply `plan.limit` only when creating `matchedTransactions` evidence. `execute` must call this same builder so the 201-row test covers production aggregation logic.

Set `summary.queryDateRange` from normalized plan dates and keep `summary.dateRange` as matched-data min/max for backward compatibility only.

- [ ] **Step 5: Run and verify GREEN**

Run Task 2 tests, then Task 1 tests. Expected: both suites pass.

- [ ] **Step 6: Commit Task 2**

```bash
git add 'Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryModels.swift' 'Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryExecutor.swift' 'Holo/Holo APP/Holo/HoloTests/Services/AI/FlexibleQueryResultConsistencyTests.swift'
git commit -m 'fix(iOS): keep flexible query aggregates exact'
```

### Task 3: Truthful answer and card semantics

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryAnswerBuilder.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/Cards/FlexibleQueryChatCard.swift`
- Modify: `Holo/Holo APP/Holo/HoloTests/Models/AI/FlexibleQueryChatCardDataTests.swift`
- Modify: `Holo/Holo APP/Holo/HoloTests/Models/ChatMessageViewDataAgentResultTests.swift`

- [ ] **Step 1: Write failing presentation tests**

For a result whose query range is `2026-06-12 ~ 2026-07-11`, matched-data range is `2026-06-16 ~ 2026-06-16`, and complete IDs contain six entries, assert:

```swift
XCTAssertTrue(answer.contains("查询范围：2026-06-12 ~ 2026-07-11"))
XCTAssertFalse(answer.contains("时间范围：2026-06-16 ~ 2026-06-16"))
XCTAssertEqual(card.summaryText, "查询范围：2026-06-12 ~ 2026-07-11")
XCTAssertEqual(card.resultTransactionIDs.count, 6)
XCTAssertEqual(card.viewAllText, "查看全部 6 顿")
```

For legacy results with three persisted evidence rows and `summary.totalMatched == 6`, assert `viewAllText == "查看已保存 3 顿"` and navigation IDs contain only those three rows.

- [ ] **Step 2: Run and verify RED**

Run the two named XCTest classes. Expected failures on query range text and navigation fields.

- [ ] **Step 3: Implement presentation contract**

Extend `FlexibleQueryChatCardData` with `queryRangeText`, `resultTransactionIDs`, and `hasCompleteResultSnapshot`. Build IDs from `allMatchedTransactionIDs` when present; otherwise use evidence UUIDs. New results use `summary.totalMatched`; legacy button copy uses the actually preserved ID count.

Change answer/card summary builders to prefer `summary.queryDateRange`. Do not label legacy `summary.dateRange` as query range. Render the query range on the card without truncating the start and end into an indistinguishable single date.

- [ ] **Step 4: Run and verify GREEN**

Run the Task 3 XCTest classes. Expected: all presentation assertions pass.

- [ ] **Step 5: Commit Task 3**

```bash
git add 'Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryAnswerBuilder.swift' 'Holo/Holo APP/Holo/Holo/Models/AI/ChatCardData.swift' 'Holo/Holo APP/Holo/Holo/Views/Chat/Cards/FlexibleQueryChatCard.swift' 'Holo/Holo APP/Holo/HoloTests/Models/AI/FlexibleQueryChatCardDataTests.swift' 'Holo/Holo APP/Holo/HoloTests/Models/ChatMessageViewDataAgentResultTests.swift'
git commit -m 'fix(iOS): show the actual flexible query scope'
```

### Task 4: Exact snapshot drill-down

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Views/Finance/FlexibleQueryResultListView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Models/AI/FlexibleQueryChatCardDataTests.swift`

- [ ] **Step 1: Write failing route test**

Build card data with six snapshot UUIDs and assert `FlexibleQueryResultRoute(cardData:)` contains exactly those six IDs, title `麦当劳消费`, and range `2026-06-12 ~ 2026-07-11`. Assert the route has no keyword-only initializer.

- [ ] **Step 2: Run and verify RED**

Run `FlexibleQueryChatCardDataTests`. Expected: compile failure because `FlexibleQueryResultRoute` does not exist.

- [ ] **Step 3: Implement route and exact list**

Define a testable route:

```swift
nonisolated struct FlexibleQueryResultRoute: Identifiable, Equatable {
    let title: String
    let queryRangeText: String?
    let transactionIDs: [UUID]
    let originalCount: Int
    var id: String { transactionIDs.map(\.uuidString).joined(separator: ",") }
}
```

`FlexibleQueryResultListView` loads only `route.transactionIDs` using `FinanceRepository.shared.findTransaction(by:)`, preserves route order, drops deleted records, and shows `当前可查看 X / 原结果 Y` when counts differ. It must not call `searchTransactions`.

Replace `FlexibleQueryFinanceSearchRoute` and `FinanceSearchView(initialSearchText:)` in `ChatView` with `FlexibleQueryResultRoute` and `FlexibleQueryResultListView`.

- [ ] **Step 4: Add source-level guard test**

Add an assertion over the route API/card conversion that a navigation route cannot be constructed without IDs. This prevents a future keyword-only regression without coupling the test to SwiftUI internals.

- [ ] **Step 5: Run and verify GREEN**

Run Task 4 tests, then generic iOS device build. Expected: tests pass and `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit Task 4**

```bash
git add 'Holo/Holo APP/Holo/Holo/Views/Finance/FlexibleQueryResultListView.swift' 'Holo/Holo APP/Holo/Holo/Views/Chat/ChatView.swift' 'Holo/Holo APP/Holo/HoloTests/Models/AI/FlexibleQueryChatCardDataTests.swift'
git commit -m 'fix(iOS): keep query drill-down on the exact result set'
```

### Task 5: Restore verified backend Planner contract to main lineage

**Files:**
- Modify: `HoloBackend/src/config.js`
- Modify: `HoloBackend/src/prompts/promptRegistry.js`
- Modify: `HoloBackend/src/providers/mockChatProvider.js`
- Modify: `HoloBackend/tests/chat.test.js`
- Modify: `HoloBackend/tests/prompts.test.js`
- Modify: `HoloBackend/tests/releaseStatus.test.js`

- [ ] **Step 1: Restore the already production-verified backend files**

```bash
git restore --source=b801690 -- HoloBackend/src/config.js HoloBackend/src/prompts/promptRegistry.js HoloBackend/src/providers/mockChatProvider.js HoloBackend/tests/chat.test.js HoloBackend/tests/prompts.test.js HoloBackend/tests/releaseStatus.test.js
```

This brings the dedicated `flexible_query_planner` route, intent v23, planner v4, and matching tests into the main-derived branch without importing unrelated iOS history.

- [ ] **Step 2: Run backend tests**

```bash
cd HoloBackend
npm test
```

Expected: 85 tests pass, 0 fail.

- [ ] **Step 3: Commit backend contract**

```bash
git add HoloBackend/src/config.js HoloBackend/src/prompts/promptRegistry.js HoloBackend/src/providers/mockChatProvider.js HoloBackend/tests/chat.test.js HoloBackend/tests/prompts.test.js HoloBackend/tests/releaseStatus.test.js
git commit -m 'fix(backend): preserve flexible query planner contract'
```

### Task 6: Full verification, changelog, integration, and production deployment

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run all targeted XCTest suites**

```bash
xcodebuild test -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.3.1' -derivedDataPath /private/tmp/holo-flex-query-tests -only-testing:HoloTests/FlexibleQueryDateRangeTests -only-testing:HoloTests/FlexibleQueryResultConsistencyTests -only-testing:HoloTests/FlexibleQueryChatCardDataTests -only-testing:HoloTests/ChatMessageViewDataAgentResultTests
```

Expected: each named suite executes non-zero tests and all pass.

- [ ] **Step 2: Run full build and backend suite**

```bash
xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -scheme Holo -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath /private/tmp/holo-flex-query-final-build CODE_SIGNING_ALLOWED=NO build
cd HoloBackend && npm test
```

Expected: `BUILD SUCCEEDED`; 85 backend tests pass.

- [ ] **Step 3: Audit exact acceptance invariants**

Verify tests prove all of the following:

- `最近一个月` on 2026-07-11 is 2026-06-12 through 2026-07-11.
- A conflicting LLM single-day plan is overridden.
- Invalid dates throw instead of dropping the predicate.
- 5 May records cannot appear in the exact snapshot route.
- More than 200 matches still calculate exact totals and averages.
- Old message JSON decodes and never opens a keyword-only historical search.

- [ ] **Step 4: Update changelog and commit**

Add a 2026-07-11 entry describing the corrected query-range display, exact result drill-down, full-set aggregation, strict dates, and backend production contract. Stage only this task’s CHANGELOG hunk and commit:

```bash
git add CHANGELOG.md
git commit -m 'docs: record flexible query consistency fix'
```

- [ ] **Step 5: Verify remote and push branch**

```bash
git remote get-url origin
git push -u origin fix/holo-flexible-query-consistency
```

Expected remote: `git@github.com:Donglin5525/Holo.git`.

- [ ] **Step 6: Integrate scoped commits into main**

Use the finishing-a-development-branch workflow. Preserve main’s unrelated dirty files; integrate only the clean feature commits, then push main after running the final device build again.

- [ ] **Step 7: Deploy HoloBackend from main**

Use the `holo-backend-deploy` skill. Deployment must preserve `.env`, `deploy/.env.production`, and `deploy/data`, build with `DOCKER_BUILDKIT=0`, force-recreate `holo-backend`, and verify `/v1/health`, `/v1/release/status`, `/v1/prompts/meta`, real intent routing, and real `flexible_query_planner` output.

- [ ] **Step 8: Final completion audit**

Compare every design requirement to current code, executed tests, git state, production container state, and live responses. Do not mark complete if simulator tests executed zero tests, backend remains on a feature branch, or the detail route can still perform a keyword-only search.
