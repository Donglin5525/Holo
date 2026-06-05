# Holo iOS Landing Page Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a responsive Holo iOS App landing page demo that highlights HoloAI, the homepage sphere, five modules, Memory Gallery, Memory Companion, and App Store required policy/support entry points.

**Architecture:** Replace the current mobile prototype shell with a marketing landing page driven by a small content model. Keep product copy in `src/landing/content.js`, render the page in `src/App.jsx`, and keep visual styling in `src/App.css` / `src/index.css`.

**Tech Stack:** React 19, Vite, CSS, lucide-react icons, Node built-in test runner.

---

### Task 1: Lock Product Content Requirements

**Files:**
- Create: `src/landing/content.js`
- Create: `tests/landingContent.test.mjs`
- Modify: `package.json`

- [ ] **Step 1: Write tests first**

Create tests verifying:
- five modules are exactly `记账`, `待办`, `习惯`, `想法`, `健康`
- core sections include `HoloAI`, `记忆长廊`, `记忆陪伴`
- legal links include `隐私政策`, `用户支持`, `数据删除`, `健康数据说明`

- [ ] **Step 2: Run tests and confirm RED**

Run: `npm test`

Expected: fail because `src/landing/content.js` does not exist yet.

- [ ] **Step 3: Implement content model**

Create `src/landing/content.js` exporting arrays for nav items, modules, sections, and legal links.

- [ ] **Step 4: Run tests and confirm GREEN**

Run: `npm test`

Expected: all tests pass.

### Task 2: Render Landing Page

**Files:**
- Modify: `src/App.jsx`
- Modify: `src/App.css`
- Modify: `src/index.css`

- [ ] **Step 1: Replace mobile prototype shell**

Render a single-page landing experience with:
- top navigation
- hero with HoloAI sphere
- five module orbit cards
- HoloAI section
- Memory Gallery section
- Memory Companion section
- privacy/support section

- [ ] **Step 2: Style responsive visual system**

Use Holo colors: `#F46D38`, `#FED7AA`, `#EA580C`, warm white backgrounds, and controlled accent colors.

- [ ] **Step 3: Verify static quality**

Run: `npm run lint`, `npm run build`.

Expected: both commands exit 0.

### Task 3: Preview

**Files:**
- No source changes expected.

- [ ] **Step 1: Start dev server**

Run: `npm run dev -- --host 127.0.0.1`

Expected: Vite local URL is printed.

- [ ] **Step 2: Provide URL**

Tell the user the local URL and summarize verification evidence.
