// P1 一次性生成脚本：从 defaultPrompts.json 的 intent_recognition 提取意图段与例段，
// 生成 src/prompts/intents.json（单一事实源），并把 defaultPrompts.json 的两段替换为 marker。
// 幂等：重复运行报错退出（已含 marker 时）。
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const promptsPath = join(here, "../src/prompts/defaultPrompts.json");
const intentsPath = join(here, "../src/prompts/intents.json");

const raw = readFileSync(promptsPath, "utf8");
const prompts = JSON.parse(raw);
const text = prompts.intent_recognition;

if (text.includes("{{HOLO_INTENT_SECTION")) {
  console.error("defaultPrompts.json 已含 marker，无需再生成（退出）");
  process.exit(1);
}

// ---- 提取意图字段段（行 12-32，清掉 3 行历史空行残留）----
const sectionStart = text.indexOf("意图字段：\n");
const sectionEnd = text.indexOf("unknown：无法判断。");
if (sectionStart < 0 || sectionEnd < 0) throw new Error("意图字段段定位失败");
const sectionText = text.slice(sectionStart, sectionEnd + "unknown：无法判断。".length);
const sectionLines = sectionText.split("\n").filter((line) => line.trim() !== "");

// ---- 提取例段 ----
const examplesStart = text.indexOf("例：\n");
const examplesEnd = text.indexOf("只回 JSON。");
if (examplesStart < 0 || examplesEnd < 0) throw new Error("例段定位失败");
const examplesText = text.slice(examplesStart, examplesEnd).trimEnd();
const exampleLines = examplesText.split("\n").slice(1).map((line) => line.replace(/^- /, ""));

// ---- 例句归属意图（按 extractedData 里的 intent 值；无 intent 的按内容判断）----
function classifyExample(example) {
  const match = example.match(/intent: "([a-z_]+)"/);
  if (match) return match[1];
  // "嗯..." → unknown 无 intent 字段
  if (example.includes("mode: \"unknown\"")) return "unknown";
  throw new Error(`例句无法归属意图: ${example}`);
}

// ---- 组装 intents.json ----
const requiredFieldsByIntent = {
  record_expense: ["amount"],
  record_income: ["amount"],
  create_task: ["title"],
  complete_task: ["taskKeyword"],
  update_task: ["taskKeyword"],
  delete_task: ["taskKeyword"],
  check_in: ["habitName"],
  update_goal_field: ["goalTitle", "field", "value"],
  link_task_to_goal: ["taskTitle", "goalTitle"],
  toggle_goal_visibility: ["goalTitle", "enable"],
  create_note: ["noteContent"],
  record_weight: ["weight"],
};

const entries = sectionLines.slice(1).map((line) => {
  const m = line.match(/^- ([a-z_ /]+)：(.*)$/);
  if (!m) throw new Error(`意图行解析失败: ${line}`);
  const ids = m[1].split(" / ").map((s) => s.trim());
  return { ids, summary: m[2], examples: [] };
});

for (const example of exampleLines) {
  const intentId = classifyExample(example);
  const entry = entries.find((e) => e.ids.includes(intentId));
  if (!entry) throw new Error(`例句意图 ${intentId} 无对应条目: ${example}`);
  entry.examples.push(example);
}

const intents = entries.map(({ ids, summary, examples }) => {
  const required = [...new Set(ids.flatMap((id) => requiredFieldsByIntent[id] ?? []))];
  return {
    ids,
    summary,
    ...(required.length > 0 ? { requiredFields: required } : {}),
    examples,
  };
});

const registry = {
  version: 1,
  updatedAt: "2026-08-15",
  note: "意图注册表（单一事实源）：promptRegistry.js 据此渲染 intent_recognition 的意图字段段与例段；iOS IntentDescriptor 与本文件同构，由 tests/intent-registry-consistency.test.js 对拍。改 summary/examples 属措辞变更（admin 可热更）；增删意图 id 属结构变更，必须两端同步并过护栏测试。",
  intents,
};

const flatIds = intents.flatMap((e) => e.ids);
if (flatIds.length !== 21) throw new Error(`意图数 ${flatIds.length} ≠ 21`);
const knownOrder = ["record_expense","record_income","create_task","complete_task","delete_task","update_task","modify_task_items","check_in","update_goal_field","link_task_to_goal","toggle_goal_visibility","create_note","record_mood","record_weight","query_tasks","query_habits","query_analysis","flexible_data_query","query","generate_memory_insight","unknown"];
for (const id of knownOrder) {
  if (!flatIds.includes(id)) throw new Error(`缺少意图 ${id}`);
}
const exampleCount = intents.reduce((sum, e) => sum + e.examples.length, 0);
if (exampleCount !== 13) throw new Error(`例句数 ${exampleCount} ≠ 13`);

writeFileSync(intentsPath, `${JSON.stringify(registry, null, 2)}\n`);

// ---- 改写 defaultPrompts.json：两段替换为 marker ----
const sectionMarkerStart = text.indexOf("意图字段：");
const sectionMarkerEnd = text.indexOf("unknown：无法判断。") + "unknown：无法判断。".length;
const examplesMarkerStart = text.indexOf("例：\n");
const examplesMarkerEnd = text.lastIndexOf("只回 JSON。");

const next =
  text.slice(0, sectionMarkerStart) +
  "{{HOLO_INTENT_SECTION}}" +
  text.slice(sectionMarkerEnd, examplesMarkerStart) +
  "{{HOLO_INTENT_EXAMPLES}}" +
  text.slice(examplesMarkerEnd);

prompts.intent_recognition = next;
writeFileSync(promptsPath, `${JSON.stringify(prompts, null, 2)}\n`);

console.log(`intents.json 生成：${intents.length} 条目 / ${flatIds.length} 意图 / ${exampleCount} 例句`);
console.log(`骨架长度：${next.length}（原 ${text.length}，差额=${next.length - text.length} 由 marker 渲染补齐）`);
