import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";

import { createApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { createDatabase } from "../src/db/database.js";
import { renderAdminLogsPage } from "../src/admin/adminLogsPage.js";

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
    exposePromptEndpointsForTests: true,
    ...overrides,
  });
}

function createRecordingAdminLogStore() {
  const entries = [];
  return {
    maxDetailChars: 20_000,
    entries,
    startAiCall(input) {
      const id = randomUUID();
      entries.push({
        id,
        ...input,
        status: "pending",
      });
      return id;
    },
    finishAiCall(id, result) {
      const entry = entries.find((item) => item.id === id);
      if (entry) {
        Object.assign(entry, result);
      }
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

test("intent route reserves enough output tokens for verbose multi-action JSON", () => {
  const config = loadConfig();

  assert.ok(
    config.routes.intent.maxTokens >= 4096,
    `intent maxTokens should support multi-action JSON, got ${config.routes.intent.maxTokens}`,
  );
});

test("flexible query planner route reserves a dedicated structured output budget", () => {
  const config = loadConfig();

  assert.ok(
    config.routes.flexible_query_planner.maxTokens >= 4096,
    `flexible query planner maxTokens should be >= 4096, got ${config.routes.flexible_query_planner.maxTokens}`,
  );
  assert.equal(config.routes.flexible_query_planner.temperature, 0);
});

test("POST /v1/ai/chat/completions accepts flexible_query_planner purpose", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "flexible-query-planner-device",
    },
    body: JSON.stringify({
      purpose: "flexible_query_planner",
      stream: false,
      response_format: { type: "json_object" },
      messages: [{ role: "user", content: "输出一个查询计划" }],
    }),
  });

  assert.equal(response.status, 200);
});

test("intent mock routes category-specific spending amount queries to flexible_data_query", async () => {
  const app = createTestApp();

  const promptResponse = await app.request("/v1/prompts/intent_recognition");
  assert.equal(promptResponse.status, 200);
  const prompt = await promptResponse.json();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "intent-fireworks-device",
    },
    body: JSON.stringify({
      purpose: "intent",
      stream: false,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: prompt.content },
        { role: "user", content: "今年买烟花了多少钱" },
      ],
    }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  const content = json.choices[0].message.content;
  const parsed = JSON.parse(content);
  assert.equal(parsed.mode, "query");
  assert.equal(parsed.items[0].intent, "flexible_data_query");
  assert.notEqual(parsed.items[0].intent, "query_analysis");
  assert.equal(parsed.items[0].extractedData.queryDomain, "finance");
  assert.match(parsed.items[0].extractedData.rawConstraints, /今年/);
  assert.match(parsed.items[0].extractedData.rawConstraints, /烟花/);
});

test("intent mock routes merchant count total and per-meal average to flexible_data_query", async () => {
  const app = createTestApp();

  const promptResponse = await app.request("/v1/prompts/intent_recognition");
  assert.equal(promptResponse.status, 200);
  const prompt = await promptResponse.json();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "intent-merchant-average-device",
    },
    body: JSON.stringify({
      purpose: "intent",
      stream: false,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: prompt.content },
        { role: "user", content: "最近一个月吃了多少吨麦当劳，花了多少钱，平均一顿多少钱" },
      ],
    }),
  });

  assert.equal(response.status, 200);
  const parsed = JSON.parse((await response.json()).choices[0].message.content);
  assert.equal(parsed.mode, "query");
  assert.equal(parsed.items[0].intent, "flexible_data_query");
  assert.notEqual(parsed.items[0].intent, "query_analysis");
  assert.match(parsed.items[0].extractedData.queryGoal, /次数/);
  assert.match(parsed.items[0].extractedData.queryGoal, /总额/);
  assert.match(parsed.items[0].extractedData.queryGoal, /平均每顿/);
  assert.match(parsed.items[0].extractedData.rawConstraints, /最近一个月/);
  assert.match(parsed.items[0].extractedData.rawConstraints, /麦当劳/);
});

test("intent mock routes direct income total queries to flexible_data_query", async () => {
  const app = createTestApp();

  const promptResponse = await app.request("/v1/prompts/intent_recognition");
  assert.equal(promptResponse.status, 200);
  const prompt = await promptResponse.json();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "intent-income-total-device",
    },
    body: JSON.stringify({
      purpose: "intent",
      stream: false,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: prompt.content },
        { role: "user", content: "今年的收入是多少" },
      ],
    }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  const parsed = JSON.parse(json.choices[0].message.content);
  assert.equal(parsed.mode, "query");
  assert.equal(parsed.items[0].intent, "flexible_data_query");
  assert.equal(parsed.items[0].extractedData.queryDomain, "finance");
  assert.match(parsed.items[0].extractedData.rawConstraints, /今年/);
  assert.match(parsed.items[0].extractedData.rawConstraints, /收入/);
});

