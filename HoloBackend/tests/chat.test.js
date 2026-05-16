import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

// 每个测试使用独立的内存数据库
function createTestDatabase() {
  return createDatabase({ dbPath: `:memory:` });
}

function createTestApp(overrides = {}) {
  return createApp({
    database: createTestDatabase(),
    auth: { enforceAppAttest: false },
    limits: {
      chatRequestsPerMinute: 2,
      chatRequestsPerDay: 10,
    },
    routes: {
      chat: {
        provider: "mock",
        model: "holo-mock",
        temperature: 0.2,
        maxTokens: 512,
      },
    },
    ...overrides,
  });
}

test("GET /v1/health returns gateway status", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/health");

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    service: "holo-ai-gateway",
  });
});

test("POST /v1/ai/chat/completions returns non-streaming model response", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "device-a",
    },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      messages: [{ role: "user", content: "你好" }],
    }),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    id: "mock-chat-completion",
    provider: "mock",
    model: "holo-mock",
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content: "Mock response for: 你好",
        },
        finish_reason: "stop",
      },
    ],
  });
});

test("admin logs are disabled when HOLO_ADMIN_TOKEN is not configured", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/admin/logs");

  assert.equal(response.status, 404);
  assert.equal((await response.json()).error.code, "ADMIN_DISABLED");
});

test("admin logs reject missing or invalid tokens", async () => {
  const app = createTestApp({
    admin: {
      token: "test-admin-token",
    },
  });

  const missing = await app.request("/v1/admin/logs");
  assert.equal(missing.status, 401);

  const invalid = await app.request("/v1/admin/logs", {
    headers: {
      "x-holo-admin-token": "wrong-token",
    },
  });
  assert.equal(invalid.status, 401);
});

test("admin logs page redirects to login when password auth is enabled", async () => {
  const app = createTestApp({
    admin: {
      username: "admin",
      password: "test-password",
      sessionSecret: "test-session-secret",
    },
  });

  const response = await app.request("/admin/logs");

  assert.equal(response.status, 302);
  assert.equal(response.headers.get("location"), "/admin/login");
});

test("admin login sets a session cookie that can access logs and JSON details", async () => {
  const app = createTestApp({
    admin: {
      username: "admin",
      password: "test-password",
      sessionSecret: "test-session-secret",
    },
  });

  const loginResponse = await app.request("/admin/login", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      username: "admin",
      password: "test-password",
    }).toString(),
  });

  assert.equal(loginResponse.status, 302);
  assert.equal(loginResponse.headers.get("location"), "/admin/logs");
  const cookie = loginResponse.headers.get("set-cookie");
  assert.match(cookie, /holo_admin_session=/);
  assert.match(cookie, /HttpOnly/);
  assert.match(cookie, /SameSite=Strict/);

  const chatResponse = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "cookie-admin-device",
    },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      messages: [{ role: "user", content: "咖啡20" }],
    }),
  });
  assert.equal(chatResponse.status, 200);

  const logsPage = await app.request("/admin/logs", {
    headers: {
      cookie,
    },
  });
  assert.equal(logsPage.status, 200);

  const logsResponse = await app.request("/v1/admin/logs", {
    headers: {
      cookie,
    },
  });
  assert.equal(logsResponse.status, 200);
  const { logs } = await logsResponse.json();
  assert.equal(logs.length, 1);

  const detailResponse = await app.request(`/v1/admin/logs/${logs[0].id}`, {
    headers: {
      cookie,
    },
  });
  assert.equal(detailResponse.status, 200);
  assert.equal((await detailResponse.json()).log.request.messages[0].content, "咖啡20");
});

test("admin test chat form creates a visible AI call log", async () => {
  const app = createTestApp({
    admin: {
      username: "admin",
      password: "test-password",
      sessionSecret: "test-session-secret",
    },
  });

  const loginResponse = await app.request("/admin/login", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      username: "admin",
      password: "test-password",
    }).toString(),
  });
  const cookie = loginResponse.headers.get("set-cookie");

  const testResponse = await app.request("/admin/test-chat", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      purpose: "chat",
      message: "后台测试：早餐18",
    }).toString(),
  });
  assert.equal(testResponse.status, 302);
  assert.equal(testResponse.headers.get("location"), "/admin/logs?notice=test_sent");

  const pageResponse = await app.request("/admin/logs", {
    headers: {
      cookie,
    },
  });
  assert.equal(pageResponse.status, 200);
  const html = await pageResponse.text();
  assert.match(html, /测试 AI 调用/);
  assert.match(html, /后台测试：早餐18/);
  assert.match(html, /Mock response for: 后台测试：早餐18/);
});

test("admin prompt editor saves prompts and affects prompt API", async () => {
  const app = createTestApp({
    admin: {
      username: "admin",
      password: "test-password",
      sessionSecret: "test-session-secret",
    },
  });

  const loginResponse = await app.request("/admin/login", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      username: "admin",
      password: "test-password",
    }).toString(),
  });
  const cookie = loginResponse.headers.get("set-cookie");

  const listResponse = await app.request("/admin/prompts", {
    headers: { cookie },
  });
  assert.equal(listResponse.status, 200);
  assert.match(await listResponse.text(), /intent_recognition/);

  const saveResponse = await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "测试 Prompt 内容",
    }).toString(),
  });
  assert.equal(saveResponse.status, 302);
  assert.equal(saveResponse.headers.get("location"), "/admin/prompts/system_prompt?notice=prompt_saved");

  const promptResponse = await app.request("/v1/prompts/system_prompt");
  assert.equal(promptResponse.status, 200);
  const prompt = await promptResponse.json();
  assert.equal(prompt.content, "测试 Prompt 内容");
  assert.equal(prompt.source, "managed");

  const resetResponse = await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      action: "reset",
    }).toString(),
  });
  assert.equal(resetResponse.status, 302);
  assert.equal(resetResponse.headers.get("location"), "/admin/prompts/system_prompt?notice=prompt_reset");
});

