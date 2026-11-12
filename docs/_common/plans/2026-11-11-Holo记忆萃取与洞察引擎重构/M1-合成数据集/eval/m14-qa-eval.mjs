#!/usr/bin/env node
// M1.4 新旧引擎回答对照（2026-11-13）：10 个问题 × 3 条件（none 无记忆 /
// old 旧引擎统计记忆 / new 新理解）× qwen3.7-flash 扮 HoloAI 回答者。
// 产出给东林产品评审的并排对照。30 次调用，成本按 ¥3/M入、¥9/M出。

import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const QUESTIONS = join(HERE, "m14-questions.jsonl");
const RESULTS = join(HERE, "results-m14");

const envText = readFileSync(join(HERE, "..", "..", "..", "..", "..", "..", "HoloBackend", ".env"), "utf8");
const env = Object.fromEntries(
  envText.split("\n").filter((l) => l.includes("=") && !l.trim().startsWith("#"))
    .map((l) => [l.slice(0, l.indexOf("=")).trim(), l.slice(l.indexOf("=") + 1).trim()])
);

const SYSTEM = `你是 Holo——用户的个人生活 AI 助手（记账、任务、健康、习惯、想法、聊天）。回答风格：先直接回答用户的问题，实用、简洁、中文。

如果下方提供了「用户背景」：
- 自然地用于让回答更贴合用户的真实生活；与问题无关的背景不要提及。
- 标注〔推断〕的内容保持推断身份（用「如果/可能」表述，可被用户纠正）；标注〔待验证〕的不得当作已确认的原因；标注〔阶段〕的是暂时现象不是性格。
- 不做医疗诊断、不开药；不评价人格（懒惰/自律/拖延之类）；不编造背景里没有的信息。
没有背景时正常回答即可。回答不超过 200 字。`;

// 旧引擎记忆：现状=程序统计命题（无归属、无语义、无跨域）
const CONTEXT_OLD = `用户背景（系统已记住的统计）：
- 近90天「猫粮」类消费 4 次，金额稳定
- 近28天入睡时间比之前晚
- 近8周体重从约64kg升至约66kg
- 习惯「健身」近28天完成 2 次`;

// 新理解：M1.2 semantic 产出并按分级规则采用的理解（带身份标记）
const CONTEXT_NEW = `用户背景（Holo 从记录中理解）：
- 〔推断·可纠正〕你很可能长期照料至少一只猫（依据：猫粮猫砂定期购买、照料任务、你写的照料想法）
- 〔待验证联系〕较晚购买咖啡的日子你更容易晚睡（原因未确认，不能排除加班；你的饮用时间未知）
- 〔阶段〕最近约一个月活动量比平常减少，体重同期缓慢上升（与你「年底控回体重」的目标相关；不是原因判定）
- 〔工作条件〕下周起夜班连上五天，作息整体后移是排班导致（不是偏好）
- 〔带条件偏好〕在可比选择中你偏好安静的工作环境（依据：咖啡馆选择与你的想法）`;

const CONDITIONS = { none: null, old: CONTEXT_OLD, new: CONTEXT_NEW };

async function ask(question, context) {
  const user = context ? `${context}\n\n用户问题：${question}` : question;
  const body = {
    model: "qwen3.7-flash",
    temperature: 0.5,
    enable_thinking: false,
    max_tokens: 600,
    messages: [
      { role: "system", content: SYSTEM },
      { role: "user", content: user },
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
  if (!resp.ok) throw new Error(`HTTP ${resp.status}: ${JSON.stringify(json).slice(0, 200)}`);
  return { raw: json.choices?.[0]?.message?.content ?? "", usage: json.usage ?? {}, seconds: ((Date.now() - started) / 1000).toFixed(1) };
}

mkdirSync(RESULTS, { recursive: true });
const questions = readFileSync(QUESTIONS, "utf8").trim().split("\n").map((l) => JSON.parse(l));
let tokensIn = 0, tokensOut = 0, costCNY = 0, fail = 0;
for (const q of questions) {
  for (const [cond, context] of Object.entries(CONDITIONS)) {
    let entry;
    try {
      const r = await ask(q.question, context);
      tokensIn += r.usage.prompt_tokens ?? 0;
      tokensOut += r.usage.completion_tokens ?? 0;
      costCNY += ((r.usage.prompt_tokens ?? 0) / 1e6) * 3 + ((r.usage.completion_tokens ?? 0) / 1e6) * 9;
      entry = { id: q.id, kind: q.kind, cond, question: q.question, expect: q.expect, ok: true, ...r };
    } catch (err) {
      fail += 1;
      entry = { id: q.id, cond, ok: false, error: String(err.message ?? err) };
    }
    writeFileSync(join(RESULTS, `${q.id}-${cond}.json`), JSON.stringify(entry, null, 2));
    await new Promise((r) => setTimeout(r, 300));
  }
  console.log(`${q.id} done`);
}
console.log(`\nM1.4 qwen 30 调用：入${tokensIn}tk 出${tokensOut}tk 成本¥${costCNY.toFixed(4)} 失败${fail}`);
