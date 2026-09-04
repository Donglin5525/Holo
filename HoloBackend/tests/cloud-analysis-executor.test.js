import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes } from "node:crypto";

import { createDatabase } from "../src/db/database.js";
import { createCloudAnalysisTaskStore } from "../src/agent/cloudAnalysisTaskStore.js";
import { createCloudAnalysisExecutor } from "../src/agent/cloudAnalysisExecutor.js";
import { createCloudAnalysisQueryEngine } from "../src/agent/cloudAnalysisQueryEngine.js";
import { insightMaxTokensFor } from "../src/config.js";

const TEST_KEY = randomBytes(32).toString("base64");

const SNAPSHOT = {
  version: 1,
  datasets: {
    "finance.transactions": {
      fields: [
        { name: "date", type: "date" },
        { name: "category", type: "text" },
        { name: "merchant", type: "text" },
        { name: "amount", type: "number", unit: "元" },
      ],
      rows: [
        { date: "2026-08-01", category: "餐饮", merchant: "麦当劳", amount: -32 },
        { date: "2026-08-02", category: "餐饮", merchant: "星巴克", amount: -42 },
        { date: "2026-08-03", category: "交通", merchant: "滴滴", amount: -18 },
        { date: "2026-08-04", category: "餐饮", merchant: "麦当劳", amount: -28 },
        { date: "2026-08-05", category: "购物", merchant: "京东", amount: -199 },
      ],
    },
  },
  statics: {
    profile: { nickname: "测试用户", timezone: "Asia/Shanghai" },
  },
};

function agentJson(status, extra = {}) {
  return JSON.stringify({ status, reasoning: "r", toolRequests: [], claims: [], warnings: [], ...extra });
}

function makeProvider(responses) {
  const calls = [];
  return {
    calls,
    async complete(request) {
      calls.push(request);
      const next = responses.shift();
      if (!next) throw new Error("PROVIDER_EXHAUSTED");
      return {
        choices: [{ index: 0, message: { role: "assistant", content: next }, finish_reason: "stop" }],
        usage: { prompt_tokens: 10, completion_tokens: 5 },
      };
    },
  };
}

function makeExecutor(provider, extras = {}) {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const executor = createCloudAnalysisExecutor({
    taskStore: store,
    providers: new Map([["fake", provider]]),
    route: { provider: "fake", model: "m", temperature: 0.2, maxTokens: 1024 },
    providerRetries: 1,
    log: () => {},
    ...extras,
  });
  return { database, store, executor };
}

// —— 周期回放（period_replay）单轮生成（2026-09-01 云端化统一）——

function makeQuotaLedger({ allowed = true } = {}) {
  const calls = { commit: 0, release: 0 };
  return {
    calls,
    reserve() {
      return allowed
        ? { allowed: true, subjectId: "s", tier: "free", quotaType: "memoryInsight", actionId: "a", periodKey: "p" }
        : { allowed: false, reason: "quota_exceeded", userMessage: "本周洞察额度已用完" };
    },
    commit() { calls.commit += 1; },
    release() { calls.release += 1; },
  };
}

const RESOLVER = { resolve: () => ({ usageSubjectId: "subj-1", tier: "free" }) };

test("period_replay：素材→单轮生成→complete+推送「回放已生成」+额度提交", async () => {
  const provider = makeProvider([
    JSON.stringify({ status: "final_claims" }),
  ]);
  // period_replay 不走 Agent 循环——第一轮 provider 响应直接作为生成输出
  const pushes = [];
  const quota = makeQuotaLedger();
  const { store, executor } = makeExecutor(provider, {
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
    pushNotifier: { notifyTaskCompleted: async (deviceId, payload) => pushes.push({ deviceId, payload }) },
  });

  const task = store.create({ deviceId: "device-replay", question: "本月", taskType: "period_replay" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify({ period: "2026-08", summary: "素材含健康摘要" }) });

  assert.equal(await executor.run(task.id), "completed");
  const result = JSON.parse(store.getDecrypted(task.id, ["result"]).result);
  assert.equal(result.kind, "period_replay");
  assert.equal(result.output, JSON.stringify({ status: "final_claims" }));
  // 额度：提交且未释放
  assert.equal(quota.calls.commit, 1);
  assert.equal(quota.calls.release, 0);
  // 推送文案区分任务类型
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].payload.title, "回放已生成");
  // 完成即焚仍适用
  assert.ok(store.isDataDestroyed(task.id));
});

