// 把三段新 prompt 正文写入 defaultPrompts.json
// 运行：node scripts/prompt-rewrite/apply.mjs

import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { newAnalysisPrompt, newMemoryInsight, newSystemPrompt } from "./newPrompts.mjs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const jsonPath = join(__dirname, "..", "..", "src", "prompts", "defaultPrompts.json");

const data = JSON.parse(fs.readFileSync(jsonPath, "utf8"));

// 备份原始长度，用于校验报告
const before = {
  system_prompt: data.system_prompt?.length ?? 0,
  memory_insight_generation: data.memory_insight_generation?.length ?? 0,
  analysis_prompt: data.analysis_prompt?.length ?? 0,
};

// 写入新正文
data.system_prompt = newSystemPrompt;
data.memory_insight_generation = newMemoryInsight;
data.analysis_prompt = newAnalysisPrompt;

// 保持 key 顺序不变（JSON.stringify 会保留插入顺序）
fs.writeFileSync(jsonPath, JSON.stringify(data, null, 2) + "\n", "utf8");

const after = {
  system_prompt: data.system_prompt.length,
  memory_insight_generation: data.memory_insight_generation.length,
  analysis_prompt: data.analysis_prompt.length,
};

console.log("=== Prompt 重写完成 ===");
for (const key of Object.keys(before)) {
  const delta = after[key] - before[key];
  const sign = delta >= 0 ? "+" : "";
  console.log(`${key}: ${before[key]} → ${after[key]} 字 (${sign}${delta})`);
}
console.log(`\nJSON keys 总数: ${Object.keys(data).length}`);
console.log(`_persona_preamble 仍在: ${"_persona_preamble" in data}`);
