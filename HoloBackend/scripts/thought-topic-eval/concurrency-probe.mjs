#!/usr/bin/env node
// 想法主题归类评测 · 并发对照实验
//
// 用法（在 HoloBackend 目录下）：
//   node scripts/thought-topic-eval/concurrency-probe.mjs --dataset <数据集.json> [--notes 60] [--repeat 2] [--lanes 1,16]
//
// 同一批想法、同一条评测路径，只改「同时发多少路请求」，回答两个问题：
//   ① 并发高时，模型答卷不合规的比例是否更高；
//   ② 并发高时拿到的判断，是否与逐条慢慢问的一致。
// 每种并发各跑 repeat 遍：「同一种并发下自身前后是否一致」是衡量的尺底。
// 会真实调用模型：调用次数约为 笔记数 × 每种并发的遍数 × （1 + 不合规重试）。

import { join, resolve } from "node:path";

import { parseArgs } from "./lib/args.mjs";
import { EVAL_DEVICE_PREFIX, BackendClient } from "./lib/backend-client.mjs";
import { loadDataset } from "./lib/dataset.mjs";
import { buildPlan, evaluateOnce } from "./lib/evaluate.mjs";
import { runLanes } from "./lib/lanes.mjs";
import { VECTORS_DIR } from "./lib/paths.mjs";
import { prepareRecallState } from "./lib/recall.mjs";
import { VectorStore } from "./lib/vectors.mjs";

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.dataset === undefined) {
    console.log("用法：node scripts/thought-topic-eval/concurrency-probe.mjs --dataset <数据集.json> [--set dev] [--notes 60] [--repeat 2] [--lanes 1,16]");
    process.exit(1);
  }
  const dataset = await loadDataset(resolve(args.dataset));
  const vectors = await VectorStore.open({ client: null, cachePath: join(VECTORS_DIR, "vectors.json") });
  const state = prepareRecallState(dataset, vectors);
  const set = args.set ?? "dev";
  const labelled = dataset.thoughts.filter((thought) => thought.gold !== null && !thought.gold.unsure && thought.split === set);
  const count = Math.min(Number(args.notes ?? 60), labelled.length);
  // 按时间等距取样，覆盖整个时间段
  const targets = Array.from({ length: count }, (_, index) => labelled[Math.floor(index * labelled.length / count)]);
  const plan = await buildPlan(state, vectors, targets, { leaveOneOut: args["leave-one-out"] !== "false" });
  const client = new BackendClient({ base: args.base ?? "http://127.0.0.1:8797" });
  const laneSettings = String(args.lanes ?? "1,16").split(",").map(Number);
  const repeat = Math.max(1, Number(args.repeat ?? 2));

  const runs = [];
  for (const lanes of laneSettings) {
    for (let rep = 0; rep < repeat; rep += 1) {
      const results = plan.map(() => null);
      const startedAt = Date.now();
      let invalid = 0;
      let terminal = 0;
      await runLanes(plan.map((_, index) => index), lanes, async (index, laneIndex) => {
        const result = await evaluateOnce(client, plan[index], `${EVAL_DEVICE_PREFIX}-probe-l${lanes}-r${rep}-${laneIndex}`);
        results[index] = result;
        if (result.error !== null) {
          terminal += 1;
          if (result.error.includes("MODEL_OUTPUT_INVALID")) invalid += result.attempts;
        } else {
          invalid += result.attempts - 1;
        }
      });
      const calls = plan.length + invalid;
      runs.push({ lanes, rep, results });
      console.log(`并发 ${String(lanes).padStart(2)} · 第 ${rep + 1} 遍：${plan.length} 条，用时 ${Math.round((Date.now() - startedAt) / 1000)} 秒；`
        + `模型调用 ${calls} 次，答卷不合规 ${invalid} 次（${(100 * invalid / calls).toFixed(0)}%）；连续失败到底 ${terminal} 条`);
    }
  }

  const positives = (result) => new Set(result.positives);
  const label = (run) => `并发${run.lanes}·第${run.rep + 1}遍`;
  const compare = (a, b) => {
    let both = 0;
    let same = 0;
    let union = 0;
    let intersection = 0;
    plan.forEach((_, index) => {
      const left = runs[a].results[index];
      const right = runs[b].results[index];
      if (left.error !== null || right.error !== null) return;
      const p = positives(left);
      const q = positives(right);
      both += 1;
      union += new Set([...p, ...q]).size;
      intersection += [...p].filter((topicId) => q.has(topicId)).length;
      if (p.size === q.size && [...p].every((topicId) => q.has(topicId))) same += 1;
    });
    console.log(`  ${label(runs[a])} ↔ ${label(runs[b])}：两边都有结果 ${both} 条；判断完全一致 ${both ? (100 * same / both).toFixed(0) : "–"}%；`
      + `按「想法×主题」算重合度 ${union ? (100 * intersection / union).toFixed(0) : "–"}%`);
  };
  console.log("\n判断结果的一致性（只比两边都拿到了结果的想法）：");
  for (let a = 0; a < runs.length; a += 1) {
    for (let b = a + 1; b < runs.length; b += 1) compare(a, b);
  }
}

main().catch((error) => {
  console.error("并发对照实验失败:", error.message);
  process.exit(1);
});
