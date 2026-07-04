# Holo Plus Subscription Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first production-ready Holo Plus subscription system for China-region users, with StoreKit purchase, backend entitlement/quota enforcement, Plus UI, graceful downgrade paths, and immediate continuation after purchase.

**Architecture:** Keep the product model simple: Free + Holo Plus, monthly/yearly subscription only, no early-bird price, no lifetime purchase, no Pro tier. iOS owns purchase UX and local entitlement display through StoreKit 2; backend owns trusted entitlement sync, quota ledger, ASR duration limits, and quota-exceeded responses. Feature entry points call a shared paywall/action coordinator so purchase success can resume the original action.

**Tech Stack:** SwiftUI, StoreKit 2, Core Data, HoloBackend Node.js/Hono, better-sqlite3, DashScope ASR provider, existing Holo AI provider APIs, App Store Connect subscriptions.

---

## Final Product Decisions

- Pricing structure: Holo Plus only, monthly/yearly subscription.
- Early bird: not included.
- Heavy Agent: not included in this phase.
- Plus product IDs:
  - `com.tangyuxuan.holo.plus.monthly`
  - `com.tangyuxuan.holo.plus.yearly`
- Recommended App Store Connect prices:
  - Monthly: `¥12/月`
  - Yearly: `¥128/年`
- Voice/task quota decision:
  - Plus natural-language task/finance parsing quota: unified to `50 次/天`.
  - ASR single-recording duration: Free `60 秒`, Plus `5 分钟`.
  - Current code does not yet fully support Plus 5 minutes: backend DashScope ASR provider has a hard `60_000ms` timeout and iOS ASR request timeout is `90s`. This plan includes the required changes.
- Member center:
  - Settings page adds Holo Plus membership center.
  - Home avatar/profile entry shows a Plus badge when active.
- Over-limit UX:
  - HoloAI over-limit uses conversational assistant message, not a modal.
  - Memory Gallery over-limit uses modal/paywall.
- Purchase flow:
  - Unified paywall.
  - Purchase success immediately returns to the original feature and retries the original action.

## Prerequisites Before Full Production Rollout

These do not block engineering start, but they block release verification.

- App Store Connect creates subscription group `Holo Plus`.
- App Store Connect creates products:
  - `com.tangyuxuan.holo.plus.monthly`
  - `com.tangyuxuan.holo.plus.yearly`
- App Store Connect configures prices for China storefront.
- Sandbox testers are available for purchase, renewal, cancel, and expiration tests.
- Backend production environment has Apple verification credentials or an approved receipt/JWS validation strategy.
- DashScope ASR 5-minute recording is live-validated after backend/iOS timeout changes.
- Backend quota changes are deployed to production before releasing the client that depends on them.

## Quota Model

Use server-side quota enforcement as the source of truth. Client-side checks are only UX optimization.

| Capability | Free | Holo Plus | Gate Behavior |
|---|---:|---:|---|
| HoloAI chat | 3/day | 30/day | HoloAI conversational limit response |
| Natural-language finance parsing | 20/day | 50/day | Fall back to manual transaction sheet |
| Natural-language task parsing | 10/day | 50/day | Fall back to manual task sheet |
| ASR requests | 20/day | 50/day | Ask user to type or upgrade |
| ASR single recording duration | 60s | 300s | Reject before upload when possible |
| Memory Gallery AI insight refresh | 1/week | 1/day | Modal paywall; cached gallery remains usable |
| Desktop widgets | locked | unlocked | Paywall from widget settings/deep link |
| Finance installments | locked | unlocked | Paywall from installment entry |

Quota days must use `Asia/Shanghai` calendar days for China-region product expectations.

## File Structure

### Backend

- Modify `HoloBackend/src/db/migrations.js`
  - Add subscription entitlement and quota ledger tables.
- Create `HoloBackend/src/subscription/productIds.js`
  - Centralize product IDs and tier mapping.
- Create `HoloBackend/src/subscription/entitlementStore.js`
  - Read/write active entitlement state.
- Create `HoloBackend/src/subscription/appleReceiptVerifier.js`
  - Verify StoreKit transaction JWS or App Store Server API response.
- Create `HoloBackend/src/usage/quotaPolicy.js`
  - Define free/plus quota limits and China-day period keys.
- Create `HoloBackend/src/usage/quotaLedgerStore.js`
  - Atomic daily usage consume/read operations in SQLite.
