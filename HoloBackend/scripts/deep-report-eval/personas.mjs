// 深度报告评测集 · 合成人设（2026-11-20「懂我」方案 P0）
// 每个人设预埋「标准答案」（truths）：评测时对照报告逐条判定是否讲到、是否讲错。
// 全部为确定性合成数据（固定随机种子），不含任何真实用户数据。

const DAY = 86_400_000;
const TZ = "+08:00";
export const NOW = Date.parse("2026-11-20T21:00:00+08:00");
const WINDOW_DAYS = 30;
const HISTORY_DAYS = 120;

function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

const pad = (n) => String(n).padStart(2, "0");
function isoAt(dayStartMs, hour = 0, minute = 0) {
  const d = new Date(dayStartMs + 8 * 3600_000);
  const date = `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
  return `${date}T${pad(hour)}:${pad(minute)}:00${TZ}`;
}
// 以东八区零点为天起点
const today0 = Date.parse("2026-11-20T00:00:00+08:00");
const dayStart = (daysAgo) => today0 - daysAgo * DAY;
const weekday = (ms) => new Date(ms + 8 * 3600_000).getUTCDay(); // 0=周日

function ds(fields, rows) {
  return { fields: fields.map((name) => ({ name })), rows };
}

function answerTask(question, label = "最近30天") {
  return {
    userQuestion: question,
    primaryTimeRange: {
      start: Math.floor(dayStart(WINDOW_DAYS - 1) / 1000),
      end: Math.floor(NOW / 1000),
      label,
    },
  };
}

function baseSnapshot(question) {
  return {
    version: 1,
    generatedAt: new Date(NOW).toISOString(),
    historyDays: HISTORY_DAYS,
    answerTask: answerTask(question),
    datasets: {},
  };
}

let txSeq = 0;
function tx(daysAgo, hour, minute, amount, category, text, extra = {}) {
  const at = isoAt(dayStart(daysAgo), hour, minute);
  return { id: `tx-${++txSeq}`, occurredAt: at, date: at, amount: Math.round(amount * 100) / 100, type: "expense", category, account: "微信", text, ...extra };
}
function income(daysAgo, amount, category, text) {
  const at = isoAt(dayStart(daysAgo), 10, 0);
  return { id: `tx-${++txSeq}`, occurredAt: at, date: at, amount, type: "income", category, account: "银行卡", text };
}
function habitRow(daysAgo, habit, type, polarity, goal, value, unit) {
  const at = isoAt(dayStart(daysAgo));
  return { id: `h-${habit}-${daysAgo}`, occurredAt: at, date: at, habit, type, polarity, goal, value, ...(unit ? { unit } : {}) };
}
function dayRow(prefix, daysAgo, value, extra = {}) {
  const at = isoAt(dayStart(daysAgo));
  return { id: `${prefix}-${daysAgo}`, occurredAt: at, date: at, value, ...extra };
}
function sleepRow(daysAgo, hours, bedtimeMinutes, wakeMinutes) {
  const at = isoAt(dayStart(daysAgo));
  return {
    id: `sleep-${daysAgo}`, occurredAt: at, date: at,
    value: Math.round(hours * 100) / 100,
    deepHours: Math.round(hours * 0.18 * 100) / 100,
    remHours: Math.round(hours * 0.22 * 100) / 100,
    coreHours: Math.round(hours * 0.55 * 100) / 100,
    awakeHours: 0.4, efficiency: 92, interruptions: 2,
    bedtimeMinutes, wakeMinutes,
  };
}

// 常规日常消费：早餐/午餐/交通/零碎，按天随机
function routineSpend(r, daysAgo, scale = 1) {
  const out = [];
  if (r() < 0.8) out.push(tx(daysAgo, 8, 20, (12 + r() * 10) * scale, "餐饮", "早餐"));
  if (r() < 0.9) out.push(tx(daysAgo, 12, 15, (25 + r() * 20) * scale, "餐饮", "午饭"));
  if (r() < 0.7) out.push(tx(daysAgo, 9, 0, 4 + r() * 6, "交通", "地铁"));
  if (r() < 0.25) out.push(tx(daysAgo, 19, 30, (30 + r() * 90) * scale, "购物", "日用品"));
  return out;
}

// ─────────────────────────────────────────────
// A · 小林：最近三周加班 → 晚睡、深夜外卖、健身中断同时出现
// ─────────────────────────────────────────────
function personaLin() {
  const r = rng(11);
  const finance = [], habit = [], sleep = [], steps = [], tasks = [], thoughts = [];
  for (let d = HISTORY_DAYS - 1; d >= 0; d -= 1) {
    const overtime = d <= 20; // 近三周加班
    const wd = weekday(dayStart(d));
    const workday = wd >= 1 && wd <= 5;
    finance.push(...routineSpend(r, d));
    // 深夜外卖：平时约每周 1 次；加班期工作日约 7 成
    if ((overtime && workday && r() < 0.7) || (!overtime && r() < 0.13)) {
      finance.push(tx(d, 23, 40 + Math.floor(r() * 15), 38 + r() * 30, "餐饮", "深夜外卖"));
    }
    if (d % 30 === 3) finance.push(tx(d, 10, 0, 3200, "住房", "房租"));
    if (d % 30 === 5) finance.push(income(d, 18000, "工资", "工资"));
    // 健身：平时每周约 3 次；加班期几乎停掉
    const gym = overtime ? (d === 15 ? 1 : 0) : ([1, 3, 6].includes(wd) && r() < 0.85 ? 1 : 0);
    habit.push(habitRow(d, "健身", "check", "positive", 3, gym));
    habit.push(habitRow(d, "喝水", "count", "positive", 8, Math.round(overtime ? 5 + r() * 2 : 7 + r() * 2), "杯"));
    // 睡眠：平时 23:30 左右入睡、7.4 小时；加班期 1:10 左右、5.9 小时
    const bed = overtime ? 60 + Math.floor(r() * 40) : 1390 + Math.floor(r() * 40);
    const hours = overtime ? 5.6 + r() * 0.7 : 7.1 + r() * 0.7;
    sleep.push(sleepRow(d, hours, bed % 1440, (bed + Math.round(hours * 60)) % 1440));
    steps.push(dayRow("steps", d, Math.round(overtime ? 4800 + r() * 1500 : 8500 + r() * 2500)));
    const done = overtime && workday ? 5 + Math.floor(r() * 3) : workday ? 2 + Math.floor(r() * 2) : Math.floor(r() * 2);
    tasks.push(dayRow("task", d, done, { highPriorityValue: overtime && workday ? 2 : 0 }));
    thoughts.push(dayRow("thought", d, r() < (overtime ? 0.15 : 0.4) ? 1 : 0));
  }
  return {
    datasets: {
      "finance.transactions": ds(["date", "amount", "type", "category", "account", "project", "text"], finance),
      "habit.daily": ds(["date", "value", "habit", "polarity", "goal", "type", "unit"], habit),
      "health.sleep": ds(["date", "value", "deepHours", "remHours", "coreHours", "awakeHours", "efficiency", "interruptions", "bedtimeMinutes", "wakeMinutes"], sleep),
      "health.steps": ds(["date", "value"], steps),
      "task.daily": ds(["date", "value", "highPriorityValue"], tasks),
      "thought.daily": ds(["date", "value"], thoughts),
    },
    profileBrief: "称呼我小林。说话直接一点，别给我列一堆建议，最多一个。",
    confirmedKnowledgeBrief: "加班的那几周，深夜点外卖会明显变多",
  };
}

// ─────────────────────────────────────────────
// B · 阿May：一趟东京旅行把总支出拉高，日常开销其实在下降
// ─────────────────────────────────────────────
function personaMay() {
  const r = rng(22);
  const finance = [];
  for (let d = HISTORY_DAYS - 1; d >= 0; d -= 1) {
    const recent = d < WINDOW_DAYS;
    finance.push(...routineSpend(r, d, recent ? 0.8 : 1));
    if (!recent && r() < 0.3) finance.push(tx(d, 20, 0, 60 + r() * 140, "娱乐", "奶茶和电影"));
    if (recent && r() < 0.12) finance.push(tx(d, 20, 0, 40 + r() * 60, "娱乐", "奶茶"));
    if (d % 30 === 1) finance.push(tx(d, 10, 0, 2800, "住房", "房租"));
    if (d % 30 === 6) finance.push(income(d, 13000, "工资", "工资"));
  }
  const trip = { project: "东京旅行" };
  finance.push(
    tx(12, 9, 0, 3260, "交通", "往返机票", trip),
    tx(10, 15, 0, 4180, "住宿", "新宿酒店 5 晚", trip),
    tx(9, 13, 0, 860, "餐饮", "寿司和拉面", trip),
    tx(8, 16, 0, 1320, "购物", "药妆", trip),
    tx(7, 11, 0, 420, "交通", "地铁周游券", trip),
    tx(6, 18, 0, 690, "餐饮", "居酒屋", trip),
  );
  return {
    datasets: { "finance.transactions": ds(["date", "amount", "type", "category", "account", "project", "text"], finance) },
    profileBrief: "我叫阿May，语气轻松一点就好。",
  };
}

// ─────────────────────────────────────────────
// C · 老周：戒烟大幅好转；两次破戒都在周五同事聚餐当天
// ─────────────────────────────────────────────
function personaZhou() {
  const r = rng(33);
  const finance = [], habit = [], sleep = [];
  for (let d = HISTORY_DAYS - 1; d >= 0; d -= 1) {
    const recent = d < WINDOW_DAYS;
    const fridayFeast = d === 6 || d === 20; // 两个周五聚餐
    finance.push(...routineSpend(r, d));
    if (fridayFeast) finance.push(tx(d, 21, 0, 268 + r() * 60, "餐饮", "同事聚餐"));
    if (!recent && r() < 0.6) finance.push(tx(d, 18, 0, 25, "烟酒", "香烟"));
    if (recent && fridayFeast) finance.push(tx(d, 22, 30, 25, "烟酒", "香烟"));
    const cigs = recent ? (fridayFeast ? 11 + Math.floor(r() * 3) : Math.floor(r() * 4)) : 7 + Math.floor(r() * 4);
    habit.push(habitRow(d, "戒烟", "count", "negative", 5, cigs, "支"));
    const run = d <= 24 && [2, 4, 0].includes(weekday(dayStart(d))) && r() < 0.8 ? 1 : 0; // 近 25 天开始跑步
    habit.push(habitRow(d, "跑步", "check", "positive", 3, run));
    const hours = recent ? 7.2 + r() * 0.6 : 6.5 + r() * 0.6;
    const bed = 1400 + Math.floor(r() * 50);
    sleep.push(sleepRow(d, hours, bed % 1440, (bed + Math.round(hours * 60)) % 1440));
  }
  return {
    datasets: {
      "finance.transactions": ds(["date", "amount", "type", "category", "account", "project", "text"], finance),
      "habit.daily": ds(["date", "value", "habit", "polarity", "goal", "type", "unit"], habit),
      "health.sleep": ds(["date", "value", "deepHours", "remHours", "coreHours", "awakeHours", "efficiency", "interruptions", "bedtimeMinutes", "wakeMinutes"], sleep),
    },
    profileBrief: "叫我老周。我在戒烟，别说教。",
  };
}

// ─────────────────────────────────────────────
// D · 新用户：只记了 10 天账，没有健康和习惯
// ─────────────────────────────────────────────
function personaNew() {
  const r = rng(44);
  const finance = [];
  for (let d = 9; d >= 0; d -= 1) finance.push(...routineSpend(r, d).slice(0, 2));
  return {
    datasets: { "finance.transactions": ds(["date", "amount", "type", "category", "account", "project", "text"], finance) },
    profileBrief: "",
  };
}

export const CASES = [
  {
    id: "A1_lin_checkup",
    persona: personaLin,
    question: "把我最近30天的账单、习惯、睡眠、任务放在一起看看：整体过得怎么样？哪些变化是一起发生的？",
    truths: [
      "近三周入睡明显推迟（约从 23:30 推到 1 点后），睡眠时长变短",
      "深夜外卖明显变多",
      "健身几乎中断",
      "完成任务数（尤其高优）上升，像是工作变忙",
      "上述变化在时间上同时发生（只能说同时，不能说导致）",
      "引用确认理解：加班周深夜外卖会变多",
    ],
    traps: ["把同时发生说成因果（如「熬夜导致」）", "编造想法内容或情绪", "列多条建议（档案要求最多一个）", "没叫「小林」"],
  },
  {
    id: "A2_lin_finance",
    persona: personaLin,
    question: "最近的钱主要花在哪里了？和之前比有什么变化？",
    truths: ["餐饮里深夜外卖变多是主要变化", "房租是最大固定支出", "总体变化幅度描述正确"],
    traps: ["数字与清单不符", "没叫「小林」", "列多条建议"],
  },
  {
    id: "B1_may_finance",
    persona: personaMay,
    question: "这个月花钱是不是太多了？主要花在哪？",
    truths: ["总支出上升主要来自东京旅行（一次性项目）", "剔除旅行后的日常支出其实比之前少", "旅行花费的大头是机票和酒店"],
    traps: ["把旅行当成日常超支来批评", "没区分一次性项目", "没叫「阿May」"],
  },
  {
    id: "C1_zhou_habit",
    persona: personaZhou,
    question: "我最近戒烟和跑步坚持得怎么样？",
    truths: ["每天抽烟量相比之前大幅下降", "有两天明显超标（破戒）", "两次超标都在周五、当天都有同事聚餐支出（并列即可）", "跑步是近期新开始的习惯并基本坚持", "睡眠时长比之前略好"],
    traps: ["说教（如「要坚持」「不能放松」）", "人格标签（如「自律」）", "把聚餐说成破戒原因的确定结论", "没叫「老周」"],
  },
  {
    id: "D1_new_checkup",
    persona: personaNew,
    question: "帮我做一次最近 30 天的生活体检",
    truths: ["坦白只有约 10 天的账单数据", "健康、习惯、任务没有记录要直说", "不硬凑结论"],
    traps: ["编造睡眠/运动/习惯结论", "把 10 天数据当作 30 天趋势"],
  },
];

export function buildSnapshot(testCase) {
  const p = testCase.persona();
  const snap = baseSnapshot(testCase.question);
  snap.datasets = p.datasets;
  if (p.profileBrief) snap.profileBrief = p.profileBrief;
  if (p.confirmedKnowledgeBrief) snap.confirmedKnowledgeBrief = p.confirmedKnowledgeBrief;
  return snap;
}
