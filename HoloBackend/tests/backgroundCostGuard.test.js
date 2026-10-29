import test from "node:test";
import assert from "node:assert/strict";
import Database from "better-sqlite3";
import { createBackgroundCostGuard, backgroundSubject } from "../src/usage/backgroundCostGuard.js";
import { loadConfig } from "../src/config.js";
import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { GatewayError } from "../src/errors.js";

const request = { purpose: "personal_context_extraction", messages: [{ role: "user", content: "记忆" }], maxTokens: 100 };
const result = { choices: [{ message: { content: "{}" }, finish_reason: "stop" }],
  usage: { prompt_tokens: 100, completion_tokens: 10 } };
function setup(overrides = {}, clock = Date.now, db = new Database(":memory:")) {
  const config = loadConfig({ backgroundCost: overrides }).backgroundCost;
  const guard = createBackgroundCostGuard(db, config, clock);
  return { guard, db, config };
}
function wrap(guard, provider) { return guard.wrapProviders(new Map([["stub", provider]])).get("stub"); }
const code = (expected) => (error) => error.code === expected;

test("并发先预留，第二笔超预算不会触达上游；完成后按 usage 释放差额", async () => {
  const { guard, db } = setup({ dailyCNY: 0.002 });
  let release;
  let calls = 0;
  const provider = wrap(guard, { async complete() {
    calls++;
    await new Promise((resolve) => { release = resolve; });
    return result;
  } });
  const first = guard.run("u1", () => provider.complete(request));
  await assert.rejects(guard.run("u1", () => provider.complete(request)), code("BACKGROUND_BUDGET_EXCEEDED"));
  assert.equal(calls, 1);
  release(); await first;
  assert.equal(db.prepare("SELECT charged_micro FROM background_cost_calls").get().charged_micro, 390);
});

test("无 usage/失败不会退款，重建 guard 后预算仍占用", async () => {
  const { guard, db, config } = setup({ dailyCNY: 0.002 });
  const provider = wrap(guard, { async complete() { throw new Error("timeout"); } });
  await assert.rejects(guard.run("u1", () => provider.complete(request)), /timeout/);
  const restarted = createBackgroundCostGuard(db, config);
  const next = wrap(restarted, { async complete() { assert.fail("不应调用"); } });
  await assert.rejects(restarted.run("u1", () => next.complete(request)), code("BACKGROUND_BUDGET_EXCEEDED"));
});

test("月预算跨北京时间午夜保留，下月恢复；全局预算阻止换设备继续调用", async () => {
  let time = Date.parse("2026-10-14T23:59:00+08:00");
  const { guard } = setup({ monthlyCNY: 0.002, globalDailyCNY: 0.002 }, () => time);
  const provider = wrap(guard, { async complete() { return {}; } });
  await guard.run("u1", () => provider.complete(request));
  await assert.rejects(guard.run("u2", () => provider.complete(request)), code("BACKGROUND_BUDGET_EXCEEDED"));
  time += 120_000;
  await assert.rejects(guard.run("u1", () => provider.complete(request)), code("BACKGROUND_BUDGET_EXCEEDED"));
  time = Date.parse("2026-11-01T00:00:00+08:00");
  await guard.run("u1", () => provider.complete(request));
});

// 2026-10-30 拆池：后台整理池烧穿不得连坐「一个发现」（10-28 事故：月池 ¥2 已耗 ¥200，
// 发现首跑 candidate 必 429）。发现池 subject 级独立限额；global 级仍聚合全部兜底。
test("拆池：后台月池烧穿不连坐发现调用", async () => {
  const time = Date.parse("2026-10-30T10:00:00+08:00");
  const { guard } = setup({ monthlyCNY: 0.002, globalDailyCNY: 10, globalMonthlyCNY: 60 }, () => time);
  const discoveryRequest = { ...request, purpose: "discovery_candidate_v1" };
  const provider = wrap(guard, { async complete() { return {}; } });
  await guard.run("u1", () => provider.complete(request));
  await assert.rejects(guard.run("u1", () => provider.complete(request)), code("BACKGROUND_BUDGET_EXCEEDED"));
  await guard.run("u1", () => provider.complete(discoveryRequest));
});