test("intent mock routes sleep and health status questions to health query_analysis", async () => {
  const app = createTestApp();

  const promptResponse = await app.request("/v1/prompts/intent_recognition");
  assert.equal(promptResponse.status, 200);
  const prompt = await promptResponse.json();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "intent-sleep-health-device",
    },
    body: JSON.stringify({
      purpose: "intent",
      stream: false,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: prompt.content },
        { role: "user", content: "最近状态不好，看看睡眠咋样" },
      ],
    }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  const parsed = JSON.parse(json.choices[0].message.content);
  assert.equal(parsed.mode, "query");
  assert.equal(parsed.items[0].intent, "query_analysis");
  assert.equal(parsed.items[0].extractedData.analysisDomain, "health");
  assert.equal(parsed.items[0].extractedData.subDomain, "sleep");
  assert.equal(parsed.items[0].extractedData.periodLabel, "最近");
  assert.notEqual(parsed.items[0].intent, "query_habits");
});

test("admin logs are disabled when HOLO_ADMIN_TOKEN is not configured", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/admin/logs");

  assert.equal(response.status, 404);
  assert.equal((await response.json()).error.code, "ADMIN_DISABLED");
});

test("AI call logs can be captured independently from admin auth", async () => {
  const adminLogStore = createRecordingAdminLogStore();
  const app = createTestApp({ adminLogStore });

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "capture-without-admin",
    },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      messages: [{ role: "user", content: "记录这次请求" }],
    }),
  });

  assert.equal(response.status, 200);
  assert.equal(adminLogStore.entries.length, 1);
  assert.equal(adminLogStore.entries[0].deviceId, "capture-without-admin");
  assert.equal(adminLogStore.entries[0].status, "success");
});

test("admin logs page displays UTC timestamps as UTC+8 local time", () => {
  const html = renderAdminLogsPage({
    token: "",
    logs: [
      {
        id: "1",
        type: "ai.chat.completions",
        status: "success",
        startedAt: "2026-05-16 09:32:11",
        durationMs: 120,
        purpose: "chat",
        provider: "mock",
        model: "holo-mock",
        deviceId: "device-a",
        stream: false,
      },
    ],
  });

  assert.match(html, /2026-05-16 17:32:11/);
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
  const detail = await detailResponse.json();
  assert.match(detail.log.request.messages[0].content, /Holo/);
  assert.equal(detail.log.request.messages[1].content, "咖啡20");
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
  assert.match(log.request.messages[0].content, /Holo/);
  assert.equal(log.request.messages[1].content, "你是 HoloAI");
  assert.equal(log.request.messages[2].content, "午饭35");
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
  assert.equal(json.version, 23);
  assert.match(json.content, /短意图 Router/);
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

// ── Phase 0: Golden tests ──

// 辅助函数：发送 intent 请求并返回解析结果
async function sendIntentGoldenTest(app, input, deviceId) {
  const promptResponse = await app.request("/v1/prompts/intent_recognition");
  assert.equal(promptResponse.status, 200);
  const prompt = await promptResponse.json();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": deviceId,
    },
    body: JSON.stringify({
      purpose: "intent",
      stream: false,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: prompt.content },
        { role: "user", content: input },
      ],
    }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  return JSON.parse(json.choices[0].message.content);
}

test("golden: 今天午饭花了35 → record_expense", async () => {
  const app = createTestApp();
  const parsed = await sendIntentGoldenTest(app, "今天午饭花了35", "golden-expense-1");

  assert.equal(parsed.mode, "single_action");
  assert.equal(parsed.items[0].intent, "record_expense");
  assert.equal(parsed.items[0].extractedData.amount, "35");
  assert.equal(parsed.items[0].extractedData.categoryCandidate, "午饭");
  assert.equal(parsed.items[0].extractedData.transactionDate, "2026-06-03");
});

test("golden: 昨天午饭花了35 → record_expense with transactionDate", async () => {
  const app = createTestApp();
  const parsed = await sendIntentGoldenTest(app, "昨天午饭花了35", "golden-expense-yesterday");

  assert.equal(parsed.mode, "single_action");
  assert.equal(parsed.items[0].intent, "record_expense");
  assert.equal(parsed.items[0].extractedData.amount, "35");
  assert.equal(parsed.items[0].extractedData.categoryCandidate, "午饭");
  assert.equal(parsed.items[0].extractedData.transactionDate, "2026-06-02");
});

test("golden: 发工资 20000 → record_income", async () => {
  const app = createTestApp();
  const parsed = await sendIntentGoldenTest(app, "发工资 20000", "golden-income-1");

  assert.equal(parsed.mode, "single_action");
  assert.equal(parsed.items[0].intent, "record_income");
  assert.equal(parsed.items[0].extractedData.amount, "20000");
  assert.equal(parsed.items[0].extractedData.categoryCandidate, "工资");
});

test("golden: 明天早上提醒我买水 → create_task with reminderDate", async () => {
  const app = createTestApp();
  const parsed = await sendIntentGoldenTest(app, "明天早上提醒我买水", "golden-task-reminder");

  assert.equal(parsed.mode, "single_action");
  assert.equal(parsed.items[0].intent, "create_task");
  assert.ok(parsed.items[0].extractedData.reminderDate, "应有 reminderDate");
  assert.ok(parsed.items[0].extractedData.title.includes("买水"), "title 应包含买水");
});

