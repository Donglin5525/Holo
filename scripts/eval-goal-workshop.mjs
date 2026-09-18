#!/usr/bin/env node
// 目标共创 P0 冻结场景评测（2026-09-17 完整开发计划任务 7）
//
// 对 45 个冻结场景（HoloTests/Fixtures/GoalWorkshop/goal-workshop-scenarios-v1.json）
// 逐个走 goal_workshop purpose 的三轮契约（understand → propose_options → build_plan），
// 客户端按 §2.2 同口径校验每轮响应，逐场景产出结果与汇总报告。
//
// 用法：
//   node scripts/eval-goal-workshop.mjs [--base-url http://localhost:8787] [--device-id xxx] [--out outputs/goal-workshop-eval]
// 环境要求：目标后端已配置 goal_workshop 路由的真实 Provider（mock 只验链路不验质量）。
// 产出：outputs/goal-workshop-eval/（生成物不入库）。
//
// 注意：本脚本自动判定「契约可解析/可确认」与结构红线；「问题是否抓关键缺口、
// 路径是否合理」属人工评审维度，报告中以 needsHumanReview 标出，不得用平均分代替。

import { parseArgs } from "node:util";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const FIXTURES = join(REPO_ROOT, "Holo/Holo APP/Holo/HoloTests/Fixtures/GoalWorkshop/goal-workshop-scenarios-v1.json");

const { values: args } = parseArgs({
  options: {
    "base-url": { type: "string", default: process.env.HOLO_EVAL_BASE_URL ?? "http://localhost:8787" },
    "device-id": { type: "string", default: process.env.HOLO_EVAL_DEVICE_ID ?? "goal-workshop-eval-runner" },
    out: { type: "string", default: "outputs/goal-workshop-eval" },
    limit: { type: "string" },
  },
});

const strictDay = (text) =>
  typeof text === "string" && text.length === 10 && /^\d{4}-\d{2}-\d{2}$/.test(text) &&
  !Number.isNaN(Date.parse(`${text}T00:00:00Z`)) && !/^0000/.test(text) &&
  dayRoundTrip(text);

function dayRoundTrip(text) {
  const date = new Date(`${text}T00:00:00Z`);
  const y = date.getUTCFullYear(), m = String(date.getUTCMonth() + 1).padStart(2, "0"), d = String(date.getUTCDate()).padStart(2, "0");
  return `${y}-${m}-${d}` === text;
}

function validateResponse(parsed, sessionID, revision, turn) {
  const violations = [];
  if (parsed.schemaVersion !== 1) violations.push(`schemaVersion=${parsed.schemaVersion}`);
  if (parsed.sessionID !== sessionID) violations.push("sessionID 未回显");
  if (parsed.revision !== revision) violations.push(`revision 未回显(${parsed.revision}!=${revision})`);
  if (!["question", "options", "plan"].includes(parsed.kind)) violations.push(`未知 kind=${parsed.kind}`);

  const kinds = { question: !!parsed.question, options: Array.isArray(parsed.options), plan: !!parsed.plan };
  const present = Object.entries(kinds).filter(([, v]) => v).map(([k]) => k);
  if (present.length !== 1) violations.push(`载荷互斥失败:${present.join("+")}`);

  if (parsed.kind === "question") {
    if (!parsed.question?.text || !parsed.question?.whyItMatters) violations.push("question 缺字段");
  }
  if (parsed.kind === "options") {
    const options = parsed.options ?? [];
    if (options.length < 1 || options.length > 3) violations.push(`options 数量 ${options.length}`);
    const ids = options.map((option) => option.id);
    if (new Set(ids).size !== ids.length) violations.push("options id 重复");
    if (parsed.recommendedOptionID && !ids.includes(parsed.recommendedOptionID)) violations.push("推荐引用悬空");
    for (const option of options) {
      if (!option.title || !option.fit || !option.effort || !option.tradeoff || !option.reason) {
        violations.push(`路径字段缺失:${option.id ?? "?"}`);
      }
    }
  }
  if (parsed.kind === "plan") {
    const plan = parsed.plan ?? {};
    if (!plan.draft?.title?.trim()) violations.push("标题为空");
    if (!plan.successEvidence?.trim()) violations.push("成功证据为空");
    const actions = [...(plan.draft?.tasks ?? []), ...(plan.draft?.habits ?? [])];
    const actionIDs = actions.map((action) => action.id);
    if (new Set(actionIDs).size !== actionIDs.length) violations.push("行动 id 重复");
    if (plan.firstActionID && !actionIDs.includes(plan.firstActionID)) violations.push("firstAction 悬空");
    if (plan.draft?.sourceHabitId != null) violations.push("越权关联既有习惯");
    const dates = [plan.draft?.deadlineText, ...(plan.draft?.tasks ?? []).map((task) => task.dueDateText),
      ...(plan.milestones ?? []).map((milestone) => milestone.dateText), plan.reviewDate].filter(Boolean);
    for (const date of dates) if (!strictDay(date)) violations.push(`非法日期:${date}`);
  }
  for (const fact of parsed.facts ?? []) {
    if (fact.provenance === "userStated" || fact.provenance === "authorizedRecord") {
      violations.push(`模型代答事实来源:${fact.provenance}`);
    }
  }
  if (turn === "propose_options" && parsed.kind !== "options" && parsed.kind !== "plan") {
    violations.push(`propose_options 轮返回 ${parsed.kind}`);
  }
  if (turn === "build_plan" && parsed.kind !== "plan") violations.push(`build_plan 轮返回 ${parsed.kind}`);
  if (/\b(已保存|已创建|已为你创建|saved)/.test(parsed.assistantText ?? "")) violations.push("声称已保存");
  return violations;
}

