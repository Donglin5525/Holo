// warm-p0-samples.mjs
// 温暖陪伴 P0 现状样本冻结（2026-09-15 方案 §16）：直接驱动云端分析执行器，
// 对同一批问题+快照生成服务端交付结果（final_claims 落库形态）。
// - 内存任务存储：不落生产库、不占用户额度、不触发推送；
// - 模型路由/key 复用生产 env（agent_loop 路由 = 与线上深度分析同一模型档位）；
// - 确定性快照：固定 seed 生成「虚拟用户」95 天多领域数据，新旧两轮输入完全一致，
//   差异只来自代码版本（P0 落库字段）与模型随机性（temperature 0.2）。
// 用法（服务器 HoloBackend 目录）：
//   DOTENV_CONFIG_PATH=deploy/.env.production node scripts/warm-p0-samples.mjs out.jsonl [sampleId ...]
// 输出：JSONL，每行 { id, question, status, durationMs, result, usage, rounds }

import "dotenv/config";
import { loadConfig } from "../src/config.js";
import { createCloudAnalysisExecutor } from "../src/agent/cloudAnalysisExecutor.js";
import { createOpenAICompatibleProvider } from "../src/providers/openAICompatibleProvider.js";

// ---------- 确定性伪随机 ----------

function lcg(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 2 ** 32;
  };
}

const TODAY = new Date();
TODAY.setHours(12, 0, 0, 0);

function dateNDaysAgo(n) {
  const d = new Date(TODAY);
  d.setDate(d.getDate() - n);
  return d.toISOString().slice(0, 10);
}

// ---------- 虚拟用户数据（95 天，按「前两期平稳 → 本期偏离」设计，让分析题有真发现） ----------

function buildFinanceRows(rand) {
  const rows = [];
  const dinners = ["麦当劳", "肯德基", "外卖·黄焖鸡", "外卖·麻辣烫", "外卖·披萨", "面馆", "食堂"];
  const drinks = ["瑞幸咖啡", "喜茶", "蜜雪冰城", "星巴克", "一点点"];
  const subs = [
    { category: "订阅", merchant: "爱奇艺", amount: -30 },
    { category: "订阅", merchant: "网易云音乐", amount: -15 },
    { category: "订阅", merchant: "iCloud", amount: -21 },
  ];
  for (let n = 94; n >= 0; n -= 1) {
    const date = dateNDaysAgo(n);
    const daysAgo = n;
    const isCurrent = daysAgo < 30; // 本期
    const dow = new Date(date).getDay();
    const isWeekend = dow === 0 || dow === 6;

    // 每月固定订阅
    if (date.endsWith("-01")) {
      for (const sub of subs) rows.push({ date, ...sub, note: "自动续费" });
    }

    // 三餐：本期餐饮上涨 ~35%（均价与频次同时抬升），夜宵外卖集中
    const lunchCount = rand() < 0.85 ? 1 : 0;
    for (let i = 0; i < lunchCount; i += 1) {
      const base = isCurrent ? 26 : 20;
      const amount = -(base + Math.round(rand() * 14));
      rows.push({
        date, category: "餐饮", merchant: dinners[Math.floor(rand() * dinners.length)],
        amount, note: "午餐",
      });
    }
    // 晚间外卖：本期工作日 22 点后概率 0.62，前期 0.28
    const nightProb = isCurrent ? (isWeekend ? 0.3 : 0.62) : isWeekend ? 0.22 : 0.28;
    if (rand() < nightProb) {
      const amount = -((isCurrent ? 34 : 28) + Math.round(rand() * 18));
      rows.push({
        date, category: "餐饮",
        merchant: ["外卖·烧烤", "外卖·炸鸡", "外卖·麻辣香锅", "外卖·小龙虾"][Math.floor(rand() * 4)],
        amount, note: "夜宵",
      });
    }
    // 奶茶咖啡：每周 3-4 笔小额
    if (rand() < 0.5) {
      rows.push({
        date, category: "餐饮", merchant: drinks[Math.floor(rand() * drinks.length)],
        amount: -(14 + Math.round(rand() * 20)), note: "",
      });
    }
    // 周末购物/娱乐
    if (isWeekend && rand() < (isCurrent ? 0.55 : 0.4)) {
      const target = rand();
      if (target < 0.5) {
        rows.push({ date, category: "购物", merchant: "淘宝", amount: -(80 + Math.round(rand() * 220)), note: "" });
      } else if (target < 0.8) {
        rows.push({ date, category: "娱乐", merchant: "电影院", amount: -(45 + Math.round(rand() * 60)), note: "" });
      } else {
        rows.push({ date, category: "交通", merchant: "滴滴", amount: -(18 + Math.round(rand() * 30)), note: "" });
      }
    }
    // 工作日通勤
    if (!isWeekend && rand() < 0.7) {
      rows.push({ date, category: "交通", merchant: "地铁", amount: -6, note: "" });
    }
  }
  // 本月一笔数码大件
  rows.push({ date: dateNDaysAgo(12), category: "购物", merchant: "Apple Store", amount: -1899, note: "耳机" });
  // 前一月一笔大件（对照）
  rows.push({ date: dateNDaysAgo(52), category: "购物", merchant: "京东", amount: -1299, note: "显示器" });
  return rows.sort((a, b) => (a.date < b.date ? -1 : 1));
}

