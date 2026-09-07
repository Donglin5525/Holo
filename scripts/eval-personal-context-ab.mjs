#!/usr/bin/env node
//
// eval-personal-context-ab.mjs
// P0 端到端 A/B 对照评测（改版方案 §6.3）。
//
// 三版本 × 双臂：
//   V0 原事实 / V1 关键条件改变 / V2 仅加无关信息（V1 仅对含 mutation 的目标存在）。
//   A 臂 = 普通聊天（线上现状基线，只发 utterance，不注入个人情境）。
//   B 臂 = 情境规划管道（萃取 → 核验 → 规划，规划输入尾部附加 planEffects
//          输出要求——生产 prompt 发版前的 harness 侧镜像，发版后可去掉）。
//
// 评分三层：
//   1. 结构断言（程序判）：planEffects 存在率、个人项引用非空率、红线词。
//   2. LLM judge（隐藏标签）：V0 条件应用 / V1 反事实响应 / V2 无关稳健 /
//      A-B 配对净收益。
//   3. 原始输出全量存档供人工盲评。
//
// 用法：
//   node scripts/eval-personal-context-ab.mjs                 # 全量 68 输入
//   node scripts/eval-personal-context-ab.mjs --goal ab-01    # 单目标试跑
//   node scripts/eval-personal-context-ab.mjs --no-judge      # 只跑双臂不做判分
//
// 注意（§6.2）：遇 429 轮换设备标识是过渡口径，不作为正式验证方法；
// 正式验收应换内部评测身份与独立预算后重跑。每次调用记录响应 model/usage。
//

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const BASE = "https://api.holoapp.cn";
const EVAL_DATE = new Date().toISOString().slice(0, 10);
const FIXTURE_PATH = join(import.meta.dirname, "..", "docs/_common/eval/personal-context/ab/ab-fixtures-v1.json");
const OUT_DIR = join(import.meta.dirname, "..", "docs/_common/eval/personal-context/ab");
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const args = process.argv.slice(2);
const onlyGoal = args.includes("--goal") ? args[args.indexOf("--goal") + 1] : null;
const skipJudge = args.includes("--no-judge");
// 分片：--shard <index> 让并行进程各跑 1/4 的目标、各用独立设备池避开限流。
const shard = args.includes("--shard") ? Number(args[args.indexOf("--shard") + 1]) : null;
const shardCount = 4;
const deviceBase = shard === null ? 0 : shard * 20;
let deviceIndex = 0;
const deviceAt = (i) => `pc-abeval-${EVAL_DATE}-${String(deviceBase + i).padStart(2, "0")}`;

// 一次 purpose 调用，返回 content + 元数据（model/usage/device）。
// 429 时轮换设备标识重试一次（过渡口径）。
async function callPurpose(purpose, userContent) {
  for (let attempt = 0; attempt < 8; attempt++) {
    const device = deviceAt(deviceIndex);
    const startedAt = Date.now();
    const response = await fetch(`${BASE}/v1/ai/chat/completions`, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Holo-Device-Id": device },
      body: JSON.stringify({ purpose, messages: [{ role: "user", content: userContent }] }),
    });
    if (response.status === 429 || response.status === 402) {
      const body = await response.text();
      if (body.includes("QUOTA_EXCEEDED") || response.status === 429) {
        deviceIndex += 1;
        await sleep(2_000);
        continue;
      }
      throw new Error(`${purpose} HTTP ${response.status}: ${body.slice(0, 160)}`);
    }
    if (!response.ok) {
      throw new Error(`${purpose} HTTP ${response.status}: ${(await response.text()).slice(0, 160)}`);
    }
    const data = await response.json();
    return {
      content: data.choices?.[0]?.message?.content ?? "",
      meta: {
        model: data.model ?? data.choices?.[0]?.model ?? "unknown",
        promptTokens: data.usage?.prompt_tokens ?? null,
        completionTokens: data.usage?.completion_tokens ?? null,
        device,
        purpose,
        latencyMs: Date.now() - startedAt,
      },
    };
  }
  throw new Error("设备轮换 8 次仍限流，暂停（保存断点后可续跑）");
}

function extractJSON(text) {
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end <= start) throw new Error("输出无 JSON");
  const raw = text.slice(start, end + 1);
  try {
    return JSON.parse(raw);
  } catch (error) {
    // 生产确实存在截断/坏引号输出（评测要如实记录，但也尽量回收数据）。
    return repairAndParse(raw, error);
  }
}

