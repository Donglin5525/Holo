import { test } from "node:test";
import assert from "node:assert/strict";
import { randomBytes } from "node:crypto";
import { createDatabase } from "../src/db/database.js";
import { createCloudAnalysisTaskStore } from "../src/agent/cloudAnalysisTaskStore.js";
import { createCloudAnalysisExecutor } from "../src/agent/cloudAnalysisExecutor.js";
import { generateDeepReport, DeepReportError } from "../src/agent/deepReport/engine.js";
import { resolveRoutedTaskType } from "../src/app.js";

const TEST_KEY = randomBytes(32).toString("base64");
const ROUTES = {
  writer: { provider: "fake", model: "m", temperature: 0.2, maxTokens: 4096, reasoningEffort: "medium", timeoutMs: 120_000 },
  checker: { provider: "fake", model: "m", temperature: 0, maxTokens: 4096, reasoningEffort: "medium", timeoutMs: 120_000 },
};

function snapshot() {
  return {
    generatedAt: "2026-11-07T12:00:00+08:00",
    historyDays: 30,
    answerTask: { primaryTimeRange: { start: 1791388800, end: 1793996800, label: "最近30天" } },
    profileBrief: "称呼我为东林",
    datasets: {
      "finance.transactions": { rows: [
        { occurredAt: "2026-11-01T00:00:00+08:00", amount: 5000, type: "expense", category: "房租", text: "", account: "现金" },
        { occurredAt: "2026-09-20T10:00:00+08:00", amount: 5711, type: "expense", category: "旅游", text: "东京酒店", project: "东京旅行", account: "现金" },
      ] },
"habit.daily": { rows: [
        { occurredAt: "2026-10-09T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 1 },
        { occurredAt: "2026-10-10T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-11T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-12T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-13T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-14T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 1 },
        { occurredAt: "2026-10-15T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-16T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-17T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-18T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-19T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 1 },
        { occurredAt: "2026-10-20T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-21T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-22T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-23T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-24T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 1 },
        { occurredAt: "2026-10-25T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-26T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-27T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-28T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-29T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 1 },
        { occurredAt: "2026-10-30T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-10-31T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-11-01T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-11-02T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-11-03T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 1 },
        { occurredAt: "2026-11-04T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-11-05T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-11-06T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
        { occurredAt: "2026-11-07T00:00:00+08:00", habit: "健身", type: "check", polarity: "positive", goal: 3, value: 0 },
      ] },
    },
  };
}

const GOOD_REPORT = `# 收入涨了，健身断了

东林，整体稳住了，最该做的是把健身接回去。

## 钱去哪了

本期最大头是房租 5000 元。

## 身体

健身最近一次完成是 10月28日。

数据说明：睡眠无数据，不能判断。`;

function makeExecutor(responses, records) {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  let i = 0;
  const provider = {
    async complete(request) {
      records.push({ messages: request.messages, timeoutMs: request.timeoutMs ?? null });
      // 档案指令化调用自动应答（不占响应序列）：system 带「逐条执行指令」特征
      const sys = request.messages?.[0]?.content ?? "";
      if (sys.includes("逐条执行指令")) {
        return { choices: [{ index: 0, message: { role: "assistant", content: JSON.stringify({ directives: ["称呼我为东林"] }) } }], usage: { prompt_tokens: 10, completion_tokens: 5 } };
      }
      const next = responses[i++];
      if (next === undefined) throw new Error("PROVIDER_EXHAUSTED");
      if (typeof next === "function") return next(request);
      return { choices: [{ index: 0, message: { role: "assistant", content: next } }], usage: { prompt_tokens: 10, completion_tokens: 5 } };
    },
  };
  const purposes = [];
  const executor = createCloudAnalysisExecutor({
    taskStore: store,
    providers: new Map([["fake", provider]]),
    route: ROUTES.writer,
    deepReportRoutes: ROUTES,
    providerRetries: 1,
    quotaLedger: {
      reserve: () => { purposes.push("reserve"); return { allowed: true, subjectId: "s", actionId: "a" }; },
      commit: () => purposes.push("commit"),
      release: () => purposes.push("release"),
    },
    entitlementResolver: { resolve: () => ({ usageSubjectId: "s", tier: "free" }) },
    aiCallLogger: {
      startAiCall: (entry) => { purposes.push(entry.purpose); return purposes.length; },
      finishAiCall: () => {},
    },
    log: () => {},
    injectedQuestionTimeResolver: { resolveQuestionTime: async () => null },
  });
  return { executor, store, database, purposes };
}

test("引擎全链：写作 → 数字修复 → 语义修复 → 映射旧契约", async () => {
  const records = [];
  const executorPack = makeExecutor([
    // writer 初稿：一句数字错（99999）+ 一句语义过头（全来自项目，实际不是全部）
    `# 报告标题\n\n导语段。\n\n房租花了 99999 元。\n\n变化全来自东京旅行项目结束。\n\n数据说明：睡眠无数据。`,
    // 数字修复
    `# 报告标题\n\n导语段。\n\n房租花了 5000 元。\n\n变化全来自东京旅行项目结束。\n\n数据说明：睡眠无数据。`,
    // 语义核对员
    () => ({ choices: [{ message: { content: JSON.stringify({ problems: [{ sentence: "变化全来自东京旅行项目结束。", issue: "清单显示总变化中 96.8% 来自项目，不是全部" }] }) } }] }),
    // 语义修复
    `# 报告标题\n\n导语段。\n\n房租花了 5000 元。\n\n变化主要来自东京旅行项目结束。\n\n数据说明：睡眠无数据。`,
    // 复核：无问题
    () => ({ choices: [{ message: { content: JSON.stringify({ problems: [] }) } }] }),
  ], records);
  const task = executorPack.store.create({ deviceId: "dev", question: "整体怎么样", taskType: "deep_report" });
  executorPack.store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(snapshot()) });
  assert.equal(await executorPack.executor.run(task.id), "completed");
  const row = executorPack.store.getDecrypted(task.id, ["result"]);
  const result = JSON.parse(row.result);
  assert.equal(result.engine, "deep-report-v1");
  assert.equal(result.title, "报告标题");
  assert.ok(result.claims.length >= 2);
  assert.equal(result.claims.some((c) => c.displayText.includes("99999")), false, "编的数字被修复");
  assert.equal(result.claims.some((c) => c.displayText.includes("主要来自")), true, "说过头被修复");
  assert.equal(result.taskRange.label, "最近30天");
  // ai_call_logs purpose 序列：writer → repair(数字) → checker → repair(语义) → checker
  const expected = ["cloud_deep_report_profile", "cloud_deep_report_writer", "cloud_deep_report_repair", "cloud_deep_report_checker", "cloud_deep_report_repair", "cloud_deep_report_checker"];
  assert.deepEqual(executorPack.purposes.filter((p) => p.startsWith("cloud_")), expected);
  // 路由级超时透传（writer 120s）
  assert.equal(records[0].timeoutMs, 120_000);
  executorPack.database.db.close();
});

test("保守删句：修复无效时最多删 3 句", async () => {
  // 夹杂足够多的正常段落：删句上限还受「不超过正文 25%」约束，太短的报告会少删
  const badReport = `# 标题\n\n导语段。\n\n错了1句 11111 元。\n\n错了2句 22222 元。\n\n错了3句 33333 元。\n\n错了4句 44444 元。\n\n正常的第1段，讲一点生活里的观察。\n\n正常的第2段，讲一点生活里的观察。\n\n正常的第3段，讲一点生活里的观察。\n\n正常的第4段，讲一点生活里的观察。\n\n正常的第5段，讲一点生活里的观察。\n\n正常的第6段，讲一点生活里的观察。\n\n数据说明：无。`;
  const records = [];
  const pack = makeExecutor([
    badReport,
    badReport, // 数字修复原样返回（数字删句预算用掉 3 句，只剩「错了4句」）
    // 核对员只能看到删句后的报告（与真实模型一致，不会点名已删除的句子）
    () => ({ choices: [{ message: { content: JSON.stringify({ problems: [
      { sentence: "错了4句 44444 元。", issue: "数字错误" },
    ] }) } }] }),
    badReport, // 语义修复也原样返回
    () => ({ choices: [{ message: { content: JSON.stringify({ problems: [
      { sentence: "错了4句 44444 元。", issue: "数字错误" },
    ] }) } }] }),
  ], records);
  const task = pack.store.create({ deviceId: "dev", question: "q", taskType: "deep_report" });
  pack.store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(snapshot()) });
  assert.equal(await pack.executor.run(task.id), "completed");
  const result = JSON.parse(pack.store.getDecrypted(task.id, ["result"]).result);
  const deleted = result.claims.filter((c) => c.displayText.startsWith("错了")).length;
  assert.equal(deleted, 1, "4 句问题句最多删 3 句：数字核对删 3，预算用尽后第 4 句保留");
});

test("writer 缺标题：给一次补写机会", async () => {
  const records = [];
  const pack = makeExecutor([
    "没有标题的正文第一段。\n\n第二段。",
    `# 补上的标题\n\n没有标题的正文第一段。\n\n第二段。`,
    () => ({ choices: [{ message: { content: JSON.stringify({ problems: [] }) } }] }),
  ], records);
  const task = pack.store.create({ deviceId: "dev", question: "q", taskType: "deep_report" });
  pack.store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(snapshot()) });
  assert.equal(await pack.executor.run(task.id), "completed");
  const result = JSON.parse(pack.store.getDecrypted(task.id, ["result"]).result);
  assert.equal(result.title, "补上的标题");
});

test("写作完全不可用：任务失败、额度释放、不落半成品", async () => {
  const records = [];
  const pack = makeExecutor(["没有段落"], records);
  const task = pack.store.create({ deviceId: "dev", question: "q", taskType: "deep_report" });
  pack.store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(snapshot()) });
  assert.equal(await pack.executor.run(task.id), "failed");
  assert.equal(pack.purposes.includes("release"), true);
  assert.equal(pack.purposes.includes("commit"), false);
});

