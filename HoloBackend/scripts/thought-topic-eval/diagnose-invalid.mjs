#!/usr/bin/env node
// 想法主题归类评测 · 「模型输出不合规」诊断
//
// 用法（在 HoloBackend 目录下）：
//   node scripts/thought-topic-eval/diagnose-invalid.mjs --results <结果.json> --dataset <数据集.json> [--attempts 2]
//
// 对结果里因 MODEL_OUTPUT_INVALID 终态失败的想法，按后端同一条代码路径直接问模型，
// 但绕过校验器看原始答卷：是漏答了候选，还是引文与正文对不上；对不上时差在哪一类字符。
// 只打印结构、长度与字符编码，不打印正文。会真实调用模型（每条想法 attempts 次）。

import { readFileSync } from "node:fs";
import { join, resolve } from "node:path";

import "./lib/production-model-env.mjs";
import { createOpenAICompatibleProvider } from "../../src/providers/openAICompatibleProvider.js";
import { injectServerPrompt } from "../../src/prompts/serverPromptPolicy.js";
import { loadConfig } from "../../src/config.js";
import { parseModelJSON } from "../../src/thoughts/organizeSchema.js";
import { validateRelateModelOutput, validateRelateRequest } from "../../src/thoughts/semanticRelateSchema.js";

import { parseArgs } from "./lib/args.mjs";
import { loadDataset } from "./lib/dataset.mjs";
import { buildLegacyCandidates, buildLegacyRequests } from "./lib/legacy.mjs";
import { EVAL_DIR, VECTORS_DIR } from "./lib/paths.mjs";
import { assertProductionRoute } from "./lib/production-model-env.mjs";
import { prepareRecallState, recall } from "./lib/recall.mjs";
import { VectorStore } from "./lib/vectors.mjs";

const COMMITTING = new Set(["same_thread", "fits_category"]);

