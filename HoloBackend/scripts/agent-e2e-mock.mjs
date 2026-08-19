// 端到端 v21 效果验证：起本地后端后，模拟 iOS 完整多轮 agent_loop 协议。
// 第一轮模型自己决定拉什么数据（验证 v21 是否驱动它拉 90 天基线），按其请求 mock 工具结果回填，
// 直到 final_claims。工具数据为 mock（财务含 6 期月度矩阵，睡眠含阶段/作息/跨域）。
// 用法：node scripts/agent-e2e-mock.mjs finance|sleep|counting
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const scenarioKey = process.argv[2] ?? "finance";
const baseUrl = "http://localhost:8787";
const deviceId = "v21-e2e-mock-device";

import defaultPrompts from "../src/prompts/defaultPrompts.json" with { type: "json" };

// 与 serverPromptPolicy.injectServerPrompt 一致：persona + agent_loop（锚点 replace 后）+ 契约追加
function buildServerSystem() {
  let content = defaultPrompts.agent_loop.replace(
    '{"status":"need_tools | need_more_analysis | final_claims","title":"string 或 null（final_claims 时给一句话标题，其余状态 null）","narrativeSummary":"string 或 null（final_claims 时给一段自然摘要，其余状态 null）","keyInsight":"string 或 null（final_claims 时给一句跨维度核心发现，≤40字，须综合至少两个维度，无真综合给 null，其余状态 null）","reasoning":"string","toolRequests":[{"id":"string","tool":"string","query":"string","parameters":{}}],',
    '{"status":"need_tools | need_more_analysis | final_claims","title":"string 或 null（final_claims 时给一句话标题，其余状态 null）","narrativeSummary":"string 或 null（final_claims 时给一段自然摘要，其余状态 null）","keyInsight":"string 或 null（final_claims 时给一句跨维度核心发现，≤40字，须综合至少两个维度，无真综合给 null，其余状态 null）","reasoning":"string","toolRequests":[{"id":"string","tool":"string","query":"string","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{},"dynamicPlan":null,"crossDomainPlan":null}],'
  );
  for (const key of ["_agent_loop_v10_contract", "_agent_loop_v11_contract", "_agent_loop_v14_contract", "_agent_loop_v15_contract", "_agent_loop_v16_contract", "_agent_loop_v21_contract"]) {
    const appendix = defaultPrompts[key];
    const marker = appendix.match(/\[([A-Z0-9_]+)\]/)?.[0];
    if (!marker || !content.includes(marker)) content += appendix;
  }
  return `${defaultPrompts._persona_preamble}\n\n${content}`;
}

const IOS_SYSTEM_PLACEHOLDER = `你是 HoloAI 的本地 Agent Loop 推理器（本地协议层）。你不能直接查询数据，只能请求 iOS 本地工具。你会收到可用工具描述、用户问题、conversationState、toolResults、patternSignals、evidenceRefs。你必须只输出 JSON。
可用工具：
- finance（敏感度 medium）：queries=spending_breakdown/balance_diagnosis/spending_pattern/meal_time_distribution/category_concentration/keyword_trend/budget_status/account_summary/dynamic_query；数据集 finance.transactions 字段 date/amount/type/category/account/text，最长 366 天；输出度量 finance.total.expense/finance.category.amount/finance.category.count/finance.budget.category.spent/finance.budget.category.remaining/finance.budget.category.progress 等。
- health（敏感度 sensitive）：queries=health_overview/steps_summary/sleep_summary/stand_summary/activity_summary/workout_summary/dynamic_query；数据集 health.sleep 字段 value/deepHours/coreHours/remHours/awakeHours/inBedHours/efficiency/bedtimeMinutes/wakeMinutes/interruptions；默认窗口 14 天，dynamic_query 最长 366 天。
- cross_domain：queries=aligned_analysis；白名单 health×finance、health×habit、task×habit、goal×task。
- discover：queries=list；探查用户实际有哪些数据。`;

