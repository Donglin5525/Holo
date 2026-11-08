// v3「一个发现」选题端点契约测试（2026-11-08 方案 §5.2）。
// 覆盖：kill switch/输入闸/幂等重放与冲突/七条护栏（含修复层）/none 分支/
// recentTopics 预过滤/降级语义（两次坏不 5xx）/purpose 域注册。
// 契约真源：本文件的响应形状断言即 iOS 侧消费契约（Swift 侧 *ContractTests 对拍）。
import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { createDatabase } from "../src/db/database.js";
import { backgroundPathPurpose } from "../src/usage/backgroundCostGuard.js";

const DEVICE = "11111111-2222-4333-8444-555555555555";

function topicStub() {
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
          id: "stub-topic",
          choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
          usage: { prompt_tokens: 800, completion_tokens: 120 },
        };
      },
    },
  };
}

function candidate(overrides = {}) {
  return {
    id: "obs-7",
    domain: "finance",
    kind: "categoryCompare",
    direction: "higher",
    label: "晚餐",
    freshness: "new",
    windowWeeks: 4,
    matchWeeks: 3,
    recordDays: 11,
    slots: ["weeks", "matchWeeks", "label", "avgWeekday", "avgWeekend"],
    topicKey: "finance-category:dinner",
    ...overrides,
  };
}

function goodSelection() {
  return {
    selected: {
      observationId: "obs-7",
      angle: "contrast",
      reasonCode: "recent_change",
      titleTemplate: "工作日的{label}，悄悄变贵了",
      bodyTemplate: "最近{weeks}周里，有{matchWeeks}周你工作日的{label}日均花销高于同周周末。",
    },
    noneReason: null,
  };
}

function makeApp(overrides = {}, stub = topicStub()) {
  const db = createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database: db,
    auth: { enforceAppAttest: false },
    routes: {
      discovery_topic_v1: {
        provider: "stub", model: "holo-mock", temperature: 0.5,
        maxTokens: 2048, reasoningEffort: "none",
        requestLimits: { perMinute: 100, perDay: 1000 },
      },
    },
    providerOverrides: [["stub", stub.provider]],
    discovery: { enabled: false, topicEnabled: true },
    ...overrides,
  });
  return { app, database: db, stub };
}

async function post(app, body, deviceId = DEVICE) {
  return app.request("/v1/discovery/topic", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": deviceId },
    body: JSON.stringify(body),
  });
}

function baseBody(extra = {}) {
  return {
    requestId: `req-${Math.random().toString(36).slice(2, 10)}`,
    language: "zh-Hans",
    poolFingerprint: "a".repeat(40),
    recentTopics: [],
    candidates: [candidate()],
    ...extra,
  };
}

test("kill switch：topicEnabled 默认关 → 503 DISCOVERY_TOPIC_DISABLED", async () => {
  const { app } = makeApp({ discovery: { enabled: false, topicEnabled: false } });
  const res = await post(app, baseBody());
  assert.equal(res.status, 503);
  assert.equal((await res.json()).error.code, "DISCOVERY_TOPIC_DISABLED");
});

test("正常选题：模型输出合格 → 200 + 契约形状 + 幂等账本落 completed", async () => {
  const stub = topicStub();
  stub.enqueue(JSON.stringify(goodSelection()));
  const { app, database } = makeApp({}, stub);
  const body = baseBody();
  const res = await post(app, body);
  assert.equal(res.status, 200);
  const json = await res.json();
  assert.equal(json.protocolVersion, 1);
  assert.equal(json.status, "completed");
  assert.equal(json.replayed, undefined);
  assert.equal(json.selection.observationId, "obs-7");
  assert.equal(json.selection.angle, "contrast");
  assert.equal(json.selection.titleTemplate, "工作日的{label}，悄悄变贵了");
  assert.equal(json.noneReason, null);
  assert.equal(typeof json.promptVersion, "number");
  const row = database.db.prepare("SELECT status, subject FROM discovery_requests WHERE request_id = ?").get(body.requestId);
  assert.equal(row.status, "completed");
  assert.ok(row.subject.length > 0);
});

test("幂等重放：同 requestId 同 body → replayed:true 且模型只调一次", async () => {
  const stub = topicStub();
  stub.enqueue(JSON.stringify(goodSelection()));
  const { app } = makeApp({}, stub);
  const body = baseBody();
  const first = await post(app, body);
  assert.equal(first.status, 200);
  const second = await post(app, body);
  assert.equal(second.status, 200);
  const json = await second.json();
  assert.equal(json.replayed, true);
  assert.equal(json.selection.observationId, "obs-7");
  assert.equal(stub.calls.length, 1);
});

test("幂等冲突：同 requestId 换 body → 409", async () => {
  const stub = topicStub();
  stub.enqueue(JSON.stringify(goodSelection()));
  const { app } = makeApp({}, stub);
  const body = baseBody();
  await post(app, body);
  const conflict = await post(app, { ...body, candidates: [candidate({ id: "obs-8" })] });
  assert.equal(conflict.status, 409);
  assert.equal((await conflict.json()).error.code, "DISCOVERY_REQUEST_CONFLICT");
});

