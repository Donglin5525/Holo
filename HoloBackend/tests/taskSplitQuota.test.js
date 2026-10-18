import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { quotaPeriodForDate } from "../src/usage/quotaPolicy.js";

const DEVICE_ID = "task-split-quota-device";

function createRecordingAdminLogStore() {
  const entries = [];
  return {
    maxDetailChars: 20_000,
    entries,
    startAiCall(input) {
      const id = randomUUID();
      entries.push({ id, ...input, status: "pending" });
      return id;
    },
    finishAiCall(id, result) {
      const entry = entries.find((item) => item.id === id);
      if (entry) Object.assign(entry, result);
    },
    list() {
      return entries;
    },
    get(id) {
      return entries.find((item) => item.id === id) ?? null;
    },
    cleanup() {},
  };
}

function createTestApp(adminLogStore) {
  const provider = {
    async complete() {
      return {
        choices: [{
          message: { content: '{"kind":"proposal","patch":{"newSteps":[{"action":"第一步","doneWhen":"完成"}]}}' },
          finish_reason: "stop",
        }],
      };
    },
  };

  return createApp({
    database: createDatabase({ dbPath: ":memory:" }),
    auth: { enforceAppAttest: false },
    holoSessionService: {
      async verify() {
        return { internalDiagnostics: true };
      },
    },
    aiCallLogs: { enabled: true },
    adminLogStore,
    routes: {
      matter_execution_plan: {
        provider: "quota-test",
        model: "quota-test-model",
        temperature: 0,
        maxTokens: 256,
      },
    },
    providerOverrides: [["quota-test", provider]],
  });
}

async function setFreeMode(app) {
  const response = await app.request("/v1/subscription/acceptance", {
    method: "POST",
    headers: {
      authorization: "Bearer internal-test-token",
      "content-type": "application/json",
      "x-holo-device-id": DEVICE_ID,
    },
    body: JSON.stringify({ mode: "free" }),
  });
  assert.equal(response.status, 200);
}

async function generateSplitPlan(app, usageActionId) {
  return app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": DEVICE_ID,
    },
    body: JSON.stringify({
      purpose: "matter_execution_plan",
      stream: false,
      usageActionId,
      messages: [{ role: "user", content: "额度测试" }],
    }),
  });
}

async function fetchStatus(app) {
  const response = await app.request("/v1/subscription/status", {
    headers: { "x-holo-device-id": DEVICE_ID },
  });
  assert.equal(response.status, 200);
  return response.json();
}

test("月窗口：periodKey 按上海自然月，resetAt 为下月一号零点", () => {
  const jan = quotaPeriodForDate(new Date("2026-01-31T23:30:00+08:00"), "month");
  assert.equal(jan.periodKey, `month:2026-01`);
  assert.equal(jan.resetAt, "2026-02-01T00:00:00+08:00");

  const dec = quotaPeriodForDate(new Date("2026-12-15T10:00:00+08:00"), "month");
  assert.equal(dec.periodKey, "month:2026-12");
  assert.equal(dec.resetAt, "2027-01-01T00:00:00+08:00");

  const midnight = quotaPeriodForDate(new Date("2026-10-01T00:00:00+08:00"), "month");
  assert.equal(midnight.periodKey, "month:2026-10");
  assert.equal(midnight.resetAt, "2026-11-01T00:00:00+08:00");
});

test("拆解额度独立成池：免费 5 次/月，第 6 次拒绝且报 taskSplit 池", async () => {
  const app = createTestApp(createRecordingAdminLogStore());
  await setFreeMode(app);

  for (let index = 1; index <= 5; index += 1) {
    assert.equal((await generateSplitPlan(app, `split-${index}`)).status, 200);
  }

  const blocked = await generateSplitPlan(app, "split-6");
  assert.equal(blocked.status, 429);
  const error = (await blocked.json()).error;
  assert.equal(error.code, "QUOTA_EXCEEDED");
  assert.equal(error.quotaType, "taskSplit");
  assert.equal(error.period, "month");
  assert.equal(error.limit, 5);
  assert.equal(error.used, 5);
  assert.equal(error.remaining, 0);
});

test("同一 usageActionId 只扣一次：澄清追问与修复重试不重复计数", async () => {
  const app = createTestApp(createRecordingAdminLogStore());
  await setFreeMode(app);

  // 同一拆解流程的三次调用（初次/追问回答/修复重试）共用一个 usageActionId
  for (let index = 0; index < 3; index += 1) {
    assert.equal((await generateSplitPlan(app, "flow-1")).status, 200);
  }
  // 再来四个独立流程：5 次月额度恰好用满（1 + 4）
  for (let index = 2; index <= 5; index += 1) {
    assert.equal((await generateSplitPlan(app, `flow-${index}`)).status, 200);
  }
  const blocked = await generateSplitPlan(app, "flow-6");
  assert.equal(blocked.status, 429);
});

test("拆解改挂 taskSplit 池后不再消耗 chat 池", async () => {
  const app = createTestApp(createRecordingAdminLogStore());
  await setFreeMode(app);

  assert.equal((await generateSplitPlan(app, "split-1")).status, 200);

  const status = await fetchStatus(app);
  assert.equal(status.quotas.taskSplit.quotaType ?? "taskSplit", "taskSplit");
  assert.equal(status.quotas.taskSplit.used, 1);
  assert.equal(status.quotas.taskSplit.limit, 5);
  assert.equal(status.quotas.taskSplit.period, "month");
  assert.equal(status.quotas.chat.used, 0, "拆解不应再扣 chat 池");
});