test("拆池：发现池独立烧穿只拒发现，后台整理不受影响", async () => {
  const time = Date.parse("2026-10-30T10:00:00+08:00");
  const { guard } = setup({ discoveryMonthlyCNY: 0.002, monthlyCNY: 10, globalDailyCNY: 10, globalMonthlyCNY: 60 }, () => time);
  const provider = wrap(guard, { async complete() { return {}; } });
  await guard.run("u1", () => provider.complete({ ...request, purpose: "discovery_candidate_v1" }));
  await assert.rejects(guard.run("u1", () => provider.complete({ ...request, purpose: "discovery_verify_v1" })), code("BACKGROUND_BUDGET_EXCEEDED"));
  await guard.run("u1", () => provider.complete(request));
});

test("拆池：global 总池耗尽时两个池都被拒（全服止损不拆）", async () => {
  const time = Date.parse("2026-10-30T10:00:00+08:00");
  const { guard } = setup({ monthlyCNY: 10, discoveryMonthlyCNY: 10, globalMonthlyCNY: 0.002 }, () => time);
  const provider = wrap(guard, { async complete() { return {}; } });
  await guard.run("u1", () => provider.complete(request));
  await assert.rejects(guard.run("u1", () => provider.complete({ ...request, purpose: "discovery_candidate_v1" })), code("BACKGROUND_BUDGET_EXCEEDED"));
  await assert.rejects(guard.run("u1", () => provider.complete(request)), code("BACKGROUND_BUDGET_EXCEEDED"));
});

test("跨设备同一已验证交易共享主体；切换验收状态不重置无订阅设备", () => {
  const purchase = { originalTransactionId: "verified-id", environment: "Production" };
  assert.equal(backgroundSubject("d1", purchase), backgroundSubject("d2", purchase));
  assert.equal(backgroundSubject("d1", {}), backgroundSubject("d1", { tier: "plus" }));
  assert.notEqual(backgroundSubject("d1", {}), backgroundSubject("d2", {}));
});

test("上游前检查完整 Prompt 长度；没有服务端主体的后台调用拒绝执行", async () => {
  const { guard } = setup({ maxInputBytes: 100 });
  const provider = wrap(guard, { async complete() { assert.fail("不应调用"); } });
  await assert.rejects(guard.run("u1", () => provider.complete({ ...request,
    messages: [{ role: "system", content: "长".repeat(100) }] })), code("BACKGROUND_INPUT_TOO_LARGE"));
  await assert.rejects(provider.complete(request), code("BACKGROUND_CONTEXT_REQUIRED"));
});

test("内部流式与外部 SSE 分片均结算；推理不重复计费，缓存折价保留", async () => {
  const { guard, db } = setup();
  const usage = { prompt_tokens: 100, completion_tokens: 10,
    prompt_cache_hit_tokens: 80, completion_tokens_details: { reasoning_tokens: 10 } };
  const sse = `data: ${JSON.stringify({ usage })}\r\n\r\ndata: [DONE]\n\n`;
  const provider = wrap(guard, {
    async completeViaStream() { return { usage }; },
    async *stream() { yield sse.slice(0, 9); yield sse.slice(9, 31); yield sse.slice(31); },
  });
  await guard.run("u1", () => provider.completeViaStream(request));
  await guard.run("u1", async () => { for await (const chunk of provider.stream(request)) assert.ok(chunk); });
  assert.deepEqual(db.prepare("SELECT charged_micro FROM background_cost_calls").all().map(r => r.charged_micro), [158, 158]);
});

test("断流保留预留；主动聊天不经过后台预算", async () => {
  const { guard, db } = setup();
  const provider = wrap(guard, {
    async *stream() { yield 'data: {"choices":[]}\n\n'; throw new Error("broken"); },
    async complete() { return result; },
  });
  await assert.rejects(guard.run("u1", async () => {
    for await (const chunk of provider.stream(request)) assert.ok(chunk);
  }), /broken/);
  await provider.complete({ ...request, purpose: "chat" });
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM background_cost_calls").get().n, 1);
  assert.equal(db.prepare("SELECT charged_micro FROM background_cost_calls").get().charged_micro, null);
});