test("period_replay：额度不足→直接 failed（不调模型、失败原因回传）", async () => {
  const provider = makeProvider([]);
  const quota = makeQuotaLedger({ allowed: false });
  const { store, executor } = makeExecutor(provider, {
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
  });
  const task = store.create({ deviceId: "d", question: "本月", taskType: "period_replay" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify({ p: 1 }) });

  assert.equal(await executor.run(task.id), "failed");
  assert.equal(provider.calls.length, 0, "额度不足不得调用模型");
  const row = store.getDecrypted(task.id, ["failureReason"]);
  assert.ok(row.failureReason.includes("额度"));
});

test("period_replay：生成失败→额度释放+failed", async () => {
  const provider = makeProvider([]); // provider 立即耗尽 → 抛错
  const quota = makeQuotaLedger();
  const { store, executor } = makeExecutor(provider, {
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
  });
  const task = store.create({ deviceId: "d", question: "本月", taskType: "period_replay" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify({ p: 1 }) });

  assert.equal(await executor.run(task.id), "failed");
  assert.equal(quota.calls.release, 1);
  assert.equal(quota.calls.commit, 0);
});

test("period_replay：素材缺失→failed 不进 running", async () => {
  const provider = makeProvider([]);
  const { store, executor } = makeExecutor(provider);
  const task = store.create({ deviceId: "d", question: "本月", taskType: "period_replay" });
  // 不上传素材直接触发（模拟启动扫描孤儿）
  store.transition(task.id, "queued");
  assert.equal(await executor.run(task.id), "failed");
});

// —— 回放摘要归纳（replay_digest，2026-09-05 摘要云端化）——

test("replay_digest：素材→单轮生成→complete+即焚；走 digestRoute、不推送不碰额度", async () => {
  const provider = makeProvider(['{"cumulativeDigest":"8月吃了5次麦当劳","coveredRangeStart":"2026-08-01","coveredRangeEnd":"2026-08-31","keyPatterns":[],"trackedGoals":[]}']);
  const quota = makeQuotaLedger();
  const pushes = [];
  const { store, executor } = makeExecutor(provider, {
    digestRoute: { provider: "fake", model: "digest-m", temperature: 0.2, maxTokens: 4096, reasoningEffort: "low" },
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
    pushNotifier: { notifyTaskCompleted: async (deviceId, payload) => pushes.push(payload) },
  });

  const material = JSON.stringify({ oldDigest: "7月…", newReplay: { title: "8月回放" } });
  const task = store.create({ deviceId: "device-digest", question: "replay_digest", taskType: "replay_digest" });
  store.attachSnapshot({ id: task.id, snapshot: material });

  assert.equal(await executor.run(task.id), "completed");
  // 路由选择：digestRoute 的 model 与 low 思考档到达 provider（与 direct 调用同档位）
  assert.equal(provider.calls.length, 1);
  assert.equal(provider.calls[0].model, "digest-m");
  assert.equal(provider.calls[0].reasoningEffort, "low");
  const result = JSON.parse(store.getDecrypted(task.id, ["result"]).result);
  assert.equal(result.kind, "replay_digest");
  assert.ok(result.output.includes("cumulativeDigest"));
  // 静默维护：无推送、无会员额度
  assert.equal(pushes.length, 0);
  assert.equal(quota.calls.commit, 0);
  assert.equal(quota.calls.release, 0);
  // 完成即焚仍适用
  assert.ok(store.isDataDestroyed(task.id));
});

test("replay_digest：空输出→failed；素材缺失→failed 不进 running", async () => {
  const provider = makeProvider(["   "]);
  const { store, executor } = makeExecutor(provider);
  const task = store.create({ deviceId: "d", question: "replay_digest", taskType: "replay_digest" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify({ oldDigest: null }) });

  assert.equal(await executor.run(task.id), "failed");
  const row = store.getDecrypted(task.id, ["failureReason"]);
  assert.ok(row.failureReason.includes("摘要"));

  const provider2 = makeProvider([]);
  const { store: store2, executor: executor2 } = makeExecutor(provider2);
  const task2 = store2.create({ deviceId: "d", question: "replay_digest", taskType: "replay_digest" });
  store2.transition(task2.id, "queued");
  assert.equal(await executor2.run(task2.id), "failed");
});

