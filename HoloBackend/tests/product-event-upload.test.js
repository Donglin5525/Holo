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

test("v2 字典 9 个新事件名全部在白名单内（双端契约：iOS 枚举同步变更）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createProductEventStore(database.db);
  const app = createTestApp({ productEventStore: store });

  const v2Events = [
    makeEvent({ name: "ai_conversation_started", params: null }),
    makeEvent({ name: "ai_message_sent", params: { kind: "text" } }),
    makeEvent({ name: "ai_deep_report_requested", params: { scenario: "finance" } }),
    makeEvent({ name: "ai_deep_report_viewed", params: null }),
    makeEvent({ name: "thought_created", params: { source: "editor" } }),
    makeEvent({ name: "habit_created", params: { type: "checkIn" } }),
    makeEvent({ name: "account_created", params: { type: "creditCard" } }),
    makeEvent({ name: "receipt_booking_started", params: { entry: "shortcutScreenshot" } }),
    makeEvent({ name: "export_performed", params: { format: "csv" } }),
  ];
  const response = await sendEvents(app, v2Events);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).accepted, 9);
  assert.equal(store.count(), 9);

  const byName = new Map(store.listByDevice("device-a").map((row) => [row.name, row]));
  assert.equal(JSON.parse(byName.get("ai_deep_report_requested").params).scenario, "finance");
  assert.equal(JSON.parse(byName.get("receipt_booking_started").params).entry, "shortcutScreenshot");
});

test("v2.1 字典 2 个新事件名全部在白名单内（第二周留存钩子漏斗；双端契约：iOS 枚举同步变更）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createProductEventStore(database.db);
  const app = createTestApp({ productEventStore: store });

  const events = [
    makeEvent({ name: "notification_opened", params: { source: "weekly_review", target: "replay" } }),
    makeEvent({ name: "weekly_review_viewed", params: { weekStart: "2026-11-02" } }),
  ];
  const response = await sendEvents(app, events);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).accepted, 2);
  assert.equal(store.count(), 2);

  const byName = new Map(store.listByDevice("device-a").map((row) => [row.name, row]));
  assert.equal(JSON.parse(byName.get("notification_opened").params).target, "replay");
  assert.equal(JSON.parse(byName.get("weekly_review_viewed").params).weekStart, "2026-11-02");
});

test("v2.2 字典 2 个新事件名全部在白名单内（留存漏斗第一环 + 付费转化终点；双端契约：iOS 枚举同步变更）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createProductEventStore(database.db);
  const app = createTestApp({ productEventStore: store });

  const events = [
    makeEvent({ name: "notification_permission", params: { status: "granted" } }),
    makeEvent({ name: "paywall_purchase_completed", params: { result: "purchased" } }),
  ];
  const response = await sendEvents(app, events);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).accepted, 2);
  assert.equal(store.count(), 2);

  const byName = new Map(store.listByDevice("device-a").map((row) => [row.name, row]));
  assert.equal(JSON.parse(byName.get("notification_permission").params).status, "granted");
  assert.equal(JSON.parse(byName.get("paywall_purchase_completed").params).result, "purchased");
});

test("v2.3 字典 6 个「一个发现」事件名全部在白名单内（iOS 已随 1.1.7 包带上；双端契约：iOS 枚举同步变更）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createProductEventStore(database.db);
  const app = createTestApp({ productEventStore: store });

  const events = [
    makeEvent({ name: "discovery_enabled", params: { scope: "all" } }),
    makeEvent({ name: "discovery_disabled", params: { reason: "settings" } }),
    makeEvent({ name: "discovery_review_opened", params: { surface: "card" } }),
    makeEvent({ name: "discovery_today_shown", params: { surface: "card" } }),
    makeEvent({ name: "discovery_today_action", params: { action: "confirm" } }),
    makeEvent({ name: "discovery_pending_action", params: { action: "snooze" } }),
  ];
  const response = await sendEvents(app, events);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).accepted, 6);
  assert.equal(store.count(), 6);

  const byName = new Map(store.listByDevice("device-a").map((row) => [row.name, row]));
  assert.equal(JSON.parse(byName.get("discovery_enabled").params).scope, "all");
  assert.equal(JSON.parse(byName.get("discovery_today_action").params).action, "confirm");
  assert.equal(JSON.parse(byName.get("discovery_pending_action").params).action, "snooze");
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