function buildSleepRows(rand) {
  const rows = [];
  for (let n = 94; n >= 0; n -= 1) {
    const isCurrent = n < 30;
    const dow = new Date(dateNDaysAgo(n)).getDay();
    const isWeekend = dow === 0 || dow === 6;
    // 本期均值下移 ~45min、入睡后移（工作日社交时差加大）、深睡占比略降
    const avgHours = isCurrent ? 6.0 : 6.9;
    const hours = Math.max(4.6, Math.min(8.2, avgHours + (rand() - 0.5) * 1.4 + (isWeekend ? 0.5 : 0)));
    const bedtime = (isCurrent ? 1435 : 1350) + (isWeekend ? 55 : 0) + (rand() - 0.5) * 50; // 分钟数，24h 制
    const wake = 445 + (isWeekend ? 70 : 0) + (rand() - 0.5) * 40;
    rows.push({
      date: dateNDaysAgo(n),
      value: Math.round(hours * 10) / 10,
      deepPct: Math.round(((isCurrent ? 17.5 : 20.5) + (rand() - 0.5) * 4) * 10) / 10,
      remPct: Math.round((22 + (rand() - 0.5) * 5) * 10) / 10,
      efficiency: Math.round(((isCurrent ? 86 : 90) + (rand() - 0.5) * 6) * 10) / 10,
      bedtimeMinutes: Math.round(bedtime) % 1440,
      wakeMinutes: Math.round(wake),
      interruptions: Math.round(rand() * (isCurrent ? 3 : 1.4)),
    });
  }
  return rows;
}

function buildStepRows(rand) {
  const rows = [];
  for (let n = 94; n >= 0; n -= 1) {
    const dow = new Date(dateNDaysAgo(n)).getDay();
    const isWeekend = dow === 0 || dow === 6;
    const base = isWeekend ? 6200 : 4300;
    rows.push({ date: dateNDaysAgo(n), value: Math.round(base + (rand() - 0.5) * 3200) });
  }
  return rows;
}

function buildWorkoutRows(rand) {
  const rows = [];
  for (let n = 94; n >= 0; n -= 1) {
    // 每周约 2 次（周三/周日节奏 + 随机）
    const dow = new Date(dateNDaysAgo(n)).getDay();
    if ((dow === 3 || dow === 0) && rand() < 0.8) {
      rows.push({
        date: dateNDaysAgo(n), type: rand() < 0.6 ? "力量训练" : "跑步",
        minutes: 35 + Math.round(rand() * 30), calories: 200 + Math.round(rand() * 180),
      });
    }
  }
  return rows;
}