- Modify `HoloBackend/src/app.js`
  - Add entitlement sync/status endpoints.
  - Replace generic rate-limit-only AI/ASR enforcement with quota-aware enforcement.
  - Return structured quota errors.
- Modify `HoloBackend/src/config.js`
  - Add ASR duration, timeout, subscription, and Apple verification config.
- Modify `HoloBackend/src/providers/dashScopeAsrProvider.js`
  - Make provider timeout configurable for Plus 5-minute recordings.
- Test `HoloBackend/tests/subscription-quota.test.js`
  - New backend quota/entitlement coverage.
- Modify `HoloBackend/tests/security-and-asr.test.js`
  - ASR duration/size/quota tests.

### iOS

- Create `Holo/Holo APP/Holo/Holo/Services/Subscription/HoloSubscriptionProducts.swift`
  - Product IDs, display tier, and subscription period metadata.
- Create `Holo/Holo APP/Holo/Holo/Services/Subscription/HoloSubscriptionService.swift`
  - StoreKit 2 product loading, purchase, transaction updates, entitlement sync.
- Create `Holo/Holo APP/Holo/Holo/Services/Subscription/HoloEntitlementState.swift`
  - Observable local entitlement state for UI.
- Create `Holo/Holo APP/Holo/Holo/Services/Subscription/HoloPlusActionCoordinator.swift`
  - Stores pending gated action and resumes it after purchase success.
- Create `Holo/Holo APP/Holo/Holo/Services/Subscription/HoloQuotaError.swift`
  - Shared typed quota errors decoded from backend responses.
- Create `Holo/Holo APP/Holo/Holo/Views/Subscription/HoloPlusPaywallView.swift`
  - Unified paywall.
- Create `Holo/Holo APP/Holo/Holo/Views/Subscription/HoloMembershipCenterView.swift`
  - Settings membership center.
- Modify `Holo/Holo APP/Holo/Holo/Views/Settings/SettingsView.swift`
  - Add membership center entry.
- Modify `Holo/Holo APP/Holo/Holo/Views/HomeView.swift`
  - Add Plus badge on avatar/profile entry.
- Modify `Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift`
  - Decode structured quota errors.
- Modify `Holo/Holo APP/Holo/Holo/Services/Speech/HoloBackendSpeechRecognitionProvider.swift`
  - Add tier-aware ASR duration/timeout handling.
- Modify `Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift`
  - Convert HoloAI quota errors into assistant conversation messages.
- Modify `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryView.swift`
  - Show modal paywall on Memory Gallery quota limits.
- Add StoreKit config file if the project does not already have one:
  - `Holo/Holo APP/Holo/HoloPlus.storekit`

## Backend API Contract

### Entitlement Status

`GET /v1/subscription/status`

Headers:

```http
X-Holo-Device-Id: <stable-device-id>
```

Response:

```json
{
  "tier": "free",
  "isPlusActive": false,
  "expiresAt": null,
  "products": {
    "plusMonthly": "com.tangyuxuan.holo.plus.monthly",
    "plusYearly": "com.tangyuxuan.holo.plus.yearly"
  },
  "quotas": {
    "chat": { "limit": 3, "used": 0, "remaining": 3, "resetAt": "2026-07-05T00:00:00+08:00" },
    "naturalLanguageTask": { "limit": 10, "used": 0, "remaining": 10, "resetAt": "2026-07-05T00:00:00+08:00" },
    "naturalLanguageFinance": { "limit": 20, "used": 0, "remaining": 20, "resetAt": "2026-07-05T00:00:00+08:00" },
    "asr": { "limit": 20, "used": 0, "remaining": 20, "resetAt": "2026-07-05T00:00:00+08:00" },
    "memoryInsight": { "limit": 1, "period": "week", "used": 0, "remaining": 1, "resetAt": "2026-07-06T00:00:00+08:00" }
  }
}
```

### Entitlement Sync

`POST /v1/subscription/sync`

Request:

```json
{
  "productId": "com.tangyuxuan.holo.plus.monthly",
  "originalTransactionId": "2000000000000000",
  "transactionId": "2000000000000001",
  "signedTransactionInfo": "<storekit-jws>",
  "environment": "Sandbox"
}
```

Response:

```json
{
  "tier": "plus",
  "isPlusActive": true,
  "productId": "com.tangyuxuan.holo.plus.monthly",
  "expiresAt": "2026-08-04T10:00:00Z"
}
```

### Quota Error

All gated backend endpoints should return the same shape:

```json
{
  "error": {
    "code": "QUOTA_EXCEEDED",
    "quotaType": "chat",
    "tier": "free",
    "limit": 3,
    "used": 3,
    "remaining": 0,
    "resetAt": "2026-07-05T00:00:00+08:00",
    "upgradeAvailable": true,
    "message": "今日 HoloAI 免费次数已用完"
  }
}
```

## Task 1: Backend Database Schema

**Files:**
- Modify: `HoloBackend/src/db/migrations.js`
- Test: `HoloBackend/tests/subscription-quota.test.js`

- [ ] Add a migration for entitlement records:

```sql
CREATE TABLE IF NOT EXISTS subscription_entitlements (
  device_id TEXT PRIMARY KEY,
  tier TEXT NOT NULL DEFAULT 'free',
  product_id TEXT,
  original_transaction_id TEXT,
  latest_transaction_id TEXT,
  environment TEXT,
  expires_at TEXT,
  revoked_at TEXT,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX IF NOT EXISTS idx_subscription_entitlements_expires
ON subscription_entitlements(expires_at);
```

- [ ] Add a migration for quota ledger:

```sql
CREATE TABLE IF NOT EXISTS quota_ledger (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  device_id TEXT NOT NULL,
  quota_type TEXT NOT NULL,
  period_key TEXT NOT NULL,
  tier TEXT NOT NULL,
  used INTEGER NOT NULL DEFAULT 0,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE(device_id, quota_type, period_key)
);

CREATE INDEX IF NOT EXISTS idx_quota_ledger_device_period
ON quota_ledger(device_id, period_key);
```

- [ ] Write migration tests that initialize an in-memory SQLite database, run migrations, and assert both tables and indexes exist.

- [ ] Run:

```bash
cd HoloBackend
npm test
```

Expected: all existing backend tests pass plus the new migration tests.

## Task 2: Backend Product IDs and Entitlement Store

**Files:**
- Create: `HoloBackend/src/subscription/productIds.js`
- Create: `HoloBackend/src/subscription/entitlementStore.js`
- Test: `HoloBackend/tests/subscription-quota.test.js`

- [ ] Create product constants:

```js
export const HOLO_PLUS_PRODUCT_IDS = Object.freeze({
  monthly: "com.tangyuxuan.holo.plus.monthly",
  yearly: "com.tangyuxuan.holo.plus.yearly",
});

export function tierForProductId(productId) {
  return Object.values(HOLO_PLUS_PRODUCT_IDS).includes(productId) ? "plus" : "free";
}
```

- [ ] Implement entitlement store methods:

```js
export function createEntitlementStore(db, { now = () => new Date() } = {}) {
  return {
    get(deviceId) {
      const row = db.prepare(
        `SELECT * FROM subscription_entitlements WHERE device_id = ?`
      ).get(deviceId);
      if (!row) return { tier: "free", isPlusActive: false, expiresAt: null };

      const revoked = Boolean(row.revoked_at);
      const expired = row.expires_at ? new Date(row.expires_at) <= now() : true;
      const isPlusActive = row.tier === "plus" && !revoked && !expired;
      return {
        tier: isPlusActive ? "plus" : "free",
        isPlusActive,
        productId: row.product_id ?? null,
        originalTransactionId: row.original_transaction_id ?? null,
        expiresAt: row.expires_at ?? null,
      };
    },

    upsertVerified(deviceId, entitlement) {
      db.prepare(`
        INSERT INTO subscription_entitlements (
          device_id, tier, product_id, original_transaction_id,
          latest_transaction_id, environment, expires_at, revoked_at, updated_at
        )
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
        ON CONFLICT(device_id) DO UPDATE SET
          tier = excluded.tier,
          product_id = excluded.product_id,
          original_transaction_id = excluded.original_transaction_id,
          latest_transaction_id = excluded.latest_transaction_id,
          environment = excluded.environment,
          expires_at = excluded.expires_at,
          revoked_at = excluded.revoked_at,
          updated_at = CURRENT_TIMESTAMP
      `).run(
        deviceId,
        entitlement.tier,
        entitlement.productId,
        entitlement.originalTransactionId,
        entitlement.latestTransactionId,
        entitlement.environment,
        entitlement.expiresAt,
        entitlement.revokedAt ?? null
      );
    },
  };
}
```

- [ ] Test active, expired, revoked, and unknown-device states.

## Task 3: Backend Quota Policy and Ledger

**Files:**
- Create: `HoloBackend/src/usage/quotaPolicy.js`
- Create: `HoloBackend/src/usage/quotaLedgerStore.js`
- Test: `HoloBackend/tests/subscription-quota.test.js`

