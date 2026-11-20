// 「一个发现」v4 洞察网关集成测试（2026-11-20 方案 02-后端实施·测试节）。
// 覆盖：开关关闭（disabled 不调上游）/ 合规输出 / 含数字触发重试后成功 /
// 两次失败 gate_rejected / none_worthwhile 透传 / 流式 SSE 形状（最终 chunk + [DONE]）/
// 非法输入包 400 / 拒因注入重试消息。
// 契约真源：最终 chunk 的 content = insightGate.buildDraftEnvelope 输出形状，
// iOS DiscoveryInsightService 按此解码（Swift 侧 DiscoveryInsightContractTests 对拍）。
import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

const DEVICE = "11111111-2222-4333-8444-555555555555";

function insightStub() {
  const calls = [];
  const queue = [];
  return {
    calls,
    enqueue(content) { queue.push(content); },
    provider: {
      async complete(request) {
        calls.push(request);
        const content = queue.length > 0 ? queue.shift() : "{}";
        return {
          id: "stub-insight",
          choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
          usage: { prompt_tokens: 900, completion_tokens: 150 },
        };
      },
    },
  };
}

function packetJSON(overrides = {}) {
  return JSON.stringify({
    schemaVersion: 1,
    kind: "insightInput",
    requestId: `req-${Math.random().toString(36).slice(2, 10)}`,
    window: { days: 28 },
    portrait: [
      { id: "p_early_sleep", dimension: "recentState", confidence: "confirmed", statement: "说想早睡", evidenceSummary: "目标原文", sourceDomains: ["goal"] },
    ],
    features: [
      { id: "f_late_night", domain: "finance", description: "深夜下单比之前少", direction: "down", slots: [{ name: "lateWeeks", unit: "weeks" }] },
      { id: "f_task_overdue", domain: "task", description: "断签日与任务逾期日重合", direction: "divergent", slots: [{ name: "overdueDays", unit: "days" }] },
    ],
    userIntents: [{ id: "u_1", source: "goal", text: "想早睡" }],
    recentTopics: [],
    rejectedAngles: [],
    ...overrides,
  });
}

function goodDraft() {
  return {
    schemaVersion: 1,
    kind: "insightDraft",
    selected: {
      angleKey: "sleep×lateNight",
      headline: "早睡在顺带帮你省钱",
      insight: "你说想早睡的那段时间，深夜下单反而变少了，早睡好像在顺带帮你省钱。",
      evidence: [{ refId: "f_late_night", template: "最近{lateWeeks}周里深夜下单明显变少" }],
      prompt: "",
      criteria: ["D1", "D2", "D4"],
      sourceDomains: ["goal", "finance"],
    },
    noneReason: null,
  };
}

function modelOutput(draft) {
  return JSON.stringify(draft);
}

function makeApp(overrides = {}, stub = insightStub()) {
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database,
    auth: { enforceAppAttest: false },
    routes: {
      discovery_insight_v2: {
        provider: "stub", model: "holo-stub", temperature: 0.4,
        maxTokens: 2048, reasoningEffort: "low",
        requestLimits: { perMinute: 100, perDay: 1000 },
      },
    },
    providerOverrides: [["stub", stub.provider]],
    discovery: { insightV2Enabled: true },
    ...overrides,
  });
  return { app, database, stub };
}

async function post(app, { packet, stream = false } = {}) {
  return app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": DEVICE },
    body: JSON.stringify({
      purpose: "discovery_insight_v2",
      stream,
      messages: [{ role: "user", content: packet ?? packetJSON() }],
    }),
  });
}

test("开关关闭：200 + noneReason=disabled，不调上游", async () => {
  const stub = insightStub();
  const { app } = makeApp({ discovery: { insightV2Enabled: false } }, stub);
  const res = await post(app);
  assert.equal(res.status, 200);
  const json = await res.json();
  const draft = JSON.parse(json.choices[0].message.content);
  assert.equal(draft.kind, "insightDraft");
  assert.equal(draft.selected, null);
  assert.equal(draft.noneReason, "disabled");
  assert.equal(stub.calls.length, 0);
});

