# Health Module Product Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rework the existing iOS health module into the approved A+C product direction: triple-ring dashboard, Apple Health data source trust, insight cards, detail pages, and resilient HealthKit states.

**Architecture:** Keep the existing HealthKit repository and SwiftUI module, but introduce small pure UI/domain models for score, metric availability, data source state, fallback copy, and insights. Views consume these models instead of scattering product decisions through SwiftUI bodies.

**Tech Stack:** SwiftUI, HealthKit, Swift Charts, XCTest-style pure model tests where feasible, existing HOLO design system.

---

### Task 1: Health Display State Models

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Models/HealthMetricType.swift`
- Create: `Holo/Holo APP/Holo/Holo/Models/HealthDashboardState.swift`
- Create: `Holo/Holo APP/Holo/HoloTests/Models/HealthDashboardStateTests.swift`

- [ ] Add `activeMinutes` to `HealthMetricType` with teal color, walking icon, 30-minute goal, and minute unit.
- [ ] Add `HealthMetricAvailability`, `HealthDataSourceState`, `HealthMetricSnapshot`, `HealthDashboardSnapshot`, and `HealthInsight`.
- [ ] Add pure logic for body score calculation: steps 0.30, sleep 0.45, stand/activity 0.25, capped at 100 and hidden when no reliable data exists.
- [ ] Add pure logic for no-Watch fallback: use active minutes when stand data is unsupported or all zero.
- [ ] Add tests for score weighting, fallback metric selection, and data source labels.

### Task 2: Repository State Refinement

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Models/HealthRepository.swift`

- [ ] Add published per-metric availability and `dataSourceState`.
- [ ] Treat simulator mock data as connected mock state while keeping true device logic HealthKit-driven.
- [ ] Do not equate `requestAuthorization` success with all read permissions granted; fetch data and update availability after authorization completes.
- [ ] Add a `refresh()` method that checks authorization and fetches today data.
- [ ] Preserve current API properties (`todaySteps`, `todaySleep`, `todayStandHours`) so Daily Kanban keeps compiling.

### Task 3: Dashboard UI Refactor

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/Health/HealthView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Health/Components/HealthRingView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Health/Components/HealthMetricCard.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Health/Components/HealthPermissionView.swift`

- [ ] Replace the old three-small-rings layout with one triple-ring hero card.
- [ ] Add metric summary chips for steps, sleep, and stand/activity.
- [ ] Add Apple Health data source card.
- [ ] Add one core insight card and a three-row lifestyle insight list.
- [ ] Update permission copy to clearly say read-only, no writing, no raw HealthKit upload.
- [ ] Add pull-to-refresh or toolbar refresh behavior.

### Task 4: Detail Pages Refactor

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/Health/HealthDetailView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Health/Components/HealthTrendChart.swift`

- [ ] Keep the big ring and 7-day chart, but update copy and stats to match the design spec.
- [ ] Add metric-specific insight sections for steps, sleep, and stand/activity.
- [ ] Ensure `activeMinutes` detail copy renders correctly when no Watch fallback is active.
- [ ] Update chart empty state copy so no data is not confused with zero progress.

### Task 5: Verification

**Files:**
- Build project only; no production files.

- [ ] Run focused test/build command for the iOS project.
- [ ] Fix compile errors.
- [ ] Summarize remaining true-device HealthKit risks.