function buildHabitRows(rand) {
  const rows = [];
  const habits = [
    { name: "冥想", type: "count", valueRange: [1, 1], weekProb: (cur) => (cur ? 0.35 : 0.62) }, // 本期下滑
    { name: "每日喝水 8 杯", type: "boolean", valueRange: [1, 1], weekProb: () => 0.82 },
    { name: "香烟（支）", type: "measure", valueRange: null, weekProb: () => 0.9 }, // 坏习惯本期回升
  ];
  for (let n = 94; n >= 0; n -= 1) {
    const isCurrent = n < 30;
    const date = dateNDaysAgo(n);
    for (const habit of habits) {
      if (rand() >= habit.weekProb(isCurrent)) continue;
      if (habit.name.startsWith("香烟")) {
        rows.push({ date, habit: habit.name, value: (isCurrent ? 9 : 6) + Math.round(rand() * 4), note: "" });
      } else {
        rows.push({ date, habit: habit.name, value: 1, note: "" });
      }
    }
  }
  return rows;
}

function buildTaskRows(rand) {
  const rows = [];
  for (let n = 94; n >= 0; n -= 1) {
    const isCurrent = n < 30;
    const done = Math.round((isCurrent ? 1.8 : 3.2) + rand() * 2.5); // 本期完成量下滑
    for (let i = 0; i < done; i += 1) {
      rows.push({
        date: dateNDaysAgo(n), title: ["写周报", "回邮件", "改方案", "健身", "读书 30 页", "整理笔记"][Math.floor(rand() * 6)],
        completed: 1, list: rand() < 0.7 ? "工作" : "生活",
      });
    }
  }
  // 常驻堆积的未完成
  for (const title of ["整理云盘照片", "预约体检", "给爸妈买礼物", "学完 Swift 第一课", "处理旧手机"]) {
    rows.push({ date: dateNDaysAgo(20 + Math.round(rand() * 40)), title, completed: 0, list: "生活" });
  }
  return rows;
}

function buildGoalRows() {
  return [
    { name: "三个月存下 1 万", progressPct: 38, deadline: dateNDaysAgo(-25), note: "每月发薪日转 3300" },
    { name: "睡前少刷手机", progressPct: 22, deadline: dateNDaysAgo(-40), note: "" },
    { name: "读完 6 本书", progressPct: 50, deadline: dateNDaysAgo(-60), note: "已读完 3 本" },
  ];
}

function buildThoughtRows(rand) {
  const topics = [
    ["职业转型", 0.3], ["健身与精力", 0.25], ["读书笔记", 0.2], ["理财", 0.15], ["杂感", 0.1],
  ];
  const rows = [];
  for (let i = 0; i < 34; i += 1) {
    const n = Math.floor(rand() * 90);
    const pick = rand();
    let acc = 0;
    let topic = "杂感";
    for (const [name, p] of topics) {
      acc += p;
      if (pick < acc) { topic = name; break; }
    }
    rows.push({
      date: dateNDaysAgo(n), topic,
      summary: {
        "职业转型": "要不要接内推的机会，纠结通勤和成长空间",
        "健身与精力": "下午三点总是犯困，怀疑和午餐结构有关",
        "读书笔记": "《纳瓦尔宝典》里关于杠杆的段落摘录",
        "理财": "记账三个月，餐饮是大头，先从外卖下手",
        "杂感": "周末什么都不想干，可能就是需要休息",
      }[topic],
    });
  }
  return rows.sort((a, b) => (a.date < b.date ? -1 : 1));
}

// ---------- 快照组装 ----------

const rand = lcg(20260915);

function dataset(fields, rows) {
  return { fields, rows };
}

const FINANCE_FIELDS = [
  { name: "date", type: "date" },
  { name: "category", type: "text" },
  { name: "merchant", type: "text" },
  { name: "amount", type: "number", unit: "元" },
  { name: "note", type: "text" },
];