test("目标回顾任务不走新引擎", async () => {
  const pack = makeExecutor([], []);
  const task = pack.store.create({ deviceId: "dev", question: "目标走到哪了", taskType: "deep_report" });
  const snap = snapshot();
  snap.goalScope = { goalID: "g" };
  pack.store.attachSnapshot({ id: task.id, snapshot: JSON.stringify(snap) });
  assert.equal(await pack.executor.run(task.id), "failed");
  const row = pack.store.getDecrypted(task.id, ["failureReason"]);
  assert.match(row.failureReason, /目标回顾暂不支持深度报告引擎/);
});

test("generateDeepReport 纯管线：checker 不点头也不修时直接删并完成", async () => {
  const calls = [];
  const responses = [
    () => { calls.push("writer"); return "# 标题\n\n导语段。\n\n对了 5000 元。\n\n数据说明：无。"; },
    () => ({ choices: [{ message: { content: JSON.stringify({ problems: [] }) } }] }),
  ];
  let i = 0;
  const callModel = async (messages) => {
    // 档案指令化调用自动应答，不占响应序列
    if ((messages?.[0]?.content ?? "").includes("逐条执行指令")) return JSON.stringify({ directives: ["称呼我为东林"] });
    const r = responses[i++]();
    return typeof r === "string" ? r : r.choices[0].message.content;
  };
  const { result, stats } = await generateDeepReport({
    snapshot: snapshot(),
    question: "q",
    callModel,
    buildWriterMessages: (u) => [{ role: "system", content: "s" }, { role: "user", content: u }],
    checkerSystemPrompt: "c",
    routes: ROUTES,
  });
  assert.equal(result.claims.length, 1);
  assert.equal(stats.flaggedNumbers, 0);
  assert.equal(stats.semanticProblems, 0);
});

test("路由灰度矩阵：开关 + 设备白名单", () => {
  const base = { deepReportEngine: { enabled: true, deviceIds: [] } };
  assert.equal(resolveRoutedTaskType(base, "d1", "deep_analysis"), "deep_report", "开关开+白名单空=全部");
  assert.equal(resolveRoutedTaskType({ deepReportEngine: { enabled: true, deviceIds: ["d1"] } }, "d1", "deep_analysis"), "deep_report");
  assert.equal(resolveRoutedTaskType({ deepReportEngine: { enabled: true, deviceIds: ["d1"] } }, "d2", "deep_analysis"), "deep_analysis", "白名单外设备走旧引擎");
  assert.equal(resolveRoutedTaskType({ deepReportEngine: { enabled: false, deviceIds: [] } }, "d1", "deep_analysis"), "deep_analysis", "开关关走旧引擎");
  assert.equal(resolveRoutedTaskType(base, "d1", "period_replay"), "period_replay", "只改写 deep_analysis");
});
