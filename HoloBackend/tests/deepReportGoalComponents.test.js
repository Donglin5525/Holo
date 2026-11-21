// 深度报告改版（2026-11-20）：目标复盘组件 / 通用组件 / 组件就位 / 目标任务端到端
import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { computeGoalComponents } from "../src/agent/deepReport/goalComponents.js";
import { computeGenericComponents, habitStatus } from "../src/agent/deepReport/componentComputator.js";
import { computeFactSheet, resolveAnalysisWindow } from "../src/agent/deepReport/factComputator.js";
import { anchorComponents, mapReportToResult } from "../src/agent/deepReport/mapper.js";
import { layoutBlock } from "../src/agent/deepReport/engine.js";
import { createDatabase } from "../src/db/database.js";
import { createCloudAnalysisTaskStore } from "../src/agent/cloudAnalysisTaskStore.js";
import { createCloudAnalysisExecutor } from "../src/agent/cloudAnalysisExecutor.js";

const DAY = 86400_000;
const NOW = Date.parse("2026-11-20T21:00:00+08:00");
const iso = (ms) => new Date(ms).toISOString();

/** 近 n 天逐日行（旧→新），on(i) 决定第 i 天是否打卡（i=0 为最早一天） */
function checkRows(name, n, on) {
  return Array.from({ length: n }, (_, i) => ({
    occurredAt: iso(NOW - (n - 1 - i) * DAY - 9 * 3600_000),
    habit: name, type: "check", polarity: "positive", goal: 1, value: on(i) ? 1 : 0,
  }));
}
function measureRows(name, weeklyValues) {
  const n = weeklyValues.length;
  return weeklyValues.flatMap((v, w) => [1, 4].map((d) => ({
    occurredAt: iso(NOW - ((n - 1 - w) * 7 + (6 - d)) * DAY - 9 * 3600_000),
    habit: name, type: "measure", unit: "kg", value: v,
  })));
}

const GOAL_ID = "10000000-0000-0000-0000-000000000001";
const SCOPE = {
  schemaVersion: 1, goalID: GOAL_ID,
  planRevisionID: "20000000-0000-0000-0000-000000000001",
  reviewID: "30000000-0000-0000-0000-000000000001",
  windowStart: "2026-11-06T00:00:00+08:00", windowEndExclusive: "2026-11-21T00:00:00+08:00",
  snapshotCutoffAt: "2026-11-20T21:00:00+08:00", timeZoneID: "Asia/Shanghai", sourceDigest: "d",
};
const habitItem = (title, i) => ({ id: `40000000-0000-0000-0000-00000000000${i}`, entityType: "habit", title, role: "action", isUnavailable: false });

/** 满配：体重 8 周、健身前稳后掉、俯卧撑稳、深蹲跟随健身、无饮食 */
function richSnapshot() {
  const gym = (i) => (i < 35 ? i % 3 === 0 : i % 6 === 0);
  return {
    generatedAt: iso(NOW), historyDays: 180,
    answerTask: { primaryTimeRange: { start: Math.floor(Date.parse(SCOPE.windowStart) / 1000), end: Math.floor(Date.parse(SCOPE.windowEndExclusive) / 1000), label: "近 14 天" } },
    goalScope: SCOPE,
    goalReview: {
      goalID: GOAL_ID, goalTitle: "减到 72kg", deadline: "2027-01-31T00:00:00+08:00",
      result: { status: "observed", sourceKind: "habit", sourceLabel: "体重", value: 75.4, unit: "kg", observedAt: iso(NOW - DAY),
        targetValue: 72, baselineValue: 78, baselineObservedAt: "2026-09-01T08:00:00+08:00", progressFraction: 0.43 },
      execution: [habitItem("健身", 1), habitItem("俯卧撑", 2), habitItem("深蹲", 3)],
      coverage: { known: [], unknown: [] },
    },
    datasets: {
      "habit.daily": { rows: [
        ...measureRows("体重", [77.3, 77.0, 76.6, 76.2, 75.9, 75.6, 75.5, 75.4]),
        ...checkRows("健身", 56, gym),
        ...checkRows("俯卧撑", 56, (i) => i % 4 !== 3),
        ...checkRows("深蹲", 56, gym),
        ...checkRows("维生素", 56, () => true), // 目标无关的习惯，不该出现
      ] },
    },
  };
}

