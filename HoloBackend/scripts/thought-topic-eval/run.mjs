#!/usr/bin/env node
// 想法主题归类评测 · 跑批入口（方案 P0.3「尺子」）
//
// 用法（在 HoloBackend 目录下）：
//   bash scripts/thought-topic-eval/serve.sh            # 另开终端常驻：本机起线上同款归类路由
//   node scripts/thought-topic-eval/run.mjs --dataset <数据集.json> [--rounds 3] [--set dev|holdout|all]
//        [--lanes N] [--limit N] [--tag 标签] [--dry-run] [--leave-one-out]
//
// 流程：读数据集 → 补向量（按内容哈希缓存）→ 逐条定候选与请求 → 问模型（多轮）→ 指标。
// 评测路径本身在 lib/evaluate.mjs。产出：含正文的结果 JSON 写 eval/private/results/
// （已 gitignore，写前校验）；只含聚合数字的报告写 eval/。
// --dry-run 只走到「组装请求」为止，不调判定模型：用来零成本核对数据转换与召回覆盖。
// --leave-one-out 把每条想法当作「刚写完、还没有任何归属」来判（标签即归属的数据集必须开）。

import { mkdirSync, writeFileSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

import { parseArgs } from "./lib/args.mjs";
import { EVAL_DEVICE_PREFIX, BackendBudgetExhaustedError, BackendClient } from "./lib/backend-client.mjs";
import { loadDataset } from "./lib/dataset.mjs";
import { buildPlan, emptyRound, evaluateOnce, isJudgeable } from "./lib/evaluate.mjs";
import { LEGACY_ENGINE_VERSION, LEGACY_SCHEMA_VERSION } from "./lib/legacy.mjs";
import { runLanes } from "./lib/lanes.mjs";
import { computeMetrics, renderDiagnosticsTable, renderMetricsTable } from "./lib/metrics.mjs";
import { EVAL_DIR, RESULTS_DIR, VECTORS_DIR, assertGitIgnored } from "./lib/paths.mjs";
import { renderReport } from "./lib/report.mjs";
import { prepareRecallState } from "./lib/recall.mjs";
import { VectorStore } from "./lib/vectors.mjs";

const DEFAULT_BASE = "http://127.0.0.1:8797";
const PROGRESS_EVERY = 50;
const EMBED_LANES = 4;
const SETS = ["all", "dev", "holdout"];

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help !== undefined || args.dataset === undefined) {
    console.log("用法：node scripts/thought-topic-eval/run.mjs --dataset <数据集.json> [--base URL] [--rounds N] [--set dev|holdout|all] [--lanes N] [--limit N] [--tag 标签] [--dry-run] [--leave-one-out]");
    process.exit(args.dataset === undefined ? 1 : 0);
  }
  const datasetFile = resolve(args.dataset);
  const base = args.base ?? DEFAULT_BASE;
  const rounds = Math.max(1, Number(args.rounds ?? 1));
  const lanes = Math.max(1, Number(args.lanes ?? 1));
  const set = args.set ?? "all";
  const dryRun = args["dry-run"] === "true";
  const leaveOneOut = args["leave-one-out"] === "true";
  const runTag = String(args.tag ?? "run").replace(/[\\/:*?"<>|\s]+/g, "_");
  if (!SETS.includes(set)) throw new Error("--set 只能是 all / dev / holdout");

  const dataset = await loadDataset(datasetFile);
  const client = new BackendClient({ base });
  // 向量缓存按正文内容哈希存取，所有数据集共用一份
  const vectors = await VectorStore.open({
    client,
    cachePath: join(VECTORS_DIR, "vectors.json"),
    deviceId: `${EVAL_DEVICE_PREFIX}-embed-${runTag}`,
  });
  const embedded = await vectors.ensureThoughtVectors(dataset.thoughts, { lanes: EMBED_LANES });
  const state = prepareRecallState(dataset, vectors);
  const targets = dataset.thoughts
    .filter((thought) => thought.gold !== null && !thought.gold.unsure)
    .filter((thought) => (set === "all" ? true : thought.split === set))
    .slice(0, args.limit === undefined ? undefined : Number(args.limit));
  const plan = await buildPlan(state, vectors, targets, { leaveOneOut });
  await vectors.flush();
  const requestCount = plan.reduce((sum, entry) => sum + entry.requests.length, 0);
  console.log(`数据集 ${dataset.name}：主题 ${dataset.topics.size} 个，想法 ${dataset.thoughts.length} 条（本次新编码 ${embedded} 条）`);
  console.log(`待评测 ${plan.length} 条 × ${rounds} 轮，每轮 ${requestCount} 次判定请求；留一法 ${leaveOneOut ? "开" : "关"}`);

  const roundResults = plan.map((entry) => Array.from({ length: rounds }, () => (entry.requests.length === 0 ? emptyRound(entry) : null)));
  if (!dryRun) {
    const items = [];
    for (let round = 0; round < rounds; round += 1) {
      plan.forEach((entry, index) => {
        if (entry.requests.length > 0) items.push({ index, round });
      });
    }
    let completed = 0;
    let failed = 0;
    await runLanes(items, lanes, async ({ index, round }, laneIndex) => {
      const result = await evaluateOnce(client, plan[index], `${EVAL_DEVICE_PREFIX}-${runTag}-lane${laneIndex}`);
      roundResults[index][round] = result;
      completed += 1;
      if (result.error !== null) failed += 1;
      if (completed % PROGRESS_EVERY === 0 || completed === items.length) {
        console.log(`[进度] ${completed}/${items.length}，失败 ${failed}`);
      }
    });
  }

  const records = plan.map((entry, index) => ({
    id: entry.target.id,
    split: entry.target.split,
    gold: entry.target.gold.topicIds,
    text: entry.target.text,
    recallReason: entry.outcome.reason,
    candidates: entry.outcome.candidates,
    rounds: dryRun ? [emptyRound(entry)] : roundResults[index],
  }));
  const effectiveRounds = dryRun ? 1 : rounds;
  const metrics = computeMetrics(records, effectiveRounds);
  const at = new Date();
  const meta = {
    at: at.toISOString(),
    dataset: dataset.name,
    datasetFile: basename(datasetFile),
    base,
    schemaVersion: LEGACY_SCHEMA_VERSION,
    engineVersion: LEGACY_ENGINE_VERSION,
    policy: "legacy",
    rounds: effectiveRounds,
    set,
    dryRun,
    leaveOneOut,
    lanes: dryRun ? 0 : lanes,
    tag: `${at.toISOString().slice(0, 10)}-schema${LEGACY_SCHEMA_VERSION}-${runTag}`,
    model: { judge: "qwen3.7-flash", embedding: "text-embedding-v3" },
  };

  const resultsPath = join(RESULTS_DIR, `${meta.tag}.json`);
  assertGitIgnored(resultsPath);
  mkdirSync(dirname(resultsPath), { recursive: true });
  const topicTitles = Object.fromEntries([...dataset.topics.values()].map((topic) => [topic.id, topic.title]));
  writeFileSync(resultsPath, JSON.stringify({ meta, topics: topicTitles, metrics, thoughts: records }, null, 2));
  const reportPath = join(EVAL_DIR, `report-${meta.tag}${dryRun ? "-dry-run" : ""}.md`);
  writeFileSync(reportPath, renderReport(meta, metrics));

  console.log(`\n总体（${metrics.overall.thoughts} 条 × ${metrics.overall.rounds} 轮）`);
  console.log(renderMetricsTable(metrics.overall));
  console.log(renderDiagnosticsTable(metrics.overall));
  console.log(`\n结果（含正文，已 gitignore）：${resultsPath}`);
  console.log(`报告（仅聚合数字，可入库）：${reportPath}`);
  if (!dryRun && requestCount > 0 && metrics.overall.usage.requests === 0) {
    console.error("没有任何一次判定请求成功，请确认本机后端已启动（serve.sh）。");
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(error instanceof BackendBudgetExhaustedError
    ? `评测中止：本机评测后端的费用护栏报「${error.code}」（当日额度用完）。没有继续空转；上调 serve.sh 里的 HOLO_BACKGROUND_* 上限后重跑。`
    : `评测失败: ${error.message}`);
  process.exit(1);
});