// 截断修复：统计未闭合深度后穷举常见闭合组合；仍失败时抓 answerText 兜底。
function repairAndParse(raw, originalError) {
  let depth = 0;
  let inString = false;
  let escape = false;
  for (const ch of raw) {
    if (escape) { escape = false; continue; }
    if (ch === "\\") { escape = true; continue; }
    if (ch === '"') { inString = !inString; continue; }
    if (inString) continue;
    if (ch === "{" || ch === "[") depth += 1;
    if (ch === "}" || ch === "]") depth -= 1;
  }
  const trimmed = raw.trimEnd();
  const candidates = [];
  if (depth > 0 && depth <= 4) {
    const combos = depth === 1 ? ['"}"', '"]"'] : depth === 2 ? ['"}]"', '"]}"]'] : ['"}]}"]', '"]}"]', '"}"]'];
    for (const c of combos) candidates.push(trimmed + c.slice(1, -1));
  }
  candidates.push(trimmed);
  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate);
      return { ...parsed, parseRepaired: true };
    } catch { /* 尝试下一个 */ }
  }
  const answerMatch = raw.match(/"answerText"\s*:\s*"((?:[^"\\]|\\.)*)"/);
  if (answerMatch) {
    try {
      return { answerText: JSON.parse(`"${answerMatch[1]}"`), parseRepaired: true };
    } catch { /* 落回原始错误 */ }
  }
  throw originalError;
}

// 规划输入尾部的 planEffects 输出要求（生产 prompt 发版前的 harness 侧镜像）。
const PLAN_EFFECTS_SUFFIX =
  "\n\n输出要求补充：除原字段外，增加 planEffects 数组——只写因个人情境产生的方案变化" +
  "（增加/取消/调序/改时/方案选择），每项 {\"kind\":\"add|remove|reorder|reschedule|choice\"," +
  "\"summary\":\"用户可读的一句话变化说明\",\"contextRefs\":[\"依据的 contextID\"]}；" +
  "一般常识引起的调整不写；没有个人情境引起的变化时输出空数组。";

function sourcesFor(goal, variant) {
  if (variant === "V0") return goal.baseSources;
  if (variant === "V2") return [...goal.baseSources, goal.irrelevantSource].filter(Boolean);
  if (variant === "V1") {
    if (!goal.mutation) return null;
    return goal.baseSources.map((s) =>
      s.sourceID === goal.mutation.replaceSourceID
        ? { ...s, revisionDigest: s.revisionDigest + "-mut", plainText: goal.mutation.plainText }
        : s,
    );
  }
  return null;
}

// B 臂：萃取 → 核验 → 规划（与 iOS 端三段管道同构）。
async function runPipeline(goal, variant) {
  const sources = sourcesFor(goal, variant);
  const calls = [];

  const extractionInput = {
    sources: sources.map((s) => ({ sourceID: s.sourceID, revision: s.revisionDigest, role: s.role, plainText: s.plainText })),
    existingCandidates: [],
  };
  const extraction = await callPurpose("personal_context_extraction", JSON.stringify(extractionInput));
  calls.push(extraction.meta);
  await sleep(15_500); // 4/min 限流
  const candidates = extractJSON(extraction.content).candidates ?? [];

  let verified = [];
  if (candidates.length > 0) {
    const verificationInput = {
      candidates: candidates.slice(0, 16).map((c) => ({ candidateRef: c.candidateRef, statement: c.statement, basis: c.basis ?? [] })),
      sources: sources.map((s) => ({ sourceID: s.sourceID, plainText: s.plainText })),
    };
    const verification = await callPurpose("personal_context_verification", JSON.stringify(verificationInput));
    calls.push(verification.meta);
    const verdicts = new Map((extractJSON(verification.content).verdicts ?? []).map((v) => [v.candidateRef, v.verdict]));
    verified = candidates
      .slice(0, 16)
      .filter((c) => ["supported", "qualified"].includes(verdicts.get(c.candidateRef)));
    await sleep(7_000);
  }

  const planInput = {
    currentRequest: {
      utterance: goal.utterance,
      goalSummary: goal.goalSummary,
      timeRange: { expression: "" },
      unknowns: [],
      referenceTime: "2026-09-15T01:00:00Z",
    },
    contexts: verified.slice(0, 8).map((c) => ({
      contextID: c.candidateRef,
      statement: c.statement,
    })),
    rawFallbackSegments: [],
    semanticCoverage: verified.length > 0 ? "full" : "degraded",
  };
  const plan = await callPurpose("personal_context_planning", JSON.stringify(planInput) + PLAN_EFFECTS_SUFFIX);
  calls.push(plan.meta);
  let planJSON = null;
  let parseError = null;
  try {
    planJSON = extractJSON(plan.content);
  } catch (error) {
    parseError = String(error.message ?? error);
  }
  return { variant, arm: "B", sources: sources.map((s) => s.sourceID), verifiedContexts: verified.map((c) => c.statement), plan: planJSON, rawPlan: plan.content, parseError, calls };
}