test("合规输出：200 + 闸门放行形状 + 证据模板原样保留", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput(goodDraft()));
  const { app } = makeApp({}, stub);
  const res = await post(app);
  assert.equal(res.status, 200);
  const draft = JSON.parse((await res.json()).choices[0].message.content);
  assert.equal(draft.selected.angleKey, "sleep×lateNight");
  assert.equal(draft.selected.evidence[0].template, "最近{lateWeeks}周里深夜下单明显变少");
  assert.equal(draft.noneReason, null);
  // 上游调用：server prompt 注入 + responseFormat json_object + 缓冲（stream=false）
  assert.equal(stub.calls.length, 1);
  assert.equal(stub.calls[0].stream, false);
  assert.equal(stub.calls[0].responseFormat.type, "json_object");
  assert.equal(stub.calls[0].messages[0].role, "system");
});

test("含数字内容：第一次拒绝 → 拒因重试 → 第二次成功", async () => {
  const stub = insightStub();
  const bad = goodDraft();
  bad.selected.headline = "最近三周的深夜变化";
  stub.enqueue(modelOutput(bad));
  stub.enqueue(modelOutput(goodDraft()));
  const { app } = makeApp({}, stub);
  const res = await post(app);
  assert.equal(res.status, 200);
  const draft = JSON.parse((await res.json()).choices[0].message.content);
  assert.equal(draft.selected.headline, "早睡在顺带帮你省钱");
  assert.equal(stub.calls.length, 2);
  // 重试消息带拒因注入（retryHint）
  const retryUser = stub.calls[1].messages.find((m) => m.role === "user");
  assert.match(retryUser.content, /拒因=bare_number/);
});

test("两次失败：gate_rejected，不 5xx（宁缺毋滥降级语义）", async () => {
  const stub = insightStub();
  const bad = goodDraft();
  bad.selected.insight = "你深夜下单大概两三次。";
  stub.enqueue(modelOutput(bad));
  stub.enqueue("完全不是 JSON");
  const { app } = makeApp({}, stub);
  const res = await post(app);
  assert.equal(res.status, 200);
  const draft = JSON.parse((await res.json()).choices[0].message.content);
  assert.equal(draft.selected, null);
  assert.equal(draft.noneReason, "gate_rejected");
  assert.equal(stub.calls.length, 2);
});

test("none_worthwhile：模型判定无值得说的 → 原样透传", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput({ schemaVersion: 1, kind: "insightDraft", selected: null, noneReason: "none_worthwhile" }));
  const { app } = makeApp({}, stub);
  const res = await post(app);
  assert.equal(res.status, 200);
  const draft = JSON.parse((await res.json()).choices[0].message.content);
  assert.equal(draft.noneReason, "none_worthwhile");
  assert.equal(stub.calls.length, 1);
});

test("流式：SSE 心跳模式——content-type event-stream + 单个最终 chunk + [DONE]", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput(goodDraft()));
  const { app } = makeApp({}, stub);
  const res = await post(app, { stream: true });
  assert.equal(res.status, 200);
  assert.match(res.headers.get("content-type"), /text\/event-stream/);
  const body = await res.text();
  const dataLines = body.split("\n").filter((line) => line.startsWith("data: "));
  const doneLine = dataLines.find((line) => line.trim() === "data: [DONE]");
  assert.ok(doneLine, "缺少 [DONE]");
  const contentLines = dataLines.filter((line) => line !== doneLine);
  assert.equal(contentLines.length, 1, "最终内容必须是单个 chunk");
  const chunk = JSON.parse(contentLines[0].slice(6));
  const draft = JSON.parse(chunk.choices[0].delta.content);
  assert.equal(draft.selected.angleKey, "sleep×lateNight");
});

test("非法输入包：400（未知枚举域）", async () => {
  const stub = insightStub();
  const { app } = makeApp({}, stub);
  const bad = JSON.stringify({
    schemaVersion: 1, kind: "insightInput", requestId: "req-bad", window: { days: 28 },
    features: [{ id: "f_1", domain: "sports", description: "d", direction: "up", slots: [] }],
  });
  const res = await post(app, { packet: bad });
  assert.equal(res.status, 400);
  assert.equal(stub.calls.length, 0);
});

test("限流配置：purpose 走 route requestLimits（perDay=1 第二次 429）", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput(goodDraft()));
  stub.enqueue(modelOutput(goodDraft()));
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database,
    auth: { enforceAppAttest: false },
    routes: {
      discovery_insight_v2: {
        provider: "stub", model: "holo-stub", temperature: 0.4,
        maxTokens: 2048, reasoningEffort: "low",
        requestLimits: { perMinute: 100, perDay: 1 },
      },
    },
    providerOverrides: [["stub", stub.provider]],
    discovery: { insightV2Enabled: true },
  });
  const first = await post(app);
  assert.equal(first.status, 200);
  const second = await post(app);
  assert.equal(second.status, 429);
});
