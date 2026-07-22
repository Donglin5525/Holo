import assert from "node:assert/strict";
import { test } from "node:test";

import Database from "better-sqlite3";

import { createApp } from "../src/app.js";
import { createAdminLogStore } from "../src/admin/adminLogStore.js";
import { createAdminSessionCookie } from "../src/admin/adminAuth.js";
import { createDatabase } from "../src/db/database.js";
import { runMigrations } from "../src/db/migrations.js";
import { closeHttpServer } from "../src/gracefulShutdown.js";

function createLimitedApp(overrides = {}) {
  let providerCalls = 0;
  const provider = {
    async complete() {
      providerCalls += 1;
      return { choices: [{ message: { content: "ok" }, finish_reason: "stop" }] };
    },
  };
  const app = createApp({
    database: createDatabase({ dbPath: ":memory:" }),
    auth: { enforceAppAttest: false },
    limits: {
      chatMaxBodyBytes: 512,
      chatMaxMessages: 2,
      chatMaxMessageChars: 8,
      chatMaxTotalChars: 12,
      deviceIdMaxChars: 16,
      chatRequestsPerMinute: 20,
      chatRequestsPerDay: 50,
      asrRequestsPerMinute: 10,
      asrRequestsPerDay: 20,
      asrMaxBytes: 1024,
      asrAllowedMimeTypes: ["audio/wav"],
    },
    routes: {
      chat: { provider: "recording", model: "test", temperature: 0, maxTokens: 64 },
    },
    providerOverrides: [["recording", provider]],
    ...overrides,
  });
  return { app, providerCalls: () => providerCalls };
}

async function postChat(app, payload, deviceId = "device-1") {
  return app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": deviceId },
    body: JSON.stringify(payload),
  });
}

test("chat 超过消息数、单条和总字符上限时不调用 Provider", async () => {
  const cases = [
    { messages: [{ role: "user", content: "1" }, { role: "user", content: "2" }, { role: "user", content: "3" }] },
    { messages: [{ role: "user", content: "123456789" }] },
    { messages: [{ role: "user", content: "1234567" }, { role: "assistant", content: "123456" }] },
  ];

  for (const payload of cases) {
    const { app, providerCalls } = createLimitedApp();
    const response = await postChat(app, payload);
    assert.equal(response.status, 413);
    assert.equal((await response.json()).error.code, "REQUEST_TOO_LARGE");
    assert.equal(providerCalls(), 0);
  }
});

test("chat 超过 JSON body 硬上限时不调用 Provider", async () => {
  const { app, providerCalls } = createLimitedApp({
    limits: { chatMaxBodyBytes: 80 },
  });
  const response = await postChat(app, {
    messages: [{ role: "user", content: "x".repeat(120) }],
  });
  assert.equal(response.status, 413);
  assert.equal((await response.json()).error.code, "REQUEST_TOO_LARGE");
  assert.equal(providerCalls(), 0);
});

test("客户端不能覆盖 temperature 或 token 预算", async () => {
  for (const field of ["temperature", "maxTokens", "max_tokens"]) {
    const { app, providerCalls } = createLimitedApp();
    const response = await postChat(app, {
      messages: [{ role: "user", content: "hello" }],
      [field]: 999999,
    });
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error.code, "INVALID_CLIENT_ROUTING");
    assert.equal(providerCalls(), 0);
  }
});

test("chat 拒绝超长或含控制字符的 device ID", async () => {
  for (const deviceId of ["x".repeat(17), "device with space", "<script>"]) {
    const { app, providerCalls } = createLimitedApp();
    const response = await postChat(app, { messages: [{ role: "user", content: "hello" }] }, deviceId);
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error.code, "INVALID_DEVICE_ID");
    assert.equal(providerCalls(), 0);
  }
});

test("ASR 拒绝未允许的 MIME 且不调用 Provider", async () => {
  let providerCalls = 0;
  const { app } = createLimitedApp({
    asrProvider: { async transcribe() { providerCalls += 1; return { text: "unexpected" }; } },
  });
  const body = new FormData();
  body.set("audio", new Blob(["fake"], { type: "text/plain" }), "audio.txt");
  const response = await app.request("/v1/asr/transcriptions", {
    method: "POST",
    headers: { "x-holo-device-id": "device-1" },
    body,
  });
  assert.equal(response.status, 415);
  assert.equal((await response.json()).error.code, "UNSUPPORTED_AUDIO_TYPE");
  assert.equal(providerCalls, 0);
});

