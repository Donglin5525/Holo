import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { createAdminLogStore } from "../src/admin/adminLogStore.js";

// 2026-10-19 前后端链路打通：客户端会话 UUID 随 x-holo-session-id 头与埋点事件上送，
// product_events / ai_call_logs / request_logs 三表同列记录，前端行为与 AI 调用可按会话 join。

test("ai_call_logs 记录会话关联键 session_id", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createAdminLogStore({ db: database.db });

  store.startAiCall({
    deviceId: "device-a",
    purpose: "chat",
    provider: "mock",
    model: "mock-model",
    stream: false,
    sessionId: "session-xyz-00000001",
    request: { messageCount: 1 },
  });

  const row = database.db
    .prepare("SELECT session_id, device_id FROM ai_call_logs ORDER BY id DESC LIMIT 1")
    .get();
  assert.equal(row.session_id, "session-xyz-00000001");
  assert.equal(row.device_id, "device-a");
});

test("缺会话头时 ai_call_logs.session_id 为空（后台唤醒进程语义）", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createAdminLogStore({ db: database.db });
  store.startAiCall({ deviceId: "device-a", purpose: "chat", provider: "mock", model: "m", stream: false });
  const row = database.db.prepare("SELECT session_id FROM ai_call_logs ORDER BY id DESC LIMIT 1").get();
  assert.equal(row.session_id, null);
});

test("同一请求：request_logs 经中间件 + product_events 同批落同一 session_id，可直接 join", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database,
    auth: { enforceAppAttest: false },
    limits: { productEventUploadsPerMinute: 100, productEventUploadsPerDay: 10_000 },
    aiCallLogs: { enabled: false },
    runtimeEnvironment: "test",
  });

  // 真实客户端会话 ID = 36 位 UUID：曾因埋点侧误用 32 字符截断导致与 request_logs
  // 存的完整值 join 失败（2026-10-19 模拟器冒烟实锤），此处必须用足长 UUID 守住
  const sessionId = "980CE24C-5720-4326-8D97-5434E5BEFA4C";
  const response = await app.request("/v1/product/events", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "device-a",
      "x-holo-session-id": sessionId,
    },
    body: JSON.stringify({
      events: [{ id: "evt-1", name: "module_view", timestampMs: Date.now(), sessionId }],
    }),
  });
  assert.equal(response.status, 200);

  // requestLogger 内存队列每 2s 批量落盘：轮询等待该行出现
  let requestRow = null;
  for (let attempt = 0; attempt < 20 && !requestRow; attempt += 1) {
    await new Promise((resolve) => setTimeout(resolve, 200));
    requestRow = database.db
      .prepare("SELECT session_id, device_id FROM request_logs WHERE path = '/v1/product/events' ORDER BY id DESC LIMIT 1")
      .get();
  }
  assert.ok(requestRow, "request_logs 应在 flush 后出现该请求");
  assert.equal(requestRow.session_id, sessionId);
  assert.equal(requestRow.device_id, "device-a");

  const eventRow = database.db.prepare("SELECT session_id FROM product_events WHERE id = 'evt-1'").get();
  assert.equal(eventRow.session_id, sessionId);

  const joined = database.db
    .prepare(`
      SELECT p.name, r.path
      FROM product_events p
      JOIN request_logs r ON r.session_id = p.session_id AND r.device_id = p.device_id
      WHERE p.id = 'evt-1'
    `)
    .get();
  assert.equal(joined.name, "module_view");
  assert.equal(joined.path, "/v1/product/events");
});