test("护栏·未知观察：模型选了不存在的 id → 带拒因重试一次，仍坏则降级不 5xx", async () => {
  const stub = topicStub();
  stub.enqueue(JSON.stringify({ selected: { ...goodSelection().selected, observationId: "obs-999" }, noneReason: null }));
  stub.enqueue(JSON.stringify({ selected: { ...goodSelection().selected, observationId: "obs-888" }, noneReason: null }));
  const { app } = makeApp({}, stub);
  const res = await post(app, baseBody());
  assert.equal(res.status, 200);
  const json = await res.json();
  assert.equal(json.selection, null);
  assert.equal(json.noneReason, "insufficient_shape");
  assert.equal(json.degraded, true);
  assert.equal(stub.calls.length, 2);
});

test("护栏·越界槽位：slots 外空位 → 修复层剥离后可过或降级（不裸放行）", async () => {
  const stub = topicStub();
  const bad = goodSelection();
  bad.selected.bodyTemplate = "最近{weeks}周里，有{matchWeeks}周你工作日的{label}日均花销高于同周周末，幅度约{madeUpRatio}。";
  stub.enqueue(JSON.stringify(bad));
  const { app } = makeApp({}, stub);
  const res = await post(app, baseBody());
  assert.equal(res.status, 200);
  const json = await res.json();
  // madeUpRatio 不在 slots：修复层剥离后正文仍合法（数字全空位化）→ 通过且不含越界槽位
  if (json.selection) {
    assert.ok(!json.selection.bodyTemplate.includes("madeUpRatio"));
  } else {
    assert.equal(json.degraded, true);
  }
});

test("护栏·裸数字：模板夹带数字 → 修复层剥离（剥离后无数字残留）", async () => {
  const stub = topicStub();
  const bad = goodSelection();
  bad.selected.bodyTemplate = "最近{weeks}周里，有3周你工作日的{label}日均花销高于同周周末。";
  stub.enqueue(JSON.stringify(bad));
  const { app } = makeApp({}, stub);
  const res = await post(app, baseBody());
  assert.equal(res.status, 200);
  const json = await res.json();
  assert.ok(json.selection, "剥离裸数字后应通过");
  assert.ok(!json.selection.bodyTemplate.includes("3周"));
});

test("护栏·方向冲突：direction=higher 写「低于」→ 降级", async () => {
  const stub = topicStub();
  const bad = goodSelection();
  bad.selected.bodyTemplate = "最近{weeks}周里，有{matchWeeks}周你工作日的{label}日均花销低于同周周末。";
  stub.enqueue(JSON.stringify(bad));
  stub.enqueue(JSON.stringify(bad));
  const { app } = makeApp({}, stub);
  const res = await post(app, baseBody());
  const json = await res.json();
  assert.equal(json.selection, null);
  assert.equal(json.degraded, true);
});

test("护栏·超长：正文模板超限 → 降级", async () => {
  const stub = topicStub();
  const bad = goodSelection();
  bad.selected.bodyTemplate = "最近{weeks}周里".repeat(25) + "你工作日的{label}日均花销高于同周周末，这个句子被故意写得非常长来触发长度护栏的拒绝路径。";
  stub.enqueue(JSON.stringify(bad));
  stub.enqueue(JSON.stringify(bad));
  const { app } = makeApp({}, stub);
  const res = await post(app, baseBody());
  const json = await res.json();
  assert.equal(json.degraded, true);
});

test("none 分支：模型判无值得看 → noneReason 透传", async () => {
  const stub = topicStub();
  stub.enqueue(JSON.stringify({ selected: null, noneReason: "none_worthwhile" }));
  const { app } = makeApp({}, stub);
  const res = await post(app, baseBody());
  const json = await res.json();
  assert.equal(json.selection, null);
  assert.equal(json.noneReason, "none_worthwhile");
  assert.equal(json.degraded, undefined);
});

test("recentTopics 预过滤：全部命中已展示命题 → 不调模型直接 all_stale", async () => {
  const stub = topicStub();
  const { app } = makeApp({}, stub);
  const res = await post(app, baseBody({ recentTopics: ["finance-category:dinner"] }));
  const json = await res.json();
  assert.equal(json.noneReason, "all_stale");
  assert.equal(stub.calls.length, 0);
});

test("输入闸：31 条候选 → 400；domain 非法 → 400；id 含中文 → 400", async () => {
  const { app } = makeApp();
  const tooMany = baseBody({ candidates: Array.from({ length: 31 }, (_, i) => candidate({ id: `obs-${i}`, topicKey: `k${i}` })) });
  assert.equal((await post(app, tooMany)).status, 400);
  const badDomain = baseBody({ candidates: [candidate({ domain: "secret" })] });
  assert.equal((await post(app, badDomain)).status, 400);
  const badId = baseBody({ candidates: [candidate({ id: "观察一" })] });
  assert.equal((await post(app, badId)).status, 400);
});

test("purpose 域：路径解析注册进发现池（预算共池）", () => {
  assert.equal(backgroundPathPurpose("/v1/discovery/topic"), "discovery_topic_v1");
});

test("配置：路由默认跟随聊天通道，maxTokens=2048，reasoningEffort=none", () => {
  const config = loadConfig();
  const route = config.routes.discovery_topic_v1;
  assert.equal(route.provider, process.env.HOLO_CHAT_PROVIDER ?? "mock");
  assert.equal(route.maxTokens, 2048);
  assert.equal(route.reasoningEffort, "none");
  assert.equal(config.discovery.topicEnabled, false);
});