test("同一类别失败持久冷却，改内容可再试，24 小时后释放", async () => {
  let time = Date.parse("2026-10-14T23:00:00+08:00");
  const { guard, db, config } = setup({}, () => time);
  let calls = 0;
  const fail = async () => { calls++; throw new GatewayError("MODEL_OUTPUT_INVALID", "quote", 502); };
  await assert.rejects(guard.briefAttempt(["u1", "证据"], fail), code("MODEL_OUTPUT_INVALID"));
  const restarted = createBackgroundCostGuard(db, config, () => time);
  await assert.rejects(restarted.briefAttempt(["u1", "证据"], fail), code("BACKGROUND_RETRY_DEFERRED"));
  await assert.rejects(restarted.briefAttempt(["u1", "新证据"], fail), code("MODEL_OUTPUT_INVALID"));
  assert.equal(calls, 2);
  time += 86400_001;
  await assert.rejects(restarted.briefAttempt(["u1", "证据"], fail), code("MODEL_OUTPUT_INVALID"));
  assert.equal(calls, 3);
});

function makeApp(overrides = {}) {
  let calls = 0;
  let moderationCalls = 0;
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createApp({ database, auth: { enforceAppAttest: false, enforceDeviceSession: false },
    contentModeration: { isEnabled: () => true, moderate: async () => { moderationCalls++; return { passed: true }; } },
    routes: { personal_context_extraction: { provider: "stub", model: "unchanged", maxTokens: 100 },
      chat: { provider: "stub", model: "unchanged", maxTokens: 100 } },
    providerOverrides: new Map([["stub", { async complete() { calls++; return result; } }]]),
    ...overrides });
  return { app, db: database.db, calls: () => calls, moderationCalls: () => moderationCalls };
}
function post(app, body, userAgent = "Holo/33", path = "/v1/ai/chat/completions") {
  return app.request(path, { method: "POST", headers: { "content-type": "application/json",
    "user-agent": userAgent, "x-holo-device-id": "cost-test" }, body: JSON.stringify(body) });
}

test("HTTP 回归：Holo/31 后台在审核与模型前拦截，主动聊天和新构建仍可用", async () => {
  const s = makeApp();
  const old = await post(s.app, request, "Holo/31 CFNetwork/test");
  assert.equal(old.status, 426);
  assert.equal((await old.json()).error.code, "BACKGROUND_CLIENT_UPDATE_REQUIRED");
  assert.equal(s.calls(), 0); assert.equal(s.moderationCalls(), 0);
  assert.equal((await post(s.app, { ...request, purpose: "chat" }, "Holo/31")).status, 200);
  assert.equal((await post(s.app, request)).status, 200);
  assert.equal(s.calls(), 2);
  assert.equal(s.db.prepare("SELECT COUNT(*) AS n FROM background_cost_calls").get().n, 1);
});

test("HTTP 回归：缺少 UA 也不能绕过实际输入上限或费用预留", async () => {
  const s = makeApp({ backgroundCost: { maxInputBytes: 1024 } });
  const long = await post(s.app, { ...request, messages: [{ role: "user", content: "想法".repeat(1000) }] }, "");
  assert.equal(long.status, 413);
  assert.equal(s.calls(), 0); assert.equal(s.moderationCalls(), 0);
});

test("HTTP 类别回归：换 operationId 重试伪造引用，不再付费；非法 JSON 也正确结算", async () => {
  for (const output of ['{"brief":{"definition":"日常","exclusions":[]},"evidence":[{"ref":"R0","quote":"伪造引用"}]}', "not-json"]) {
    let calls = 0;
    const s = makeApp({ thoughtSemanticRelate: { privacyVerified: true },
      routes: { thought_category_brief_v1: { provider: "stub", model: "unchanged", maxTokens: 600 } },
      providerOverrides: new Map([["stub", { async complete() {
        calls++;
        return { ...result, choices: [{ message: { content: output } }] };
      } }]]) });
    const body = { schemaVersion: 1, operationId: "first", engineVersion: "v1", topic: { title: "碎碎念" },
      members: [0, 1, 2].map(i => ({ ref: `R${i}`, text: "今天喂了猫", source: "user" })), removals: [] };
    const first = await post(s.app, body, "Holo/33", "/v1/thoughts/category-brief");
    assert.equal(first.status, 502);
    const again = await post(s.app, { ...body, operationId: "second" }, "Holo/33", "/v1/thoughts/category-brief");
    assert.equal(again.status, 429);
    assert.equal((await again.json()).error.code, "BACKGROUND_RETRY_DEFERRED");
    assert.equal(calls, 1);
    assert.equal(s.moderationCalls(), 1);
    assert.equal(s.db.prepare("SELECT charged_micro FROM background_cost_calls").get().charged_micro, 390);
  }
});