test("查询引擎：filter+groupBy+sum 输出 iOS 同构结构", () => {
  const engine = createCloudAnalysisQueryEngine();
  const result = engine.execute({
    source: "finance.transactions",
    filters: [{ field: "category", operation: "equal", value: { type: "text", text: "餐饮" } }],
    groupBy: [{ type: "field", field: "merchant" }],
    aggregations: [
      { id: "total", operation: "sum", field: "amount", unit: "元" },
      { id: "times", operation: "count" },
    ],
    derivations: [],
    limit: 10,
    evidenceLimit: 5,
  }, SNAPSHOT, { toolRequestID: "t1", tool: "finance" });
  assert.equal(result.status, "success");
  assert.equal(result.toolRequestID, "t1");
  const byKey = {};
  for (const metric of result.metrics) {
    if (metric.metricKey.includes(".total.")) byKey[metric.comparison] = metric.value;
  }
  assert.equal(byKey["麦当劳"], -60);
  assert.equal(byKey["星巴克"], -42);
  // metricKey iOS 格式：dynamic.{source}.{id}.{group}，sanitize 为小写
  assert.ok(result.metrics[0].metricKey.startsWith("dynamic.finance_transactions.total."));
  // evidence 摘要为 iOS evidenceText 格式
  assert.ok(result.events[0].excerpt.includes("动态计算 dynamic."));
  assert.ok(result.events[0].excerpt.includes("公式："));
});

test("查询引擎：oneOf 与数值比较 + distinctCount", () => {
  const engine = createCloudAnalysisQueryEngine();
  const result = engine.execute({
    source: "finance.transactions",
    filters: [{
      field: "amount",
      operation: "lessThanOrEqual",
      value: { type: "number", number: -40 },
    }],
    groupBy: [],
    aggregations: [{ id: "merchants", operation: "distinctCount", field: "merchant" }],
    derivations: [],
    limit: 10,
    evidenceLimit: 5,
  }, SNAPSHOT);
  assert.equal(result.status, "success");
  assert.equal(result.metrics[0].value, 2);
  assert.equal(result.metrics[0].comparison, null);
});

test("查询引擎：expression/linearTrend/coverage 明确拒绝（模型降级换路）", () => {
  const engine = createCloudAnalysisQueryEngine();
  const result = engine.execute({
    source: "finance.transactions",
    filters: [],
    groupBy: [],
    aggregations: [{ id: "a", operation: "sum", field: "amount" }],
    derivations: [{ id: "d", operation: "expression" }],
    limit: 5,
    evidenceLimit: 5,
  }, SNAPSHOT);
  assert.equal(result.status, "error");
  assert.equal(result.error.code, "NOT_SUPPORTED_BY_CLOUD");
  assert.equal(result.error.recoverable, true);
});

test("执行器全循环：need_tools→工具结果→final_claims→完成即焚", async () => {
  const provider = makeProvider([
    agentJson("need_tools", {
      toolRequests: [{
        id: "t1",
        tool: "finance",
        query: "dynamic_query",
        parameters: {
          dynamicPlan: {
            source: "finance.transactions",
            filters: [],
            groupBy: [{ type: "field", field: "category" }],
            aggregations: [{ id: "cat_total", operation: "sum", field: "amount", unit: "元" }],
            derivations: [],
            limit: 10,
            evidenceLimit: 10,
          },
        },
      }],
    }),
    agentJson("final_claims", {
      claims: [{
        summary: "本月餐饮 102 元",
        displayText: "本月餐饮支出合计 102 元",
        metricAssertions: [],
        evidenceIDs: ["finance.transactions#0"],
      }],
    }),
  ]);
  const { store, executor } = makeExecutor(provider);

  const task = store.create({ deviceId: "device-a", question: "分析我的支出结构" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(SNAPSHOT) });

  const status = await executor.run(task.id);
  assert.equal(status, "completed");

  // 模型收到了工具结果（含分组聚合值）
  const toolTurn = provider.calls[1].messages.find((m) => m.content?.startsWith("toolResults:"));
  assert.ok(toolTurn, "第二轮应携带 toolResults");
  const toolPayload = JSON.parse(toolTurn.content.slice("toolResults: ".length));
  assert.equal(toolPayload[0].status, "success");
  assert.equal(toolPayload[0].toolRequestID, "t1");
  assert.ok(toolPayload[0].metrics.length > 0);
  assert.ok(toolPayload[0].metrics[0].metricKey.startsWith("dynamic."));

  // 完成即焚：问题与快照密文清空，结果仍在等回传
  assert.ok(store.isDataDestroyed(task.id));
  const row = store.get(task.id);
  assert.notEqual(row.result_ciphertext, null);

  // 结果可解密回传
  const fetched = store.getDecrypted(task.id, ["result"]);
  const result = JSON.parse(fetched.result);
  assert.equal(result.claims.length, 1);
  assert.equal(result.engine, "cloud-m2a");
});

