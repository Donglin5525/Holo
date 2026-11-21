// 深度报告评测集 · 目标复盘人设（2026-11-20 报告改版 C2）
// 四种数据形态：满配 / 起步期 / 结果中断 / 过程型无结果。全部确定性合成数据。
const DAY = 86_400_000;
const NOW = Date.parse("2026-11-20T21:00:00+08:00");
const iso = (ms) => new Date(ms).toISOString();

const checkRows = (name, n, on) => Array.from({ length: n }, (_, i) => ({
  occurredAt: iso(NOW - (n - 1 - i) * DAY - 9 * 3600_000), habit: name, type: "check", polarity: "positive", goal: 1, value: on(i) ? 1 : 0,
}));
const measureRows = (name, weekly, skipLastWeeks = 0) => weekly.flatMap((v, w) => (w >= weekly.length - skipLastWeeks ? [] : [1, 4].map((d) => ({
  occurredAt: iso(NOW - ((weekly.length - 1 - w) * 7 + (6 - d)) * DAY - 9 * 3600_000), habit: name, type: "measure", unit: "kg", value: v,
}))));
const taskRows = (n) => Array.from({ length: n }, (_, i) => ({ occurredAt: iso(NOW - i * DAY), value: i % 4 === 0 ? 1 : 0, highPriorityValue: 0 }));

const SCOPE = (n) => ({
  schemaVersion: 1, goalID: `10000000-0000-0000-0000-00000000000${n}`,
  planRevisionID: `20000000-0000-0000-0000-00000000000${n}`, reviewID: `30000000-0000-0000-0000-00000000000${n}`,
  windowStart: iso(NOW - 14 * DAY), windowEndExclusive: iso(NOW + 3 * 3600_000), snapshotCutoffAt: iso(NOW),
  timeZoneID: "Asia/Shanghai", sourceDigest: `digest-${n}`,
});
const habit = (title, i) => ({ id: `40000000-0000-0000-0000-00000000000${i}`, entityType: "habit", entityID: `50000000-0000-0000-0000-00000000000${i}`, title, role: "action", isUnavailable: false });
const task = (title, i, done) => ({ id: `40000000-0000-0000-0000-00000000001${i}`, entityType: "task", title, role: "action", isUnavailable: false, taskCompleted: done });

function base(n, question, goalReview, rows, extra = {}) {
  const scope = SCOPE(n);
  return {
    version: 1, generatedAt: iso(NOW), historyDays: 180,
    answerTask: { userQuestion: question, primaryTimeRange: { start: Math.floor(Date.parse(scope.windowStart) / 1000), end: Math.floor(Date.parse(scope.windowEndExclusive) / 1000), label: "近14天" } },
    goalScope: scope,
    goalReview: { schemaVersion: 1, goalID: scope.goalID, planRevisionID: scope.planRevisionID, coverage: { known: [], unknown: [] }, ...goalReview },
    datasets: { "habit.daily": { rows }, ...extra },
  };
}

const gym = (i) => (i < 35 ? i % 3 === 0 : i % 6 === 0);
const weight = { sourceKind: "habit", sourceLabel: "体重", unit: "kg", targetValue: 72, baselineValue: 78 };

export const GOAL_CASES = [
  {
    id: "G1_goal_rich",
    question: "我的减肥目标最近怎么样？",
    build: () => base(1, "我的减肥目标最近怎么样？", {
      goalTitle: "减到 72kg", deadline: "2027-01-31T00:00:00+08:00",
      result: { status: "observed", value: 75.4, observedAt: iso(NOW - DAY), baselineObservedAt: "2026-09-01T08:00:00+08:00", progressFraction: 0.43, ...weight },
      execution: [habit("健身", 1), habit("俯卧撑", 2), habit("深蹲", 3), habit("早睡", 4)],
    }, [
      ...measureRows("体重", [77.3, 77.0, 76.6, 76.2, 75.9, 75.6, 75.5, 75.4]),
      ...checkRows("健身", 56, gym), ...checkRows("俯卧撑", 56, (i) => i % 4 !== 3), ...checkRows("深蹲", 56, gym),
      ...checkRows("早睡", 56, (i) => (i < 35 ? i % 7 < 4 : i % 7 < 2)), ...checkRows("维生素", 56, () => true),
    ]),
    truths: ["体重在降但近 3 周变慢", "健身和早睡掉档、俯卧撑稳", "深蹲跟着健身走", "没有饮食记录影响判断", "按小节「结果/关联事项/还缺什么/下一步」组织"],
    traps: ["出现维生素等无关习惯", "把同时发生说成因果", "罗列逐周体重序列", "段落超过 150 字"],
  },
  {
    id: "G2_goal_early",
    question: "减肥目标开头怎么样",
    build: () => base(2, "减肥目标开头怎么样", {
      goalTitle: "减到 72kg", deadline: "2027-01-31T00:00:00+08:00",
      result: { status: "observed", value: 77.8, observedAt: iso(NOW - DAY), baselineObservedAt: iso(NOW - 5 * DAY), progressFraction: 0.03, ...weight },
      execution: [habit("健身", 1), habit("俯卧撑", 2)],
    }, [...measureRows("体重", [77.8]), ...checkRows("健身", 5, (i) => i === 0), ...checkRows("俯卧撑", 5, (i) => i < 4)]),
    truths: ["坦白目标刚开始、数据不足以判断趋势", "不给完成预测", "说明再记录多久能看出什么"],
    traps: ["给出完成日期预测", "把 0.2kg 当成趋势"],
  },
  {
    id: "G3_goal_stale",
    question: "我减肥目标进度如何",
    build: () => base(3, "我减肥目标进度如何", {
      goalTitle: "减到 72kg", deadline: "2027-01-31T00:00:00+08:00",
      result: { status: "stale", value: 75.6, observedAt: iso(NOW - 21 * DAY), baselineObservedAt: "2026-09-01T08:00:00+08:00", progressFraction: 0.4, ...weight },
      execution: [habit("健身", 1), habit("俯卧撑", 2)],
    }, [...measureRows("体重", [77.3, 77.0, 76.6, 76.2, 75.9, 75.6, 75.6, 75.6], 3), ...checkRows("健身", 56, gym), ...checkRows("俯卧撑", 56, (i) => i % 4 !== 3)]),
    truths: ["3 周没称重、进度无法判断", "行为数据照常分析", "建议先补记一次体重"],
    traps: ["编造最近体重", "给完成预测"],
  },
  {
    id: "G4_goal_process",
    question: "雅思备考目标推进得怎么样",
    build: () => base(4, "雅思备考目标推进得怎么样", {
      goalTitle: "备考雅思", deadline: "2027-03-01T00:00:00+08:00",
      result: { status: "not_applicable", sourceLabel: "过程型目标" },
      execution: [habit("英语", 1), task("刷一套真题", 1, true), task("口语练习 10 次", 2, false), task("背完核心词汇", 3, false)],
    }, checkRows("英语", 56, (i) => i < 28 && i % 2 === 0), { "task.daily": { rows: taskRows(56) } }),
    truths: ["英语已停（最近两周以上没打卡）", "任务完成 1/3", "目标没有可衡量的结果"],
    traps: ["编造分数或水平变化", "写「结果」小节"],
  },
];
