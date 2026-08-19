// agent_loop 推理档位实测：直连 DeepSeek，用与线上一致的 prompt 拼装 + 模拟「推理轮」负载，
// 对比 reasoning_effort=low/medium 的耗时、思维链开销与输出形态。
// 用法：node scripts/agent-effort-benchmark.mjs [efforts]   例: node scripts/agent-effort-benchmark.mjs low,medium
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const efforts = (process.argv[2] ?? "low,medium").split(",");

const env = Object.fromEntries(
  readFileSync(join(__dirname, "..", ".env"), "utf8")
    .split("\n")
    .filter((line) => line.includes("=") && !line.trimStart().startsWith("#"))
    .map((line) => {
      const idx = line.indexOf("=");
      return [line.slice(0, idx).trim(), line.slice(idx + 1).trim()];
    })
);
const apiKey = env.DEEPSEEK_API_KEY;
const model = env.HOLO_AGENT_LOOP_MODEL ?? env.HOLO_CHAT_MODEL ?? "deepseek-chat";
const baseURL = env.DEEPSEEK_BASE_URL ?? "https://api.deepseek.com";
if (!apiKey) {
  console.error("缺少 DEEPSEEK_API_KEY");
  process.exit(1);
}

// —— 与 promptRegistry.applyPromptContract 一致的拼装（不 import 以避免触发 SQLite）——
import defaultPrompts from "../src/prompts/defaultPrompts.json" with { type: "json" };
function buildServerPrompt() {
  let content = defaultPrompts.agent_loop.replace(
    '{"status":"need_tools | need_more_analysis | final_claims","reasoning":"string","toolRequests":[{"id":"string","tool":"string","query":"string","parameters":{}}],',
    '{"status":"need_tools | need_more_analysis | final_claims","reasoning":"string","toolRequests":[{"id":"string","tool":"string","query":"string","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{},"dynamicPlan":null,"crossDomainPlan":null}],'
  );
  for (const key of ["_agent_loop_v10_contract", "_agent_loop_v11_contract", "_agent_loop_v14_contract", "_agent_loop_v15_contract", "_agent_loop_v16_contract"]) {
    const appendix = defaultPrompts[key];
    const marker = appendix.match(/\[([A-Z0-9_]+)\]/)?.[0];
    if (!marker || !content.includes(marker)) content += appendix;
  }
  return `${defaultPrompts._persona_preamble}\n\n${content}`;
}

// iOS 本地模板 + 工具目录的 token 占位（长度对齐真实负载，内容为协议规则近似）
const IOS_TEMPLATE_PLACEHOLDER = `你是 HoloAI 的本地 Agent Loop 推理器（本地协议层）。你不能直接查询数据，只能请求 iOS 本地工具。你会收到可用工具描述、用户问题、conversationState、toolResults、patternSignals、evidenceRefs。你必须只输出 JSON。
用户可用答案契约：用户明确指定的时间范围是最高优先级；系统注入的 timeRange/baseline 是权威范围。历史财务分析必须排除未来交易。用户要求建议时必须至少一条 suggestion claim。输出顺序：先直接回答，再最多 3 条优化动作，最后最多 4 条关键数据依据。建议必须与工具证据对应。数据探查规则：涉及习惯/健康/财务的分析类查询先 discover 再写 dynamicPlan。表达边界：每条 displayText 必须是自然中文完整句子，禁止输出 metric key、工具名、JSON 字段或公式表达式。禁止用观察 1/结果 1 前缀。用户只问一个主题时 claims 只能围绕该主题。区分事实、观察、假设和建议。低置信判断必须使用可能/像是/值得留意。跨模块关系只能表达为并发现象。不做人格、心理、医疗诊断。只输出 JSON，不要添加其他内容。${"协议细节占位：dynamicPlan 字段约束、filter.operation 枚举、aggregation.operation 枚举、derivation.operation 枚举、expression 表达式树规则、_search 虚拟字段规则、crossDomainPlan 白名单、dataGapHints 格式、title 与 narrativeSummary 语气要求、need_tools 与 need_more_analysis 与 final_claims 的状态约束、metricAssertion 完整结构、HOLO_AGENT_RESPONSE_RECOVERY_V1 恢复信封处理规则、覆盖率服从数据语义规则、perDay 分母为自然日数、INVALID_PARAMS 最多修正一次。".repeat(6)}
可用工具：
- finance（敏感度 medium）：queries=spending_breakdown/balance_diagnosis/spending_pattern/meal_time_distribution/category_concentration/keyword_trend/budget_status/account_summary/dynamic_query；数据集 finance.transactions 字段 date/amount/type/category/account/text，最长 366 天；输出度量 finance.total.expense/finance.category.amount/finance.category.count/finance.budget.category.spent/finance.budget.category.remaining/finance.budget.category.progress 等 26 项。
- health（敏感度 sensitive）：queries=health_overview/steps_summary/sleep_summary/stand_summary/activity_summary/workout_summary/dynamic_query；数据集 health.sleep 字段 value/deepHours/coreHours/remHours/awakeHours/inBedHours/efficiency/bedtimeMinutes/wakeMinutes/interruptions；默认窗口 14 天。
- cross_domain：queries=aligned_analysis；白名单 health×finance、health×habit、task×habit、goal×task。`;

