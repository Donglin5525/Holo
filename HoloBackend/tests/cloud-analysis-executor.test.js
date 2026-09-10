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

test("查询引擎：health.sleep 富字段日聚合（2026-09-10 健康域入快照）", () => {
  // 行结构 = iOS HoloHealthTool.sleepQueryRow 产出的字段身份证子集，
  // 云端模型据此可答「睡眠质量如何」（时长+深睡/REM+效率+入睡时间趋势）。
  const engine = createCloudAnalysisQueryEngine();
  const sleepSnapshot = {
    version: 1,
    datasets: {
      "health.sleep": {
        fields: [
          { name: "date", type: "date" },
          { name: "value", type: "number", unit: "小时", description: "每日睡眠时长" },
          { name: "deepHours", type: "number", unit: "小时" },
          { name: "remHours", type: "number", unit: "小时" },
          { name: "efficiency", type: "number", unit: "%" },
          { name: "bedtimeMinutes", type: "number", unit: "分钟" },
        ],
        rows: [
          { date: "2026-08-01", value: 7.5, deepHours: 1.8, remHours: 1.6, efficiency: 91, bedtimeMinutes: -30 },
          { date: "2026-08-02", value: 6.5, deepHours: 1.2, remHours: 1.2, efficiency: 85, bedtimeMinutes: 30 },
          { date: "2026-08-03", value: 8, deepHours: 2, remHours: 1.8, efficiency: 93, bedtimeMinutes: -15 },
        ],
      },
    },
  };
  const result = engine.execute({
    source: "health.sleep",
    filters: [],
    groupBy: [],
    aggregations: [
      { id: "avg_sleep", operation: "average", field: "value", unit: "小时" },
      { id: "avg_deep", operation: "average", field: "deepHours", unit: "小时" },
      { id: "avg_efficiency", operation: "average", field: "efficiency", unit: "%" },
    ],
    derivations: [],
    limit: 10,
    evidenceLimit: 5,
  }, sleepSnapshot, { toolRequestID: "h1", tool: "health" });
  assert.equal(result.status, "success");
  const byId = {};
  for (const metric of result.metrics) {
    if (metric.metricKey.includes(".avg_sleep.")) byId.sleep = metric.value;
    if (metric.metricKey.includes(".avg_deep.")) byId.deep = metric.value;
    if (metric.metricKey.includes(".avg_efficiency.")) byId.efficiency = metric.value;
  }
  // 引擎输出统一保留 4 位小数
  assert.equal(byId.sleep, 7.3333);
  assert.equal(byId.deep, 1.6667);
  assert.equal(byId.efficiency, 89.6667);
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

// —— 2026-09-09 根治：_search 虚拟字段 + 未知字段显式报错 ——

test("_search：跨字段关键词命中备注与分类（猫砂补货误报回归）", () => {
  const engine = createCloudAnalysisQueryEngine();
  // 备注命中：商品名在 text 字段（提示词 v19 承诺的核心场景）
  const byNote = engine.sampleRows({
    source: "finance.transactions",
    filters: [{ field: "_search", operation: "contains", value: { type: "text", text: "TIMA" } }],
    sortBy: "date",
    sortDirection: "descending",
    limit: 10,
  }, NOTE_SNAPSHOT);
  assert.equal(byNote.status, "success");
  assert.equal(byNote.events.length, 1);
  assert.ok(byNote.events[0].excerpt.includes("TIMA音乐盛典"));
  // 分类命中：_search 同时覆盖目录声明的全部 text 字段
  const byCategory = engine.execute({
    source: "finance.transactions",
    filters: [{ field: "_search", operation: "contains", value: { type: "text", text: "音乐" } }],
    groupBy: [],
    aggregations: [{ id: "n", operation: "count" }],
    derivations: [],
    limit: 10,
    evidenceLimit: 10,
  }, NOTE_SNAPSHOT);
  assert.equal(byCategory.status, "success");
  assert.equal(byCategory.metrics[0].value, 2);
});

test("_search：仅允许 contains，其他操作报可恢复错误", () => {
  const engine = createCloudAnalysisQueryEngine();
  const result = engine.sampleRows({
    source: "finance.transactions",
    filters: [{ field: "_search", operation: "equal", value: { type: "text", text: "猫砂" } }],
  }, NOTE_SNAPSHOT);
  assert.equal(result.status, "error");
  assert.equal(result.error.code, "INVALID_PARAMS");
  assert.equal(result.error.recoverable, true);
});

test("未知字段：snapshot_rows 与 dynamicPlan 一律报 UNKNOWN_FIELD，不再静默返回空", () => {
  const engine = createCloudAnalysisQueryEngine();
  const rows = engine.sampleRows({
    source: "finance.transactions",
    filters: [{ field: "note", operation: "contains", value: { type: "text", text: "猫砂" } }],
  }, NOTE_SNAPSHOT);
  assert.equal(rows.status, "error");
  assert.equal(rows.error.code, "UNKNOWN_FIELD");
  assert.equal(rows.error.recoverable, true);
  assert.ok(rows.error.message.includes("note"), "错误须点名拼错的字段");
  assert.ok(rows.error.message.includes("_search"), "错误须指引 _search 用法");

  const dynamic = engine.execute({
    source: "finance.transactions",
    filters: [],
    groupBy: [],
    aggregations: [{
      id: "n",
      operation: "count",
      filters: [{ field: "note", operation: "contains", value: { type: "text", text: "麦当劳" } }],
    }],
    derivations: [],
    limit: 10,
    evidenceLimit: 10,
  }, SNAPSHOT);
  assert.equal(dynamic.status, "error");
  assert.equal(dynamic.error.code, "UNKNOWN_FIELD");
  assert.equal(dynamic.error.recoverable, true);
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

// —— 深度分析额度与取消（2026-09-07 体检 M3：云端轨道接入同池额度 + 取消检查点）——

function makeRecordingLedger({ allowed = true } = {}) {
  const calls = { reserve: [], commit: 0, release: 0 };
  return {
    calls,
    reserve(input) {
      calls.reserve.push(input);
      return allowed
        ? { allowed: true, subjectId: "s", tier: "free", quotaType: "deepAnalysis", actionId: "a", periodKey: "p" }
        : { allowed: false, reason: "quota_exceeded", userMessage: "今日深度分析额度已用完" };
    },
    commit() { calls.commit += 1; },
    release() { calls.release += 1; },
  };
}

test("deep_analysis：额度预订-提交（同池 deepAnalysis，actionId 幂等）", async () => {
  const provider = makeProvider([agentJson("final_claims", { claims: [] })]);
  const quota = makeRecordingLedger();
  const pushes = [];
  const { store, executor } = makeExecutor(provider, {
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
    pushNotifier: { notifyTaskCompleted: async (deviceId, payload) => pushes.push(payload) },
  });
  const task = store.create({ deviceId: "device-da", question: "分析我的支出" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(SNAPSHOT) });

  assert.equal(await executor.run(task.id), "completed");
  assert.equal(quota.calls.reserve.length, 1);
  assert.equal(quota.calls.reserve[0].quotaType, "deepAnalysis");
  assert.ok(quota.calls.reserve[0].actionId.startsWith("cloud-deep-analysis-"));
  assert.equal(quota.calls.commit, 1);
  assert.equal(quota.calls.release, 0);
  assert.equal(pushes.length, 1);
});

test("deep_analysis：额度拒绝→failed，不调模型，原因回传", async () => {
  const provider = makeProvider([]);
  const quota = makeRecordingLedger({ allowed: false });
  const { store, executor } = makeExecutor(provider, {
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
  });
  const task = store.create({ deviceId: "d", question: "分析我的支出" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(SNAPSHOT) });

  assert.equal(await executor.run(task.id), "failed");
  assert.equal(provider.calls.length, 0, "额度不足不得调用模型");
  const row = store.getDecrypted(task.id, ["failureReason"]);
  assert.ok(row.failureReason.includes("额度"));
});

test("deep_analysis：中途取消（行已删除）→下一轮前停止，返回 cancelled，额度释放、无推送", async () => {
  let store;
  let task;
  let firstCall = true;
  const provider = {
    calls: 0,
    async complete() {
      this.calls += 1;
      if (firstCall) {
        firstCall = false;
        store.cancel(task.id); // 用户在第一轮执行期间取消：取消即整行删除
        return agentJson("need_tools", { toolRequests: [] });
      }
      return agentJson("final_claims", { claims: [] });
    },
  };
  const pushes = [];
  const quota = makeRecordingLedger();
  const made = makeExecutor(provider, {
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
    pushNotifier: { notifyTaskCompleted: async (deviceId, payload) => pushes.push(payload) },
  });
  store = made.store;
  task = store.create({ deviceId: "d", question: "分析我的支出" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(SNAPSHOT) });

  assert.equal(await made.executor.run(task.id), "cancelled");
  assert.equal(provider.calls, 1, "取消后不得再调用模型");
  assert.equal(quota.calls.commit, 0);
  assert.equal(quota.calls.release, 1);
  assert.equal(pushes.length, 0, "已取消的任务不得收到完成推送");
});

test("deep_analysis：完成落库前被取消→cancelled，不提交额度、无推送", async () => {
  let store;
  let task;
  const provider = {
    calls: 0,
    async complete() {
      this.calls += 1;
      store.cancel(task.id); // 模型给出 final_claims 的同时用户取消
      return agentJson("final_claims", { claims: [] });
    },
  };
  const pushes = [];
  const quota = makeRecordingLedger();
  const made = makeExecutor(provider, {
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
    pushNotifier: { notifyTaskCompleted: async (deviceId, payload) => pushes.push(payload) },
  });
  store = made.store;
  task = store.create({ deviceId: "d", question: "分析我的支出" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(SNAPSHOT) });

  assert.equal(await made.executor.run(task.id), "cancelled");
  assert.equal(pushes.length, 0);
  assert.equal(quota.calls.commit, 0);
  assert.equal(quota.calls.release, 1);
});

// —— 个人情境规划（context_plan）单轮生成（2026-09-09 方案 §5.3）——

test("context_plan：快照prompt→单轮生成→complete+阶段draftReady+chat池额度提交", async () => {
  const planJSON = JSON.stringify({
    goalSummary: "日本旅行准备",
    answerText: "出发前需要办签证、订机票。",
    items: [{ itemID: "i1", title: "核对护照有效期", kind: "task", basis: "generalKnowledge", sourceRefs: [], preconditions: [], relativeTiming: null, selected: false }],
    unknowns: [], dependencyEdges: [], usedContextRefs: [], planEffects: [],
    coverage: { readSources: [], missingScopes: [], externalFactsVerified: false },
  });
  const provider = makeProvider([planJSON]);
  const pushes = [];
  const quota = makeQuotaLedger();
  const { store, executor } = makeExecutor(provider, {
    contextPlanRoute: { provider: "fake", model: "planner-m", temperature: 0.3, maxTokens: 8000 },
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
    pushNotifier: { notifyTaskCompleted: async (deviceId, payload) => pushes.push({ deviceId, payload }) },
  });

  const task = store.create({ deviceId: "device-plan", question: "要去日本旅行，要提前做什么准备", taskType: "context_plan" });
  store.attachSnapshot({ id: task.id, snapshot: "规划prompt全文（iOS 检索后组装）" });

  assert.equal(await executor.run(task.id), "completed");
  const result = JSON.parse(store.getDecrypted(task.id, ["result"]).result);
  assert.equal(result.kind, "context_plan");
  assert.equal(result.output, planJSON);

  // 阶段：cloudPlanning → draftReady，revision 服务端单调
  const row = store.get(task.id);
  assert.equal(row.stage, "draftReady");
  assert.ok(row.stage_revision >= 2, `阶段推进至少两次，实际 ${row.stage_revision}`);

  // 额度：chat 池提交且未释放
  assert.equal(quota.calls.commit, 1);
  assert.equal(quota.calls.release, 0);
  // 完成推送
  assert.equal(pushes.length, 1);
  assert.equal(pushes[0].payload.title, "个性化方案已就绪");
  // 完成即焚仍适用（问题与快照密文销毁）
  assert.ok(store.isDataDestroyed(task.id));

  // 模型调用：系统提示词为 personal_context_planning（含「个人情境规划器」标识），user=prompt 全文
  assert.equal(provider.calls.length, 1);
  assert.ok(provider.calls[0].messages[0].content.includes("个人情境规划器"), "必须走规划服务端提示词");
  assert.equal(provider.calls[0].messages[1].content, "规划prompt全文（iOS 检索后组装）");
});

test("context_plan：额度不足→failed+阶段failed（不调模型、不写draftReady）", async () => {
  const provider = makeProvider([]);
  const quota = makeQuotaLedger({ allowed: false });
  const { store, executor } = makeExecutor(provider, {
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
  });
  const task = store.create({ deviceId: "d", question: "搬家准备", taskType: "context_plan" });
  store.attachSnapshot({ id: task.id, snapshot: "prompt" });

  assert.equal(await executor.run(task.id), "failed");
  assert.equal(provider.calls.length, 0, "额度不足不得调用模型");
  const row = store.get(task.id);
  assert.equal(row.stage, "failed");
  assert.ok(row.stage_revision >= 1);
});

test("context_plan：生成失败→额度释放+阶段failed+即焚", async () => {
  const provider = makeProvider(["   "]); // 空白输出 → 抛错
  const quota = makeQuotaLedger();
  const { store, executor } = makeExecutor(provider, {
    quotaLedger: quota,
    entitlementResolver: RESOLVER,
  });
  const task = store.create({ deviceId: "d", question: "考试准备", taskType: "context_plan" });
  store.attachSnapshot({ id: task.id, snapshot: "prompt" });

  assert.equal(await executor.run(task.id), "failed");
  assert.equal(quota.calls.commit, 0);
  assert.equal(quota.calls.release, 1, "失败必须释放预订");
  const row = store.get(task.id);
  assert.equal(row.stage, "failed");
  assert.ok(store.isDataDestroyed(task.id));
  const failure = store.getDecrypted(task.id, ["failureReason"]).failureReason;
  assert.ok(failure.includes("云端规划生成失败"));
});

test("context_plan：快照为空白→failed（不调模型、阶段failed）", async () => {
  const provider = makeProvider([]);
  const { store, executor } = makeExecutor(provider, {});
  const task = store.create({ deviceId: "d", question: "词", taskType: "context_plan" });
  store.attachSnapshot({ id: task.id, snapshot: "   " }); // 空白 prompt → 防御拒绝
  assert.equal(await executor.run(task.id), "failed");
  assert.equal(provider.calls.length, 0);
  assert.equal(store.get(task.id).stage, "failed");
});
