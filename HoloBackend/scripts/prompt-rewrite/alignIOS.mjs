// 把 iOS PromptManager.swift 的三个后备模板对齐后端 defaultPrompts.json
// 运行：node scripts/prompt-rewrite/alignIOS.mjs
//
// 策略：读后端 JSON 的三段正文 → 定位 iOS 模板边界（`.xxx: """` 到下一个 `""",`）→ 替换。
// Swift 多行字符串里，正文原样写入（Swift 的 """ 不需要转义内部双引号，除非连续出现）。

import fs from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const __dirname = dirname(fileURLToPath(import.meta.url));
const backendJsonPath = join(__dirname, "..", "..", "src", "prompts", "defaultPrompts.json");
const iosSwiftPath = join(__dirname, "..", "..", "..", "Holo", "Holo APP", "Holo", "Holo", "Services", "AI", "PromptManager.swift");

const data = JSON.parse(fs.readFileSync(backendJsonPath, "utf8"));
let swift = fs.readFileSync(iosSwiftPath, "utf8");

// 三个要替换的模板：key 是后端 JSON 的 key，定位标记是 iOS Swift 里的 `.caseName: """`
const replacements = [
  { jsonKey: "system_prompt", swiftCase: ".systemPrompt" },
  { jsonKey: "analysis_prompt", swiftCase: ".analysisPrompt" },
  { jsonKey: "memory_insight_generation", swiftCase: ".memoryInsightGeneration" },
];

function replaceTemplate(swiftContent, swiftCase, newBody) {
  // 匹配 `.swiftCase: """ ... """,`（到下一个独占一行的 """,）
  // 用 [^] 匹配所有字符（含换行），非贪婪到第一个 """,
  const pattern = new RegExp(
    `(${swiftCase.replace(/\./g, "\\.")}: """\\n)([\\s\\S]*?)(""",)`,
    "m"
  );
  const match = swiftContent.match(pattern);
  if (!match) {
    throw new Error(`未找到 ${swiftCase} 模板边界`);
  }
  // 保留原来的缩进（模板正文每行前的 8 个空格）
  const indent = "        ";
  const indentedBody = newBody.split("\n").map(line => line ? indent + line : line).join("\n");
  return swiftContent.replace(pattern, `${match[1]}${indentedBody}\n${indent}${match[3]}`);
}

let report = [];
for (const { jsonKey, swiftCase } of replacements) {
  const beforeLen = swift.length;
  const newBody = data[jsonKey];
  if (!newBody) {
    throw new Error(`后端 JSON 没有 ${jsonKey}`);
  }
  swift = replaceTemplate(swift, swiftCase, newBody);
  report.push(`${swiftCase} (${jsonKey}): 新正文 ${newBody.length} 字`);
}

fs.writeFileSync(iosSwiftPath, swift, "utf8");

console.log("=== iOS 后备模板对齐完成 ===");
for (const line of report) console.log(line);
console.log(`\n文件总长度: ${swift.length} 字符`);