test("满配目标：进度+预测、趋势高亮、习惯状态含跟随、前后对比、饮食缺口、四节骨架", () => {
  const snap = richSnapshot();
  const g = computeGoalComponents(snap, resolveAnalysisWindow(snap));
  const kinds = g.components.map((c) => c.kind);
  for (const k of ["progress", "trendLine", "habitStrip", "periodCompare", "gapCards"]) assert.ok(kinds.includes(k), `缺 ${k}：${kinds}`);
  const progress = g.components.find((c) => c.kind === "progress").payload;
  assert.equal(progress.current, 75.4);
  assert.ok(["略落后", "落后", "按计划"].includes(progress.statusLabel));
  assert.ok(progress.projections.length >= 1, "≥3 个周均点给完成预测");
  const strip = g.components.find((c) => c.kind === "habitStrip").payload;
  const byName = Object.fromEntries(strip.rows.map((r) => [r.name, r]));
  assert.equal(byName["健身"].statusLabel, "掉档");
  assert.equal(byName["俯卧撑"].statusLabel, "稳");
  assert.equal(byName["深蹲"].statusLabel, "跟随健身");
  assert.ok(!strip.rows.some((r) => r.name === "维生素" || r.name === "体重"), "无关习惯与结果习惯不进习惯条");
  assert.ok(g.components.find((c) => c.kind === "gapCards").payload.cards.some((c) => c.title === "没有饮食记录"));
  assert.deepEqual(g.skeleton, ["结果", "关联事项", "还缺什么", "下一步"]);
  assert.ok(g.factLines.some((l) => l.includes("程序判定：掉档")), "状态判定写进事实清单");
});

test("事实清单：目标模式只保留关联习惯，组件随清单返回", () => {
  const sheet = computeFactSheet(richSnapshot());
  assert.ok(!sheet.text.includes("维生素"), "目标复盘不扫无关习惯");
  assert.ok(sheet.components.length >= 4);
  assert.equal(sheet.goal.title, "减到 72kg");
  assert.ok(layoutBlock(sheet).includes("## 结果：一句判断"));
});

test("起步期（建 5 天）：给里程碑，不给预测与前后对比", () => {
  const snap = richSnapshot();
  snap.goalReview.result.baselineObservedAt = iso(NOW - 5 * DAY);
  snap.datasets["habit.daily"].rows = [...checkRows("健身", 5, (i) => i === 0), ...checkRows("俯卧撑", 5, (i) => i < 4)];
  const g = computeGoalComponents(snap, resolveAnalysisWindow(snap));
  const kinds = g.components.map((c) => c.kind);
  assert.ok(kinds.includes("milestones"));
  assert.ok(!kinds.includes("periodCompare") && !kinds.includes("trendLine"));
  const strip = g.components.find((c) => c.kind === "habitStrip").payload;
  assert.equal(strip.rows[0].days.length, 7, "回看窗口最短 7 天");
});

test("结果过期：进度虚化 + 数据中断缺口，不做预测", () => {
  const snap = richSnapshot();
  Object.assign(snap.goalReview.result, { status: "stale", observedAt: iso(NOW - 21 * DAY) });
  const g = computeGoalComponents(snap, resolveAnalysisWindow(snap));
  const p = g.components.find((c) => c.kind === "progress").payload;
  assert.equal(p.isStale, true);
  assert.equal(p.statusLabel, "数据中断");
  assert.deepEqual(p.projections, []);
  assert.ok(g.components.find((c) => c.kind === "gapCards").payload.cards[0].title.startsWith("结果数据中断"));
});

test("过程型目标 + 单个已停习惯：不画进度，骨架不写「结果」", () => {
  const snap = richSnapshot();
  snap.goalReview.goalTitle = "备考雅思";
  snap.goalReview.result = { status: "not_applicable", sourceLabel: "过程型目标" };
  snap.goalReview.execution = [habitItem("英语", 1)];
  snap.datasets["habit.daily"].rows = checkRows("英语", 56, (i) => i < 28 && i % 2 === 0);
  const g = computeGoalComponents(snap, resolveAnalysisWindow(snap));
  assert.ok(!g.components.some((c) => c.kind === "progress"));
  assert.equal(g.components.find((c) => c.kind === "habitStrip").payload.rows[0].statusLabel, "已停");
  assert.deepEqual(g.skeleton, ["关联事项", "还缺什么", "下一步"]);
});

test("状态规则边界", () => {
  assert.equal(habitStatus(new Array(56).fill(0)), null, "没有记录不判定");
  assert.equal(habitStatus(new Array(20).fill(1)), null, "不足 5 周不判稳/掉");
  assert.equal(habitStatus(new Array(56).fill(1)).label, "稳");
});