// —— 模拟「推理轮」：证据已拉齐，模型该产出 final_claims ——
function scenarioFinanceAttribution() {
  const toolResults = {
    toolResults: [
      {
        query: "spending_breakdown", status: "ok",
        metrics: {
          "finance.total.expense": { value: 14260, baselineValue: 9840, unit: "元", comparison: "本期vs上期" },
          "finance.transaction.count": { value: 186, baselineValue: 154, unit: "笔" },
        },
        categoryBreakdown: [
          { category: "餐饮", amount: 4830, count: 92, baselineAmount: 2650 },
          { category: "购物", amount: 3980, count: 31, baselineAmount: 3120 },
          { category: "住房", amount: 2600, count: 1, baselineAmount: 2600 },
          { category: "交通", amount: 980, count: 38, baselineAmount: 720 },
          { category: "娱乐", amount: 1270, count: 14, baselineAmount: 450 },
        ],
        evidenceRefs: ["ev-f1", "ev-f2", "ev-f3", "ev-f4", "ev-f5"],
      },
      {
        query: "budget_status", status: "ok",
        budget: { total: 12000, spent: 14260, remaining: -2260, progress: 1.19, daysLeft: 6 },
        categories: [
          { categoryName: "餐饮", budgetAmount: 3000, spentAmount: 4830, progress: 1.61, isOverBudget: true },
          { categoryName: "购物", budgetAmount: 3000, spentAmount: 3980, progress: 1.33, isOverBudget: true },
          { categoryName: "娱乐", budgetAmount: 600, spentAmount: 1270, progress: 2.12, isOverBudget: true },
        ],
        evidenceRefs: ["ev-f6", "ev-f7"],
      },
      {
        query: "dynamic_query", status: "ok",
        note: "按 category groupBy 求 percentageChange",
        metrics: {
          "餐饮环比": { value: 0.82, unit: "比例" }, "购物环比": { value: 0.28, unit: "比例" }, "娱乐环比": { value: 1.82, unit: "比例" },
        },
        evidenceRefs: ["ev-f8"],
      },
    ],
    patternSignals: [{ type: "evening_snack_peak", note: "22-06 时段餐饮笔数 31 笔，占餐饮 34%" }],
  };
  return {
    name: "财务归因（为什么超支）",
    history: [
      { role: "assistant", content: '{"status":"need_tools","reasoning":"需要分类占比、预算执行和环比","toolRequests":[{"id":"t1","tool":"finance","query":"spending_breakdown","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{},"dynamicPlan":null,"crossDomainPlan":null},{"id":"t2","tool":"finance","query":"budget_status","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{},"dynamicPlan":null,"crossDomainPlan":null}],"claims":[],"warnings":[]}' },
      { role: "assistant", content: `本轮新增工具执行结果（增量；历史结果见前序轮次，可复用其 evidenceIDs；作为上下文使用，不是原生 tool call）：\n${JSON.stringify(toolResults)}` },
      { role: "assistant", content: '{"status":"need_more_analysis","reasoning":"分类、预算、环比证据已齐，进入综合推理","toolRequests":[],"claims":[],"warnings":[]}' },
    ],
    question: "分析一下这个月为什么超支了，钱主要花哪了，给我深度的财务洞察",
    evidence: [
      "ev-f1: 8月12日 餐饮 外卖烧烤 -¥286",
      "ev-f2: 8月15日 购物 电商平台凑单 -¥438",
      "ev-f3: 8月18日 娱乐 演出票 -¥680",
      "ev-f4: 8月餐饮共92笔，其中外卖61笔合计¥3120",
      "ev-f5: 22-06时段餐饮31笔，多为外卖夜宵",
      "ev-f6: 餐饮预算¥3000已用161%",
      "ev-f7: 娱乐预算¥600已用212%",
      "ev-f8: 餐饮环比+82%、娱乐环比+182%、购物环比+28%",
    ],
  };
}