async function callModel(baseUrl, deviceId, body) {
  const response = await fetch(`${baseUrl}/v1/ai/chat/completions`, {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": deviceId },
    body: JSON.stringify(body),
  });
  if (!response.ok) {
    throw new Error(`HTTP ${response.status}: ${await response.text()}`);
  }
  const json = await response.json();
  return json.choices?.[0]?.message?.content ?? "";
}

function buildRequestBody(state, operation, sameRevision = false) {
  // 同客户端口径：beginModelRequest 先 +1，请求体带推进后的 revision（模型须回显该值）；
  // 受控重试同 revision 重发（GoalWorkshopCoordinator.applyResponse 口径）
  if (!sameRevision) state.revision += 1;
  return {
    purpose: "goal_workshop",
    stream: false,
    messages: [{
      role: "user",
      content: JSON.stringify({
        schemaVersion: 1,
        sessionID: state.sessionID,
        revision: state.revision,
        operation,
        input: state.input,
        skippedQuestion: state.skippedQuestion,
        sessionSnapshot: {
          phase: state.phase,
          questionsAsked: state.questionsAsked,
          originalText: state.originalText,
          activeFacts: state.facts,
          routeOptions: state.routeOptions,
          selectedRouteID: state.selectedRouteID,
          goalDefinition: null,
          today: state.today,
        },
        contextRefs: [],
      }),
    }],
  };
}

const stripFence = (raw) => raw.replace(/^```(json)?\n?/, "").replace(/\n?```$/, "").trim();

/// 一轮调用：解析/校验失败做一次受控重试（同 revision、input=null、skippedQuestion=false），
/// 与客户端 applyResponse 的非法输出重试同口径；返回 parsed 与累计 violations。
async function callTurn(baseUrl, deviceId, state, operation, label) {
  let violations = [];
  for (let attempt = 0; attempt < 2; attempt += 1) {
    const raw = await callModel(baseUrl, deviceId, buildRequestBody(state, operation, attempt > 0));
    if (attempt > 0) { state.input = null; state.skippedQuestion = false; }
    let parsed = null;
    try {
      parsed = JSON.parse(stripFence(raw));
    } catch {
      violations.push(`[${label}] 响应非合法 JSON（第 ${attempt + 1} 次）`);
      continue;
    }
    violations = validateResponse(parsed, state.sessionID, state.revision, label)
      .map((v) => `[${label}] ${v}`);
    if (violations.length === 0) return { parsed, violations };
    violations = violations.map((v) => attempt > 0 ? v : `${v}（重试后仍违反）`);
  }
  return { parsed: null, violations };
}

/// 同 GoalWorkshopSessionV1.apply：question/options/plan 推进 + inference 事实整组替换 + touch
function applyResponseToState(state, parsed) {
  if (parsed.kind === "question") state.questionsAsked += 1;
  if (parsed.kind === "options") {
    state.routeOptions = parsed.options ?? [];
    state.phase = "exploring";
  }
  if (parsed.kind === "plan") state.phase = "reviewing";
  const inferences = (parsed.facts ?? []).filter((fact) => fact.provenance === "inference");
  state.facts = state.facts.filter((fact) => fact.provenance !== "inference").concat(inferences);
  state.revision += 1;
}

