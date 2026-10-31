import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes } from "node:crypto";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import {
  injectServerPrompt,
  isProfileChannelPurpose,
  normalizeProfileBrief,
} from "../src/prompts/serverPromptPolicy.js";
import { createCloudAnalysisTaskStore } from "../src/agent/cloudAnalysisTaskStore.js";
import { createCloudAnalysisExecutor } from "../src/agent/cloudAnalysisExecutor.js";

// 个人档案通道（2026-11-01 东林拍板「档案=通用指令而非备注」）：
// 用户亲写档案原文随请求上行（profileBrief），服务端在所有「用户直接阅读输出」
// purpose 统一注入成指令级 system 消息；结构化/萃取类不注入。本文件锁三层行为：
// 1) prompt 策略层（injectServerPrompt）
// 2) 网关请求层（/v1/ai/chat/completions 校验与透传）
// 3) 云端任务流（快照 profileBrief → executor 注入）

// —— 1) 策略层 ——

test("profile channel: chat 注入档案 system 消息（主 system 之后、用户消息之前）", () => {
  const result = injectServerPrompt(
    "chat",
    [{ role: "user", content: "你好" }],
    { profileBrief: "称呼我为东林\n- 职业：产品经理" },
  );
  assert.equal(result.messages[0].role, "system");
  assert.ok(result.messages[0].content.length > 0, "主 system 仍在第一位");
  const profile = result.messages[1];
  assert.equal(profile.role, "system");
  assert.match(profile.content, /用户个人档案/);
  assert.match(profile.content, /称呼我为东林/);
  assert.match(profile.content, /效力等同于用户当面告诉你的话/);
  assert.match(profile.content, /档案使用规则/);
  assert.equal(result.messages[2].content, "你好", "用户消息在档案消息之后");
});

test("profile channel: 结构化/萃取 purpose 不注入（数据不可执行纪律不与档案指令打架）", () => {
  for (const purpose of ["intent", "memory_domain_extraction", "personal_context_verification", "replayDigest"]) {
    assert.equal(isProfileChannelPurpose(purpose), false, purpose);
    const result = injectServerPrompt(
      purpose,
      [{ role: "user", content: "{}" }],
      { profileBrief: "称呼我为东林" },
    );
    const profileMessages = result.messages.filter((m, index) => index > 0 && m.role === "system");
    assert.equal(profileMessages.length, 0, `${purpose} 不应注入档案消息`);
    assert.ok(!result.messages.some((m) => m.content.includes("称呼我为东林")), purpose);
  }
});

test("profile channel: 开关关闭或 brief 非法时不注入", () => {
  const messages = [{ role: "user", content: "你好" }];
  const off = injectServerPrompt("chat", messages, {
    profileBrief: "称呼我为东林",
    profileChannelEnabled: false,
  });
  assert.equal(off.messages.length, 2, "关闭总闸后只剩主 system + 用户消息");

  const empty = injectServerPrompt("chat", messages, { profileBrief: "   " });
  assert.equal(empty.messages.length, 2, "空白 brief 不注入");

  const notString = injectServerPrompt("chat", messages, { profileBrief: 123 });
  assert.equal(notString.messages.length, 2, "非字符串 brief 不注入");
});

test("profile channel: normalizeProfileBrief 超限拒绝而非截断", () => {
  assert.equal(normalizeProfileBrief("x".repeat(13 * 1024), 12 * 1024), null);
  assert.equal(normalizeProfileBrief("  东林  "), "东林");
  assert.equal(normalizeProfileBrief(null), null);
});

// —— 2) 网关请求层 ——

function createTestApp(overrides = {}) {
  return createApp({
    database: overrides.database ?? createDatabase({ dbPath: ":memory:" }),
    auth: { enforceAppAttest: false },
    limits: { chatRequestsPerMinute: 20, chatRequestsPerDay: 100 },
    routes: {
      chat: { provider: "mock", model: "holo-mock", temperature: 0.2, maxTokens: 512 },
    },
    exposePromptEndpointsForTests: true,
    ...overrides,
  });
}

test("网关：chat 请求携带 profileBrief → 上游收到档案 system 消息", async () => {
  const seen = [];
  const app = createTestApp({
    providerOverrides: new Map([["recorder", {
      async complete(request) {
        seen.push(request.messages);
        return {
          choices: [{ index: 0, message: { role: "assistant", content: "ok" }, finish_reason: "stop" }],
        };
      },
    }]]),
    routes: {
      chat: { provider: "recorder", model: "m", temperature: 0.2, maxTokens: 512 },
    },
  });

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "device-profile" },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      profileBrief: "称呼我为东林",
      messages: [{ role: "user", content: "你好" }],
    }),
  });
  assert.equal(response.status, 200);
  assert.equal(seen.length, 1);
  const profile = seen[0][1];
  assert.equal(profile.role, "system");
  assert.match(profile.content, /称呼我为东林/);
});

