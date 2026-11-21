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
import { createInsightDeliveryStore } from "../src/discovery/insightDeliveryStore.js";

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

test("数字内容：轻量修复（剥数字词）即过，不再烧重试", async () => {
  const stub = insightStub();
  const bad = goodDraft();
  bad.selected.headline = "最近三周的深夜变化";
  stub.enqueue(modelOutput(bad));
  const { app } = makeApp({}, stub);
  const res = await post(app);
  assert.equal(res.status, 200);
  const draft = JSON.parse((await res.json()).choices[0].message.content);
  assert.equal(draft.selected.headline, "最近的深夜变化");
  assert.equal(stub.calls.length, 1);
});

test("不可修复内容（未知引用）：拒因重试 → 第二次成功", async () => {
  const stub = insightStub();
  const bad = goodDraft();
  bad.selected.evidence = [{ refId: "f_ghost", template: "修不好的引用" }];
  stub.enqueue(modelOutput(bad));
  stub.enqueue(modelOutput(goodDraft()));
  const { app } = makeApp({}, stub);
  const res = await post(app);
  assert.equal(res.status, 200);
  const draft = JSON.parse((await res.json()).choices[0].message.content);
  assert.equal(draft.selected.headline, "早睡在顺带帮你省钱");
  assert.equal(stub.calls.length, 2);
  const retryUser = stub.calls[1].messages.find((m) => m.role === "user");
  assert.match(retryUser.content, /拒因=evidence_count/);
});

test("两次失败：gate_rejected，不 5xx（宁缺毋滥降级语义）", async () => {
  const stub = insightStub();
  const bad = goodDraft();
  bad.selected.evidence = [{ refId: "f_ghost", template: "修不好的引用" }];
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

test("流式：第二条证据超长且截断点在槽位中间，重写后才发出完整证据", async () => {
  const stub = insightStub();
  const valid = goodDraft();
  valid.selected.evidence.push({
    refId: "f_task_overdue",
    template: "原先逾期{overdueDays}天，近期逾期{recentDays}天",
  });
  const long = structuredClone(valid);
  const template = "原先逾期{overdueDays}天，期间也有多次临时改期，近期逾期{recentDays}天";
  assert.match(template.slice(0, 40), /\{[a-zA-Z]+$/);
  long.selected.evidence[1].template = template;
  const packet = JSON.parse(packetJSON());
  packet.features[1].slots.push({ name: "recentDays", unit: "days" });
  stub.enqueue(modelOutput(long));
  stub.enqueue(modelOutput(valid));
  const { app, database } = makeApp({}, stub);

  const response = await post(app, { packet: JSON.stringify(packet), stream: true });
  const dataLine = (await response.text()).split("\n").find((line) => line.startsWith("data: {"));
  const draft = JSON.parse(JSON.parse(dataLine.slice(6)).choices[0].delta.content);

  assert.equal(stub.calls.length, 2);
  assert.match(stub.calls[1].messages.find((message) => message.role === "user").content, /拒因=evidence_template_length/);
  assert.deepEqual(draft.selected.evidence, valid.selected.evidence);
  assert.equal(database.db.prepare("SELECT COUNT(*) c FROM insight_deliveries").get().c, 1);
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

// ============ 预算墙（2026-11-21 东林拍板：送达计数 / 7 天滚动 / 免费1 Plus5） ============

test("预算墙·免费：第 1 张送达后第 2 次请求直接 quota_exhausted，零上游调用", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput(goodDraft()));
  stub.enqueue(modelOutput(goodDraft()));
  const { app, database } = makeApp({}, stub);
  const first = await post(app);
  assert.equal(first.status, 200);
  assert.equal(JSON.parse((await first.json()).choices[0].message.content).selected.angleKey, "sleep×lateNight");
  const second = await post(app);
  assert.equal(second.status, 200);
  const draft = JSON.parse((await second.json()).choices[0].message.content);
  assert.equal(draft.selected, null);
  assert.equal(draft.noneReason, "quota_exhausted");
  assert.equal(stub.calls.length, 1, "撞墙后不得再调模型");
  // 台账只有一条送达记录
  const count = database.db.prepare("SELECT COUNT(*) c FROM insight_deliveries").get().c;
  assert.equal(count, 1);
});

test("预算墙·计数口径：none_worthwhile 与 gate_rejected 不烧名额", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput({ schemaVersion: 1, kind: "insightDraft", selected: null, noneReason: "none_worthwhile" }));
  stub.enqueue("根本不是 JSON");
  stub.enqueue("根本不是 JSON");
  stub.enqueue(modelOutput(goodDraft()));
  const { app } = makeApp({}, stub);
  const first = await post(app);
  assert.equal(JSON.parse((await first.json()).choices[0].message.content).noneReason, "none_worthwhile");
  const second = await post(app);  // 两次坏稿 → gate_rejected，未送达
  assert.equal(JSON.parse((await second.json()).choices[0].message.content).noneReason, "gate_rejected");
  const third = await post(app);   // 名额未被烧 → 仍能生成
  assert.equal(JSON.parse((await third.json()).choices[0].message.content).selected.angleKey, "sleep×lateNight");
});

test("预算墙·Plus：5 条/周，第 6 次撞墙", async () => {
  const stub = insightStub();
  for (let i = 0; i < 6; i += 1) stub.enqueue(modelOutput(goodDraft()));
  const { app, database } = makeApp({}, stub);
  database.db
    .prepare("INSERT INTO subscription_acceptance_overrides (device_id, tier, updated_at) VALUES (?, 'plus', CURRENT_TIMESTAMP)")
    .run(DEVICE);
  for (let i = 0; i < 5; i += 1) {
    const res = await post(app);
    assert.equal(JSON.parse((await res.json()).choices[0].message.content).selected.angleKey, "sleep×lateNight");
  }
  const sixth = await post(app);
  assert.equal(JSON.parse((await sixth.json()).choices[0].message.content).noneReason, "quota_exhausted");
  assert.equal(stub.calls.length, 5);
});

test("预算墙·参数：freeWeekly=0 表示不限（内测/排查用）", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput(goodDraft()));
  stub.enqueue(modelOutput(goodDraft()));
  stub.enqueue(modelOutput(goodDraft()));
  const { app } = makeApp({ discovery: { insightV2Enabled: true, insightFreeWeekly: 0 } }, stub);
  for (let i = 0; i < 3; i += 1) {
    const res = await post(app);
    assert.equal(JSON.parse((await res.json()).choices[0].message.content).selected.angleKey, "sleep×lateNight");
  }
});