async function runScenario(baseUrl, deviceId, scenario) {
  const state = {
    sessionID: crypto.randomUUID(),
    revision: 0,
    questionsAsked: 0,
    originalText: scenario.input,
    facts: [{ id: crypto.randomUUID(), text: scenario.input, provenance: "userStated",
              sourceID: null, sourceRevision: null, isRetracted: false }],
    phase: "understanding",
    routeOptions: [],
    selectedRouteID: null,
    today: new Date().toISOString().slice(0, 10),
    skippedQuestion: false,
    input: scenario.input,
  };
  const result = { id: scenario.id, domain: scenario.domain, turns: [], violations: [], needsHumanReview: true };
  try {
    // 轮 1：understand（同 start：input=原话，skippedQuestion=false）
    const understandTurn = await callTurn(baseUrl, deviceId, state, "understand", "understand");
    result.violations.push(...understandTurn.violations);
    let parsed = understandTurn.parsed;
    if (!parsed) throw new Error("understand 轮两次响应均不可用");
    result.turns.push({ turn: "understand", kind: parsed.kind, assistantText: parsed.assistantText ?? null,
      question: parsed.question ?? null });
    applyResponseToState(state, parsed);

    // 轮 2：propose_options（同 requestOptions：input=null，skippedQuestion=true，
    // 快照带轮 1 后的完整会话状态——修复前固定发空会话快照导致模型继续追问）
    state.input = null;
    state.skippedQuestion = true;
    const optionsTurn = await callTurn(baseUrl, deviceId, state, "propose_options", "propose_options");
    result.violations.push(...optionsTurn.violations);
    parsed = optionsTurn.parsed;
    if (!parsed) throw new Error("propose_options 轮两次响应均不可用");
    result.turns.push({ turn: "propose_options", kind: parsed.kind,
      optionCount: parsed.options?.length ?? 0, recommended: parsed.recommendedOptionID ?? null });
    applyResponseToState(state, parsed);

    // choose（同 choose(routeID:)：纯状态迁移 + touch，不发请求）
    state.selectedRouteID = parsed.recommendedOptionID ?? parsed.options?.[0]?.id ?? null;
    state.phase = "choosing";
    state.revision += 1;
    state.skippedQuestion = false;

    // 轮 3：build_plan（同 generatePlan：input=null，快照带真实 options 与选择）
    state.input = null;
    const planTurn = await callTurn(baseUrl, deviceId, state, "build_plan", "build_plan");
    result.violations.push(...planTurn.violations);
    parsed = planTurn.parsed;
    if (!parsed) throw new Error("build_plan 轮两次响应均不可用");
    result.turns.push({ turn: "build_plan", kind: parsed.kind,
      title: parsed.plan?.draft?.title ?? null,
      taskCount: parsed.plan?.draft?.tasks?.length ?? 0,
      habitCount: parsed.plan?.draft?.habits?.length ?? 0,
      assumptionCount: parsed.plan?.assumptions?.length ?? 0 });

    result.contractOK = result.violations.length === 0 && result.turns[2]?.kind === "plan";
  } catch (error) {
    result.error = String(error.message ?? error);
    result.contractOK = false;
  }
  return result;
}

async function main() {
  const fixtures = JSON.parse(readFileSync(FIXTURES, "utf8"));
  const scenarios = args.limit ? fixtures.scenarios.slice(0, Number(args.limit)) : fixtures.scenarios;
  const outDir = join(REPO_ROOT, args.out);
  mkdirSync(outDir, { recursive: true });

  // 设备额度轮换：chat 池 free 档 15 次/天/设备，每场景 3 轮（+重试余量），
  // 每 4 个场景换一个本地设备 ID，避免单设备撞额度（本地库匿名设备，不消耗生产额度）
  const SCENARIOS_PER_DEVICE = 4;
  let deviceOrdinal = 0;
  const deviceIdFor = (index) =>
    `${args["device-id"]}-${Math.floor(index / SCENARIOS_PER_DEVICE)}`;

  console.log(`评测 ${scenarios.length} 个冻结场景 → ${args["base-url"]}`);
  const results = [];
  for (const [index, scenario] of scenarios.entries()) {
    const deviceId = deviceIdFor(index);
    if (Math.floor(index / SCENARIOS_PER_DEVICE) !== deviceOrdinal) {
      deviceOrdinal = Math.floor(index / SCENARIOS_PER_DEVICE);
      console.log(`  —— 切换评测设备 ${deviceId} ——`);
    }
    const result = await runScenario(args["base-url"], deviceId, scenario);
    results.push(result);
    const mark = result.contractOK ? "PASS" : "FAIL";
    console.log(`  [${mark}] ${scenario.id} (${scenario.domain})${result.violations.length ? " :: " + result.violations.join("; ") : ""}${result.error ? " :: " + result.error : ""}`);
  }

  const contractOKCount = results.filter((r) => r.contractOK).length;
  const summary = {
    ranAt: new Date().toISOString(),
    baseUrl: args["base-url"],
    total: results.length,
    contractOK: contractOKCount,
    gate_P0_minParseable: `${contractOKCount}/${results.length}（门槛 ≥36/40 可解析且可供确认）`,
    structuralRedLines: {
      modelClaimedUserFact: results.filter((r) => r.violations.some((v) => v.includes("模型代答"))).length,
      modelClaimedSaved: results.filter((r) => r.violations.some((v) => v.includes("声称已保存"))).length,
    },
    needsHumanReview: ["问题是否抓关键缺口", "路径是否有实质取舍", "成功标准是否可观察", "第一步是否可做", "路径建议合理性 ≥32/40"],
  };
  writeFileSync(join(outDir, "results.json"), JSON.stringify(results, null, 2));
  writeFileSync(join(outDir, "summary.json"), JSON.stringify(summary, null, 2));
  console.log("\n汇总：", JSON.stringify(summary, null, 2));
  console.log(`报告：${outDir}/results.json`);
}

main().catch((error) => {
  console.error("评测脚本失败：", error);
  process.exitCode = 1;
});