test("执行器：静态块直读 + 未知数据集返回可解释错误", async () => {
  const provider = makeProvider([
    agentJson("need_tools", {
      toolRequests: [
        { id: "t1", tool: "profile", query: "static", parameters: {} },
        { id: "t2", tool: "finance", query: "dynamic_query", parameters: { dynamicPlan: { source: "no.such.dataset", filters: [], groupBy: [], aggregations: [{ id: "a", operation: "count" }], derivations: [] } } },
      ],
    }),
    agentJson("final_claims", { claims: [] }),
  ]);
  const { store, executor } = makeExecutor(provider);
  const task = store.create({ deviceId: "d", question: "q" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(SNAPSHOT) });

  assert.equal(await executor.run(task.id), "completed");
  const toolTurn = provider.calls[1].messages.find((m) => m.content?.startsWith("toolResults:"));
  const payload = JSON.parse(toolTurn.content.slice("toolResults: ".length));
  assert.equal(payload[0].status, "success");
  assert.equal(payload[0].result.nickname, "测试用户");
  assert.equal(payload[1].status, "error");
  assert.equal(payload[1].error.code, "INVALID_DATASET");
});

test("执行器：provider 连续失败→任务 failed 且输入即焚", async () => {
  const provider = makeProvider([]); // 立即耗尽 → 全部重试失败
  const { store, executor } = makeExecutor(provider);
  const task = store.create({ deviceId: "d", question: "q" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(SNAPSHOT) });

  assert.equal(await executor.run(task.id), "failed");
  const row = store.getDecrypted(task.id, ["failureReason"]);
  assert.ok(row.failureReason.includes("云端执行失败"));
  assert.ok(store.isDataDestroyed(task.id));
});

test("执行器：轮次耗尽→failed", async () => {
  const endless = Array.from({ length: 20 }, () => agentJson("need_more_analysis"));
  const provider = makeProvider(endless);
  const { store, executor } = makeExecutor(provider);
  const task = store.create({ deviceId: "d", question: "q" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(SNAPSHOT) });

  assert.equal(await executor.run(task.id), "failed");
  assert.ok(store.getDecrypted(task.id, ["failureReason"]).failureReason.includes("最大轮次"));
});

// —— 2026-08-31 验收修复：备注识别 + 证据回传 ——

/** 带备注与摘录的快照：模拟东林验收场景（音乐 3316 元，备注 TIMA音乐盛典）。 */
const NOTE_SNAPSHOT = {
  version: 1,
  datasets: {
    "finance.transactions": {
      fields: [
        { name: "date", type: "date", description: "交易日期" },
        { name: "amount", type: "number", unit: "元", description: "交易金额" },
        { name: "category", type: "text", description: "交易分类" },
        { name: "text", type: "text", description: "备注、说明和标签合并文本" },
      ],
      rows: [
        { id: "r1", occurredAt: "2026-08-15", date: "2026-08-15", amount: 3316, category: "音乐", text: "TIMA音乐盛典", excerpt: "8月15日 音乐 TIMA音乐盛典 -¥3316" },
        { id: "r2", occurredAt: "2026-08-20", date: "2026-08-20", amount: 45, category: "餐饮", text: "午餐", excerpt: "8月20日 餐饮 午餐 -¥45" },
        { id: "r3", occurredAt: "2026-08-21", date: "2026-08-21", amount: 120, category: "音乐", text: "专辑", excerpt: "8月21日 音乐 专辑 -¥120" },
      ],
    },
  },
};

test("目录：字段说明必须进工具目录（模型才知道 text 是备注）", async () => {
  const { buildCloudToolCatalog } = await import("../src/agent/cloudAnalysisQueryEngine.js");
  const catalog = buildCloudToolCatalog(NOTE_SNAPSHOT);
  assert.ok(catalog.includes("text:text(备注、说明和标签合并文本)"), "text 字段须带中文说明");
  assert.ok(catalog.includes("snapshot_rows"), "目录须声明行明细工具用法");
  assert.ok(catalog.includes("TIMA") === false, "目录不包含数据内容本身");
});

test("snapshot_rows：按分类过滤+金额倒序返回行摘录（含备注原文）", () => {
  const engine = createCloudAnalysisQueryEngine();
  const result = engine.sampleRows({
    source: "finance.transactions",
    filters: [{ field: "category", operation: "equal", value: { text: "音乐" } }],
    sortBy: "amount",
    sortDirection: "descending",
    limit: 3,
  }, NOTE_SNAPSHOT, { toolRequestID: "rows1", tool: "snapshot_rows" });
  assert.equal(result.status, "success");
  assert.equal(result.events.length, 2);
  assert.equal(result.events[0].excerpt, "8月15日 音乐 TIMA音乐盛典 -¥3316");
  assert.equal(result.events[1].excerpt, "8月21日 音乐 专辑 -¥120");
});