test("网关：profileBrief 超限 → 400 PROFILE_BRIEF_TOO_LARGE（拒绝而非截断）", async () => {
  const app = createTestApp();
  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "device-profile-big" },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      profileBrief: "x".repeat(13 * 1024),
      messages: [{ role: "user", content: "你好" }],
    }),
  });
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, "PROFILE_BRIEF_TOO_LARGE");
});

test("网关：profileBrief 非字符串 → 400；缺省仍兼容", async () => {
  const app = createTestApp();
  const bad = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "device-profile-type" },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      profileBrief: 42,
      messages: [{ role: "user", content: "你好" }],
    }),
  });
  assert.equal(bad.status, 400);

  const ok = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "device-profile-legacy" },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      messages: [{ role: "user", content: "你好" }],
    }),
  });
  assert.equal(ok.status, 200, "旧客户端不带 profileBrief 必须完全兼容");
});

// —— 3) 云端任务流 ——

const TEST_KEY = randomBytes(32).toString("base64");

function agentJson(status, extra = {}) {
  return JSON.stringify({ status, reasoning: "r", toolRequests: [], claims: [], warnings: [], ...extra });
}

test("云端 deep_analysis：快照 profileBrief → agent_loop system 含档案指令", async () => {
  const calls = [];
  const responses = [
    agentJson("need_tools", {
      toolRequests: [{
        id: "t1",
        tool: "finance",
        query: "dynamic_query",
        parameters: {
          dynamicPlan: {
            source: "finance.transactions",
            filters: [],
            groupBy: [],
            aggregations: [{ id: "total", operation: "sum", field: "amount", unit: "元" }],
            derivations: [],
            limit: 5,
            evidenceLimit: 5,
          },
        },
      }],
    }),
    agentJson("final_claims", {
      claims: [{
        summary: "支出合计 32 元",
        displayText: "本期支出合计 32 元",
        metricAssertions: [{
          metricKey: "dynamic.finance_transactions.total.all",
          value: -32,
          baselineValue: null,
          unit: "元",
          comparison: null,
          evidenceIDs: [],
        }],
        evidenceIDs: [],
        type: "observation",
        confidence: 0.6,
      }],
    }),
  ];
  const provider = {
    async complete(request) {
      calls.push(request.messages);
      const next = responses.shift();
      if (next === undefined) throw new Error("PROVIDER_EXHAUSTED");
      return {
        choices: [{ index: 0, message: { role: "assistant", content: next }, finish_reason: "stop" }],
        usage: { prompt_tokens: 10, completion_tokens: 5 },
      };
    },
  };
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const executor = createCloudAnalysisExecutor({
    taskStore: store,
    providers: new Map([["fake", provider]]),
    route: { provider: "fake", model: "m", temperature: 0.2, maxTokens: 1024 },
    providerRetries: 1,
    log: () => {},
    injectedQuestionTimeResolver: { resolveQuestionTime: async () => null },
  });

  const task = store.create({ deviceId: "device-cloud-profile", question: "深度分析我的消费", taskType: "deep_analysis" });
  store.attachSnapshot({
    id: task.id,
    snapshot: JSON.stringify({
      version: 1,
      profileBrief: "称呼我为东林\n我有膝伤，不能给跑步类建议",
      datasets: {
        "finance.transactions": {
          fields: [
            { name: "date", type: "date" },
            { name: "category", type: "text" },
            { name: "amount", type: "number", unit: "元" },
          ],
          rows: [{ date: "2026-08-01", category: "餐饮", amount: -32 }],
        },
      },
    }),
  });

  assert.equal(await executor.run(task.id), "completed");
  const system = calls[0].find((m) => m.role === "system");
  assert.match(system.content, /称呼我为东林/);
  assert.match(system.content, /我有膝伤/);
  assert.match(system.content, /用户个人档案/);
});

test("云端 period_replay：context JSON 根字段 profileBrief → 注入档案消息", async () => {
  const calls = [];
  const provider = {
    async complete(request) {
      calls.push(request.messages);
      return {
        choices: [{
          index: 0,
          message: { role: "assistant", content: '{"title":"上周","summary":"摘要","cards":[],"suggestedQuestions":[]}' },
          finish_reason: "stop",
        }],
        usage: { prompt_tokens: 10, completion_tokens: 5 },
      };
    },
  };
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const executor = createCloudAnalysisExecutor({
    taskStore: store,
    providers: new Map([["fake", provider]]),
    route: { provider: "fake", model: "m", temperature: 0.2, maxTokens: 1024 },
    providerRetries: 1,
    log: () => {},
    injectedQuestionTimeResolver: { resolveQuestionTime: async () => null },
  });

  const task = store.create({ deviceId: "device-replay-profile", question: "本月", taskType: "period_replay" });
  store.attachSnapshot({
    id: task.id,
    snapshot: JSON.stringify({ periodType: "weekly", summary: "素材", profileBrief: "称呼我为东林" }),
  });

  assert.equal(await executor.run(task.id), "completed");
  const systemMessages = calls[0].filter((m) => m.role === "system");
  assert.equal(systemMessages.length, 2, "主 system + 档案 system");
  assert.match(systemMessages[1].content, /称呼我为东林/);
});
