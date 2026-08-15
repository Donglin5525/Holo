// P2 服务端功能开关：migration 建表、订阅状态带 featureFlags、admin 修改即生效
import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

const DEVICE_ID = "test-device-flag-001";

function createTestApp() {
  const database = createDatabase({ dbPath: ":memory:" });
  return createApp({
    database,
    auth: { sessionSecret: "test-secret" },
    admin: { token: "secret-admin-token", username: "admin", password: "pw", sessionSecret: "test-secret" },
    holoSessionService: { async verify() { return { internalDiagnostics: true }; } },
  });
}

test("migration #12 创建 feature_flags 表", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const tables = database.db
    .prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='feature_flags'")
    .all();
  assert.equal(tables.length, 1);
});

test("订阅状态默认带 featureFlags（出厂默认值）", async () => {
  const app = createTestApp();
  const response = await app.request("/v1/subscription/status", {
    headers: { "x-holo-device-id": DEVICE_ID },
  });
  assert.equal(response.status, 200);
  const json = await response.json();
  assert.deepEqual(json.featureFlags, { agentDeepAnalysis: true });
});

test("admin 关闭开关后订阅状态立即下发 false（急停链路）", async () => {
  const app = createTestApp();

  const toggle = await app.request("/admin/feature-flags/agentDeepAnalysis", {
    method: "POST",
    headers: { "x-holo-admin-token": "secret-admin-token" },
    body: new URLSearchParams({ value: "false" }).toString(),
  });
  assert.equal(toggle.status, 302);

  const status = await app.request("/v1/subscription/status", {
    headers: { "x-holo-device-id": DEVICE_ID },
  });
  const json = await status.json();
  assert.equal(json.featureFlags.agentDeepAnalysis, false);

  // 再开回来
  await app.request("/admin/feature-flags/agentDeepAnalysis", {
    method: "POST",
    headers: { "x-holo-admin-token": "secret-admin-token" },
    body: new URLSearchParams({ value: "true" }).toString(),
  });
  const statusAfter = await app.request("/v1/subscription/status", {
    headers: { "x-holo-device-id": DEVICE_ID },
  });
  assert.equal((await statusAfter.json()).featureFlags.agentDeepAnalysis, true);
});

test("未知开关名被拒绝", async () => {
  const app = createTestApp();
  const response = await app.request("/admin/feature-flags/not_a_flag", {
    method: "POST",
    headers: { "x-holo-admin-token": "secret-admin-token" },
    body: new URLSearchParams({ value: "true" }).toString(),
  });
  assert.equal(response.status, 302);
  assert.match(response.headers.get("location"), /error=/);
});

test("admin 指标页与开关页可访问", async () => {
  const app = createTestApp();
  const headers = { "x-holo-admin-token": "secret-admin-token" };
  const metrics = await app.request("/admin/ai-metrics", { headers });
  assert.equal(metrics.status, 200);
  assert.match(await metrics.text(), /AI 调用指标/);
  const flags = await app.request("/admin/feature-flags", { headers });
  assert.equal(flags.status, 200);
  assert.match(await flags.text(), /agentDeepAnalysis/);
});