test("snapshot_rows：limit 钳制到 10、空结果返回 empty、未知数据集报可恢复错误", () => {
  const engine = createCloudAnalysisQueryEngine();
  const clamped = engine.sampleRows({ source: "finance.transactions", limit: 999 }, NOTE_SNAPSHOT);
  assert.ok(clamped.events.length <= 10);
  const empty = engine.sampleRows({
    source: "finance.transactions",
    filters: [{ field: "category", operation: "equal", value: { text: "不存在" } }],
  }, NOTE_SNAPSHOT);
  assert.equal(empty.status, "empty");
  const missing = engine.sampleRows({ source: "no.such" }, NOTE_SNAPSHOT);
  assert.equal(missing.status, "error");
  assert.equal(missing.error.code, "INVALID_DATASET");
  assert.equal(missing.error.recoverable, true);
});

test("执行器：聚合+行明细混合查询→final result.evidence 回传 metric 与 rows 两类证据", async () => {
  const provider = makeProvider([
    agentJson("need_tools", {
      toolRequests: [
        {
          id: "t1",
          tool: "finance",
          query: "dynamic_query",
          parameters: {
            dynamicPlan: {
              source: "finance.transactions",
              filters: [],
              groupBy: [{ type: "field", field: "category" }],
              aggregations: [{ id: "cat_sum", operation: "sum", field: "amount", unit: "元" }],
              derivations: [],
              limit: 10,
              evidenceLimit: 10,
            },
          },
        },
        {
          id: "t2",
          tool: "snapshot_rows",
          query: "rows_sample",
          parameters: {
            source: "finance.transactions",
            filters: [{ field: "category", operation: "equal", value: { text: "音乐" } }],
            sortBy: "amount",
            sortDirection: "descending",
            limit: 3,
          },
        },
      ],
    }),
    agentJson("final_claims", {
      claims: [{
        summary: "音乐 3436 元",
        displayText: "音乐类支出 3436 元，其中 3316 元是一笔「TIMA音乐盛典」购票",
        metricAssertions: [],
        evidenceIDs: [],
      }],
    }),
  ]);
  const { store, executor } = makeExecutor(provider);
  const task = store.create({ deviceId: "d-note", question: "音乐分类的大额支出是什么" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(NOTE_SNAPSHOT) });

  assert.equal(await executor.run(task.id), "completed");
  const result = JSON.parse(store.getDecrypted(task.id, ["result"]).result);

  const metrics = result.evidence.filter((e) => e.kind === "metric");
  const rows = result.evidence.filter((e) => e.kind === "rows");
  assert.ok(metrics.length > 0, "须回传聚合指标证据");
  assert.ok(metrics[0].metricKey.startsWith("dynamic."));
  assert.equal(metrics[0].dataset, "finance.transactions");
  const musicMetric = metrics.find((m) => m.group === "音乐");
  assert.ok(musicMetric, "音乐分组指标存在");
  assert.equal(musicMetric.value, 3436);
  assert.equal(musicMetric.formula, "sum(amount)");
  assert.equal(rows.length, 1, "须回传行样本证据");
  assert.equal(rows[0].dataset, "finance.transactions");
  assert.ok(rows[0].excerpts[0].includes("TIMA音乐盛典"), "行样本含备注原文");
});

test("insightMaxTokensFor: 长周期提到 8192，短周期与非周期维持原值", () => {
  // 长周期（月/季/自定义）：提到 ≥8192，思考模型 reasoning+正文共享预算不再截断
  assert.equal(insightMaxTokensFor("monthly", 4096), 8192);
  assert.equal(insightMaxTokensFor("quarterly", 4096), 8192);
  assert.equal(insightMaxTokensFor("custom", 4096), 8192);
  assert.equal(insightMaxTokensFor("monthly", 12288), 12288, "原值更大时保留原值");
  // 短周期与未知周期：维持 route 原值
  assert.equal(insightMaxTokensFor("daily", 4096), 4096);
  assert.equal(insightMaxTokensFor("weekly", 4096), 4096);
  assert.equal(insightMaxTokensFor(null, 4096), 4096);
  assert.equal(insightMaxTokensFor(undefined, 4096), 4096);
});
