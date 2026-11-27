// 记忆萃取「每包段数」对照评测（2026-11-27 降本方案 P2）。
// 合成人物「小林」的想法记录（虚构，无真实用户数据）：signal 条各埋一条可萃取的个人情境，
// noise 条是单次事件/无关记录。同一批来源按 12/24/36 段分包调用线上萃取提示词与模型，
// 比较召回（signal 被任一候选引用的比例）、噪声误抽、引用逐字率与 token。
// 用法（在生产容器内跑，复用线上路由与钥匙；只读 DB）：
//   ssh <ecs> "docker exec -i -w /app holo-backend node --input-type=module -" < scripts/extraction-batch-eval/run.mjs
import Database from "better-sqlite3";
import { loadConfig } from "/app/src/config.js";
import { createOpenAICompatibleProvider } from "/app/src/providers/openAICompatibleProvider.js";

const SIGNAL = [
  "我对花生过敏，吃到一点就会起疹子，点外卖都得备注",
  "每周三晚上要去接女儿下舞蹈课，这天不能安排加班",
  "最近在准备明年三月的 CPA 考试，晚上基本都在刷题",
  "我妈腰不好，每个月月初我都要回老家陪她去复查",
  "我习惯早上六点起来跑步，不跑一整天都没精神",
  "自从换了新组，周会改到周一早上九点，周日晚上就开始焦虑",
  "我不喝咖啡，一喝就心慌睡不着，只喝茶",
  "房贷每月 15 号扣款，月中前手头要留够钱",
  "我在学日语，打算明年秋天去京都住一个月",
  "公司规定周五可以远程，我一般周五在家写方案",
  "老婆怀孕五个月了，周末尽量不出远门",
  "膝盖做过半月板手术，医生说不能再打篮球",
  "我是素食者，已经坚持三年了，聚餐只能挑素菜",
  "每天中午要给楼下的流浪猫留点吃的，已经喂了大半年",
  "我更喜欢用纸质笔记本做计划，手机上的待办总是忘看",
  "这个季度的目标是把副业收入做到每月五千",
  "我晚上十一点后看屏幕就会失眠，所以十点半就放下手机",
  "爸爸下个月退休，我想带他去一趟云南",
];
const NOISE = [
  "今天午饭吃了一碗牛肉面", "地铁上看到一只很胖的柯基", "下午开了个会，没什么结论",
  "买了一包纸巾", "天气预报说明天下雨", "刚把快递取回来了", "电脑更新了一下系统",
  "楼下新开了家奶茶店", "今天走了八千步", "把桌面整理了一下", "看了一集纪录片，还行",
  "晚上做了番茄炒蛋", "同事请大家吃了蛋糕", "手机壳有点旧了", "路过公园人很多",
  "把旧衣服装袋放门口了", "今天的日落挺好看", "下班路上有点堵",
];

function buildSources() {
  const out = [];
  const base = Date.parse("2026-10-01T08:00:00Z");
  for (let i = 0; i < SIGNAL.length; i++) {
    out.push({ id: `thought:s${i}`, kind: "signal", text: SIGNAL[i] });
    out.push({ id: `thought:n${i}`, kind: "noise", text: NOISE[i] });
  }
  return out.map((s, i) => ({ ...s, at: new Date(base + i * 36e5 * 20).toISOString() }));
}

function packagePrompt(pkg) {
  const sources = pkg.map((s) => ({
    sourceID: s.id, revision: "r1", sourceDomain: "thought", sourceKind: "thought",
    recordedAt: s.at, plainText: s.text,
  }));
  return JSON.stringify({ existingCandidates: [], sources });
}

const config = loadConfig();
const route = config.routes.personal_context_extraction;
const provider = createOpenAICompatibleProvider(config.providers[route.provider]);
const db = new Database("/data/holo-backend.db", { readonly: true });
const system = db.prepare(
  "SELECT content FROM prompt_versions WHERE prompt_type='personal_context_extraction' ORDER BY version DESC LIMIT 1",
).get()?.content;
if (!system) throw new Error("线上 prompt_versions 缺 personal_context_extraction");
// 提示词变体：PROMPT_SUFFIX 追加到系统提示词末尾（对照输出瘦身等改动）
const SYSTEM = process.env.PROMPT_SUFFIX ? `${system}\n\n${process.env.PROMPT_SUFFIX}` : system;

const SIZES = (process.env.SIZES ?? "12,24,36").split(",").map(Number);
const REPEATS = Number(process.env.REPEATS ?? 2);
const MAX_TOKENS = Number(process.env.MAX_TOKENS ?? 6000);
const sources = buildSources();
const byID = new Map(sources.map((s) => [s.id, s]));

async function runOnce(size) {
  const cited = new Set();
  let withSubjects = 0, withEpistemic = 0, quotes = 0, verbatim = 0, pt = 0, ct = 0, calls = 0, parseFail = 0, truncated = 0, candidates = 0;
  for (let i = 0; i < sources.length; i += size) {
    const pkg = sources.slice(i, i + size);
    const res = await provider.complete({
      model: route.model, temperature: route.temperature, maxTokens: MAX_TOKENS,
      reasoningEffort: route.reasoningEffort,
      messages: [{ role: "system", content: SYSTEM }, { role: "user", content: packagePrompt(pkg) }],
    });
    calls++;
    pt += res.usage?.prompt_tokens ?? 0; ct += res.usage?.completion_tokens ?? 0;
    if (res.choices?.[0]?.finish_reason === "length") truncated++;
    let parsed;
    try { parsed = JSON.parse(res.choices[0].message.content.replace(/^```json\s*|```$/g, "")); }
    catch { parseFail++; continue; }
    for (const c of parsed.candidates ?? []) {
      candidates++;
      if (Array.isArray(c.subjects) && c.subjects.length > 0) withSubjects++;
      if (c.epistemicStatus) withEpistemic++;
      for (const b of c.basis ?? []) {
        cited.add(b.sourceID);
        quotes++;
        if (b.quote && byID.get(b.sourceID)?.text.includes(b.quote)) verbatim++;
      }
    }
  }
  const signalHit = [...cited].filter((id) => byID.get(id)?.kind === "signal").length;
  const noiseHit = [...cited].filter((id) => byID.get(id)?.kind === "noise").length;
  return { size, calls, recall: `${signalHit}/${SIGNAL.length}`, noiseHit, candidates,
    verbatim: quotes ? (verbatim / quotes).toFixed(2) : "-", subj: `${withSubjects}/${candidates}`, epi: `${withEpistemic}/${candidates}`, parseFail, truncated, inTok: pt, outTok: ct };
}

console.log(`suffix=${process.env.PROMPT_SUFFIX ? "on" : "off"} model=${route.provider}/${route.model} effort=${route.reasoningEffort} maxTokens=${MAX_TOKENS}`);
const rows = [];
for (const size of SIZES) for (let r = 0; r < REPEATS; r++) rows.push(await runOnce(size));
console.table(rows);
