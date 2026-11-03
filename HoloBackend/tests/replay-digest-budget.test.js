// 报告融合理解方案：回放摘要预算端到端修复专项（B01–B06，2026-10-20）。
// 覆盖两条真实轨道：
//   B01 直调 replayDigest 经守卫包装 provider（预留+结算+预算耗尽不触上游）
//   B02 云端 worker reserveDirect 显式主体（不依赖 HTTP 上下文；主体来自任务归属）
//   B03 云端预算拒绝 → 任务 failed 且 reason 携带错误码（客户端据此不回落直调）
//   B04 版本闸门对后台目的生效（含 replayDigest；minBuild 拦旧客户端）
//   B05 主动 agent_loop 不进后台集合（保护主动深度分析不被误扣/误拒）
//   B06 重复预留不免费：两次真实尝试都计费，缺 usage 保留全额预留
import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes } from "node:crypto";
import Database from "better-sqlite3";

import { createBackgroundCostGuard, backgroundSubject, BACKGROUND_PURPOSES } from "../src/usage/backgroundCostGuard.js";
import { loadConfig } from "../src/config.js";
import { createDatabase } from "../src/db/database.js";
import { createCloudAnalysisTaskStore } from "../src/agent/cloudAnalysisTaskStore.js";
import { createCloudAnalysisExecutor } from "../src/agent/cloudAnalysisExecutor.js";

const TEST_KEY = randomBytes(32).toString("base64");
const result = {
  choices: [{ message: { content: "{\"cumulativeDigest\":\"摘要\"}" }, finish_reason: "stop" }],
  usage: { prompt_tokens: 100, completion_tokens: 10 },
};
const digestRequest = {
  purpose: "replayDigest",
  messages: [{ role: "user", content: "旧摘要+本期回放素材" }],
  maxTokens: 512,
};

function setupGuard(overrides = {}, clock = Date.now, db = new Database(":memory:")) {
  const config = loadConfig({ backgroundCost: overrides }).backgroundCost;
  const guard = createBackgroundCostGuard(db, config, clock);
  return { guard, db, config };
}
const code = (expected) => (error) => error.code === expected;

function makeExecutor(provider, extras = {}) {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const executor = createCloudAnalysisExecutor({
    taskStore: store,
    providers: new Map([["fake", provider]]),
    route: { provider: "fake", model: "m", temperature: 0.2, maxTokens: 1024 },
    providerRetries: 1,
    log: () => {},
    injectedQuestionTimeResolver: { resolveQuestionTime: async () => null },
    ...extras,
  });
  return { database, store, executor };
}

test("B01 直调 replayDigest：包装 provider 预留+按 usage 结算；预算耗尽不触上游", async () => {
  const { guard, db } = setupGuard({ dailyCNY: 0.006 });
  let release;
  let calls = 0;
  const provider = guard.wrapProviders(new Map([["stub", {
    async complete() {
      calls++;
      await new Promise((resolve) => { release = resolve; });
      return result;
    },
  }]])).get("stub");

  // 首笔在途（预留占额）：第二笔同主体累计超预算 → 预留即拒，上游零触达
  const first = guard.run("subject-a", () => provider.complete(digestRequest));
  await assert.rejects(
    guard.run("subject-a", () => provider.complete(digestRequest)),
    code("BACKGROUND_BUDGET_EXCEEDED"),
  );
  assert.equal(calls, 1);
  release();
  await first;

  const row = db.prepare("SELECT purpose, charged_micro FROM background_cost_calls").get();
  assert.equal(row.purpose, "replayDigest");
  assert.equal(row.charged_micro, 390); // 100 in ×3 + 10 out ×9（元/百万token）
});