function fullSnapshot() {
  return {
    version: 1,
    generatedAt: TODAY.toISOString(),
    statics: {
      profile: {
        nickname: "阿林", timezone: "Asia/Shanghai",
        weekdayRoutine: "工作日 10:00-19:00，通勤地铁 40 分钟",
        note: "独居，工作日晚上常点外卖",
      },
    },
    datasets: {
      "finance.transactions": dataset(FINANCE_FIELDS, buildFinanceRows(lcg(101))),
      "health.sleep": dataset([
        { name: "date", type: "date" },
        { name: "value", type: "number", unit: "小时" },
        { name: "deepPct", type: "number", unit: "%" },
        { name: "remPct", type: "number", unit: "%" },
        { name: "efficiency", type: "number", unit: "%" },
        { name: "bedtimeMinutes", type: "number", unit: "分钟" },
        { name: "wakeMinutes", type: "number", unit: "分钟" },
        { name: "interruptions", type: "number", unit: "次" },
      ], buildSleepRows(lcg(202))),
      "health.steps": dataset([
        { name: "date", type: "date" },
        { name: "value", type: "number", unit: "步" },
      ], buildStepRows(lcg(303))),
      "health.workouts": dataset([
        { name: "date", type: "date" },
        { name: "type", type: "text" },
        { name: "minutes", type: "number", unit: "分钟" },
        { name: "calories", type: "number", unit: "千卡" },
      ], buildWorkoutRows(lcg(404))),
      "habit.records": dataset([
        { name: "date", type: "date" },
        { name: "habit", type: "text" },
        { name: "value", type: "number" },
        { name: "note", type: "text" },
      ], buildHabitRows(lcg(505))),
      "task.tasks": dataset([
        { name: "date", type: "date" },
        { name: "title", type: "text" },
        { name: "completed", type: "number" },
        { name: "list", type: "text" },
      ], buildTaskRows(lcg(606))),
      "goal.goals": dataset([
        { name: "name", type: "text" },
        { name: "progressPct", type: "number", unit: "%" },
        { name: "deadline", type: "date" },
        { name: "note", type: "text" },
      ], buildGoalRows()),
      "thought.thoughts": dataset([
        { name: "date", type: "date" },
        { name: "topic", type: "text" },
        { name: "summary", type: "text" },
      ], buildThoughtRows(lcg(707))),
    },
  };
}

function financeOnlySnapshot() {
  const snap = fullSnapshot();
  snap.datasets = { "finance.transactions": snap.datasets["finance.transactions"] };
  return snap;
}

function financeNoDiningSnapshot() {
  const snap = financeOnlySnapshot();
  snap.datasets["finance.transactions"].rows = snap.datasets["finance.transactions"].rows
    .filter((row) => row.category !== "餐饮");
  return snap;
}

function sleepEmptySnapshot() {
  const snap = fullSnapshot();
  snap.datasets["health.sleep"].rows = [];
  return snap;
}

// ---------- 样本清单（30 条：方案 §9.3 领域矩阵——财务/健康/习惯/任务/目标/想法/跨域/无数据/简单查数） ----------