// ===== mock 数据池 =====
// 财务：6 期月度分类矩阵。餐饮连续 4 期上行且本期加速；娱乐本期翻倍；购物/住房稳定。
const FINANCE_MONTHLY = [
  { month: "2026-03", 餐饮: 2650, 娱乐: 450, 购物: 3120, 住房: 2600, 交通: 700 },
  { month: "2026-04", 餐饮: 2580, 娱乐: 380, 购物: 2900, 住房: 2600, 交通: 690 },
  { month: "2026-05", 餐饮: 2820, 娱乐: 520, 购物: 3300, 住房: 2600, 交通: 720 },
  { month: "2026-06", 餐饮: 3100, 娱乐: 410, 购物: 3050, 住房: 2600, 交通: 710 },
  { month: "2026-07", 餐饮: 3350, 娱乐: 450, 购物: 2980, 住房: 2600, 交通: 730 },
  { month: "2026-08", 餐饮: 4830, 娱乐: 1270, 购物: 3980, 住房: 2600, 交通: 980 },
];
const SLEEP_MONTHLY = [
  { month: "2026-06", avgHours: 7.4, deepHours: 1.5, remHours: 1.6, efficiency: 0.88, interruptions: 2.0, bedtimeAvgMinutes: 35 },
  { month: "2026-07", avgHours: 7.0, deepHours: 1.3, remHours: 1.5, efficiency: 0.86, interruptions: 2.4, bedtimeAvgMinutes: 46 },
  { month: "2026-08", avgHours: 6.4, deepHours: 1.1, remHours: 1.3, efficiency: 0.84, interruptions: 2.8, bedtimeAvgMinutes: 67 },
];

let evidenceSeq = 0;
function evId(prefix) { evidenceSeq += 1; return `ev-${prefix}${evidenceSeq}`; }

