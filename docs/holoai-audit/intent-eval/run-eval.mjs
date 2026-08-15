#!/usr/bin/env node
// 意图识别评测 runner（P0 评测基线的执行器）
//
// 用法：
//   node run-eval.mjs                          # 打 localhost:3000（本地 dev/mock）
//   node run-eval.mjs --base-url https://...   # 打指定环境
//   node run-eval.mjs --limit 10               # 只跑前 10 条（调试）
//   node run-eval.mjs --tag baseline           # 报告文件名后缀
//
// 请求形状与 iOS 真实链路一致（HoloBackendAIProvider.parseUserInputBatch）：
//   POST /v1/ai/chat/completions
//   { purpose:"intent", stream:false, response_format:{type:"json_object"},
//     messages:[ system(最小用户上下文), user(样本) ] }
// 意图 prompt 由后端注入（含 {{todayDate}} 渲染与 intentResponseStabilizer 规则旁路），
// 因此评测结果反映「生产链路真实行为」，包含确定性旁路命中（报告标注 provider）。

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

function parseArgs(argv) {
  const args = { baseUrl: "http://localhost:3000", corpus: resolve(here, "corpus/seed-v1.json"), tag: "", delayMs: 200, limit: 0 };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--base-url") args.baseUrl = argv[++i];
    else if (argv[i] === "--corpus") args.corpus = resolve(here, argv[++i]);
    else if (argv[i] === "--tag") args.tag = argv[++i];
    else if (argv[i] === "--delay-ms") args.delayMs = Number(argv[++i]);
    else if (argv[i] === "--limit") args.limit = Number(argv[++i]);
  }
  return args;
}

const args = parseArgs(process.argv.slice(2));
const corpus = JSON.parse(readFileSync(args.corpus, "utf8"));
let samples = corpus.samples;
if (args.limit > 0) samples = samples.slice(0, args.limit);

// 最小用户上下文：模拟 AIUserContextMessageBuilder.buildIntentRecognitionContext 的基础块
// （日期用运行当天，与后端 {{todayDate}} 渲染一致，避免相对日期语义漂移）
const today = new Date().toISOString().slice(0, 10);
const SYSTEM_CONTEXT = [
  "当前用户上下文：",
  `- 日期：${today}`,
  "- 今日支出：0，今日收入：0",
  "",
  "上下文使用规则：",
  "- 这部分上下文只用于识别本轮输入意图和财务账户消歧，不得主动扩展用户动作。",
].join("\n");

async function callIntent(text) {
  const response = await fetch(`${args.baseUrl}/v1/ai/chat/completions`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Holo-Device-Id": "intent-eval-runner" },
    body: JSON.stringify({
      purpose: "intent",
      stream: false,
      response_format: { type: "json_object" },
      messages: [
        { role: "system", content: SYSTEM_CONTEXT },
        { role: "user", content: text },
      ],
    }),
  });
  if (!response.ok) throw new Error(`HTTP ${response.status}: ${(await response.text()).slice(0, 200)}`);
  const json = await response.json();
  const content = json.choices?.[0]?.message?.content;
  if (!content) throw new Error("empty completion content");
  const parsed = JSON.parse(content);
  return {
    mode: parsed.mode ?? "",
    intent: parsed.items?.[0]?.intent ?? (parsed.mode === "clarification" ? "clarification" : "unknown"),
    needsClarification: parsed.needsClarification === true,
    provider: json.provider ?? "",
  };
}

const results = [];
for (const [index, sample] of samples.entries()) {
  let outcome = null;
  for (let attempt = 0; attempt < 2 && !outcome; attempt++) {
    try {
      outcome = await callIntent(sample.text);
    } catch (error) {
      if (attempt === 1) outcome = { mode: "error", intent: "error", needsClarification: false, provider: "", error: error.message };
    }
  }
  const intentOk = sample.acceptable.includes(outcome.intent);
  const clarifOk = sample.expectClarification ? outcome.needsClarification : true;
  const pass = intentOk && clarifOk;
  results.push({ ...sample, actual: outcome, pass });
  process.stdout.write(`[${index + 1}/${samples.length}] ${pass ? "✓" : "✗"} ${sample.id} ${sample.text.slice(0, 24)} → ${outcome.intent}${outcome.needsClarification ? " (clarif)" : ""}${outcome.provider === "holo-rules" ? " [rules]" : ""}\n`);
  if (args.delayMs > 0) await new Promise((r) => setTimeout(r, args.delayMs));
}

// ---- 汇总 ----
const total = results.length;
const passed = results.filter((r) => r.pass).length;
const accuracy = total ? (passed / total) * 100 : 0;

const byIntent = new Map();
for (const r of results) {
  const key = r.acceptable[0];
  const entry = byIntent.get(key) ?? { pass: 0, total: 0 };
  entry.total += 1;
  if (r.pass) entry.pass += 1;
  byIntent.set(key, entry);
}

const failures = results.filter((r) => !r.pass);
const timestamp = new Date().toISOString().replace(/[:T]/g, "-").slice(0, 16);
const reportName = `eval-${timestamp}-${corpus.version}${args.tag ? `-${args.tag}` : ""}.md`;

let report = `# 意图识别评测报告：${corpus.version}${args.tag ? ` (${args.tag})` : ""}

- 时间：${new Date().toISOString()}
- 环境：${args.baseUrl}
- 语料：${args.corpus}（${total} 条）
- **总体准确率：${accuracy.toFixed(1)}%（${passed}/${total}）**

## 按期望意图分布

| 期望意图 | 通过/总数 | 准确率 |
|---|---|---|
`;
for (const [intent, entry] of [...byIntent.entries()].sort()) {
  report += `| ${intent} | ${entry.pass}/${entry.total} | ${((entry.pass / entry.total) * 100).toFixed(0)}% |\n`;
}
report += `
## 失败样本（${failures.length}）

| id | 输入 | 期望 | 实际 | mode | 澄清 | 备注 |
|---|---|---|---|---|---|---|
`;
for (const f of failures) {
  const note = (f.note ?? "") + (f.actual.provider === "holo-rules" ? " [rules旁路]" : "");
  report += `| ${f.id} | ${f.text} | ${f.acceptable.join("/")} | ${f.actual.intent} | ${f.actual.mode} | ${f.actual.needsClarification ? "是" : "否"} | ${note} |\n`;
}
if (failures.length === 0) report += "| — | 全部通过 | | | | | |\n";

mkdirSync(resolve(here, "reports"), { recursive: true });
writeFileSync(resolve(here, "reports", reportName), report);
writeFileSync(resolve(here, "reports", "last-failures.json"), JSON.stringify(failures, null, 2));

console.log(`\n总体准确率：${accuracy.toFixed(1)}%（${passed}/${total}）`);
console.log(`报告：reports/${reportName}`);
process.exitCode = 0;
