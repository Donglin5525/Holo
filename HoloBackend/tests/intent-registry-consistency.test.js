// 跨端意图注册表一致性对拍（P1 护栏）：
// 1. 客户端 IntentDescriptor.swift 必须是后端 intents.json 的确定性生成产物（重生成 diff，漂移即红）
// 2. 客户端 AIIntent 枚举的 rawValue 集合必须与 intents.json 的意图 id 集合完全一致
//    （防止「加了枚举忘了登记注册表」或「注册表有、枚举没有」两个方向的结构漂移）
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const backendRoot = join(here, "..");
const clientRoot = join(backendRoot, "../Holo/Holo APP/Holo/Holo");

test("客户端 IntentDescriptor.swift 与后端 intents.json 一致（生成器 --check）", () => {
  const output = execFileSync("node", [join(backendRoot, "scripts/generate-intent-descriptors.mjs"), "--check"], {
    cwd: backendRoot,
    encoding: "utf8",
    stdio: "pipe",
  });
  assert.match(output, /一致/);
});

test("客户端 AIIntent 枚举与 intents.json 意图 id 集合一致", () => {
  const registry = JSON.parse(readFileSync(join(backendRoot, "src/prompts/intents.json"), "utf8"));
  const registryIds = new Set(registry.intents.flatMap((entry) => entry.ids));

  const aiModels = readFileSync(join(clientRoot, "Models/AI/AIModels.swift"), "utf8");
  const enumMatch = aiModels.match(/enum AIIntent: String[\s\S]*?\n\}/);
  assert.ok(enumMatch, "AIIntent 枚举定位失败");
  const rawValues = [...enumMatch[0].matchAll(/=\s*"([a-z_]+)"/g)].map((m) => m[1]);
  assert.ok(rawValues.length >= 21, `AIIntent 枚举数异常: ${rawValues.length}`);
  const enumIds = new Set(rawValues);

  const missingInEnum = [...registryIds].filter((id) => !enumIds.has(id));
  const missingInRegistry = [...enumIds].filter((id) => !registryIds.has(id));
  assert.deepEqual(missingInEnum, [], `intents.json 有但 AIIntent 枚举没有: ${missingInEnum}`);
  assert.deepEqual(missingInRegistry, [], `AIIntent 枚举有但 intents.json 没登记: ${missingInRegistry}`);
});

test("意图评测语料覆盖 intents.json 全部意图", () => {
  const registry = JSON.parse(readFileSync(join(backendRoot, "src/prompts/intents.json"), "utf8"));
  const corpusPath = join(backendRoot, "../docs/holoai-audit/intent-eval/corpus/seed-v1.json");
  const corpus = JSON.parse(readFileSync(corpusPath, "utf8"));
  const covered = new Set(corpus.samples.flatMap((sample) => sample.acceptable));
  const registryIds = new Set(registry.intents.flatMap((entry) => entry.ids));
  const uncovered = [...registryIds].filter((id) => !covered.has(id));
  assert.deepEqual(uncovered, [], `评测语料未覆盖的意图（每意图至少 1 条样本）: ${uncovered}`);
});
