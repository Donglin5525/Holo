import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { createProductEventStore } from "../src/product/productEventStore.js";

function createTestApp(overrides = {}) {
  return createApp({
    database: createDatabase({ dbPath: ":memory:" }),
    auth: { enforceAppAttest: false },
    limits: {
      productEventUploadsPerMinute: 100,
      productEventUploadsPerDay: 10_000,
    },
    aiCallLogs: { enabled: false },
    runtimeEnvironment: "test",
    ...overrides,
  });
}

function sendEvents(app, events, deviceId = "device-a") {
  return app.request("/v1/product/events", {
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
    name: "module_view",
    timestampMs: Date.now(),
    params: { module: "finance" },
    appVersion: "1.1.3",
    buildChannel: "release",
    sessionId: "1B6E1A0E-9F2C-4B2A-8E6D-3C1F0A2B9D77",
    ...overrides,
  };
}

test("产品事件批量上报落库并返回新增条数", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createProductEventStore(database.db);
  const app = createTestApp({ productEventStore: store });

  const events = [makeEvent(), makeEvent({ name: "bill_created", params: { source: "ai" } })];
  const response = await sendEvents(app, events);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).accepted, 2);
  assert.equal(store.count(), 2);

  const rows = store.listByDevice("device-a");
  assert.equal(rows[0].name, "module_view");
  assert.equal(JSON.parse(rows[0].params).module, "finance");
  assert.equal(rows[0].build_channel, "release");
  assert.equal(rows[0].session_id, "1B6E1A0E-9F2C-4B2A-8E6D-3C1F0A2B9D77");
});

test("同一事件 id 重发幂等去重（上报失败重试不产生重复行）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createProductEventStore(database.db);
  const app = createTestApp({ productEventStore: store });

  const event = makeEvent({ id: "evt-fixed-id" });
  await sendEvents(app, [event]);
  const retry = await sendEvents(app, [event]);
  assert.equal((await retry.json()).accepted, 0);
  assert.equal(store.count(), 1);
});

test("未知事件名与缺 id 拒绝 400", async () => {
  const app = createTestApp();
  const bad1 = await sendEvents(app, [makeEvent({ name: "not_a_real_event" })]);
  assert.equal(bad1.status, 400);
  const bad2 = await sendEvents(app, [{ name: "module_view", timestampMs: Date.now() }]);
  assert.equal(bad2.status, 400);
});

test("空数组、超 100 条批次、params 非对象拒绝 400", async () => {
  const app = createTestApp();
  assert.equal((await sendEvents(app, [])).status, 400);
  assert.equal(
    (await sendEvents(app, Array.from({ length: 101 }, () => makeEvent()))).status,
    400,
  );
  assert.equal(
    (await sendEvents(app, [makeEvent({ params: ["array"] })])).status,
    400,
  );
});

test("超长字段截断，非法 buildChannel 置空", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createProductEventStore(database.db);
  const app = createTestApp({ productEventStore: store });

  const response = await sendEvents(app, [makeEvent({
    appVersion: "9".repeat(200),
    buildChannel: "beta",
    params: { module: "M".repeat(300) },
  })]);
  assert.equal(response.status, 200);
  const rows = store.listByDevice("device-a");
  assert.equal(rows[0].app_version.length, 32);
  assert.equal(rows[0].build_channel, null);
  assert.equal(JSON.parse(rows[0].params).module.length, 128);
});

test("总开关关闭：返回 2xx accepted 0 且不落库（客户端清队列、不发版关停）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createProductEventStore(database.db);
  const app = createTestApp({
    productEventStore: store,
    productAnalytics: { enabled: false },
  });

  const response = await sendEvents(app, [makeEvent()]);
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.accepted, 0);
  assert.equal(body.disabled, true);
  assert.equal(store.count(), 0);
});
