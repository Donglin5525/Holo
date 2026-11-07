import { test } from "node:test";
import assert from "node:assert/strict";
import { computeFactSheet, resolveAnalysisWindow } from "../src/agent/deepReport/factComputator.js";

// 构造一份确定性快照：横跨两个 30 天窗口 + 4 个自然月（覆盖个人历史/固定大额）
const DAY = 86400_000;
const genMs = Date.parse("2026-11-07T12:00:00+08:00");
const curStart = Date.parse("2026-10-08T00:00:00+08:00");
const curEnd = genMs;
const prevStart = Date.parse("2026-09-08T00:00:00+08:00");
const iso = (ms) => new Date(ms + 8 * 3600_000).toISOString().replace("Z", "+08:00");

function buildSnapshot() {
  const fin = [];
  // 本期：房租 + 两笔同备注山姆 + 一笔挂项目
  fin.push({ occurredAt: iso(Date.parse("2026-11-01T00:00:00+08:00")), amount: 5000, type: "expense", category: "房租", text: "", account: "现金" });
  fin.push({ occurredAt: iso(Date.parse("2026-10-20T10:00:00+08:00")), amount: 800, type: "expense", category: "超市", text: "山姆", account: "现金" });
  fin.push({ occurredAt: iso(Date.parse("2026-10-25T10:00:00+08:00")), amount: 750.2, type: "expense", category: "超市", text: "山姆", account: "现金" });
  fin.push({ occurredAt: iso(Date.parse("2026-10-12T10:00:00+08:00")), amount: 240, type: "expense", category: "烟酒", text: "深圳市兴悦超市", account: "现金" });
  // 上期：项目支出 + 聂的两笔不同备注 + 服饰收入（疑似退款）
  fin.push({ occurredAt: iso(Date.parse("2026-09-20T10:00:00+08:00")), amount: 5711, type: "expense", category: "旅游", text: "东京酒店", project: "东京旅行", account: "现金" });
  fin.push({ occurredAt: iso(Date.parse("2026-09-29T10:00:00+08:00")), amount: 652, type: "expense", category: "送礼", text: "聂 鞋", project: "东京旅行", account: "现金" });
  fin.push({ occurredAt: iso(Date.parse("2026-09-29T11:00:00+08:00")), amount: 1299, type: "expense", category: "送礼", text: "聂 衣服", project: "东京旅行", account: "现金" });
  fin.push({ occurredAt: iso(Date.parse("2026-09-25T10:00:00+08:00")), amount: 252, type: "income", category: "服饰", text: "淘宝退款", account: "现金" });
  fin.push({ occurredAt: iso(Date.parse("2026-09-24T10:00:00+08:00")), amount: 300, type: "expense", category: "服饰", text: "衬衫", account: "现金" });
  fin.push({ occurredAt: iso(Date.parse("2026-10-29T10:00:00+08:00")), amount: 22772, type: "income", category: "工资", text: "", account: "现金" });
  // 固定大额：数码连续 4 个月同金额（分期形态）
  for (const m of ["2026-07-17", "2026-08-17", "2026-09-17", "2026-10-17"]) {
    fin.push({ occurredAt: iso(Date.parse(`${m}T10:00:00+08:00`)), amount: 1333.25, type: "expense", category: "数码", text: "macbook", account: "现金" });
  }
  // 窗口外一行（不该被算进任何窗口）
  fin.push({ occurredAt: iso(Date.parse("2026-04-01T10:00:00+08:00")), amount: 99999, type: "expense", category: "不该出现", text: "", account: "现金" });

  const habit = [];
  // 戒烟（计数型负向）：本期 20 天有量，与烟酒消费可并列
  for (let i = 0; i < 30; i += 1) {
    const t = curStart + i * DAY;
    habit.push({ occurredAt: iso(t), habit: "戒烟", type: "count", polarity: "negative", goal: 10, unit: "支", value: i % 3 === 0 ? 6 : 2 });
  }
  // 健身（打卡型）：连续 3 天、断 8 天、再连续 3 天；最近一次距 gen 5 天
  const fitDays = [-20, -19, -18, -10, -9, -8, -5];
  for (let i = 0; i < 30; i += 1) {
    const t = curStart + i * DAY;
    const done = fitDays.includes(i - 30);
    habit.push({ occurredAt: iso(t), habit: "健身", type: "check", polarity: "positive", goal: 3, value: done ? 1 : 0 });
  }
  return {
    generatedAt: iso(genMs),
    historyDays: 180,
    answerTask: { primaryTimeRange: { start: Math.floor(curStart / 1000), end: Math.floor(curEnd / 1000), label: "问句指定：最近30天" } },
    datasets: {
      "finance.transactions": { rows: fin },
      "habit.daily": { rows: habit },
      "task.daily": { rows: Array.from({ length: 30 }, (_, i) => ({ occurredAt: iso(curStart + i * DAY), value: i % 2 })) },
      "thought.daily": { rows: Array.from({ length: 30 }, (_, i) => ({ occurredAt: iso(curStart + i * DAY), value: i % 3 === 0 ? 1 : 0 })) },
    },
  };
}