test("B02 云端 worker：reserveDirect 显式建域，主体来自任务归属（device→权益）", async () => {
  const { guard, db } = setupGuard({ dailyCNY: 0.5 });
  let calls = 0;
  const provider = { async complete() { calls++; return result; } };
  const { store, executor } = makeExecutor(provider, {
    digestRoute: { provider: "fake", model: "m", temperature: 0.2, maxTokens: 512 },
    backgroundBudget: {
      guard,
      entitlementStore: { get: () => ({ originalTransactionId: "txn-verified", environment: "Production" }) },
    },
  });

  const task = store.create({ deviceId: "device-digest", question: "replay_digest", taskType: "replay_digest" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify({ material: "素材" }) });

  assert.equal(await executor.run(task.id), "completed");
  assert.equal(calls, 1);
  const rows = db.prepare("SELECT subject, purpose FROM background_cost_calls").all();
  assert.equal(rows.length, 1);
  assert.equal(rows[0].purpose, "cloud_replay_digest");
  // 主体 = 已验证交易号派生（与直调同一主体口径，两轨共享同一额度）
  assert.equal(rows[0].subject, backgroundSubject("device-digest", {
    originalTransactionId: "txn-verified", environment: "Production",
  }));
});

test("B03 云端预算拒绝：任务 failed 且 reason 携带错误码（客户端不回落直调的依据）", async () => {
  const { guard } = setupGuard({ dailyCNY: 0.0000001 });
  const provider = { async complete() { assert.fail("预算拒绝不应触达上游"); } };
  const { store, executor } = makeExecutor(provider, {
    digestRoute: { provider: "fake", model: "m", temperature: 0.2, maxTokens: 4096 },
    backgroundBudget: { guard, entitlementStore: { get: () => null } },
  });

  const task = store.create({ deviceId: "device-digest", question: "replay_digest", taskType: "replay_digest" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify({ material: "素材" }) });

  assert.equal(await executor.run(task.id), "failed");
  const failed = store.getDecrypted(task.id, ["failureReason"]);
  assert.ok(failed.failureReason.includes("BACKGROUND_BUDGET_EXCEEDED"), failed.failureReason);
});

test("B04 版本闸门：旧客户端后台调用被 426 拦截（replayDigest 已进后台目的集合）", () => {
  const { guard } = setupGuard();
  assert.ok(BACKGROUND_PURPOSES.has("replayDigest"), "replayDigest 必须在后台目的集合（直调真实 purpose）");
  assert.throws(
    () => guard.checkIngress({ subject: "s", userAgent: "Holo/31 HoloAI/1.1.0", body: digestRequest }),
    code("BACKGROUND_CLIENT_UPDATE_REQUIRED"),
  );
  // 新构建正常通过入口检查
  guard.checkIngress({ subject: "s", userAgent: "Holo/34 HoloAI/1.1.2", body: digestRequest });
});

test("B05 主动轨道保护：agent_loop 不在后台集合，主动深度分析不预留不拦截", async () => {
  assert.equal(BACKGROUND_PURPOSES.has("agent_loop"), false);
  const { guard, db } = setupGuard({ dailyCNY: 0.0000001 });
  let calls = 0;
  const provider = guard.wrapProviders(new Map([["stub", {
    async complete() { calls++; return result; },
  }]])).get("stub");
  // 即使预算几乎为零，主动 agent_loop 也不经过预算通道
  await provider.complete({ ...digestRequest, purpose: "agent_loop" });
  assert.equal(calls, 1);
  assert.equal(db.prepare("SELECT COUNT(*) AS n FROM background_cost_calls").get().n, 0);
});

test("B06 重复预留不免费：两次真实尝试都全额计费；缺 usage 保留全额预留", async () => {
  const { guard, db } = setupGuard({ dailyCNY: 0.5 });
  const subject = "subject-b06";
  const first = guard.reserveDirect(subject, { ...digestRequest, purpose: "cloud_replay_digest" });
  guard.settleDirect(first, { prompt_tokens: 100, completion_tokens: 10 });

  // 合法上游失败后的第二次真实尝试：再次预留再次计费（重试不免费）
  const second = guard.reserveDirect(subject, { ...digestRequest, purpose: "cloud_replay_digest" });
  guard.settleDirect(second, undefined); // 缺 usage：保留全额预留不退回

  const rows = db.prepare("SELECT reserved_micro, charged_micro FROM background_cost_calls ORDER BY created_at").all();
  assert.equal(rows.length, 2);
  assert.ok(rows[0].charged_micro > 0, "有 usage 的第一笔按实结");
  assert.equal(rows[1].charged_micro, null, "缺 usage 的第二笔保留全额预留不退回");
});