test("已应用 migration 即使没有 pending 也校验 checksum", () => {
  const db = new Database(":memory:");
  runMigrations(db);
  db.prepare("UPDATE schema_version SET checksum = 'tampered' WHERE migration_id = 1").run();
  assert.throws(() => runMigrations(db), /checksum 不匹配/);
  db.close();
});

test("关闭内容采集时 hot cache 与 SQLite 都不保存请求响应正文", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createAdminLogStore({ db: database.db, contentCaptureEnabled: false });
  const id = store.startAiCall({
    deviceId: "device-1",
    purpose: "chat",
    provider: "mock",
    model: "mock",
    stream: false,
    request: { messages: [{ role: "user", content: "我的秘密" }] },
  });
  store.finishAiCall(id, { status: "success", response: { text: "敏感回答" } });

  const hot = store.get(id);
  assert.equal(hot.request, null);
  assert.equal(hot.response, null);
  const persisted = database.db.prepare("SELECT request_summary, response_summary FROM ai_call_logs").get();
  assert.equal(persisted.request_summary, null);
  assert.equal(persisted.response_summary, null);
  database.close();
});

test("即使开启内容采集，健康和财务 purpose 也只保留元数据", () => {
  const store = createAdminLogStore({ contentCaptureEnabled: true });
  for (const purpose of ["health_insight_generation", "finance_action_parser"]) {
    const id = store.startAiCall({
      deviceId: "device-1", purpose, provider: "mock", model: "mock", stream: false,
      request: { messages: [{ role: "user", content: "敏感正文" }] },
    });
    store.finishAiCall(id, { status: "success", response: { text: "敏感回答" } });
    assert.equal(store.get(id).request, null);
    assert.equal(store.get(id).response, null);
  }
});

test("管理员登录连续失败会触发限流，成功 cookie 在生产环境带 Secure", async () => {
  const { app } = createLimitedApp({
    admin: {
      username: "admin",
      password: "correct-password",
      sessionSecret: "a".repeat(32),
      loginMaxAttempts: 2,
      loginWindowSeconds: 60,
    },
  });
  for (const expectedStatus of [401, 401, 429]) {
    const response = await app.request("/admin/login", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded", "x-real-ip": "203.0.113.1" },
      body: new URLSearchParams({ username: "admin", password: "wrong" }).toString(),
    });
    assert.equal(response.status, expectedStatus);
    if (expectedStatus === 429) assert.ok(Number(response.headers.get("retry-after")) > 0);
  }
  assert.match(createAdminSessionCookie({
    runtimeEnvironment: "production",
    admin: { username: "admin", password: "correct-password", sessionSecret: "a".repeat(32) },
  }), /; Secure$/);
});

test("ready 检查真实访问数据库并披露 App Attest 阶段状态", async () => {
  const { app } = createLimitedApp();
  const response = await app.request("/v1/ready");
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).checks, {
    database: "ready",
    appAttest: "pending_phase_4",
  });
});

test("非法数值配置和生产 mock provider 会 fail-fast", () => {
  assert.throws(() => createLimitedApp({ limits: { chatMaxBodyBytes: 0 } }), /chatMaxBodyBytes/);
  assert.throws(() => createApp({
    runtimeEnvironment: "production",
    agentStepIdempotencyEncryptionKey: Buffer.alloc(32, 1).toString("base64"),
  }), /mock AI provider/);
});

test("HTTP 优雅关闭会等待在途请求完成", async () => {
  let closeCallback;
  let closeAllCalled = false;
  const server = {
    close(callback) { closeCallback = callback; },
    closeAllConnections() { closeAllCalled = true; },
  };
  const closing = closeHttpServer(server, { timeoutMs: 100 });
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(closeAllCalled, false);
  closeCallback();
  await closing;
  assert.equal(closeAllCalled, false);
});
