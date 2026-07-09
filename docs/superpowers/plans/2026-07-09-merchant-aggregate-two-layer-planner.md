# Merchant Aggregate Two-Layer Planner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make merchant count/total/per-unit-average queries deterministic locally and give all remaining flexible queries a dedicated 4096-token backend Planner route.

**Architecture:** `MerchantAggregatePlanResolver` performs a narrow local resolution before any LLM call. `AIProvider.completeFlexibleQueryPlan` provides a semantic provider boundary; HoloBackend uses the new `flexible_query_planner` purpose while other providers retain the existing chat fallback.

**Tech Stack:** Swift 5, XCTest, Node.js, Hono, node:test, Docker Compose.

---

### Task 1: Deterministic Merchant Aggregate Resolver

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryPlanner.swift`
- Test: `Holo/Holo APP/Holo/HoloTests/Models/ChatMessageViewDataAgentResultTests.swift`

- [ ] **Step 1: Write failing resolver tests**

Add tests that call:

```swift
let plan = MerchantAggregatePlanResolver.resolve(
    userQuestion: "最近一个月吃了多少吨麦当劳，花了多少钱，平均一顿多少钱",
    extractedData: [
        "queryGoal": "最近一个月麦当劳的消费次数、总花费和平均每顿花费",
        "categoryHint": "麦当劳",
        "periodLabel": "最近一个月"
    ],
    now: fixedDate
)
```

Assert `sumAmount`, `averageAmount`, `.meal`, keyword `麦当劳`, and inclusive dates `2026-06-10...2026-07-09`. Add negative tests for a missing merchant and a trend-only query.

- [ ] **Step 2: Verify RED**

Run:

```bash
xcodebuild -project 'Holo/Holo APP/Holo/Holo.xcodeproj' -target HoloTests -configuration Debug -sdk iphoneos SYMROOT=/private/tmp/holo-fastpath-red/products OBJROOT=/private/tmp/holo-fastpath-red/intermediates CODE_SIGNING_ALLOWED=NO build
```

Expected: compilation fails because `MerchantAggregatePlanResolver` does not exist.

- [ ] **Step 3: Implement the resolver and fast-path**

Add:

```swift
nonisolated enum MerchantAggregatePlanResolver {
    static func resolve(
        userQuestion: String,
        extractedData: [String: String]?,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> FlexibleQueryPlan?
}
```

The resolver must require merchant, three requested metrics, explicit average unit, and a locally supported 30-day period. Call it at the start of `FlexibleQueryPlanner.plan`; when it returns a plan, return `.ready` without invoking AI.

- [ ] **Step 4: Verify GREEN**

Build the HoloTests target with the same command and expect `BUILD SUCCEEDED`.

### Task 2: Semantic Planner Provider Boundary

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/AIProvider.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/FlexibleQuery/FlexibleQueryPlanner.swift`

- [ ] **Step 1: Add the protocol requirement**

Add:

```swift
func completeFlexibleQueryPlan(
    prompt: String,
    userContext: UserContext
) async throws -> String
```

The default implementation sends one user message through existing chat.

- [ ] **Step 2: Add HoloBackend specialization**

Add `.flexibleQueryPlanner = "flexible_query_planner"` to `HoloBackendPurpose`. Implement `completeFlexibleQueryPlan` in `HoloBackendAIProvider` using that purpose and JSON response format, without adding general chat context.

- [ ] **Step 3: Route LLM fallback through the semantic method**

Replace the old `provider.chat(...)` call in `FlexibleQueryPlanner` with `provider.completeFlexibleQueryPlan(...)`.

- [ ] **Step 4: Compile**

Build the HoloTests target and expect `BUILD SUCCEEDED`.

### Task 3: Dedicated Backend Planner Route

**Files:**
- Modify: `HoloBackend/src/config.js`
- Modify: `HoloBackend/tests/chat.test.js`
- Modify: `HoloBackend/tests/releaseStatus.test.js`

- [ ] **Step 1: Write failing backend tests**

Assert:

```js
assert.ok(config.routes.flexible_query_planner.maxTokens >= 4096);
assert.equal(json.routes.flexible_query_planner.maxTokens, 4096);
```

Also POST a request with `purpose: "flexible_query_planner"` and expect status 200.

- [ ] **Step 2: Verify RED**

Run:

```bash
node --test HoloBackend/tests/chat.test.js HoloBackend/tests/releaseStatus.test.js
```

Expected: failure because the route is missing.

- [ ] **Step 3: Implement route**

Add a config route whose provider/model inherit intent then chat, with temperature 0 and `HOLO_FLEXIBLE_QUERY_PLANNER_MAX_TOKENS ?? 4096`.

- [ ] **Step 4: Verify GREEN**

Run the targeted backend tests and expect zero failures.

### Task 4: Full Verification and Release

**Files:**
- Verify all modified files.

- [ ] **Step 1: Run backend suite**

```bash
npm test --prefix HoloBackend
```

Expected: all tests pass.

- [ ] **Step 2: Build iOS app and tests**

Run generic iOS app build and HoloTests target build with fresh `/private/tmp` output directories. Expect both builds to succeed.

- [ ] **Step 3: Review diff**

Run `git diff --check`, verify only scoped files are staged, and commit backend separately from iOS changes.

- [ ] **Step 4: Deploy backend**

Push the branch, fast-forward ECS, rebuild `holo-backend` with the legacy builder if BuildKit again attempts Docker Hub lookup, and verify ECS/public health.

- [ ] **Step 5: Live production verification**

Verify:

- `release/status` contains `flexible_query_planner.maxTokens >= 4096`;
- original query routes to `flexible_data_query`;
- dedicated Planner returns `sumAmount`, `averageAmount`, `meal`, and keyword `麦当劳`.