function mockToolResult(request, scenario) {
  const query = request.query;
  const tool = request.tool;
  if (query === "list" || tool === "discover") {
    return { query: "list", status: "ok", datasets: ["finance.transactions", "health.sleep", "health.steps"], notes: "finance 366 天 186 笔；health.sleep 90 天 84 晚" };
  }
  if (query === "budget_status") {
    return {
      query, status: "ok",
      metrics: {
        "finance.budget.total": { value: 12000, unit: "元" },
        "finance.budget.total.spent": { value: 14260, unit: "元" },
      },
      budget: { total: 12000, spent: 14260, remaining: -2260, progress: 1.19, daysLeft: 6 },
      categories: [
        { categoryName: "餐饮", budgetAmount: 3000, spentAmount: 4830, remainingAmount: -1830, progress: 1.61, isOverBudget: true, evidenceID: evId("b") },
        { categoryName: "娱乐", budgetAmount: 600, spentAmount: 1270, remainingAmount: -670, progress: 2.12, isOverBudget: true, evidenceID: evId("b") },
        { categoryName: "购物", budgetAmount: 3000, spentAmount: 3980, remainingAmount: -980, progress: 1.33, isOverBudget: true, evidenceID: evId("b") },
        { categoryName: "住房", budgetAmount: 2600, spentAmount: 2600, remainingAmount: 0, progress: 1.0, isOverBudget: false, evidenceID: evId("b") },
      ],
      evidenceRefs: [],
    };
  }
  if (query === "spending_breakdown") {
    return {
      query, status: "ok",
      metrics: {
        "finance.total.expense": { value: 14260, baselineValue: 10110, unit: "元", comparison: "本月vs上月" },
        "finance.transaction.count": { value: 186, baselineValue: 154, unit: "笔" },
      },
      categoryBreakdown: [
        { category: "餐饮", amount: 4830, count: 92, baselineAmount: 3350, evidenceID: evId("f") },
        { category: "购物", amount: 3980, count: 31, baselineAmount: 2980, evidenceID: evId("f") },
        { category: "住房", amount: 2600, count: 1, baselineAmount: 2600, evidenceID: evId("f") },
        { category: "娱乐", amount: 1270, count: 14, baselineAmount: 450, evidenceID: evId("f") },
        { category: "交通", amount: 980, count: 38, baselineAmount: 730, evidenceID: evId("f") },
      ],
      topExpenses: [
        { date: "2026-08-12", category: "餐饮", text: "外卖烧烤夜宵", amount: -286, evidenceID: evId("f") },
        { date: "2026-08-18", category: "娱乐", text: "演出票两张", amount: -680, evidenceID: evId("f") },
      ],
      evidenceRefs: [],
    };
  }
  if (query === "sleep_summary") {
    return {
      query, status: "ok",
      metrics: {
        "health.sleep.average": { value: 6.4, baselineValue: 7.6, unit: "小时" },
        "health.sleep.nights_below_6h": { value: 5, unit: "晚" },
        "health.sleep.nights_goal_met": { value: 1, unit: "晚" },
        "health.sleep.deep.average": { value: 1.1, unit: "小时" },
        "health.sleep.rem.average": { value: 1.3, unit: "小时" },
        "health.sleep.efficiency.average": { value: 0.84, unit: "比例" },
        "health.sleep.interruptions.average": { value: 2.8, unit: "次" },
        "health.sleep.duration.stddev": { value: 1.2, unit: "小时" },
        "health.sleep.bedtime.average.minutes": { value: 67, unit: "分钟", comparison: "相对0点" },
        "health.sleep.bedtime.weekday.minutes": { value: 40, unit: "分钟", comparison: "工作日入睡约00:40" },
        "health.sleep.bedtime.weekend.minutes": { value: 100, unit: "分钟", comparison: "周末入睡约01:40" },
      },
      recordedNights: 14, evidenceRefs: [],
    };
  }
  if (query === "aligned_analysis" || request.crossDomainPlan) {
    return {
      query, status: "ok",
      metrics: {
        "低睡晚(≤6h)次日消费均值": { value: 218, unit: "元", evidenceID: evId("x") },
        "充足睡(≥7h)次日消费均值": { value: 126, unit: "元", evidenceID: evId("x") },
        "对齐天数": { value: 14, unit: "天" },
      },
      evidenceRefs: [],
    };
  }
  if (query === "dynamic_query" && request.dynamicPlan) {
    const plan = request.dynamicPlan;
    const source = plan.source ?? "";
    const groups = (plan.groupBy ?? []).map((g) => g.type ?? g.field).join("+");
    if (source.includes("sleep")) {
      if (groups.includes("month")) {
        return {
          query, status: "ok", note: "health.sleep 按月聚合",
          rows: SLEEP_MONTHLY.map((m) => ({ group: m.month, average_sleep_hours: m.avgHours, average_deep_hours: m.deepHours, average_efficiency: m.efficiency })),
          evidenceRefs: [evId("s")],
        };
      }
      return {
        query, status: "ok", note: "health.sleep 汇总（90天84晚）",
        metrics: {
          "average_sleep_hours": { value: 6.9, unit: "小时", comparison: "近90天均值（个人常态基线）" },
          "average_deep_hours": { value: 1.3, unit: "小时" },
          "low_sleep_nights_90d": { value: 11, unit: "晚", comparison: "不足6小时" },
        },
        evidenceRefs: [evId("s")],
      };
    }
    // finance：按月分组给全 6 期；否则给聚合
    if (groups.includes("month")) {
      return {
        query, status: "ok", note: "finance.transactions 按月×分类聚合（6期）",
        rows: FINANCE_MONTHLY.flatMap((m) => ["餐饮", "娱乐", "购物", "住房", "交通"].map((cat) => ({
          month: m.month, category: cat, amount: m[cat], count: Math.max(1, Math.round(m[cat] / 52)),
        }))),
        evidenceRefs: [evId("m")],
      };
    }
    return {
      query, status: "ok", note: "finance.transactions 聚合",
      metrics: {
        "total_expense": { value: 14260, unit: "元" },
        "evening_food_count_22_06": { value: 31, unit: "笔", comparison: "22-06时段餐饮" },
        "evening_food_amount_22_06": { value: 1720, unit: "元", comparison: "22-06时段餐饮" },
      },
      evidenceRefs: [evId("m")],
    };
  }
  // 通用兜底：返回合理结构，模型可继续
  return { query, status: "ok", metrics: {}, note: "mock 数据", evidenceRefs: [evId("g")] };
}