test("通用报告：习惯条按关键词就位，正文没提到的组件不出；下一步转结论条目", () => {
  const snap = {
    generatedAt: iso(NOW), historyDays: 180,
    datasets: {
      "habit.daily": { rows: [...checkRows("健身", 120, (i) => (i < 99 ? i % 3 === 0 : false)), ...checkRows("冥想", 120, (i) => i % 2 === 0)] },
      "task.daily": { rows: Array.from({ length: 120 }, (_, i) => ({ occurredAt: iso(NOW - i * DAY), value: i % 5 === 0 ? 2 : 0 })) },
    },
  };
  const w = resolveAnalysisWindow(snap);
  const generic = computeGenericComponents(snap, w);
  assert.ok(generic.components.some((c) => c.kind === "habitStrip"));
  assert.ok(generic.components.some((c) => c.kind === "barSeries"));
  const sheet = computeFactSheet(snap);
  const report = "# 健身停了\n\n导语一段。\n\n## 习惯：健身停了\n\n健身最近停了，冥想还在。\n\n## 下一步：先恢复\n\n先把健身恢复起来。\n\n数据说明：无。";
  const { result } = mapReportToResult({ reportText: report, sheet, window: sheet.window, snapshotCoverage: null });
  const strip = result.reportComponents.find((c) => c.kind === "habitStrip");
  assert.equal(strip.anchor, 0, "习惯条落在提到健身的第一节");
  assert.ok(!result.reportComponents.some((c) => c.kind === "barSeries"), "正文没讲任务 → 任务柱不出");
  assert.equal(result.reportStructure.conclusionItems.length, 1);
  assert.ok(!result.reportStructure.sections.some((s) => s.title.startsWith("下一步")));
});

test("anchorComponents：目标骨架按标题关键词就位，找不到放最后一节", () => {
  const sections = [{ title: "结果：慢了", paragraphClaimIDs: [] }, { title: "关联事项：两个掉档", paragraphClaimIDs: [] }];
  const out = anchorComponents([
    { kind: "progress", anchorTitle: null, payload: {} },
    { kind: "habitStrip", anchorTitle: "关联事项", payload: {} },
    { kind: "gapCards", anchorTitle: "还缺什么", payload: {} },
  ], sections, new Map());
  assert.deepEqual(out.map((c) => c.anchor), [-1, 1, 1]);
  assert.deepEqual(out.map((c) => c.id), ["c1", "c2", "c3"]);
});

test("端到端：目标复盘任务走新引擎完成，回显 goalScope 并带组件", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: randomBytes(32).toString("base64") });
  const responses = [
    "# 体重还在降，但最近慢了\n\n目标还在往前走，只是最近慢下来了。\n\n## 结果：降速变慢\n\n体重还在往下走，最近几周变化变小了。\n\n## 关联事项：健身掉档\n\n健身最近明显少了，俯卧撑还很稳。\n\n## 还缺什么：没有饮食记录\n\n饮食完全没有记录，原因只能从运动看。\n\n## 下一步：先恢复健身\n\n先把健身恢复到之前的节奏。\n\n数据说明：没有饮食数据。",
    JSON.stringify({ problems: [] }),
  ];
  let i = 0;
  const provider = {
    async complete(request) {
      const sys = request.messages?.[0]?.content ?? "";
      if (sys.includes("逐条执行指令")) return { choices: [{ message: { content: JSON.stringify({ directives: [] }) } }] };
      const next = responses[i++];
      if (next === undefined) throw new Error("PROVIDER_EXHAUSTED");
      return { choices: [{ message: { content: next } }], usage: { prompt_tokens: 1, completion_tokens: 1 } };
    },
  };
  const route = { provider: "fake", model: "m", temperature: 0, maxTokens: 100, reasoningEffort: "low", timeoutMs: 1000 };
  const executor = createCloudAnalysisExecutor({
    taskStore: store, providers: new Map([["fake", provider]]), route, deepReportRoutes: { writer: route, checker: route },
    providerRetries: 1, log: () => {}, injectedQuestionTimeResolver: { resolveQuestionTime: async () => null },
  });
  const task = store.create({ deviceId: "dev", question: "我的减肥目标怎么样", taskType: "deep_report" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(richSnapshot()) });
  assert.equal(await executor.run(task.id), "completed");
  const result = JSON.parse(store.getDecrypted(task.id, ["result"]).result);
  assert.equal(result.goalScope.goalID, GOAL_ID);
  const kinds = result.reportComponents.map((c) => c.kind);
  assert.ok(kinds.includes("progress") && kinds.includes("habitStrip"));
  const relatedIdx = result.reportStructure.sections.findIndex((s) => s.title.startsWith("关联事项"));
  assert.equal(result.reportComponents.find((c) => c.kind === "habitStrip").anchor, relatedIdx);
  assert.equal(result.reportStructure.conclusionItems.length, 1);
});

test("苹果健康目标：只靠 iOS 上行的周序列也能画趋势、给预测", () => {
  const snap = richSnapshot();
  snap.goalReview.result = { ...snap.goalReview.result, sourceKind: "healthKit", sourceLabel: "体重" };
  snap.datasets["habit.daily"].rows = snap.datasets["habit.daily"].rows.filter((r) => r.habit !== "体重");
  snap.goalResultSeries = { points: [77.3, 77.0, 76.6, 76.2, 75.9, 75.6].map((value, i) => ({ label: `10/${i + 1}`, value })) };
  const g = computeGoalComponents(snap, resolveAnalysisWindow(snap));
  assert.ok(g.components.some((c) => c.kind === "trendLine"), "周序列 ≥4 点画趋势");
  assert.ok(g.components.find((c) => c.kind === "progress").payload.projections.length >= 1);
});
