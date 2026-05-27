# Finance Category Inline Add Entry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add visible inline `+` entries at the end of finance category lists so users can create top-level and second-level categories from the natural browsing position.

**Architecture:** Reuse the existing `AddCategorySheet` and `addCategoryParentId` flow. Add one small reusable row component inside `CategoryManagementView` and insert it at the end of the top-level list, subcategory list, and empty subcategory state.

**Tech Stack:** SwiftUI, Core Data-backed `Category`, existing `FinanceRepository`.

---

### Task 1: Add Reusable Inline Add Row

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/CategoryManagementView.swift`

- [x] **Step 1: Add a reusable `addCategoryRow` view helper**

Create a button-styled row matching existing category row spacing. It should show a circular `+`, a primary title, and an optional subtitle.

- [x] **Step 2: Insert the row at the end of the top-level list**

Tap behavior: set `addCategoryParentId = nil`, then `showAddCategory = true`.

- [x] **Step 3: Insert the row at the end of each non-empty subcategory list**

Tap behavior: set `addCategoryParentId = parent.id`, then `showAddCategory = true`.

- [x] **Step 4: Replace the empty subcategory state with a direct add action**

Empty state should show a large circular `+`, “新增第一个二级分类”, and a short parent-context subtitle.

- [x] **Step 5: Keep existing right navigation `+` buttons**

The inline row becomes the discoverable primary path, while the old toolbar button remains for existing muscle memory.

### Task 2: Verify

**Files:**
- Verify: `Holo/Holo APP/Holo/Holo.xcodeproj`

- [x] **Step 1: Build the iOS app**

Run:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/holo-derived-data build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2: Manual verification checklist**

Check:
- Top-level category list ends with “新增一级分类”.
- Tapping it opens “新增一级分类”.
- A parent category screen ends with “在当前分类下新增二级分类”.
- Tapping it opens “新增二级分类” and shows the selected parent.
- Empty subcategory screen has a direct “新增第一个二级分类” action.