// ===== 场景 =====
const SCENARIOS = {
  finance: {
    question: "分析一下这个月为什么超支了，钱主要花哪了，给我深度的财务洞察",
    deliverables: "diagnosis, directAnswer, ranking",
    range: "本月（2026-08-01 至 2026-09-01，exclusive）；start=2026-08-01；end(exclusive)=2026-09-01",
    profile: "分析型（singleDomainAnalysis）",
  },
  sleep: {
    question: "深度分析一下我最近的睡眠质量，给我专业的睡眠洞察",
    deliverables: "diagnosis, directAnswer",
    range: "最近 14 天；start=2026-08-05；end(exclusive)=2026-08-19",
    profile: "分析型（sensitiveAnalysis）",
  },
  counting: {
    question: "这个月总共花了多少钱？",
    deliverables: "directAnswer",
    range: "本月（2026-08-01 至 2026-09-01，exclusive）；start=2026-08-01；end(exclusive)=2026-09-01",
    profile: "数数型（simpleLookup）",
  },
};

async function callAgentLoop(messages) {
  const response = await fetch(`${baseUrl}/v1/ai/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": deviceId },
    body: JSON.stringify({ purpose: "agent_loop", messages, stream: false }),
    signal: AbortSignal.timeout(120_000),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`);
  const data = await response.json();
  return data.choices?.[0]?.message?.content ?? "";
}

const scenario = SCENARIOS[scenarioKey];
if (!scenario) { console.error("未知场景：", scenarioKey); process.exit(1); }

const contract = `[HOLO_AGENT_ANSWER_CONTRACT_V1]
用户问题的确定性交付物：${scenario.deliverables}。
权威查询时间：${scenario.range}。
查询画像：${scenario.profile}（本地确定性分类信号，供 HOLO_AGENT_ANALYSIS_MASTERY_V21 分档使用）。
- 权威查询时间来自用户原话，所有 toolRequest、dynamicPlan、crossDomainPlan 必须使用它，禁止自行缩成"近30天"等其他范围。
- final_claims 必须先直接回答用户问题，再给最关键证据；不能只罗列指标。
- 历史事实只统计 snapshotCutoffAt 之前已经发生的数据。`;

const conversation = [
  { role: "system", content: buildServerSystem() },
  { role: "system", content: IOS_SYSTEM_PLACEHOLDER },
  { role: "system", content: contract },
  { role: "user", content: scenario.question },
];

console.log(`\n========== 场景 [${scenarioKey}] ==========`);
for (let round = 1; round <= 5; round++) {
  const raw = await callAgentLoop(conversation);
  let output;
  try { output = JSON.parse(raw); } catch { console.log(`第${round}轮非JSON:`, raw.slice(0, 200)); break; }
  console.log(`\n--- 第${round}轮 status=${output.status} ---`);
  if (output.status === "need_tools") {
    for (const req of output.toolRequests ?? []) {
      console.log(`  请求工具: ${req.tool}.${req.query}` +
        (req.dynamicPlan ? ` dynamicPlan{source=${req.dynamicPlan.source}, groupBy=${JSON.stringify((req.dynamicPlan.groupBy ?? []).map((g) => g.type ?? g.field))}, timeRange=${req.dynamicPlan.timeRange?.label ?? "默认"}}` : ""));
    }
    conversation.push({ role: "assistant", content: raw });
    const results = (output.toolRequests ?? []).map((req) => mockToolResult(req, scenarioKey));
    conversation.push({ role: "assistant", content: `本轮新增工具执行结果（增量；历史结果见前序轮次，可复用其 evidenceIDs；作为上下文使用，不是原生 tool call）：\n${JSON.stringify({ toolResults: results, patternSignals: [] })}` });
    continue;
  }
  if (output.status === "final_claims") {
    console.log(`title: ${output.title}`);
    console.log(`keyInsight: ${output.keyInsight}`);
    console.log(`narrativeSummary: ${output.narrativeSummary}`);
    for (const claim of output.claims ?? []) {
      console.log(`\n[${claim.type}] ${claim.displayText}`);
      if (claim.interpretation) console.log(`  ↳ 解读: ${claim.interpretation}`);
    }
    if (output.warnings?.length) console.log(`\nwarnings: ${output.warnings.join(" | ")}`);
    break;
  }
  conversation.push({ role: "assistant", content: raw });
}
