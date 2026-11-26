#!/usr/bin/env node
// 想法主题归类评测 · 用人工标注重新评分
//
// 用法：node scripts/thought-topic-eval/rescore.mjs --results <结果.json> --gold <gold.json>
//
// 模型判定结果落盘后与答案解耦：人工改了答案不需要重新问模型，直接按新答案重算指标。
// 标了「拿不准」的想法不参与统计；没被标注的想法沿用数据集自带的答案。

import { readFileSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

import { parseArgs } from "./lib/args.mjs";
import { computeMetrics, renderDiagnosticsTable, renderMetricsTable } from "./lib/metrics.mjs";
import { EVAL_DIR, RESULTS_DIR, assertGitIgnored } from "./lib/paths.mjs";
import { renderReport } from "./lib/report.mjs";

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.results === undefined || args.gold === undefined) {
    console.log("用法：node scripts/thought-topic-eval/rescore.mjs --results <结果.json> --gold <gold.json>");
    process.exit(1);
  }
  const results = JSON.parse(readFileSync(resolve(args.results), "utf8"));
  const gold = JSON.parse(readFileSync(resolve(args.gold), "utf8"));
  const labels = new Map((gold.labels ?? []).map((label) => [label.thoughtId, label]));

  let rescored = 0;
  const thoughts = results.thoughts.map((record) => {
    const label = labels.get(record.id);
    if (label === undefined) return record;
    rescored += 1;
    return { ...record, gold: label.topicIds, unsure: label.unsure === true };
  });
  const scored = thoughts.filter((record) => record.unsure !== true);
  const metrics = computeMetrics(scored, results.meta.rounds);
  const meta = {
    ...results.meta,
    at: new Date().toISOString(),
    tag: `${results.meta.tag}-rescored`,
    note: `按人工标注重新评分：标注覆盖 ${rescored} 条，其中「拿不准」${thoughts.length - scored.length} 条不计`,
  };

  const resultsPath = join(RESULTS_DIR, `${meta.tag}.json`);
  assertGitIgnored(resultsPath);
  writeFileSync(resultsPath, JSON.stringify({ ...results, meta, metrics, thoughts }, null, 2));
  const reportPath = join(EVAL_DIR, `report-${meta.tag}.md`);
  writeFileSync(reportPath, renderReport(meta, metrics));

  console.log(`${meta.note}；参与统计 ${scored.length} 条 × ${results.meta.rounds} 轮`);
  console.log(renderMetricsTable(metrics.overall));
  console.log(renderDiagnosticsTable(metrics.overall));
  console.log(`\n结果（含正文，已 gitignore）：${resultsPath}`);
  console.log(`报告（仅聚合数字，可入库）：${reportPath}`);
}

main().catch((error) => {
  console.error("重新评分失败:", error.message);
  process.exit(1);
});
