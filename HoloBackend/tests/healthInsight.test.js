import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";

import { createApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
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
      entries.push({ id, ...input, status: "pending" });
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

// === route config ===

test("health_insight_generation route 存在、token 充足、不含 response_format（P1）", () => {
  const route = loadConfig().routes.health_insight_generation;
  assert.ok(route, "应存在 health_insight_generation route");
  assert.equal(typeof route.provider, "string");
  assert.equal(typeof route.model, "string");
  assert.ok(
    route.maxTokens >= 1600,
    `maxTokens 应 >= 1600 防 lifestyleLoop 截断，实际 ${route.maxTokens}`,
  );
  // P1：response_format 由 iOS 请求体透传，route 不应配置该字段
  assert.equal(route.responseFormat, undefined, "route 不应配置 response_format");
});

// === prompt 存在 + 内容约束（5.1）===

test("health_insight_generation prompt 存在并包含医疗安全与 evidenceId 约束", async () => {
  const app = createTestApp();
  const response = await app.request("/v1/prompts/health_insight_generation");
  assert.equal(response.status, 200);

  const prompt = await response.json();
  assert.match(prompt.content, /不做医学诊断/);
  assert.match(prompt.content, /evidenceId/);
  assert.match(prompt.content, /只输出 JSON/);
  assert.equal(prompt.version, 2);
});

// === 版本登记（R3）===

test("PROMPT_VERSIONS 登记 health_insight_generation 版本 2", async () => {
  const app = createTestApp();
  const response = await app.request("/v1/prompts/meta");
  assert.equal(response.status, 200);

  const json = await response.json();
  const entry = json.prompts.find((p) => p.type === "health_insight_generation");
  assert.ok(entry, "meta 应包含 health_insight_generation");
  assert.equal(entry.version, 2);
});

// === response_format 透传（P1：从请求体经 app 到 provider）===

test("health_insight_generation purpose 从请求体透传 response_format", async () => {
  const adminLogStore = createRecordingAdminLogStore();
  const app = createTestApp({ adminLogStore });

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "device-health",
    },
    body: JSON.stringify({
      purpose: "health_insight_generation",
      stream: false,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: "system prompt" },
        { role: "user", content: '{"healthSummary":{"sleepAverageHours":6.4}}' },
      ],
    }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  assert.equal(json.provider, "mock");
  assert.ok(json.choices[0].message.content);

  // P1：response_format 从请求体被正确接收（app.js 取 request.response_format 用于 upstreamRequest）
  const entry = adminLogStore.entries.find((e) => e.purpose === "health_insight_generation");
  assert.ok(entry, "应记录健康洞察调用");
  assert.deepEqual(entry.request.responseFormat, { type: "json_object" });
});

// === 回归：新增 prompt 不破坏既有 prompt 注册 ===

test("新增 health_insight_generation 不破坏既有 prompt 注册", async () => {
  const app = createTestApp();
  const response = await app.request("/v1/prompts/meta");
  const json = await response.json();
  const types = json.prompts.map((p) => p.type);

  assert.ok(types.includes("system_prompt"));
  assert.ok(types.includes("memory_insight_generation"));
  assert.ok(types.includes("agent_loop"));
  assert.ok(types.includes("health_insight_generation"));
});
