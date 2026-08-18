import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

const DEVICE_ID = "insight-quota-device";

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
      return entries.find((entry) => entry.id === id) ?? null;
    },
    cleanup() {},
  };
}

function createTestApp(adminLogStore) {
  const provider = {
    async complete() {
      return {
        choices: [{
          message: { content: '{"title":"测试洞察","summary":"测试","cards":[]}' },
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
      insight: {
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

async function generateInsight(app, usageActionId) {
  return app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": DEVICE_ID,
    },
    body: JSON.stringify({
      purpose: "insight",
      stream: false,
      usageActionId,
      messages: [{ role: "user", content: "额度测试" }],
    }),
  });
}

test("insight quota exposes period and records rejected requests", async () => {
  const adminLogStore = createRecordingAdminLogStore();
  const app = createTestApp(adminLogStore);
  await setFreeMode(app);

  assert.equal((await generateInsight(app, "insight-1")).status, 200);

  const blocked = await generateInsight(app, "insight-2");
  assert.equal(blocked.status, 429);
  const error = (await blocked.json()).error;
  assert.equal(error.code, "QUOTA_EXCEEDED");
  assert.equal(error.quotaType, "memoryInsight");
  assert.equal(error.period, "week");
  assert.equal(error.limit, 1);
  assert.equal(error.used, 1);
  assert.equal(error.remaining, 0);

  const rejectedLog = adminLogStore.entries.find((entry) => entry.status === "quota_exceeded");
  assert.ok(rejectedLog, "额度拒绝应写入 AI 管理日志");
  assert.equal(rejectedLog.error.code, "QUOTA_EXCEEDED");
  assert.equal(rejectedLog.response.period, "week");
});