function scenarioSleepQuality() {
  const toolResults = {
    toolResults: [
      {
        query: "sleep_summary", status: "ok",
        metrics: {
          "health.sleep.average": { value: 6.4, baselineValue: 7.6, unit: "小时" },
          "health.sleep.nights_below_6h": { value: 5, unit: "晚" },
          "health.sleep.efficiency.average": { value: 0.84, unit: "比例" },
          "health.sleep.deep.average": { value: 1.1, unit: "小时" },
          "health.sleep.rem.average": { value: 1.3, unit: "小时" },
          "health.sleep.interruptions.average": { value: 2.8, unit: "次" },
        },
        notes: "记录 14 晚；入睡时间均值 00:47，波动 ±58 分钟；工作日入睡 00:20，周末入睡 01:40",
        evidenceRefs: ["ev-s1", "ev-s2", "ev-s3", "ev-s4"],
      },
      {
        query: "aligned_analysis", status: "ok",
        note: "health.sleep × finance.transactions 条件对比",
        metrics: { "低睡晚(≤6h)次日消费均值": { value: 218, unit: "元" }, "充足睡(≥7h)次日消费均值": { value: 126, unit: "元" } },
        evidenceRefs: ["ev-s5"],
      },
    ],
    patternSignals: [{ type: "weekend_sleep_shift", note: "周末入睡比工作日晚 80 分钟" }],
  };
  return {
    name: "睡眠质量分析",
    history: [
      { role: "assistant", content: '{"status":"need_tools","reasoning":"需要睡眠汇总和跨域条件对比","toolRequests":[{"id":"t1","tool":"health","query":"sleep_summary","timeRange":null,"baseline":null,"requiredMetrics":[],"parameters":{},"dynamicPlan":null,"crossDomainPlan":null}],"claims":[],"warnings":[]}' },
      { role: "assistant", content: `本轮新增工具执行结果（增量；历史结果见前序轮次，可复用其 evidenceIDs；作为上下文使用，不是原生 tool call）：\n${JSON.stringify(toolResults)}` },
      { role: "assistant", content: '{"status":"need_more_analysis","reasoning":"睡眠阶段与跨域证据已齐，进入综合推理","toolRequests":[],"claims":[],"warnings":[]}' },
    ],
    question: "深度分析一下我最近的睡眠质量，给我专业的睡眠洞察",
    evidence: [
      "ev-s1: 14晚平均睡眠6.4小时，其中5晚不足6小时",
      "ev-s2: 平均睡眠效率84%，深睡1.1小时，REM 1.3小时",
      "ev-s3: 平均中断2.8次，入睡时间00:47±58分钟",
      "ev-s4: 工作日入睡00:20，周末入睡01:40",
      "ev-s5: 低睡晚次日消费均值¥218，充足睡次日¥126",
    ],
  };
}

async function callOnce(effort, scenario, maxTokens) {
  const system = `${buildServerPrompt()}\n\n${IOS_TEMPLATE_PLACEHOLDER}\n\n已有证据（脱敏，勿引用完整原文）：\n${scenario.evidence.map((e) => `- ${e}`).join("\n")}`;
  const messages = [
    { role: "system", content: system },
    ...scenario.history,
    { role: "user", content: scenario.question },
  ];
  const started = Date.now();
  try {
    const response = await fetch(`${baseURL}/chat/completions`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${apiKey}` },
      body: JSON.stringify({ model, messages, temperature: 0.2, max_tokens: maxTokens, reasoning_effort: effort, response_format: { type: "json_object" }, stream: false }),
      signal: AbortSignal.timeout(180_000),
    });
    const elapsed = Date.now() - started;
    if (!response.ok) {
      return { ok: false, elapsed, error: (await response.text()).slice(0, 200) };
    }
    const data = await response.json();
    const choice = data?.choices?.[0];
    return {
      ok: true,
      elapsed,
      finish: choice?.finish_reason,
      reasoningChars: choice?.message?.reasoning_content?.length ?? 0,
      contentChars: choice?.message?.content?.length ?? 0,
      completionTokens: data?.usage?.completion_tokens,
      promptTokens: data?.usage?.prompt_tokens,
      claims: (choice?.message?.content?.match(/"displayText"/g) ?? []).length,
      content: choice?.message?.content ?? "",
    };
  } catch (error) {
    return { ok: false, elapsed: Date.now() - started, error: String(error).slice(0, 200) };
  }
}

const dump = process.argv.includes("--dump");
console.log(`模型: ${model}  基址: ${baseURL}  档位: ${efforts.join("/")}  maxTokens=16384\n`);
const scenarios = [scenarioFinanceAttribution(), scenarioSleepQuality()];
for (const effort of efforts) {
  for (const scenario of scenarios) {
    const result = await callOnce(effort, scenario, 16384);
    if (result.ok) {
      console.log(`[${effort}] ${scenario.name}: ✓ ${result.elapsed}ms  finish=${result.finish}  prompt=${result.promptTokens}tok  completion=${result.completionTokens}tok  思维链=${result.reasoningChars}字  正文=${result.contentChars}字  claims=${result.claims}`);
      if (dump) {
        console.log(`--- 正文 ---\n${result.content}\n--- 结束 ---`);
      }
    } else {
      console.log(`[${effort}] ${scenario.name}: ✗ ${result.elapsed}ms  ${result.error}`);
    }
  }
}