test("golden: 明天去山姆买牛奶、鸡蛋和纸巾 → create_task with subtasks", async () => {
  const app = createTestApp();
  const parsed = await sendIntentGoldenTest(app, "明天去山姆买牛奶、鸡蛋和纸巾", "golden-task-subtasks");

  assert.equal(parsed.mode, "single_action");
  assert.equal(parsed.items[0].intent, "create_task");
  const title = parsed.items[0].extractedData.title;
  assert.ok(title.includes("山姆") || title.includes("购物"), `title 应包含山姆或购物，实际: ${title}`);
  const subtasks = parsed.items[0].extractedData.subtasks;
  assert.ok(subtasks.includes("买牛奶"), `subtasks 应包含买牛奶，实际: ${subtasks}`);
  assert.ok(subtasks.includes("买鸡蛋"), `subtasks 应包含买鸡蛋，实际: ${subtasks}`);
  assert.ok(subtasks.includes("买纸巾"), `subtasks 应包含买纸巾，实际: ${subtasks}`);
});

test("golden: 今天跑步打卡 → check_in", async () => {
  const app = createTestApp();
  const parsed = await sendIntentGoldenTest(app, "今天跑步打卡", "golden-checkin-1");

  assert.equal(parsed.mode, "single_action");
  assert.equal(parsed.items[0].intent, "check_in");
  assert.equal(parsed.items[0].extractedData.habitName, "跑步");
});

test("golden: 最近一次打车是什么时候 → flexible_data_query", async () => {
  const app = createTestApp();
  const parsed = await sendIntentGoldenTest(app, "最近一次打车是什么时候", "golden-latest-query");

  assert.equal(parsed.mode, "query");
  assert.equal(parsed.items[0].intent, "flexible_data_query");
  assert.equal(parsed.items[0].extractedData.queryDomain, "finance");
  assert.notEqual(parsed.items[0].intent, "query_analysis");
});

test("golden: 分析今年收入结构 → query_analysis", async () => {
  const app = createTestApp();
  const parsed = await sendIntentGoldenTest(app, "分析今年收入结构", "golden-analysis-1");

  assert.equal(parsed.mode, "query");
  assert.equal(parsed.items[0].intent, "query_analysis");
  assert.equal(parsed.items[0].extractedData.analysisDomain, "finance");
  assert.notEqual(parsed.items[0].intent, "flexible_data_query");
});

test("golden: 复盘本月消费 → query_analysis", async () => {
  const app = createTestApp();
  const parsed = await sendIntentGoldenTest(app, "复盘本月消费", "golden-analysis-2");

  assert.equal(parsed.mode, "query");
  assert.equal(parsed.items[0].intent, "query_analysis");
  assert.notEqual(parsed.items[0].intent, "flexible_data_query");
});

test("golden: 你能做什么 → query", async () => {
  const app = createTestApp();
  const parsed = await sendIntentGoldenTest(app, "你能做什么", "golden-query-1");

  assert.equal(parsed.mode, "query");
  assert.equal(parsed.items[0].intent, "query");
  assert.notEqual(parsed.items[0].intent, "flexible_data_query");
  assert.notEqual(parsed.items[0].intent, "query_analysis");
});

// ── End Phase 0: Golden tests ──

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

test("agent_loop purpose uses route-specific request limits", async () => {
  const app = createTestApp({
    routes: {
      agent_loop: {
        provider: "mock",
        model: "holo-mock",
        temperature: 0.1,
        maxTokens: 512,
        requestLimits: {
          perMinute: 3,
          perDay: 10,
        },
      },
    },
  });
  const body = JSON.stringify({
    purpose: "agent_loop",
    stream: false,
    messages: [{ role: "user", content: "分析最近的开销" }],
  });

  for (let index = 0; index < 3; index += 1) {
    const response = await app.request("/v1/ai/chat/completions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-holo-device-id": "agent-loop-rate-device",
      },
      body,
    });
    assert.equal(response.status, 200);
  }

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "agent-loop-rate-device",
    },
    body,
  });

  assert.equal(response.status, 429);
  assert.equal((await response.json()).error.code, "RATE_LIMITED");
});

test("agent_loop purpose 被接受并返回 mock agent JSON", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "device-agent",
    },
    body: JSON.stringify({
      purpose: "agent_loop",
      stream: false,
      messages: [{ role: "user", content: "分析最近的开销" }],
    }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  const content = json.choices[0].message.content;
  const parsed = JSON.parse(content);
  assert.ok(
    ["need_tools", "need_more_analysis", "final_claims"].includes(parsed.status),
    `agent_loop mock 应返回合法 status，实际 ${parsed.status}`
  );
  assert.equal(parsed.claims[0].displayText, "mock claim");
  assert.equal(parsed.claims[0].type, "observation");
  assert.equal(parsed.claims[0].confidence, 0.5);
});
