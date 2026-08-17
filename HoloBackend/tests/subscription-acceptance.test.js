import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

const DEVICE_ID = "acceptance-device";
const INTERNAL_HEADERS = {
  authorization: "Bearer internal-test-token",
  "content-type": "application/json",
  "x-holo-device-id": DEVICE_ID,
};

function createTestApp(overrides = {}) {
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database,
    auth: { enforceAppAttest: false },
    holoSessionService: {
      async verify() {
        return { internalDiagnostics: true };
      },
    },
    ...overrides,
  });
  return { app, database };
}

async function setMode(app, mode) {
  const response = await app.request("/v1/subscription/acceptance", {
    method: "POST",
    headers: INTERNAL_HEADERS,
    body: JSON.stringify({ mode }),
  });
  assert.equal(response.status, 200);
  return response.json();
}

async function getStatus(app) {
  const response = await app.request("/v1/subscription/status", {
    headers: { "x-holo-device-id": DEVICE_ID },
  });
  assert.equal(response.status, 200);
  return response.json();
}

async function chat(app, usageActionId, extra = {}) {
  return app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": DEVICE_ID,
    },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      usageActionId,
      messages: [{ role: "user", content: "额度验收" }],
      ...extra,
    }),
  });
}

test("subscription migrations create entitlement, acceptance and action ledger tables", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const tables = database.db.prepare(`
    SELECT name FROM sqlite_master WHERE type = 'table'
  `).all().map((row) => row.name);
  assert.ok(tables.includes("subscription_entitlements"));
  assert.ok(tables.includes("subscription_acceptance_overrides"));
  assert.ok(tables.includes("quota_action_ledger"));
});

test("acceptance switching requires internal diagnostics authorization", async () => {
  const { app } = createTestApp();
  const response = await app.request("/v1/subscription/acceptance", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": DEVICE_ID,
    },
    body: JSON.stringify({ mode: "free" }),
  });
  assert.equal(response.status, 403);
});

test("free and plus acceptance modes use isolated quotas and followPurchase restores real status", async () => {
  const { app } = createTestApp();

  const free = await setMode(app, "free");
  assert.equal(free.tier, "free");
  assert.equal(free.source, "acceptance");
  assert.equal(free.acceptanceMode, "free");
  assert.equal(free.quotas.chat.limit, 15);
  assert.equal(free.quotas.deepAnalysis.limit, 2);
  assert.equal(free.quotas.naturalLanguageTask.limit, 20);

  assert.equal((await chat(app, "free-action-1")).status, 200);
  assert.equal((await getStatus(app)).quotas.chat.used, 1);

  const plus = await setMode(app, "plus");
  assert.equal(plus.tier, "plus");
  assert.equal(plus.quotas.chat.limit, 30);
  assert.equal(plus.quotas.chat.used, 0);
  assert.equal((await chat(app, "plus-action-1")).status, 200);
  assert.equal((await getStatus(app)).quotas.chat.used, 1);

  const freeAgain = await setMode(app, "free");
  assert.equal(freeAgain.quotas.chat.used, 1);

  const purchase = await setMode(app, "followPurchase");
  assert.equal(purchase.source, "backend");
  assert.equal(purchase.acceptanceMode, "followPurchase");
  assert.equal(purchase.tier, "free");
  assert.equal(purchase.quotas.chat.used, 0);
});

test("same action id is idempotent and only successful actions consume quota", async () => {
  const failingProvider = {
    async complete() {
      throw new Error("simulated provider failure");
    },
    async *stream() {
      throw new Error("simulated provider failure");
    },
  };
  const { app } = createTestApp({
    routes: {
      chat: {
        provider: "failing",
        model: "failing-model",
        temperature: 0,
        maxTokens: 64,
      },
    },
    providerOverrides: [["failing", failingProvider]],
  });
  await setMode(app, "free");

  assert.equal((await chat(app, "failed-action")).status, 500);
  assert.equal((await getStatus(app)).quotas.chat.used, 0);

  const { app: successApp } = createTestApp();
  await setMode(successApp, "free");
  assert.equal((await chat(successApp, "same-action")).status, 200);
  assert.equal((await chat(successApp, "same-action")).status, 200);
  assert.equal((await getStatus(successApp)).quotas.chat.used, 1);
});

