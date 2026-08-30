import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { createAgentTelemetryStore } from "../src/agent/agentTelemetryStore.js";

function createTestApp(overrides = {}) {
  return createApp({
    database: createDatabase({ dbPath: ":memory:" }),
    auth: { enforceAppAttest: false },
    limits: {
      chatRequestsPerMinute: 100,
      chatRequestsPerDay: 1000,
      agentTelemetryUploadsPerMinute: 100,
      agentTelemetryUploadsPerDay: 10_000,
    },
    aiCallLogs: { enabled: false },
    runtimeEnvironment: "test",
    ...overrides,
  });
}

function sendTelemetry(app, events, deviceId = "device-a") {
  return app.request("/v1/ai/agent/telemetry", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": deviceId,
    },
    body: JSON.stringify({ events }),
  });
}

function makeEvent(overrides = {}) {
  return {
    id: `evt-${Math.random().toString(36).slice(2, 10)}`,
    name: "agent_execution_expired",
    timestampMs: Date.now(),
    jobID: "job-1",
    leaseKind: "continuedProcessing",
    errorCode: "SYSTEM_CAPACITY",
    durationMilliseconds: 30_500,
    ...overrides,
  };
}

test("批量上报落库并返回新增条数", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createAgentTelemetryStore(database.db);
  const app = createTestApp({ agentTelemetryStore: store });

  const events = [makeEvent(), makeEvent({ name: "agent_job_failed", errorCode: null })];
  const response = await sendTelemetry(app, events);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).accepted, 2);
  assert.equal(store.count(), 2);
});

test("同一事件 id 重发幂等去重（上报失败重试不产生重复行）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createAgentTelemetryStore(database.db);
  const app = createTestApp({ agentTelemetryStore: store });

  const event = makeEvent({ id: "evt-fixed-id" });
  await sendTelemetry(app, [event]);
  const retry = await sendTelemetry(app, [event]);
  assert.equal((await retry.json()).accepted, 0);
  assert.equal(store.count(), 1);
});

test("未知事件名与缺 id 拒绝 400", async () => {
  const app = createTestApp();
  const bad1 = await sendTelemetry(app, [makeEvent({ name: "not_a_real_event" })]);
  assert.equal(bad1.status, 400);
  const bad2 = await sendTelemetry(app, [{ name: "agent_job_failed", timestampMs: Date.now() }]);
  assert.equal(bad2.status, 400);
});

test("空数组与超过 100 条的批次拒绝 400", async () => {
  const app = createTestApp();
  assert.equal((await sendTelemetry(app, [])).status, 400);
  assert.equal((await sendTelemetry(app, Array.from({ length: 101 }, () => makeEvent()))).status, 400);
});

test("超长字符串字段截断到 64 字符，非法数字置空", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createAgentTelemetryStore(database.db);
  const app = createTestApp({ agentTelemetryStore: store });

  const response = await sendTelemetry(app, [makeEvent({
    jobID: "J".repeat(200),
    generation: "not-a-number",
  })]);
  assert.equal(response.status, 200);
  const rows = store.listByJob("J".repeat(64));
  assert.equal(rows.length, 1);
  assert.equal(rows[0].job_id.length, 64);
  assert.equal(rows[0].generation, null);
});