const SAMPLES = [
  { id: "F01", question: "为什么这个月又超支了？", snapshot: fullSnapshot },
  { id: "F02", question: "这个月钱都花哪了？", snapshot: fullSnapshot },
  { id: "F03", question: "最近奶茶咖啡喝得是不是有点多？", snapshot: fullSnapshot },
  { id: "F04", question: "为什么晚上总是忍不住点外卖？", snapshot: fullSnapshot },
  { id: "F05", question: "按现在这个节奏，月底大概会花多少钱？", snapshot: fullSnapshot },
  { id: "F06", question: "这个月和上个月比，支出变化大吗？", snapshot: fullSnapshot },
  { id: "F07", question: "我每个月固定要花多少钱？", snapshot: fullSnapshot },
  { id: "F08", question: "这个月最大的一笔花销是什么？值不值？", snapshot: fullSnapshot },
  { id: "F09", question: "工作日和周末花钱差别大吗？", snapshot: fullSnapshot },
  { id: "F10", question: "这个月一共花了多少钱？", snapshot: fullSnapshot }, // 数数型：应克制直答
  { id: "F11", question: "餐饮和购物哪个花得多？差多少？", snapshot: fullSnapshot },
  { id: "F12", question: "给我这个月的消费做个全面复盘", snapshot: fullSnapshot },
  { id: "H01", question: "最近睡得好吗？", snapshot: fullSnapshot },
  { id: "H02", question: "我的深睡够不够？", snapshot: fullSnapshot },
  { id: "H03", question: "这个月的睡眠比上个月好了还是差了？", snapshot: fullSnapshot },
  { id: "H04", question: "我作息规律吗？", snapshot: fullSnapshot },
  { id: "H05", question: "最近运动量怎么样？", snapshot: fullSnapshot },
  { id: "X01", question: "晚上熬夜的时候，花钱是不是也变多了？", snapshot: fullSnapshot }, // 跨域
  { id: "X02", question: "睡得晚的日子，第二天任务完成得怎么样？", snapshot: fullSnapshot }, // 跨域
  { id: "B01", question: "习惯坚持得怎么样？", snapshot: fullSnapshot },
  { id: "B02", question: "烟抽得多了还是少了？", snapshot: fullSnapshot },
  { id: "B03", question: "这个月冥想了多少次？", snapshot: fullSnapshot }, // 数数型
  { id: "T01", question: "最近的任务完成得如何？", snapshot: fullSnapshot },
  { id: "T02", question: "我的待办是不是堆积太多了？", snapshot: fullSnapshot },
  { id: "G01", question: "我的目标进展怎么样？", snapshot: fullSnapshot },
  { id: "C01", question: "最近我都在想些什么？", snapshot: fullSnapshot },
  { id: "N01", question: "分析一下我的餐饮支出结构", snapshot: financeNoDiningSnapshot }, // 数据缺失：餐饮被裁掉
  { id: "N02", question: "我的睡眠有什么问题吗？", snapshot: sleepEmptySnapshot }, // 空 records
  { id: "N03", question: "我最近炒股收益怎么样？", snapshot: financeOnlySnapshot }, // 无此数据域
];

// ---------- 内存任务存储（接口对齐 cloudAnalysisTaskStore，最小实现） ----------

function createMemoryTaskStore() {
  const tasks = new Map();
  return {
    create({ id, deviceId, question, snapshot, taskType }) {
      const task = {
        id: id ?? `sample-${tasks.size + 1}`, device_id: deviceId, question,
        snapshot, task_type: taskType ?? "deep_analysis", status: "queued",
      };
      tasks.set(task.id, task);
      return task;
    },
    get(id) { return tasks.get(id) ?? null; },
    getDecrypted(id) { return tasks.get(id) ?? null; },
    transition(id, to) {
      const task = tasks.get(id);
      if (!task) return false;
      task.status = to;
      return true;
    },
    complete({ id, result }) {
      const task = tasks.get(id);
      if (!task) return false;
      task.status = "completed";
      task.result = result;
      return true;
    },
    fail({ id, reason }) {
      const task = tasks.get(id);
      if (!task) return false;
      task.status = "failed";
      task.failureReason = reason;
      return true;
    },
    updateStage() { return true; },
  };
}

// ---------- 轻量记账（usage/轮次/耗时；不动生产库） ----------

function createMemoryAiCallLogger() {
  const calls = [];
  const open = new Map();
  return {
    calls,
    startAiCall({ deviceId, purpose, model, request }) {
      const call = {
        id: `call-${calls.length + 1}`, deviceId, purpose, model,
        taskId: request?.taskId ?? null, round: request?.round ?? null,
        status: "running", usage: null,
      };
      open.set(call.id, call);
      calls.push(call);
      return call.id;
    },
    finishAiCall(id, { status, usage }) {
      const call = open.get(id);
      if (!call) return;
      call.status = status;
      call.usage = usage
        ? { prompt: usage.prompt_tokens ?? 0, completion: usage.completion_tokens ?? 0 }
        : { prompt: 0, completion: 0 };
    },
  };
}