test("free chat quota blocks the action beyond the daily limit with structured details", async () => {
  const { app } = createTestApp();
  await setMode(app, "free");

  for (let index = 0; index < 15; index += 1) {
    assert.equal((await chat(app, `free-limit-${index}`)).status, 200);
  }
  const blocked = await chat(app, "free-limit-15");
  assert.equal(blocked.status, 429);
  const error = (await blocked.json()).error;
  assert.equal(error.code, "QUOTA_EXCEEDED");
  assert.equal(error.quotaType, "chat");
  assert.equal(error.tier, "free");
  assert.equal(error.limit, 15);
  assert.equal(error.used, 15);
  assert.equal(error.upgradeAvailable, true);
});

test("acceptance quota reset only resets the active acceptance ledger", async () => {
  const { app } = createTestApp();
  await setMode(app, "free");
  assert.equal((await chat(app, "before-reset")).status, 200);

  const response = await app.request("/v1/subscription/acceptance/reset", {
    method: "POST",
    headers: INTERNAL_HEADERS,
    body: "{}",
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).quotas.chat.used, 0);
});

test("ASR duration and successful action count follow the active tier", async () => {
  const { app } = createTestApp();
  await setMode(app, "free");

  const tooLong = new FormData();
  tooLong.append("audio", new Blob([new Uint8Array([1, 2, 3])], { type: "audio/m4a" }), "voice.m4a");
  // 62 秒：超出免费档 60 秒 + 1 秒容差（容差用于吸收客户端倒计时轮询导致的 60.x 秒抖动）。
  tooLong.append("durationSeconds", "62");
  tooLong.append("usageActionId", "asr-too-long");
  const blocked = await app.request("/v1/asr/transcriptions", {
    method: "POST",
    headers: { "x-holo-device-id": DEVICE_ID },
    body: tooLong,
  });
  assert.equal(blocked.status, 429);
  const error = (await blocked.json()).error;
  assert.equal(error.code, "ASR_DURATION_EXCEEDED");
  assert.equal(error.maxSeconds, 60);
  assert.equal((await getStatus(app)).quotas.asr.used, 0);

  const valid = new FormData();
  valid.append("audio", new Blob([new Uint8Array([1, 2, 3])], { type: "audio/m4a" }), "voice.m4a");
  valid.append("durationSeconds", "30");
  valid.append("usageActionId", "asr-valid");
  const accepted = await app.request("/v1/asr/transcriptions", {
    method: "POST",
    headers: { "x-holo-device-id": DEVICE_ID },
    body: valid,
  });
  assert.equal(accepted.status, 200);
  assert.equal((await getStatus(app)).quotas.asr.used, 1);
});

test("multiple Agent steps in one run consume one deepAnalysis action, not chat", async () => {
  const { app } = createTestApp();
  await setMode(app, "free");
  for (const step of ["step-1", "step-2"]) {
    const response = await chat(app, undefined, {
      purpose: "agent_loop",
      runId: "shared-agent-run",
      stepId: step,
      requestHash: `hash-${step}`,
    });
    assert.equal(response.status, 200);
  }
  assert.equal((await getStatus(app)).quotas.deepAnalysis.used, 1);
  assert.equal((await getStatus(app)).quotas.chat.used, 0);
});

test("weekly plan generation consumes the lifePlan pool instead of chat", async () => {
  const { app } = createTestApp();
  await setMode(app, "free");
  const response = await chat(app, "weekly-plan-action", { purpose: "weekly_plan_generation" });
  assert.equal(response.status, 200);
  const quotas = (await getStatus(app)).quotas;
  assert.equal(quotas.lifePlan.used, 1);
  assert.equal(quotas.lifePlan.limit, 1);
  assert.equal(quotas.chat.used, 0);
});

test("acceptance override with expiry stops granting tier after it lapses", async () => {
  const { app, database } = createTestApp();
  database.db
    .prepare(
      `INSERT INTO subscription_acceptance_overrides (device_id, tier, expires_at, updated_at)
       VALUES (?, 'plus', ?, CURRENT_TIMESTAMP)`,
    )
    .run(DEVICE_ID, new Date(Date.now() - 60_000).toISOString());

  const lapsed = await getStatus(app);
  assert.equal(lapsed.tier, "free");
  assert.equal(lapsed.source, "backend");

  database.db
    .prepare(
      `INSERT INTO subscription_acceptance_overrides (device_id, tier, expires_at, updated_at)
       VALUES (?, 'plus', ?, CURRENT_TIMESTAMP)
       ON CONFLICT(device_id) DO UPDATE SET tier = 'plus', expires_at = excluded.expires_at`,
    )
    .run(DEVICE_ID, new Date(Date.now() + 86_400_000).toISOString());

  const active = await getStatus(app);
  assert.equal(active.tier, "plus");
  assert.equal(active.source, "acceptance");
});