/** 引文为什么对不上：逐字命中 / 只是排版差异（给出第一处不同的字符）/ 改写了内容。 */
function classifyQuote(quote, text) {
  if (text.includes(quote)) return "逐字命中";
  const fold = (ch) => ch.replace(/\s+/g, "").replace(/[“”]/g, "\"").replace(/[‘’]/g, "'")
    .replace(/，/g, ",").replace(/。/g, ".").replace(/：/g, ":").replace(/；/g, ";").replace(/！/g, "!").replace(/？/g, "?")
    .replace(/（/g, "(").replace(/）/g, ")").replace(/\u00a0/g, " ").replace(/\u3000/g, " ");
  let normalized = "";
  const offsets = [];
  for (let index = 0; index < text.length; index += 1) {
    const folded = fold(text[index]);
    if (folded === "") continue;
    normalized += folded;
    offsets.push(index);
  }
  const at = normalized.indexOf([...quote].map(fold).join(""));
  if (at === -1) return `改写了内容（引文 ${quote.length} 字）`;
  const original = text.slice(offsets[at], offsets[at + [...quote].map(fold).join("").length - 1] + 1);
  let index = 0;
  while (index < quote.length && index < original.length && quote[index] === original[index]) index += 1;
  const describe = (code) => (code === undefined ? "无" : `U+${code.toString(16).toUpperCase().padStart(4, "0")}${/\s/u.test(String.fromCodePoint(code)) ? "(空白)" : /\p{P}|\p{S}/u.test(String.fromCodePoint(code)) ? "(标点/符号)" : ""}`);
  return `只是排版差异：原文 ${original.length} 字 ${describe(original.codePointAt(index))} ↔ 模型 ${quote.length} 字 ${describe(quote.codePointAt(index))}`;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.results === undefined || args.dataset === undefined) {
    console.log("用法：node scripts/thought-topic-eval/diagnose-invalid.mjs --results <结果.json> --dataset <数据集.json> [--attempts 2]");
    process.exit(1);
  }
  const config = loadConfig();
  const route = assertProductionRoute(config.routes.thought_semantic_relate_v1);
  const provider = createOpenAICompatibleProvider(config.providers[route.provider]);
  const attempts = Math.max(1, Number(args.attempts ?? 2));

  const results = JSON.parse(readFileSync(resolve(args.results), "utf8"));
  const dataset = await loadDataset(resolve(args.dataset));
  const vectors = await VectorStore.open({ client: null, cachePath: join(VECTORS_DIR, "vectors.json") });
  const state = prepareRecallState(dataset, vectors);
  const failed = results.thoughts.filter((record) => record.rounds.some((round) => (round.error ?? "").includes("MODEL_OUTPUT_INVALID")));
  console.log(`结果里因「模型输出不合规」失败的想法 ${failed.length} 条；每条再问模型 ${attempts} 次`);

  const tally = {};
  for (const record of failed) {
    const target = dataset.thoughts.find((thought) => thought.id === record.id);
    const view = { ...target, links: [] };
    const outcome = await recall(state, view, { excludeThoughtId: target.id });
    const { candidates, topicByRef } = buildLegacyCandidates(state, view, outcome);
    const [chunk] = buildLegacyRequests(view, candidates);
    const parsedRequest = validateRelateRequest(JSON.parse(JSON.stringify(chunk.request)));
    console.log(`\n[${record.id.slice(0, 8)}] 正文 ${target.text.length} 字，候选 ${candidates.length} 个`);
    for (let attempt = 1; attempt <= attempts; attempt += 1) {
      const userContent = JSON.stringify({
        schemaVersion: parsedRequest.schemaVersion,
        target: { ref: "T0", text: chunk.chunkText },
        candidates: parsedRequest.candidates,
      });
      const serverPrompt = injectServerPrompt("thought_semantic_relate_v2", [{ role: "user", content: userContent }]);
      const result = await provider.complete({
        purpose: "thought_semantic_relate_v1",
        messages: serverPrompt.messages,
        stream: false,
        model: route.model,
        temperature: route.temperature,
        maxTokens: route.maxTokens,
        responseFormat: { type: "json_object" },
        reasoningEffort: route.reasoningEffort,
        clientSignal: AbortSignal.timeout(60_000),
      });
      const choice = result?.choices?.[0];
      const content = choice?.message?.content ?? "";
      let output;
      try {
        output = parseModelJSON(content);
      } catch {
        tally["JSON 解析失败"] = (tally["JSON 解析失败"] ?? 0) + 1;
        console.log(`  第 ${attempt} 次：JSON 解析失败（结束原因 ${choice?.finish_reason ?? "?"}，输出 ${content.length} 字）`);
        continue;
      }
      const validated = validateRelateModelOutput(output, parsedRequest);
      const decisions = output.decisions ?? [];
      const missing = parsedRequest.candidates.filter((candidate) => !decisions.some((decision) => decision.candidateRef === candidate.ref)).map((candidate) => candidate.ref);
      console.log(`  第 ${attempt} 次：${validated.malformed ? `不合规（${validated.reason}）` : "合规"}；回答 ${decisions.length} / 候选 ${parsedRequest.candidates.length}${missing.length ? `，漏答 ${missing.join(",")}` : ""}；结束原因 ${choice?.finish_reason ?? "?"}；输出 ${result?.usage?.completion_tokens ?? "?"} tokens`);
      for (const decision of decisions) {
        if (!COMMITTING.has(decision.relation) || typeof decision.quote !== "string") continue;
        const candidate = parsedRequest.candidates.find((item) => item.ref === decision.candidateRef);
        const basis = decision.representativeRef === "definition"
          ? (candidate.definition ?? candidate.summary ?? candidate.title)
          : candidate.representatives.find((item) => item.ref === decision.representativeRef)?.text;
        const quoteKind = classifyQuote(decision.quote, chunk.chunkText);
        tally[quoteKind.split("：")[0]] = (tally[quoteKind.split("：")[0]] ?? 0) + 1;
        console.log(`     ${decision.candidateRef} ${decision.relation}：目标引文 ${quoteKind}；主题侧引文${typeof decision.representativeQuote === "string" && basis?.includes(decision.representativeQuote) ? "命中" : "未命中"}`);
      }
    }
  }
  console.log("\n汇总（正项引文的情况）:", JSON.stringify(tally));
}

main().catch((error) => {
  console.error("诊断失败:", error.message);
  process.exit(1);
});