- [ ] Define quota policy:

```js
export const QUOTA_TYPES = Object.freeze({
  chat: "chat",
  naturalLanguageFinance: "naturalLanguageFinance",
  naturalLanguageTask: "naturalLanguageTask",
  asr: "asr",
  memoryInsight: "memoryInsight",
});

export const QUOTA_POLICY = Object.freeze({
  free: {
    chat: { limit: 3, period: "day" },
    naturalLanguageFinance: { limit: 20, period: "day" },
    naturalLanguageTask: { limit: 10, period: "day" },
    asr: { limit: 20, period: "day", maxSeconds: 60 },
    memoryInsight: { limit: 1, period: "week" },
  },
  plus: {
    chat: { limit: 30, period: "day" },
    naturalLanguageFinance: { limit: 50, period: "day" },
    naturalLanguageTask: { limit: 50, period: "day" },
    asr: { limit: 50, period: "day", maxSeconds: 300 },
    memoryInsight: { limit: 1, period: "day" },
  },
});
```

- [ ] Implement China-region period keys with `Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Shanghai" })`.

- [ ] Implement atomic `consume({ deviceId, tier, quotaType })` returning:

```js
{
  allowed: true,
  quotaType: "chat",
  tier: "free",
  limit: 3,
  used: 1,
  remaining: 2,
  resetAt: "2026-07-05T00:00:00+08:00"
}
```

- [ ] Test day reset uses China date, not UTC date.

- [ ] Test free/plus daily limits for chat, ASR, finance parsing, task parsing, and memory insight.

## Task 4: Backend Subscription Endpoints and Quota Errors

**Files:**
- Create: `HoloBackend/src/subscription/appleReceiptVerifier.js`
- Modify: `HoloBackend/src/app.js`
- Modify: `HoloBackend/src/config.js`
- Test: `HoloBackend/tests/subscription-quota.test.js`

- [ ] Add config:

```js
subscription: {
  appleVerificationMode: process.env.HOLO_APPLE_VERIFICATION_MODE ?? "disabled",
  bundleId: process.env.HOLO_APPLE_BUNDLE_ID ?? "com.tangyuxuan.holo-app",
  appAppleId: process.env.HOLO_APPLE_APP_ID ?? "",
}
```

- [ ] Implement `GET /v1/subscription/status`.

- [ ] Implement `POST /v1/subscription/sync`.

- [ ] In local/test mode, allow a deterministic test verifier that accepts only known product IDs and explicit future `expiresAt`.

- [ ] In production mode, reject unverified transactions instead of trusting client-only product IDs.

- [ ] Replace current generic daily `usageStore.consume` calls on AI and ASR with quota-aware consumes.

- [ ] Return `429` with the shared `QUOTA_EXCEEDED` JSON shape when over quota.

- [ ] Keep existing minute-level abuse rate limiting as a separate guard if needed; do not use it as subscription quota.

## Task 5: Backend ASR 5-Minute Support

**Files:**
- Modify: `HoloBackend/src/config.js`
- Modify: `HoloBackend/src/app.js`
- Modify: `HoloBackend/src/providers/dashScopeAsrProvider.js`
- Modify: `HoloBackend/tests/security-and-asr.test.js`

- [ ] Add config:

```js
asr: {
  freeMaxSeconds: Number(process.env.HOLO_ASR_FREE_MAX_SECONDS ?? 60),
  plusMaxSeconds: Number(process.env.HOLO_ASR_PLUS_MAX_SECONDS ?? 300),
  providerTimeoutMs: Number(process.env.HOLO_ASR_PROVIDER_TIMEOUT_MS ?? 360_000),
}
```

- [ ] Increase default `HOLO_ASR_MAX_BYTES` from `10MB` to at least `16MB` or make it product-tier aware.

- [ ] Parse WAV duration server-side when possible. If duration cannot be parsed, require client-provided `durationSeconds` and fail closed for over-limit requests.

- [ ] In `dashScopeAsrProvider.js`, replace the hard `60_000` timeout with configurable `providerTimeoutMs`.

- [ ] Tests:
  - Free user uploading `61s` audio returns `ASR_DURATION_EXCEEDED`.
  - Plus user uploading `300s` audio passes duration validation.
  - Plus user uploading `301s` audio returns `ASR_DURATION_EXCEEDED`.
  - Provider receives the configured timeout.

- [ ] Manual validation after implementation:

```bash
cd HoloBackend
npm test
HOLO_ASR_PROVIDER=dashscope npm run smoke
```

