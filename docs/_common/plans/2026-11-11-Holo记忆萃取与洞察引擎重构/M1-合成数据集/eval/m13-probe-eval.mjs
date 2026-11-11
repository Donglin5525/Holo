#!/usr/bin/env node
// M1.3 双模型提案小样（2026-11-12）
// 用途：同一组 10 条合成语义证据材料，分别让 qwen3.7-flash 与 deepseek-flash
// 输出「候选理解提案」，供东林人工对比选型。只许 flash 档（项目 AI 红线）。
//
//   node m13-probe-eval.mjs [--limit N] [--only qwen|deepseek]
//
// key 从 HoloBackend/.env（本机开发文件）读取；成本按后端台账基准
// ¥3/M 入、¥9/M 出（config.js 定价基准）折算。失败不自动重试（单次记录）。

import { readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DATASET = join(HERE, "..", "probe-materials.jsonl");
const RESULTS = join(HERE, "results");

// ---------- env ----------
const envText = readFileSync(join(HERE, "..", "..", "..", "..", "..", "..", "HoloBackend", ".env"), "utf8");
const env = Object.fromEntries(
  envText.split("\n").filter((l) => l.includes("=") && !l.trim().startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
);
if (!env.DASHSCOPE_API_KEY || !env.DEEPSEEK_API_KEY) {
  console.error("缺少 DASHSCOPE_API_KEY / DEEPSEEK_API_KEY（HoloBackend/.env）");
  process.exit(1);
}

const MODELS = {
  qwen: {
    label: "qwen3.7-flash（dashscope，生产同款）",
    url: "https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions",
    key: env.DASHSCOPE_API_KEY,
    body: { model: "qwen3.7-flash", temperature: 0.3, enable_thinking: false },
  },
  deepseek: {
    label: "deepseek-flash（生产同款）",
    url: "https://api.deepseek.com/chat/completions",
    key: env.DEEPSEEK_API_KEY,
    body: { model: "deepseek-flash", temperature: 0.3 },
  },
};

// ---------- prompt（提案器 v0，与 11-11 工程稿 §2.2 对齐的精简版） ----------
const SYSTEM = `你是 Holo 生活理解引擎的「提案器」。输入是关于同一个人的一组观察材料（已脱敏、程序预整理；不含金额与精确数值）。

任务：基于材料提出【最多 2 条】值得查证的候选理解。每条输出：
{
  "claimType": "role(生活角色/责任) | preference(偏好) | recurringBehavior(重复行为) | phaseState(阶段状态) | conditionalAssociation(条件性关联)",
  "statement": "一句话命题（中文）",
  "supportingRefs": ["观察的 oid"],
  "alternativeExplanations": ["1-2 个与此候选直接竞争的合理解释"],
  "verificationPlan": [{"op": "retrieveRelated|checkOwnership|comparePeriods|compareConditions|alignEvents|searchCounterEvidence|checkCoverage", "question": "这步想查什么"}],
  "whatWouldChangeTheAnswer": "成立后会改变哪类回答",
  "evidenceGrade": "线索 | 支持",
  "action": "adopt(证据充分可直接采用) | observe(仅观察) | ask(建议补问)"
}

硬规则：
1. 证据不足时宁可 observe/ask，不给强命题；材料只有购买记录时禁止说「使用/饮用」。
2. attribution 为 unknown 时不得默认是本人的；proxy 是明确的代办。
3. timePrecision 为 midnight-default 的时间不可当真实发生时刻用。
4. 禁止医疗诊断、禁止人格/心理标签、禁止把条件导致的作息当偏好。
5. 提不出可执行查证计划的候选不要输出；没有值得提的候选就输出空数组。
6. 只输出 JSON：{"candidates": [...], "noValueReason": "空数组时填一句原因"}`;

// ---------- 调用 ----------
async function callModel(model, material) {
  const body = {
    ...MODELS[model].body,
    messages: [
      { role: "system", content: SYSTEM },
      { role: "user", content: `观察材料（id=${material.id}）：\n${JSON.stringify(material.observations, null, 2)}` },
    ],
    max_tokens: maxTokens,
  };
  const started = Date.now();
  const resp = await fetch(MODELS[model].url, {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${MODELS[model].key}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(90_000),
  });
  const json = await resp.json();
  if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${JSON.stringify(json).slice(0, 300)}`);
  const choice = json.choices?.[0]?.message?.content ?? "";
  return {
    raw: choice,
    usage: json.usage ?? {},
    seconds: ((Date.now() - started) / 1000).toFixed(1),
  };
}

function costOf(usage) {
  const inCNY = ((usage.prompt_tokens ?? 0) / 1e6) * 3;
  const outCNY = ((usage.completion_tokens ?? 0) / 1e6) * 9;
  return { inCNY, outCNY, totalCNY: inCNY + outCNY };
}

// ---------- main ----------
const args = process.argv.slice(2);
const limitIdx = args.indexOf("--limit");
const limit = limitIdx >= 0 ? Number(args[limitIdx + 1]) : Infinity;
const onlyIdx = args.indexOf("--only");
const only = onlyIdx >= 0 ? args[onlyIdx + 1] : null;
const mtIdx = args.indexOf("--max-tokens");
const maxTokens = mtIdx >= 0 ? Number(args[mtIdx + 1]) : 1500;
const tagIdx = args.indexOf("--tag");
const tag = tagIdx >= 0 ? args[tagIdx + 1] : null;

const materials = readFileSync(DATASET, "utf8").trim().split("\n").map((l) => JSON.parse(l)).slice(0, limit);
const outDir = tag ? join(RESULTS, tag) : RESULTS;
mkdirSync(join(outDir, "qwen"), { recursive: true });
mkdirSync(join(outDir, "deepseek"), { recursive: true });

const summary = {};
for (const model of Object.keys(MODELS)) {
  if (only && model !== only) continue;
  summary[model] = { calls: 0, fail: 0, tokensIn: 0, tokensOut: 0, costCNY: 0, seconds: [] };
  for (const material of materials) {
    let entry;
    try {
      const r = await callModel(model, material);
      const cost = costOf(r.usage);
      summary[model].calls += 1;
      summary[model].tokensIn += r.usage.prompt_tokens ?? 0;
      summary[model].tokensOut += r.usage.completion_tokens ?? 0;
      summary[model].costCNY += cost.totalCNY;
      summary[model].seconds.push(Number(r.seconds));
      entry = { id: material.id, ok: true, seconds: r.seconds, usage: r.usage, cost, raw: r.raw };
      process.stdout.write(`[${model}] ${material.id} ok ${r.seconds}s ${cost.totalCNY.toFixed(5)}CNY\n`);
    } catch (err) {
      summary[model].fail += 1;
      entry = { id: material.id, ok: false, error: String(err.message ?? err) };
      process.stdout.write(`[${model}] ${material.id} FAIL ${err.message}\n`);
    }
    writeFileSync(join(outDir, model, `${material.id}.json`), JSON.stringify(entry, null, 2));
    await new Promise((r) => setTimeout(r, 500));
  }
}

writeFileSync(join(outDir, tag ? `summary-${tag}.json` : "summary.json"), JSON.stringify(summary, null, 2));
const grand = Object.values(summary).reduce((a, s) => a + s.costCNY, 0);
console.log(`\n== 成本合计（基准 ¥3/M 入、¥9/M 出）：¥${grand.toFixed(4)} ==`);
for (const [m, s] of Object.entries(summary)) {
  const avg = s.seconds.length ? (s.seconds.reduce((a, b) => a + b, 0) / s.seconds.length).toFixed(1) : "-";
  console.log(`${m}: ${s.calls} 成功 / ${s.fail} 失败，入${s.tokensIn}tk 出${s.tokensOut}tk，¥${s.costCNY.toFixed(4)}，均时 ${avg}s`);
}