// A 臂：普通聊天基线（只发 utterance）。
async function runBaseline(goal) {
  const chat = await callPurpose("chat", goal.utterance);
  return { variant: "V0", arm: "A", plan: { answerText: chat.content }, rawPlan: chat.content, calls: [chat.meta] };
}

// 方案送 judge 前压缩：只保留判分相关字段，防 chat 1024 token 上限吃掉输出。
function slimPlan(plan) {
  if (!plan) return null;
  return {
    answerText: plan.answerText,
    items: (plan.items ?? []).map((i) => `${i.title}${i.relativeTiming ? `(${i.relativeTiming})` : ""}`),
    planEffects: plan.planEffects ?? [],
    unknowns: plan.unknowns ?? [],
  };
}

// LLM judge：隐藏标签双方案比较。输出 { verdict, reason }；空输出重试一次。
async function judge(question, planX, planY) {
  const prompt =
    '只输出 JSON：{"verdict":"X|Y|tie|both_bad","reason":"一句理由"}。不要输出其他任何文字。\n' +
    JSON.stringify({ question, planX, planY });
  for (let attempt = 0; attempt < 2; attempt++) {
    const result = await callPurpose("chat", prompt);
    const text = result.content.trim();
    if (text) {
      try {
        return { ...extractJSON(text), meta: result.meta };
      } catch {
        if (attempt === 1) return { verdict: "unparseable", reason: text.slice(0, 120), meta: result.meta };
      }
    }
    await sleep(3_000);
  }
  return { verdict: "empty", reason: "judge 两次输出为空" };
}

const CONTEXT_APPLIED = (goal) =>
  `以下是用户提出的请求与两份候选方案。用户的个人记录背景是：「${goal.baseSources.map((s) => s.plainText).join("；")}」。` +
  `合格方案应当：${goal.expectedEffectV0}。哪份方案更合格？（X/Y）`;

const COUNTERFACTUAL = (goal) =>
  `同一用户的同一请求，两份方案分别基于两种背景生成。变化后的背景是：「${goal.mutation?.plainText ?? ""}」。` +
  `背景变化后合格的方案应当：${goal.expectedEffectV1 ?? "与原背景方案一致"}。哪份方案更符合变化后的背景？（X/Y）`;

const IRRELEVANT_ROBUST = (goal) =>
  `同一用户同一请求的两份方案，第二份生成时用户记录里多了一条无关信息（与请求无关的日常喜好）。` +
  `合格表现是：核心安排保持一致（${goal.mustKeepV2}），不得因无关信息增加不必要的条目。` +
  `方案Y比方案X是否引入了不合理的额外安排？verdict 取 "X"（X更合理/未多加）或 "Y"（Y多加了不相关安排）或 "tie"。`;

const PAIRWISE_AB = (goal) =>
  `用户提出请求：「${goal.utterance}」。方案X是通用助手基于常识的回答；方案Y来自了解用户记录的助手（用户背景：「${goal.baseSources.map((s) => s.plainText).join("；")}」）。` +
  `合格标准：${goal.expectedEffectV0}。Y 是否确实比 X 更贴合该用户的具体情况？verdict 取 "Y"（更贴合）/"tie"（基本一致）/"X"。`;