// ---------- 主流程 ----------

async function main() {
  const [outPath, ...onlyIds] = process.argv.slice(2);
  if (!outPath) {
    console.error("用法: node scripts/warm-p0-samples.mjs <out.jsonl> [sampleId ...]");
    process.exit(2);
  }
  const config = loadConfig();
  const route = config.routes.agent_loop;
  if (!route) {
    console.error("agent_loop 路由未配置（检查 env：HOLO_AGENT_LOOP_PROVIDER/HOLO_CHAT_PROVIDER）");
    process.exit(2);
  }
  const provider = createOpenAICompatibleProvider(config.providers[route.provider]);
  if (!config.providers[route.provider]?.apiKey) {
    console.error(`provider ${route.provider} 缺少 apiKey，样本无法调用真实模型`);
    process.exit(2);
  }
  console.log(`[samples] provider=${route.provider} model=${route.model} temp=${route.temperature} effort=${route.reasoningEffort}`);

  const store = createMemoryTaskStore();
  const aiCallLogger = createMemoryAiCallLogger();
  const executor = createCloudAnalysisExecutor({
    taskStore: store,
    providers: new Map([[route.provider, provider]]),
    route,
    providerRetries: 2,
    aiCallLogger,
    log: (...args) => console.log("[executor]", ...String(args[0]).split("\n")[0]),
  });

  const samples = onlyIds.length > 0
    ? SAMPLES.filter((s) => onlyIds.includes(s.id))
    : SAMPLES;

  const fs = await import("node:fs");
  const out = fs.createWriteStream(outPath, { flags: "w" });

  let index = 0;
  for (const sample of samples) {
    index += 1;
    const callCountBefore = aiCallLogger.calls.length;
    const startedAt = Date.now();
    const snapshot = sample.snapshot();
    const task = store.create({
      deviceId: "warm-p0-samples",
      question: sample.question,
      snapshot: JSON.stringify(snapshot),
    });
    const status = await executor.run(task.id);
    const final = store.get(task.id);
    const usage = aiCallLogger.calls.slice(callCountBefore).reduce(
      (acc, call) => ({
        prompt: acc.prompt + (call.usage?.prompt ?? 0),
        completion: acc.completion + (call.usage?.completion ?? 0),
      }),
      { prompt: 0, completion: 0 },
    );
    const record = {
      id: sample.id,
      question: sample.question,
      datasetKeys: Object.keys(snapshot.datasets),
      status,
      failureReason: final?.failureReason ?? null,
      durationMs: Date.now() - startedAt,
      rounds: Math.max(0, ...aiCallLogger.calls.slice(callCountBefore).map((c) => c.round ?? 0)) || null,
      usage,
      result: final?.status === "completed" ? JSON.parse(final.result) : null,
    };
    out.write(JSON.stringify(record) + "\n");
    console.log(
      `[samples ${index}/${samples.length}] ${sample.id} status=${status} rounds=${record.rounds} ` +
      `claims=${record.result?.claims?.length ?? 0} narrative=${record.result?.narrativeSummary ? "Y" : "-"} ` +
      `keyInsight=${record.result?.keyInsight ? "Y" : "-"} ${record.durationMs}ms`,
    );
    await new Promise((resolve) => setTimeout(resolve, 2000));
  }
  out.end();

  const totalUsage = aiCallLogger.calls.reduce(
    (acc, call) => ({
      prompt: acc.prompt + (call.usage?.prompt ?? 0),
      completion: acc.completion + (call.usage?.completion ?? 0),
    }),
    { prompt: 0, completion: 0 },
  );
  console.log(
    `[samples] 完成：${samples.length} 条 / ${aiCallLogger.calls.length} 次模型调用 / ` +
    `prompt=${totalUsage.prompt}tok completion=${totalUsage.completion}tok`,
  );
}

main().catch((error) => {
  console.error("[samples] 致命错误:", error?.stack ?? error);
  process.exit(1);
});