Expected: backend tests pass; DashScope smoke validates provider behavior with a controlled sample.

## Task 6: iOS StoreKit Subscription Service

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Services/Subscription/HoloSubscriptionProducts.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/Subscription/HoloEntitlementState.swift`
- Create: `Holo/Holo APP/Holo/Holo/Services/Subscription/HoloSubscriptionService.swift`
- Add: `Holo/Holo APP/Holo/HoloPlus.storekit`

- [ ] Define product IDs:

```swift
enum HoloSubscriptionProduct: String, CaseIterable {
    case plusMonthly = "com.tangyuxuan.holo.plus.monthly"
    case plusYearly = "com.tangyuxuan.holo.plus.yearly"

    var displayName: String {
        switch self {
        case .plusMonthly: return "Holo Plus 月度会员"
        case .plusYearly: return "Holo Plus 年度会员"
        }
    }
}
```

- [ ] Implement `HoloEntitlementState` with `tier`, `isPlusActive`, `expiresAt`, and quota snapshot.

- [ ] Implement `HoloSubscriptionService`:
  - Load `Product.products(for:)`.
  - Purchase selected product.
  - Listen to `Transaction.updates`.
  - Sync verified transaction JWS to backend.
  - Refresh backend status on app launch and foreground.

- [ ] Add a StoreKit config with the two product IDs for local simulator purchase tests.

## Task 7: iOS Paywall and Action Resume

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Services/Subscription/HoloPlusActionCoordinator.swift`
- Create: `Holo/Holo APP/Holo/Holo/Views/Subscription/HoloPlusPaywallView.swift`

- [ ] Implement pending action model:

```swift
enum HoloPlusGateContext: Equatable {
    case holoAI
    case memoryGallery
    case financeInstallment
    case desktopWidget
    case asrDuration
    case naturalLanguageFinance
    case naturalLanguageTask
}
```

- [ ] Implement coordinator behavior:
  - `requirePlus(context:resume:)` stores the pending action and opens paywall.
  - Successful purchase dismisses paywall.
  - After backend entitlement sync confirms Plus, execute the stored action once.
  - Paywall dismiss without purchase preserves user input and does not execute gated action.

- [ ] Build paywall UI:
  - Title: `升级 Holo Plus`
  - Benefits adapt by context.
  - Primary product emphasis: yearly.
  - Secondary option: monthly.
  - Restore purchase button.
  - Terms and subscription management links.

## Task 8: iOS Settings Member Center and Home Plus Badge

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Views/Subscription/HoloMembershipCenterView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/Settings/SettingsView.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Views/HomeView.swift`

- [ ] Add a `Holo Plus` entry in Settings near AI/voice settings.

- [ ] Membership center shows:
  - Current tier.
  - Renewal/expiration date.
  - Daily quota usage.
  - Monthly/yearly products.
  - Restore purchase.
  - Manage subscription deep link.

- [ ] Add Plus badge to Home avatar/profile entry only when `isPlusActive == true`.

- [ ] Badge should be subtle: small `PLUS` capsule or sparkle icon overlay, no blocking text.

## Task 9: iOS Backend Quota Error Handling

**Files:**
- Create: `Holo/Holo APP/Holo/Holo/Services/Subscription/HoloQuotaError.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/AI/HoloBackendAIProvider.swift`
- Modify: `Holo/Holo APP/Holo/Holo/Services/Speech/HoloBackendSpeechRecognitionProvider.swift`

- [ ] Decode backend quota error:

```swift
struct HoloQuotaErrorResponse: Decodable, Error {
    struct Payload: Decodable {
        let code: String
        let quotaType: String
        let tier: String
        let limit: Int
        let used: Int
        let remaining: Int
        let resetAt: String
        let upgradeAvailable: Bool
        let message: String
    }

    let error: Payload
}
```

- [ ] Map `QUOTA_EXCEEDED` into app-level `HoloQuotaError`.

- [ ] ASR provider:
  - Free timeout remains short enough for 60s recordings.
  - Plus request timeout supports 5-minute recordings plus provider buffer.
  - Client pre-check rejects over-limit audio before upload when duration is known.

## Task 10: HoloAI Conversational Limit Response

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/Chat/ChatViewModel.swift`
- Modify where chat action buttons/deep links open paywall.

- [ ] When `HoloBackendAIProvider` throws `HoloQuotaError` for chat or natural-language parsing, append an assistant message instead of showing a modal.

- [ ] Message style:

```text
今天的免费 HoloAI 次数已经用完了。你可以明天继续，或者升级 Holo Plus 解锁更高的每日额度。
```

- [ ] Message actions:
  - `升级 Plus`
  - `明天再说`

- [ ] If the user taps `升级 Plus`, open paywall with the original chat/parsing action as pending action.

- [ ] On successful purchase, retry the original user request automatically.

## Task 11: Memory Gallery Modal Paywall

**Files:**
- Modify: `Holo/Holo APP/Holo/Holo/Views/MemoryGallery/MemoryGalleryView.swift`
- Modify related Memory Gallery view model if the refresh action lives there.

- [ ] When memory insight refresh returns quota error, show `HoloPlusPaywallView` as a modal.

- [ ] Keep existing cached gallery content visible behind the modal.

- [ ] On successful purchase, dismiss modal and retry the refresh action automatically.

- [ ] On dismiss without purchase, return to gallery without clearing content or scroll position.

## Task 12: Downgrade Paths

**Files:**
- Modify the relevant feature entry points for each gated capability.

- [ ] Natural-language finance over quota:
  - Preserve raw user text.
  - Open manual `AddTransactionSheet`.
  - Prefill note/remark with raw text when structured parsing is unavailable.

- [ ] Natural-language task over quota:
  - Preserve raw user text.
  - Open manual task creation with title prefilled from raw text.

- [ ] ASR over duration/quota:
  - Keep typed input available.
  - Tell user the current limit and the Plus limit.
  - Do not discard recorded text if transcript already exists.

- [ ] Finance installments locked:
  - Show paywall from installment entry.
  - If dismissed, return to normal one-time transaction save flow.

- [ ] Desktop widgets locked:
  - Widget configuration shows Plus paywall entry.
  - Existing non-widget app features remain usable.

## Task 13: Verification and Release Checklist

**Files:**
- Modify docs/changelog if this repo uses a changelog for product changes.
- Backend deploy required after backend changes.

- [ ] Backend tests:

```bash
cd HoloBackend
npm test
```

- [ ] iOS build:

```bash
xcodebuild -project "Holo/Holo APP/Holo/Holo.xcodeproj" -scheme Holo -destination 'platform=iOS Simulator,name=iPhone 17' build
```

- [ ] StoreKit local simulator test:
  - Free user sees no badge.
  - Purchase monthly product.
  - Entitlement becomes Plus.
  - Home avatar badge appears.
  - Settings membership center shows Plus.
  - Original gated action resumes after purchase.

- [ ] Backend sandbox test:
  - Subscription sync accepts valid sandbox transaction.
  - Expired transaction downgrades to Free.
  - Quotas switch from Plus limits back to Free limits.

- [ ] ASR validation:
  - Free 61s rejected.
  - Plus 300s accepted by app and backend.
  - Plus 301s rejected.
  - DashScope provider handles configured timeout in live smoke test.

- [ ] Production deploy:
  - Deploy HoloBackend after merging backend changes.
  - Verify `GET /v1/subscription/status` on `https://api.holoapp.cn`.
  - Verify quota exceeded response from production.

## Risk Notes

- StoreKit transaction verification must not trust client-only product IDs in production.
- `deviceId` is currently the main identity hook; entitlement transfer across reinstall/device changes is limited unless Apple original transaction/account mapping is added.
- Existing `rate_limits` table is not enough for paid quota accounting because it lacks tier, quota type, local-day period, and entitlement history.
- ASR 5-minute support is a real engineering change: current backend provider timeout and iOS request timeout are too short.
- Backend changes must be deployed before the iOS release reaches users; otherwise Plus users may purchase successfully but still hit Free server quotas.

## Self-Review

- Spec coverage:
  - No early bird: covered in final product decisions.
  - No heavy Agent: covered in final product decisions.
  - Voice/task quota and ASR limits: covered in quota model and ASR task.
  - Product ID naming: covered with two final IDs.
  - Member center and Home badge: covered in Task 8.
  - HoloAI conversational over-limit: covered in Task 10.
  - Memory Gallery modal: covered in Task 11.
  - Paywall: covered in Task 7.
  - Downgrade paths: covered in Task 12.
  - Purchase success resumes original function: covered in Task 7, 10, and 11.
- Placeholder scan:
  - No intentional TBD/TODO placeholders.
  - External prerequisites are listed as release gates, not implementation blanks.
- Type consistency:
  - Product IDs, quota type names, tier names, and error code names are reused consistently across backend and iOS tasks.