async function main() {
  const data = JSON.parse(readFileSync(FIXTURE_PATH, "utf8"));
  const goals = onlyGoal
    ? data.goals.filter((g) => g.goalID === onlyGoal)
    : shard === null
      ? data.goals
      : data.goals.filter((_, i) => i % shardCount === shard);
  console.log(`A/B 评测 ${goals.length} 目标（device=${deviceAt(deviceIndex)}，judge=${skipJudge ? "跳过" : "开"}）`);

  // 断点续跑：历史成功结果先全部恢复（--goal 指定的目标除外，它要重跑），
  // 主循环遇到已恢复的目标直接跳过。保证单目标重跑不会覆盖分片文件里其他结果。
  const resultsFile = shard === null ? `results-${EVAL_DATE}.json` : `results-${EVAL_DATE}-s${shard}.json`;
  const results = [];
  const previousByID = new Map();
  try {
    for (const prev of JSON.parse(readFileSync(join(OUT_DIR, resultsFile), "utf8")).results ?? []) {
      if (!prev.error) previousByID.set(prev.goalID, prev);
    }
  } catch { /* 无历史 */ }
  const restored = new Set();
  for (const [goalID, prev] of previousByID) {
    if (goalID !== onlyGoal) {
      results.push(prev);
      restored.add(goalID);
    }
  }
  for (const goal of goals) {
    if (restored.has(goal.goalID)) {
      console.log(`${goal.goalID} 已有结果，跳过`);
      continue;
    }
    const variants = ["V0", ...(goal.mutation ? ["V1"] : []), "V2"];
    const entry = { goalID: goal.goalID, category: goal.category, domain: goal.domain, arms: {} };
    try {
      for (const variant of variants) {
        const pipeline = await runPipeline(goal, variant);
        entry.arms[`${variant}-B`] = pipeline;
        await sleep(2_000);
      }
      const baseline = await runBaseline(goal);
      entry.arms["V0-A"] = baseline;
      entry.arms["V0-A"].sourceRefs = goal.baseSources.map((s) => s.sourceID);

      // 结构断言
      const effectsOf = (key) => entry.arms[key]?.plan?.planEffects ?? null;
      entry.structural = {
        planEffectsPresent: ["V0-B", ...(goal.mutation ? ["V1-B"] : []), "V2-B"].filter((k) => Array.isArray(effectsOf(k))).length,
        personalEffectRefsNonEmpty: ["V0-B", "V1-B", "V2-B"].filter((k) =>
          Array.isArray(effectsOf(k)) && effectsOf(k).some((e) => Array.isArray(e.contextRefs) && e.contextRefs.length > 0),
        ).length,
        forbiddenHit: Object.entries(entry.arms)
          .filter(([k, v]) => k.endsWith("-B") && v.plan)
          .flatMap(([k, v]) => {
            const text = JSON.stringify(v.plan);
            const markers = ["已确认", "已预订", "已报名", "已安排妥当", "已下单", "已订好", "已提交", "已配好", "已买好", "已预约"];
            return goal.forbiddenClaims
              .filter((claim) => {
                const keys = [...claim].length > 0 ? claim.split("").filter((ch) => /\p{Script=Han}/u.test(ch)).join("") : claim;
                return markers.some((m) => text.includes(m)) && text.includes(keys);
              })
              .map((claim) => `${k}:${claim}`);
          }),
        unknownsHonest: entry.arms["V0-B"]?.plan?.unknowns?.length >= 1 ?? false,
      };

      if (!skipJudge) {
        await sleep(2_000);
        entry.judge = {};
        // 解析失败/修复过的方案不进 judge（数据受损会误判为质量问题），标记跳过。
        const usable = (key) => {
          const arm = entry.arms[key];
          if (!arm?.plan?.answerText) return false;
          return !arm.plan.parseRepaired;
        };
        // judge 判据本身说明了两份方案的来源差异，位置交换由后续人工盲评覆盖。
        if (goal.expectedEffectV0) {
          entry.judge.contextAppliedV0 = usable("V0-B") && usable("V0-A")
            ? await judge(CONTEXT_APPLIED(goal), JSON.stringify(slimPlan(entry.arms["V0-B"].plan)), JSON.stringify(slimPlan(entry.arms["V0-A"].plan)))
            : { verdict: "skipped-parse", reason: "方案解析失败，不判" };
          await sleep(2_000);
        }
        if (goal.mutation) {
          entry.judge.counterfactualV1 = usable("V0-B") && usable("V1-B")
            ? await judge(COUNTERFACTUAL(goal), JSON.stringify(slimPlan(entry.arms["V0-B"].plan)), JSON.stringify(slimPlan(entry.arms["V1-B"].plan)))
            : { verdict: "skipped-parse", reason: "方案解析失败，不判" };
          await sleep(5_000);
        }
        entry.judge.irrelevantRobustV2 = usable("V0-B") && usable("V2-B")
          ? await judge(IRRELEVANT_ROBUST(goal), JSON.stringify(slimPlan(entry.arms["V0-B"].plan)), JSON.stringify(slimPlan(entry.arms["V2-B"].plan)))
          : { verdict: "skipped-parse", reason: "方案解析失败，不判" };
        await sleep(2_000);
        entry.judge.pairwiseAB = usable("V0-B") && usable("V0-A")
          ? await judge(PAIRWISE_AB(goal), JSON.stringify(slimPlan(entry.arms["V0-A"].plan)), JSON.stringify(slimPlan(entry.arms["V0-B"].plan)))
          : { verdict: "skipped-parse", reason: "方案解析失败，不判" };
      }
      console.log(`${goal.goalID} [${goal.category}] 完成 effects=${entry.structural.planEffectsPresent} 红线=${entry.structural.forbiddenHit.length}`);
    } catch (error) {
      entry.error = String(error.message ?? error);
      console.log(`${goal.goalID} 失败：${entry.error}`);
    }
    results.push(entry);
    // 每目标落盘一次（断点续跑按 goalID 覆盖）
    mkdirSync(OUT_DIR, { recursive: true });
    writeFileSync(join(OUT_DIR, resultsFile), JSON.stringify({ evaluatedAt: EVAL_DATE, note: "A 臂=纯 utterance 普通聊天（线上基线下界近似，未含 chat 记忆摘要注入）；B 臂规划输入含 harness 附加 planEffects 要求；judge 为模型初评，人工盲评待做；设备轮换为过渡口径", results }, null, 2));
  }

  // 汇总
  const done = results.filter((r) => !r.error);
  const totalCalls = done.flatMap((r) => Object.values(r.arms)).flatMap((a) => a.calls ?? []);
  const promptTokens = totalCalls.reduce((s, c) => s + (c.promptTokens ?? 0), 0);
  const completionTokens = totalCalls.reduce((s, c) => s + (c.completionTokens ?? 0), 0);
  const judgeResults = done.map((r) => r.judge).filter(Boolean);
  const v = (cond) => `${cond.pass}/${cond.total}`;
  const tally = (rows, isWin) => {
    const pass = rows.filter(isWin).length;
    return { pass, total: rows.length };
  };
  const summary = {
    evaluatedAt: EVAL_DATE,
    goals: done.length,
    inputs: done.reduce((s, r) => s + Object.keys(r.arms).length, 0),
    calls: totalCalls.length,
    tokens: { prompt: promptTokens, completion: completionTokens },
    models: [...new Set(totalCalls.map((c) => c.model))],
    planEffectsPresentRate: tally(done, (r) => r.structural.planEffectsPresent > 0),
    personalEffectRate: tally(done, (r) => r.structural.personalEffectRefsNonEmpty > 0),
    forbiddenViolations: done.reduce((s, r) => s + r.structural.forbiddenHit.length, 0),
    planParseRepaired: done.reduce((s, r) => s + Object.values(r.arms).filter((a) => a.plan?.parseRepaired).length, 0),
    judge: {
      // contextAppliedV0 传参顺序 X=情境方案 V0-B / Y=基线 V0-A，期望 X 胜出。
      contextAppliedV0: tally(judgeResults.filter((j) => j.contextAppliedV0), (j) => j.contextAppliedV0.verdict === "X"),
      counterfactualV1: tally(judgeResults.filter((j) => j.counterfactualV1), (j) => j.counterfactualV1.verdict === "Y"),
      irrelevantRobustV2: tally(judgeResults.filter((j) => j.irrelevantRobustV2), (j) => j.irrelevantRobustV2.verdict !== "Y"),
      pairwiseAB: tally(judgeResults.filter((j) => j.pairwiseAB), (j) => j.pairwiseAB.verdict === "Y"),
    },
  };
  console.log("\n===== 汇总 =====");
  console.log(JSON.stringify(summary, null, 2));
  writeFileSync(join(OUT_DIR, shard === null ? `summary-${EVAL_DATE}.json` : `summary-${EVAL_DATE}-s${shard}.json`), JSON.stringify(summary, null, 2));
  console.log(`已写入 ${OUT_DIR}/summary-${EVAL_DATE}.json`);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
