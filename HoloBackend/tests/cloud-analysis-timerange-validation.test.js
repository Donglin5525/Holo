import assert from "node:assert/strict";
import { test } from "node:test";

import { createCloudAnalysisQueryEngine } from "../src/agent/cloudAnalysisQueryEngine.js";

/**
 * 时间窗口显式校验（2026-09-21 静默失效根治）：
 * 模型显式传 timeRange/baseline 但格式非 Unix 秒/毫秒（ISO 日期、中文日期等）
 * 或 start≥end 时，此前 windowOf 返回 null → 静默当作「无窗口」返回全量，
 * 模型只能在报告里承认「时间过滤没有生效」（东林「最近一个季度」追问 538 笔
 * 全量作答实锤）。现改为 INVALID_TIMERANGE 可恢复报错，模型按消息换格式重试。
 * 不传 timeRange 的「无窗口 = 不过滤」旧协议语义保持不变。
 */

const SNAPSHOT = {
  version: 1,
  generatedAt: "2026-09-21T12:13:00+08:00",
  datasets: {
    "finance.transactions": {
      fields: [
        { name: "amount", type: "number", unit: "元" },
        { name: "category", type: "text" },
      ],
      rows: [
        { id: "r1", occurredAt: "2026-07-15T12:00:00+08:00", amount: 100, category: "七月" },
        { id: "r2", occurredAt: "2026-09-01T12:00:00+08:00", amount: 200, category: "九月" },
      ],
    },
  },
};

const UNIX_START = Math.floor(Date.parse("2026-08-01T00:00:00+08:00") / 1000);
const UNIX_END = Math.floor(Date.parse("2026-09-21T20:15:00+08:00") / 1000);

function run(timeRange, extra = {}) {
  const engine = createCloudAnalysisQueryEngine();
  return engine.execute(
    {
      source: "finance.transactions",
      aggregations: [{ id: "cnt", operation: "count", unit: "笔" }],
      ...(timeRange !== undefined ? { timeRange } : {}),
      ...extra,
    },
    SNAPSHOT,
    { toolRequestID: "t", tool: "finance" },
  );
}

function countOf(result) {
  return result.metrics?.find((m) => m.metricKey.includes(".cnt."))?.value ?? null;
}

test("Unix 秒 timeRange 正常过滤（提示词教的正确传法，回归保障）", () => {
  const r = run({ start: UNIX_START, end: UNIX_END });
  assert.equal(r.status, "success");
  assert.equal(countOf(r), 1);
});

test("ISO 日期字符串 timeRange → INVALID_TIMERANGE 可恢复报错（此前静默全量）", () => {
  const r = run({ start: "2026-08-01", end: "2026-09-21" });
  assert.equal(r.status, "error");
  assert.equal(r.error.code, "INVALID_TIMERANGE");
  assert.equal(r.error.recoverable, true);
  assert.match(r.error.message, /Unix 秒/);
  assert.match(r.error.message, /2026-08-01/); // 回显收到的原始值，模型能对准改哪
});

test("ISO 带时分秒 timeRange → INVALID_TIMERANGE", () => {
  const r = run({ start: "2026-08-01T00:00:00+08:00", end: "2026-09-21T20:15:00+08:00" });
  assert.equal(r.status, "error");
  assert.equal(r.error.code, "INVALID_TIMERANGE");
});

test("中文日期 timeRange → INVALID_TIMERANGE", () => {
  const r = run({ start: "2026年8月", end: "2026年9月21日" });
  assert.equal(r.status, "error");
  assert.equal(r.error.code, "INVALID_TIMERANGE");
});

test("start≥end（合法 Unix 秒但窗口反了）→ INVALID_TIMERANGE", () => {
  const r = run({ start: UNIX_END, end: UNIX_START });
  assert.equal(r.status, "error");
  assert.equal(r.error.code, "INVALID_TIMERANGE");
  assert.match(r.error.message, /start 必须早于 end/);
});

test("不传 timeRange 保持「无窗口 = 不过滤」旧协议语义（全量 2 行）", () => {
  const r = run(undefined);
  assert.equal(r.status, "success");
  assert.equal(countOf(r), 2);
});

test("baseline 格式错 → INVALID_TIMERANGE 且消息点名 baseline", () => {
  const r = run({ start: UNIX_START, end: UNIX_END }, { baseline: { start: "2026-05-01", end: "2026-07-31" } });
  assert.equal(r.status, "error");
  assert.equal(r.error.code, "INVALID_TIMERANGE");
  assert.match(r.error.message, /baseline/);
});

test("baseline 合法 Unix 秒 → 正常出对照值", () => {
  const engine = createCloudAnalysisQueryEngine();
  const r = engine.execute(
    {
      source: "finance.transactions",
      aggregations: [{ id: "cnt", operation: "count" }],
      timeRange: { start: UNIX_START, end: UNIX_END },
      baseline: {
        start: UNIX_START - 90 * 86_400,
        end: UNIX_START,
      },
      derivations: [{ id: "chg", metricID: "cnt", operation: "percentageChange" }],
    },
    SNAPSHOT,
    { toolRequestID: "t", tool: "finance" },
  );
  assert.equal(r.status, "success");
  assert.equal(countOf(r), 1);
});

test("perDay 派生缺 timeRange → INVALID_TIMERANGE（此前派生静默消失）", () => {
  const r = run(undefined, { derivations: [{ id: "d", metricID: "cnt", operation: "perDay", unit: "笔/天" }] });
  assert.equal(r.status, "error");
  assert.equal(r.error.code, "INVALID_TIMERANGE");
  assert.match(r.error.message, /perDay/);
});

test("perDay 派生 + 合法 timeRange → 正常出日均", () => {
  const r = run({ start: UNIX_START, end: UNIX_END }, { derivations: [{ id: "d", metricID: "cnt", operation: "perDay", unit: "笔/天" }] });
  assert.equal(r.status, "success");
  const perDay = r.metrics?.find((m) => m.metricKey.includes(".d."))?.value;
  assert.ok(perDay != null && perDay > 0);
});