test("窗口：冻结窗优先，上期=紧邻前移同长度", () => {
  const w = resolveAnalysisWindow(buildSnapshot());
  assert.equal(w.startMs, curStart);
  assert.equal(w.label, "问句指定：最近30天");
  assert.equal(w.hasPrev, true);
  assert.equal(w.prevStartMs < w.startMs, true);
});

test("一次性项目拆分：总变化归因到项目 vs 日常", () => {
  const sheet = computeFactSheet(buildSnapshot());
  const text = sheet.text;
  assert.match(text, /项目「东京旅行」：本期 0\.00 元（0 笔）；上期 7662\.00 元（3 笔）/);
  assert.match(text, /剔除项目后的日常支出/);
  assert.match(text, /两者方向相反，不能合并归因/, "项目降、日常升时不给百分比");
  // 窗口外的 99999 不进任何窗口
  assert.equal(text.includes("99999"), false);
});

test("收入构成：疑似退款标注 + 工资拆分", () => {
  const sheet = computeFactSheet(buildSnapshot());
  assert.match(sheet.text, /收入·服饰：本期 0\.00 元（0 笔）；上期 252\.00 元/);
  assert.match(sheet.text, /该分类同时也是支出分类，这类收入可能是退款或报销/);
  assert.match(sheet.text, /收入·工资：本期 22772\.00 元/);
});

test("备注归人：跨备注同词「聂」归并出合计", () => {
  const sheet = computeFactSheet(buildSnapshot());
  assert.match(sheet.text, /「聂」：2 笔，合计 1951\.00 元/);
  assert.match(sheet.text, /聂 鞋/);
});

test("固定大额：连续同金额标注分期形态", () => {
  const sheet = computeFactSheet(buildSnapshot());
  assert.match(sheet.text, /固定大额·数码：4 笔，每笔都是 1333\.25 元/);
  assert.match(sheet.text, /像是分期或固定订阅，不是一次性购买/);
});

test("习惯：中断统计与恢复日；戒断与相关消费并列", () => {
  const sheet = computeFactSheet(buildSnapshot());
  assert.match(sheet.text, /戒烟（计数型，每日上限 10 支）/);
  assert.match(sheet.text, /戒烟与相关消费并列/);
  assert.match(sheet.text, /同期相关消费 1 笔，合计 240\.00 元/);
  assert.match(sheet.text, /健身：最近一次完成是/);
});

test("任务/想法按月与本期对比", () => {
  const sheet = computeFactSheet(buildSnapshot());
  assert.match(sheet.text, /本期完成任务 15 个，分布在 15 天/);
  assert.match(sheet.text, /想法正文不在数据里/);
});

test("白名单含关键数值，供核对器使用", () => {
  const sheet = computeFactSheet(buildSnapshot());
  const near = (v) => sheet.whitelist.some((x) => Math.abs(x.value - v) <= Math.max(0.05, Math.abs(v) * 0.02));
  assert.equal(near(5711), true);
  assert.equal(near(1951), true);
  assert.equal(near(22772), true);
  assert.equal(near(1333.25), true);
  assert.equal(near(99999), false, "窗口外的值不进白名单");
});

test("个人历史：月度序列与中位数", () => {
  const sheet = computeFactSheet(buildSnapshot());
  assert.match(sheet.text, /日常支出月均/);
  assert.match(sheet.text, /中位数/);
  assert.match(sheet.text, /从低到高排第/);
});
