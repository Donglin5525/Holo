import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { createContentModerationService } from "../src/moderation/contentModerationService.js";

const REFUSAL_MESSAGE = "抱歉，你的问题我暂时无法回应。换个话题吧。";

function createTestDatabase() {
  return createDatabase({ dbPath: `:memory:` });
}

// 模拟阿里云 textModerationPlus 的原始响应（{ body } 形态）。
function mockSdkResponse({ code = 200, results = [], riskLevel = "none" } = {}) {
  return { body: { code, data: { result: results, riskLevel }, requestId: "req-mock" } };
}

// ── 单元测试：createContentModerationService ──

test("isEnabled is false and moderate degrades to disabled when credentials are missing", async () => {
  const service = createContentModerationService({ accessKeyId: "", accessKeySecret: "" });
  assert.equal(service.isEnabled(), false);
  assert.deepEqual(await service.moderate("任意内容"), { passed: true, reason: "disabled" });
});

test("isEnabled can be forced off via the enabled flag even with credentials", () => {
  const service = createContentModerationService({
    accessKeyId: "id",
    accessKeySecret: "secret",
    enabled: false,
  });
  assert.equal(service.isEnabled(), false);
});

test("moderate passes empty text without calling the SDK", async () => {
  const service = createContentModerationService({
    accessKeyId: "id",
    accessKeySecret: "secret",
    moderateImpl: () => {
      throw new Error("SDK should not be called for empty text");
    },
  });
  assert.deepEqual(await service.moderate(""), { passed: true });
  assert.deepEqual(await service.moderate(null), { passed: true });
});

test("moderate returns passed:true when SDK reports only nonLabel", async () => {
  const service = createContentModerationService({
    accessKeyId: "id",
    accessKeySecret: "secret",
    moderateImpl: () => mockSdkResponse({ results: [{ label: "nonLabel", confidence: 0.1 }] }),
  });
  assert.deepEqual(await service.moderate("你好"), { passed: true });
});

test("moderate blocks when SDK reports a violation label and forwards labels/riskLevel", async () => {
  const service = createContentModerationService({
    accessKeyId: "id",
    accessKeySecret: "secret",
    moderateImpl: () =>
      mockSdkResponse({
        results: [{ label: "political_entity", confidence: 99 }],
        riskLevel: "high",
      }),
  });
  const result = await service.moderate("违规内容");
  assert.equal(result.passed, false);
  assert.deepEqual(result.labels, ["political_entity"]);
  assert.equal(result.riskLevel, "high");
});

test("moderate degrades to service-error when SDK returns a non-200 code", async () => {
  const service = createContentModerationService({
    accessKeyId: "id",
    accessKeySecret: "secret",
    moderateImpl: () => mockSdkResponse({ code: 500 }),
  });
  assert.deepEqual(await service.moderate("任意内容"), { passed: true, reason: "service-error" });
});

test("moderate degrades to service-error when the SDK throws", async () => {
  const service = createContentModerationService({
    accessKeyId: "id",
    accessKeySecret: "secret",
    moderateImpl: () => {
      throw new Error("network down");
    },
  });
  assert.deepEqual(await service.moderate("任意内容"), { passed: true, reason: "service-error" });
});

// ── 集成测试：chat completions 内容审核 ──

// 命中违规的审核服务（输入即拦截）。
function blockedModeration(labels = ["spam"], riskLevel = "medium") {
  return {
    isEnabled: () => true,
    async moderate() {
      return { passed: false, labels, riskLevel };
    },
  };
}

// 放行的审核服务。
function passthroughModeration() {
  return {
    isEnabled: () => true,
    async moderate() {
      return { passed: true };
    },
  };
}

// 输入放行、输出拦截的审核服务（验证非流式输出审核）。
function blockOnOutputModeration() {
  let calls = 0;
  return {
    isEnabled: () => true,
    async moderate() {
      calls += 1;
      return calls === 1
        ? { passed: true }
        : { passed: false, labels: ["spam"], riskLevel: "high" };
    },
  };
}

// 记录 reserve/commit/release 调用次数的配额 store。
function createRecordingQuotaStore() {
  const calls = { reserve: 0, commit: 0, release: 0 };
  return {
    calls,
    reserve() {
      calls.reserve += 1;
      return { allowed: true, duplicate: false, status: "reserved" };
    },
    commit() {
      calls.commit += 1;
    },
    release() {
      calls.release += 1;
    },
    peek() {
      return { used: 0, remaining: 100, available: 100 };
    },
    reset() {},
  };
}

function createTestApp(overrides = {}) {
  return createApp({
    database: createTestDatabase(),
    auth: { enforceAppAttest: false },
    limits: { chatRequestsPerMinute: 5, chatRequestsPerDay: 20 },
    routes: {
      chat: { provider: "mock", model: "holo-mock", temperature: 0.2, maxTokens: 512 },
    },
    ...overrides,
  });
}

test("non-streaming chat blocked by input moderation returns refusal and releases quota", async () => {
  const quotaStore = createRecordingQuotaStore();
  const app = createTestApp({
    contentModeration: blockedModeration(),
    quotaActionLedgerStore: quotaStore,
  });

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "dev-blocked-1" },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      messages: [{ role: "user", content: "违规内容" }],
    }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  assert.equal(json.moderation_blocked, true);
  assert.equal(json.choices[0].finish_reason, "content_filter");
  assert.equal(json.choices[0].message.role, "assistant");
  assert.equal(json.choices[0].message.content, REFUSAL_MESSAGE);
  // 命中拦截：配额释放，未提交。
  assert.equal(quotaStore.calls.release, 1);
  assert.equal(quotaStore.calls.commit, 0);
});

test("streaming chat blocked by input moderation returns an SSE refusal stream", async () => {
  const app = createTestApp({ contentModeration: blockedModeration() });

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "dev-blocked-2" },
    body: JSON.stringify({
      purpose: "chat",
      stream: true,
      messages: [{ role: "user", content: "违规内容" }],
    }),
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "text/event-stream; charset=UTF-8");
  const text = await response.text();
  assert.match(text, /data: \{.*content_filter/s);
  assert.ok(text.includes(REFUSAL_MESSAGE));
  assert.match(text, /data: \[DONE\]/);
});

test("chat proceeds normally when input moderation passes and commits quota", async () => {
  const quotaStore = createRecordingQuotaStore();
  const app = createTestApp({
    contentModeration: passthroughModeration(),
    quotaActionLedgerStore: quotaStore,
  });

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "dev-pass-1" },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      messages: [{ role: "user", content: "你好" }],
    }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  assert.equal(json.choices[0].message.content, "Mock response for: 你好");
  assert.equal(quotaStore.calls.commit, 1);
  assert.equal(quotaStore.calls.release, 0);
});

test("non-streaming output moderation replaces violating model content with refusal", async () => {
  const app = createTestApp({ contentModeration: blockOnOutputModeration() });

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "dev-output-1" },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      messages: [{ role: "user", content: "你好" }],
    }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  assert.equal(json.moderation_blocked, true);
  assert.equal(json.choices[0].finish_reason, "content_filter");
  assert.equal(json.choices[0].message.content, REFUSAL_MESSAGE);
});
