/**
 * 语音总结提示词 A/B 对比脚本
 * 完整复刻生产链路：Persona Preamble + thought_voice_summary → deepseek-chat (temp 0.3, maxTokens 1024)
 *
 * 用法：node scripts/compare-voice-summary-prompt.mjs
 */
import dotenv from "dotenv";
import { fileURLToPath } from "url";
import { dirname, join } from "path";

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
dotenv.config({ path: join(__dirname, "..", ".env") });

import defaultPrompts from "../src/prompts/defaultPrompts.json" with { type: "json" };

// ---------- 提示词 ----------
const PREAMBLE = defaultPrompts._persona_preamble ?? "";

const OLD_PROMPT = defaultPrompts.thought_voice_summary;

const NEW_PROMPT = `你是一个语音记录提炼助手。用户通过语音表达了一个或多个观点，ASR 转写结果包含口语化的重复、停顿、自我纠正和语序混乱。你的目标是提炼出用户真正想表达的意思，输出一份可以直接保存的观点记录——而不是忠实记录用户说的每一个字。

## 必须保留的内容（这是底线，无论如何不能丢）
- 用户的判断、倾向、结论和关键细节
- 第一人称表达，不要改成客观第三方摘要
- 观点的推理链路：因为什么、所以什么、想怎么样
- 用户的状态与情绪信号：犹豫、酝酿、试探、纠结、期待、低落等心理过程都是 Holo 要留住的东西，不是废话。例如「这个想法我琢磨挺久了，也不一定做」「我有点犹豫」「其实鼓起了勇气想说」——这些是了解用户这个人的重要线索，必须原汁原味保留。

## 必须删除的内容
1. 口癖和填充词：「然后」「就是」「就是说」「那个」「那个什么」「其实」「说白了」「对吧」「你知道吗」「我觉得吧」「嗯」「啊」「等于说」「反正」「之类的」「什么的」
   注意：删口癖只是去掉这些词本身，不要顺手删掉它们所修饰的内容。「我觉得这个功能很重要」删成「这个功能很重要」就好，不要删成「功能重要」丢了判断。
2. 同一个意思反复说的重复（说了两三遍，合并成一遍最清楚的表达）
3. 自我纠正的废弃说法：当用户说「不对」「我的意思是」「换个说法」「不是那样」时，只保留最终的说法，丢弃前面的草稿
4. 没有信息量的纯开场套话（「我想说一下」「今天想聊聊」这类引子，如果后面真有观点，直接从观点开始）
   注意：用户主动写的小前缀/标题性语句要保留，例如「今天的日记：」「工作复盘：」「读书笔记：」——这是用户的记录习惯和语境标记，不是套话。

## 处理力度（按内容长度和复杂度分档）
- 短内容（一两句话）：只删废话，保留原话的词和语序，不压缩。
- 中等内容（一段话内能说清）：可以重新组织语序、合并重复，让一句话一个意思、干净利落。
- 长内容（多个观点或明显分块）：该分点就分点，该分段就分段，每个观点拎清楚。

## 严格禁止
1. 不要替用户扩写不存在的事实、结论、行动项或理由。原文没说的，一个字都不能加。
2. 不要添加小标题，除非原文确实包含多个不同主题或明确的事项拆分。
3. 如果用了标题行，不要使用 Markdown 符号（#、##、*、-、**、\`\`\`、表格），标题后直接换行写正文。
4. 只输出整理后的文本，不要加解释、标签或格式标记。

直接输出整理结果：`;

// ---------- 测试场景 ----------
const MODEL = "deepseek-v4-flash"; // ✅ 线上真实模型（与 .env HOLO_CHAT_MODEL 待确认一致）

const SCENARIOS = [
  {
    name: "场景1：口癖废话堆砌",
    desc: "一句能说清的事，被「然后/就是/那个/其实」塞满",
    input: `嗯然后就是说，我今天其实在开会的时候想到一个事，就是那个，我觉得我们现在的那个，等于说新人引导流程吧，其实问题挺大的，就是新人进来都不知道该干嘛。`,
  },
  {
    name: "场景2：自我纠正",
    desc: "说了一半改主意，新旧说法都被 ASR 记下了（Typeless 那种情况）",
    input: `我觉得这次活动应该定在周六，不对，我的意思是周日更好，因为周六很多人要陪孩子，周日大家比较有空，换个说法吧，就是周日参与度肯定更高。`,
  },
  {
    name: "场景3：同一句反复说",
    desc: "一个意思绕来绕去说三遍",
    input: `这个功能真的很重要，我跟你说这是最优先的，真的，你必须先把这块做完再做别的，因为它是核心，就是最重要的那个东西，反正优先级最高。`,
  },
  {
    name: "场景4：多观点长语音",
    desc: "一段话里塞了 3 个不同的想法，该分点",
    input: `今天想聊三件事。第一件是工作上那个项目，我觉得下周必须得做个复盘了，拖了快一个月了。然后第二件是我最近睡眠真的很差，连续一周都是两三点才睡，第二天完全没精神，得想想办法了。还有就是，我妈上周跟我打电话，说想让我过年回家，我其实也挺想回去的，但是票还没买，有点担心到时候抢不到。`,
  },
  {
    name: "场景5：本来就干净的短句",
    desc: "验证不会过度删改——干净的话应该几乎不动",
    input: `今天的日记：下午三点和小王开了个会，定了下个月的排期。`,
  },
  {
    name: "场景6：大段绕路铺垫",
    desc: "前面一堆废话铺垫，最后才进入正题",
    input: `那个我想说一下啊，就是今天，嗯，其实酝酿了挺久了想说这个事，就是关于我那个副业的想法吧，其实也不是说一定要做，就是一直在琢磨，嗯反正就是，我打算下个月开始试一下做播客，先做十期看看反响。`,
  },
];