test("admin login rejects invalid credentials without setting a session cookie", async () => {
  const app = createTestApp({
    admin: {
      username: "admin",
      password: "test-password",
      sessionSecret: "test-session-secret",
    },
  });

  const response = await app.request("/admin/login", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      username: "admin",
      password: "wrong-password",
    }).toString(),
  });

  assert.equal(response.status, 401);
  assert.equal(response.headers.get("set-cookie"), null);
  assert.match(await response.text(), /账号或密码不正确/);
});

test("admin logs record non-streaming AI request and response details", async () => {
  const app = createTestApp({
    admin: {
      token: "test-admin-token",
    },
  });

  const chatResponse = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "admin-log-device",
    },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      messages: [
        { role: "system", content: "你是 HoloAI" },
        { role: "user", content: "午饭35" },
      ],
    }),
  });
  assert.equal(chatResponse.status, 200);

  const logsResponse = await app.request("/v1/admin/logs", {
    headers: {
      "x-holo-admin-token": "test-admin-token",
    },
  });
  assert.equal(logsResponse.status, 200);

  const { logs } = await logsResponse.json();
  assert.equal(logs.length, 1);
  assert.equal(logs[0].status, "success");
  assert.equal(logs[0].purpose, "chat");
  assert.equal(logs[0].model, "holo-mock");

  const detailResponse = await app.request(`/v1/admin/logs/${logs[0].id}`, {
    headers: {
      "x-holo-admin-token": "test-admin-token",
    },
  });
  assert.equal(detailResponse.status, 200);
  const { log } = await detailResponse.json();
  assert.equal(log.request.messages[0].content, "你是 HoloAI");
  assert.equal(log.request.messages[1].content, "午饭35");
  assert.equal(log.response.choices[0].message.content, "Mock response for: 午饭35");
});

test("admin logs page escapes logged content", async () => {
  const app = createTestApp({
    admin: {
      token: "test-admin-token",
    },
  });

  const chatResponse = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "<script>alert(1)</script>",
    },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      messages: [{ role: "user", content: "<script>alert(1)</script>" }],
    }),
  });
  assert.equal(chatResponse.status, 200);

  const pageResponse = await app.request("/admin/logs?token=test-admin-token");
  assert.equal(pageResponse.status, 200);
  assert.match(pageResponse.headers.get("content-security-policy"), /default-src 'none'/);

  const html = await pageResponse.text();
  assert.doesNotMatch(html, /<script>alert\(1\)<\/script>/);
  assert.match(html, /&lt;script&gt;alert\(1\)&lt;\/script&gt;/);
});

test("GET /v1/prompts lists backend-managed prompt types", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts");

  assert.equal(response.status, 200);
  const json = await response.json();
  assert.ok(json.prompts.some((prompt) => prompt.type === "intent_recognition"));
  assert.ok(json.prompts.some((prompt) => prompt.type === "system_prompt"));
});

test("GET /v1/prompts/:type returns prompt content and version", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/intent_recognition");

  assert.equal(response.status, 200);
  const json = await response.json();
  assert.equal(json.type, "intent_recognition");
  assert.equal(json.version, 6);
  assert.match(json.content, /你是意图识别模块/);
});

test("GET /v1/prompts/:type rejects unsupported prompt types", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/unknown_prompt");

  assert.equal(response.status, 404);
  assert.equal((await response.json()).error.code, "PROMPT_NOT_FOUND");
});

test("POST /v1/ai/chat/completions streams SSE when stream is true", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "device-b",
    },
    body: JSON.stringify({
      purpose: "chat",
      stream: true,
      messages: [{ role: "user", content: "流式" }],
    }),
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "text/event-stream; charset=UTF-8");
  const text = await response.text();
  assert.match(text, /data: .*Mock/);
  assert.match(text, /data: \[DONE\]/);
});

test("chat endpoint rejects client-supplied provider routing fields", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "device-c",
    },
    body: JSON.stringify({
      purpose: "chat",
      baseURL: "https://attacker.example.com/v1",
      model: "client-chosen-model",
      stream: false,
      messages: [{ role: "user", content: "test" }],
    }),
  });

  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, "INVALID_CLIENT_ROUTING");
});

test("chat endpoint applies per-device minute rate limit", async () => {
  const app = createTestApp();
  const body = JSON.stringify({
    purpose: "chat",
    stream: false,
    messages: [{ role: "user", content: "rate" }],
  });

  for (let index = 0; index < 2; index += 1) {
    const response = await app.request("/v1/ai/chat/completions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-holo-device-id": "rate-limited-device",
      },
      body,
    });
    assert.equal(response.status, 200);
  }

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "rate-limited-device",
    },
    body,
  });

  assert.equal(response.status, 429);
  assert.equal((await response.json()).error.code, "RATE_LIMITED");
});
