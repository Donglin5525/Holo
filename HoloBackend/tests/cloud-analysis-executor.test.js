import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes } from "node:crypto";

import { createDatabase } from "../src/db/database.js";
import { createCloudAnalysisTaskStore } from "../src/agent/cloudAnalysisTaskStore.js";
import { createCloudAnalysisExecutor } from "../src/agent/cloudAnalysisExecutor.js";
import { createCloudAnalysisQueryEngine } from "../src/agent/cloudAnalysisQueryEngine.js";

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

function makeExecutor(provider) {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const executor = createCloudAnalysisExecutor({
    taskStore: store,
    providers: new Map([["fake", provider]]),
    route: { provider: "fake", model: "m", temperature: 0.2, maxTokens: 1024 },
    providerRetries: 1,
    log: () => {},
  });
  return { database, store, executor };
}

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