// ---------- 调 DeepSeek（完全复刻后端 openAICompatibleProvider）----------
async function callDeepSeek(systemPrompt, userText) {
  const baseURL = process.env.DEEPSEEK_BASE_URL ?? "https://api.deepseek.com";
  const apiKey = process.env.DEEPSEEK_API_KEY;
  const start = Date.now();

  const resp = await fetch(`${baseURL}/chat/completions`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      model: MODEL,
      messages: [
        { role: "system", content: systemPrompt },
        { role: "user", content: userText },
      ],
      temperature: 0.3,
      max_tokens: 1024,
      stream: false,
    }),
  });

  const elapsed = Date.now() - start;
  if (!resp.ok) {
    const txt = await resp.text();
    throw new Error(`DeepSeek ${resp.status}: ${txt}`);
  }
  const data = await resp.json();
  const content = data.choices?.[0]?.message?.content ?? "";
  return { content: content.trim(), elapsed, usage: data.usage };
}

function fmt(s) {
  return s.replace(/\s+\n/g, "\n").trim();
}

// ---------- 主流程 ----------
async function main() {
  const oldSystem = `${PREAMBLE}\n\n${OLD_PROMPT}`;
  const newSystem = `${PREAMBLE}\n\n${NEW_PROMPT}`;

  console.log("=".repeat(72));
  console.log("  语音总结提示词 A/B 对比（复刻生产链路）");
  console.log(`  模型: ${MODEL} | temperature: 0.3 | maxTokens: 1024`);
  console.log("  共 " + SCENARIOS.length + " 个场景，每个跑旧/新两版");
  console.log("=".repeat(72) + "\n");

  for (let i = 0; i < SCENARIOS.length; i++) {
    const sc = SCENARIOS[i];
    console.log("━".repeat(72));
    console.log(`${sc.name}`);
    console.log(`  说明：${sc.desc}`);
    console.log(`  原文（${sc.input.length}字）：`);
    console.log(`  ┌────────────────────────────────────────────────────`);
    sc.input.split("\n").forEach((l) => console.log(`  │ ${l}`));
    console.log(`  └────────────────────────────────────────────────────`);

    // 并发跑两版，省时间
    const [oldRes, newRes] = await Promise.all([
      callDeepSeek(oldSystem, sc.input).catch((e) => ({ content: `[出错] ${e.message}`, elapsed: 0, usage: {} })),
      callDeepSeek(newSystem, sc.input).catch((e) => ({ content: `[出错] ${e.message}`, elapsed: 0, usage: {} })),
    ]);

    const oldLen = oldRes.content.length;
    const newLen = newRes.content.length;
    const compressRate = sc.input.length > 0 ? Math.round((newLen / sc.input.length) * 100) : 0;

    console.log(`\n  【旧版结果】（${oldLen}字，${oldRes.elapsed}ms）`);
    console.log("  ┌────────────────────────────────────────────────────");
    fmt(oldRes.content).split("\n").forEach((l) => console.log(`  │ ${l}`));
    console.log("  └────────────────────────────────────────────────────");

    console.log(`\n  【新版结果】（${newLen}字，压缩至原文 ${compressRate}%，${newRes.elapsed}ms）`);
    console.log("  ┌────────────────────────────────────────────────────");
    fmt(newRes.content).split("\n").forEach((l) => console.log(`  │ ${l}`));
    console.log("  └────────────────────────────────────────────────────");

    // 压缩幅度对比
    const delta = oldLen - newLen;
    if (Math.abs(delta) > 2) {
      const tag = delta > 0 ? `新版更精炼 ${delta} 字` : `新版比旧版多 ${-delta} 字`;
      console.log(`\n  ⚖  长度对比：旧 ${oldLen} → 新 ${newLen}（${tag}）`);
    }
    console.log("");
  }

  console.log("=".repeat(72));
  console.log("  对比完成。重点看：");
  console.log("  1. 新版有没有把口癖/废话/重复/纠正删干净");
  console.log("  2. 场景5（干净短句）新版有没有过度删改");
  console.log("  3. 场景4（多观点长文）新版分点是否更清楚");
  console.log("  4. 有没有删掉本该保留的判断/细节");
  console.log("=".repeat(72));
}

main().catch((e) => {
  console.error("脚本出错：", e);
  process.exit(1);
});