// ============ 额度信息回传（2026-11-21 Plus 分层 B1） ============

test("额度回传·免费：送达带 used=1/limit=1/resetAt，撞墙带同一 resetAt", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput(goodDraft()));
  const { app } = makeApp({}, stub);
  const first = JSON.parse((await (await post(app)).json()).choices[0].message.content);
  assert.equal(first.quota.used, 1);
  assert.equal(first.quota.limit, 1);
  assert.equal(first.quota.tier, "free");
  assert.equal(typeof first.quota.resetAt, "number");
  const second = JSON.parse((await (await post(app)).json()).choices[0].message.content);
  assert.equal(second.noneReason, "quota_exhausted");
  assert.equal(second.quota.resetAt, first.quota.resetAt);
  // resetAt ≈ 送达时刻 + 7 天（允许 1 分钟误差）
  assert.ok(Math.abs(second.quota.resetAt - (Date.now() + 7 * 24 * 3600 * 1000)) < 60_000);
});

test("额度回传·Plus 未达上限：resetAt 为 null", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput(goodDraft()));
  const { app, database } = makeApp({}, stub);
  database.db
    .prepare("INSERT INTO subscription_acceptance_overrides (device_id, tier, updated_at) VALUES (?, 'plus', CURRENT_TIMESTAMP)")
    .run(DEVICE);
  const first = JSON.parse((await (await post(app)).json()).choices[0].message.content);
  assert.equal(first.quota.tier, "plus");
  assert.equal(first.quota.limit, 5);
  assert.equal(first.quota.resetAt, null);
});

test("额度回传：none_worthwhile 不带 quota", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput({ schemaVersion: 1, kind: "insightDraft", selected: null, noneReason: "none_worthwhile" }));
  const { app } = makeApp({}, stub);
  const draft = JSON.parse((await (await post(app)).json()).choices[0].message.content);
  assert.equal(draft.noneReason, "none_worthwhile");
  assert.equal(draft.quota, undefined);
});

test("nextReleaseAt：窗口内 3 条、上限 2 → 第 2 旧那条 +7 天", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  let now = 1_000_000_000_000;
  const store = createInsightDeliveryStore(database.db, { now: () => now });
  store.record("d", now - 3000);
  store.record("d", now - 2000);
  store.record("d", now - 1000);
  assert.equal(store.nextReleaseAt("d", 2, now), now - 2000 + 7 * 24 * 3600 * 1000);
  assert.equal(store.nextReleaseAt("d", 5, now), null);
  assert.equal(store.nextReleaseAt("d", 0, now), null);
});

// ============ Plus 点名看（2026-11-21 Plus 分层 B2） ============

function plusApp(stub) {
  const made = makeApp({}, stub);
  made.database.db
    .prepare("INSERT INTO subscription_acceptance_overrides (device_id, tier, updated_at) VALUES (?, 'plus', CURRENT_TIMESTAMP)")
    .run(DEVICE);
  return made;
}

test("点名看·Plus：evidence 未引用点名 feature → focus_missed 重试，第二次命中放行", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput(goodDraft())); // 引用 f_late_night，不是点名的 f_task_overdue
  const hit = goodDraft();
  hit.selected.evidence = [{ refId: "f_task_overdue", template: "其中{overdueDays}天任务逾期" }];
  stub.enqueue(modelOutput(hit));
  const { app } = plusApp(stub);
  const res = await post(app, { packet: packetJSON({ focusFeatureIds: ["f_task_overdue"] }) });
  const draft = JSON.parse((await res.json()).choices[0].message.content);
  assert.equal(draft.selected.evidence[0].refId, "f_task_overdue");
  assert.equal(stub.calls.length, 2);
  assert.match(JSON.stringify(stub.calls[1].messages), /focus_missed/);
});

test("点名看·免费：focusFeatureIds 被丢弃，不影响闸门", async () => {
  const stub = insightStub();
  stub.enqueue(modelOutput(goodDraft()));
  const { app } = makeApp({}, stub);
  const res = await post(app, { packet: packetJSON({ focusFeatureIds: ["f_task_overdue"] }) });
  const draft = JSON.parse((await res.json()).choices[0].message.content);
  assert.equal(draft.selected.angleKey, "sleep×lateNight");
  assert.equal(stub.calls.length, 1);
  // 断言收窄到 user message（packet 本体）：system prompt 因 B2-4a 的「用户点名」段落
  // 合法包含 focusFeatureIds 字样，全 messages 断言会误伤（施工图测试与 4a 内部矛盾，按意图修正）。
  const userMessage = stub.calls[0].messages.find((m) => m.role === "user");
  assert.doesNotMatch(userMessage.content, /focusFeatureIds/);
});

test("点名看：引用不存在的 feature id → 400", async () => {
  const { app } = plusApp(insightStub());
  const res = await post(app, { packet: packetJSON({ focusFeatureIds: ["f_not_exist"] }) });
  assert.equal(res.status, 400);
});
