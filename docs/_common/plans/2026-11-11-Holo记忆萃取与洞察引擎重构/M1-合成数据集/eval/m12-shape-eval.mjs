#!/usr/bin/env node
// M1.2 三组材料对照（门槛 A，2026-11-13）：同一主题的三种材料形状
// （legacy=生产聚合信号 / semantic=新语义证据视图 / full=完整材料上限）
// 全部交给 qwen3.7-flash（东林 2026-11-13 拍板选型）+ 同一提案提示词。
//
//   node m12-shape-eval.mjs
//
// 成本按后端台账基准 ¥3/M 入、¥9/M 出；失败不自动重试。

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const DATASET = join(HERE, "m12-materials.jsonl");
const RESULTS = join(HERE, "results-m12");

const envText = readFileSync(join(HERE, "..", "..", "..", "..", "..", "..", "HoloBackend", ".env"), "utf8");
const env = Object.fromEntries(
  envText.split("\n").filter((l) => l.includes("=") && !l.trim().startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
);

const SYSTEM = `你是 Holo 生活理解引擎的「提案器」。输入是关于同一个人的一组观察材料（已脱敏、程序预整理）。

任务：基于材料提出【最多 2 条】值得查证的候选理解。每条输出：
{
  "claimType": "role(生活角色/责任) | preference(偏好) | recurringBehavior(重复行为) | phaseState(阶段状态) | conditionalAssociation(条件性关联)",
  "statement": "一句话命题（中文）",
  "supportingRefs": ["观察的 oid 或材料条目名"],
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
5. 材料里没有的信息不许编造；统计数字（次数/极值/均值）只能支撑统计层面的结论。
6. 提不出可执行查证计划的候选不要输出；没有值得提的候选就输出空数组。
7. 只输出 JSON：{"candidates": [...], "noValueReason": "空数组时填一句原因"}`;

async function callQwen(material) {
  const body = {
    model: "qwen3.7-flash",
    temperature: 0.3,
    enable_thinking: false,
    max_tokens: 1500,
    messages: [
      { role: "system", content: SYSTEM },
      {
        role: "user",
        content: `观察材料（id=${material.id}，theme=${material.theme}）：\n${JSON.stringify(material.material, null, 2)}`,
      },
    ],
  };
  const started = Date.now();
  const resp = await fetch("https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions", {
    method: "POST",
    headers: { "Content-Type": "application/json", Authorization: `Bearer ${env.DASHSCOPE_API_KEY}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(90_000),
  });
  const json = await resp.json();
  if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${JSON.stringify(json).slice(0, 300)}`);
  return {
    raw: json.choices?.[0]?.message?.content ?? "",
    usage: json.usage ?? {},
    seconds: ((Date.now() - started) / 1000).toFixed(1),
  };
}

mkdirSync(RESULTS, { recursive: true });
const materials = readFileSync(DATASET, "utf8").trim().split("\n").map((l) => JSON.parse(l));
let tokensIn = 0, tokensOut = 0, costCNY = 0, fail = 0;
for (const material of materials) {
  let entry;
  try {
    const r = await callQwen(material);
    const inC = ((r.usage.prompt_tokens ?? 0) / 1e6) * 3;
    const outC = ((r.usage.completion_tokens ?? 0) / 1e6) * 9;
    tokensIn += r.usage.prompt_tokens ?? 0;
    tokensOut += r.usage.completion_tokens ?? 0;
    costCNY += inC + outC;
    entry = { id: material.id, theme: material.theme, shape: material.shape, ok: true, ...r, cost: inC + outC };
    console.log(`${material.id} ok ${r.seconds}s`);
  } catch (err) {
    fail += 1;
    entry = { id: material.id, ok: false, error: String(err.message ?? err) };
    console.log(`${material.id} FAIL ${err.message}`);
  }
  writeFileSync(join(RESULTS, `${material.id}.json`), JSON.stringify(entry, null, 2));
  await new Promise((r) => setTimeout(r, 500));
}
console.log(`\nM1.2 qwen 12 调用：入${tokensIn}tk 出${tokensOut}tk 成本¥${costCNY.toFixed(4)} 失败${fail}`);
