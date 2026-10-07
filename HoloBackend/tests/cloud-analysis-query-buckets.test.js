import assert from "node:assert/strict";
import { test } from "node:test";

import { createCloudAnalysisQueryEngine } from "../src/agent/cloudAnalysisQueryEngine.js";

/**
 * 时间分桶时区语义（2026-09-21 财务深析改造）：
 * 桶值直接切 ISO 值的本地部分（带时区偏移前缀即用户本地日期/小时），
 * 不经 Date→toISOString 的 UTC 往返——根治东八区凌晨交易被切进前一天的错日。
 * 纯日期旧快照（无 T 时刻成分）hour 桶落 unknown，模型按能力声明绕行时段分析。
 */

const SNAPSHOT = {
  version: 1,
  datasets: {
    "finance.transactions": {
      fields: [
        { name: "date", type: "date" },
        { name: "amount", type: "number", unit: "元" },
        { name: "category", type: "text" },
      ],
      rows: [],
    },
  },
};

function runGrouped(rows, groupType, timeField = "occurredAt") {
  const engine = createCloudAnalysisQueryEngine();
  const snapshot = {
    ...SNAPSHOT,
    datasets: {
      "finance.transactions": {
        ...SNAPSHOT.datasets["finance.transactions"],
        rows: rows.map((r) => ({ ...r, occurredAt: r[timeField] ?? r.occurredAt })),
      },
    },
  };
  const result = engine.execute(
    {
      source: "finance.transactions",
      filters: [],
      groupBy: [{ type: groupType }],
      aggregations: [{ id: "total", operation: "sum", field: "amount", unit: "元" }],
      derivations: [],
      limit: 50,
      evidenceLimit: 5,
    },
    snapshot,
    { toolRequestID: "t", tool: "finance" },
  );
  assert.equal(result.status, "success");
  const byKey = {};
  for (const metric of result.metrics) {
    if (metric.metricKey.includes(".total.")) byKey[metric.comparison] = metric.value;
  }
  return byKey;
}

test("hour 桶：按用户本地时刻分桶（22:40+08:00 → 22，01:10+08:00 → 01）", () => {
  const byKey = runGrouped([
    { occurredAt: "2026-09-21T22:40:00+08:00", amount: -30, category: "餐饮" },
    { occurredAt: "2026-09-22T01:10:00+08:00", amount: -20, category: "餐饮" },
    { occurredAt: "2026-09-21T22:05:00+08:00", amount: -15, category: "餐饮" },
  ], "hour");
  assert.equal(byKey["22"], -45);
  assert.equal(byKey["01"], -20);
});

test("day 桶：东八区凌晨交易归本地当天（旧 UTC 往返会错切前一天）", () => {
  const byKey = runGrouped([
    { occurredAt: "2026-09-22T01:10:00+08:00", amount: -20, category: "餐饮" },
    { occurredAt: "2026-09-21T23:50:00+08:00", amount: -10, category: "餐饮" },
  ], "day");
  assert.equal(byKey["2026-09-22"], -20);
  assert.equal(byKey["2026-09-21"], -10);
});

test("month 桶：本地 10 月凌晨不落进 UTC 的 9 月", () => {
  const byKey = runGrouped([
    { occurredAt: "2026-10-01T02:00:00+08:00", amount: -99, category: "餐饮" },
  ], "month");
  assert.equal(byKey["2026-10"], -99);
  assert.equal(byKey["2026-09"], undefined);
});

test("weekend 桶：按本地星期判断（本地周一凌晨不被 UTC 周日误判为周末）", () => {
  // 2026-09-21 是周一；本地 01:00 = UTC 周日 17:00，旧实现 getUTCDay 会误判 weekend
  const byKey = runGrouped([
    { occurredAt: "2026-09-21T01:00:00+08:00", amount: -20, category: "交通" },
    { occurredAt: "2026-09-19T23:30:00+08:00", amount: -50, category: "餐饮" },
  ], "weekend");
  assert.equal(byKey["weekday"], -20);
  assert.equal(byKey["weekend"], -50);
});

test("week 桶：同一本地周的凌晨与白天同桶（ISO 周按本地日期算）", () => {
  const byKey = runGrouped([
    { occurredAt: "2026-09-21T01:00:00+08:00", amount: -20, category: "交通" },
    { occurredAt: "2026-09-22T10:00:00+08:00", amount: -30, category: "餐饮" },
    { occurredAt: "2026-09-28T10:00:00+08:00", amount: -40, category: "餐饮" },
  ], "week");
  const keys = Object.keys(byKey);
  assert.equal(keys.length, 2);
  assert.equal(byKey[keys[0]], -50); // 周一凌晨 + 周二白天同桶
  assert.equal(byKey[keys[1]], -40); // 下周一另一桶
});

test("旧格式纯日期：day 正常、hour 落 unknown（发版顺序防线）", () => {
  const byKey = runGrouped([
    { occurredAt: "2026-08-01", amount: -32, category: "餐饮" },
  ], "day");
  assert.equal(byKey["2026-08-01"], -32);

  const hourKey = runGrouped([
    { occurredAt: "2026-08-01", amount: -32, category: "餐饮" },
  ], "hour");
  assert.equal(hourKey["unknown"], -32);
  assert.equal(Object.keys(hourKey).length, 1);
});

test("date 字段兜底：无 occurredAt 的行从声明时间字段取值分桶", () => {
  const engine = createCloudAnalysisQueryEngine();
  const snapshot = {
    ...SNAPSHOT,
    datasets: {
      "finance.transactions": {
        ...SNAPSHOT.datasets["finance.transactions"],
        rows: [{ date: "2026-09-22T01:10:00+08:00", amount: -20, category: "餐饮" }],
      },
    },
  };
  const result = engine.execute(
    {
      source: "finance.transactions",
      filters: [],
      groupBy: [{ type: "day" }],
      aggregations: [{ id: "total", operation: "sum", field: "amount", unit: "元" }],
      derivations: [],
      limit: 50,
      evidenceLimit: 5,
    },
    snapshot,
    { toolRequestID: "t", tool: "finance" },
  );
  assert.equal(result.status, "success");
  assert.ok(result.metrics.some((m) => m.metricKey.includes(".total.2026_09_22")));
});
