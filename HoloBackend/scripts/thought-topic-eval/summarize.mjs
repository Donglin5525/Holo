#!/usr/bin/env node
// 想法主题归类评测 · 结果细看
//
// 用法：node scripts/thought-topic-eval/summarize.mjs --results <结果.json>
//
// 把一份结果整理成几张给人读的聚合表：每个主题的命中率、「你的标签 → Holo 归到哪」的去向、
// 多归了哪些主题、每条想法被归了几个、三轮之间是否一致。只输出计数与主题名，不输出正文。

import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import { parseArgs } from "./lib/args.mjs";

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.results === undefined) {
    console.log("用法：node scripts/thought-topic-eval/summarize.mjs --results <结果.json>");
    process.exit(1);
  }
  const results = JSON.parse(readFileSync(resolve(args.results), "utf8"));
  const title = (id) => (results.topics[id] ?? id.slice(0, 8)).replace(/^(Think|Area)\//, "");
  const rounds = results.meta.rounds;
  const thoughts = results.thoughts.filter((record) => record.unsure !== true);
  const count = (map, key) => map.set(key, (map.get(key) ?? 0) + 1);

  // ① 每个主题：有多少条想法以它为答案，其中多少条被 Holo 归了进去
  const goldTotals = new Map();
  const goldHits = new Map();
  for (const record of thoughts) {
    for (const topicId of record.gold) {
      count(goldTotals, topicId);
      for (const round of record.rounds) if (round.committed.includes(topicId)) count(goldHits, topicId);
    }
  }
  console.log(`\n【命中率】数据集 ${results.meta.dataset} · ${thoughts.length} 条 × ${rounds} 轮 · 答案里带该主题的想法，有多少被 Holo 归了进去`);
  console.table([...goldTotals].sort((a, b) => b[1] - a[1]).map(([topicId, total]) => {
    const hits = goldHits.get(topicId) ?? 0;
    return { 主题: title(topicId), 应归入: total / rounds, 实际归入: hits / rounds, 命中率: `${(100 * hits / total).toFixed(0)}%` };
  }));

  // ② 只打了一个标签的想法：「你的标签 → Holo 归到哪」
  console.log("\n【去向】只打了一个标签的想法，Holo 把它归到了哪（轮次累计；「无」= 一条都没归）");
  const single = thoughts.filter((record) => record.gold.length === 1);
  const byGold = new Map();
  for (const record of single) {
    const destinations = byGold.get(record.gold[0]) ?? new Map();
    for (const round of record.rounds) {
      if (round.error !== null) continue;
      count(destinations, round.committed.length === 0 ? "无" : round.committed.map(title).sort().join(" + "));
    }
    byGold.set(record.gold[0], destinations);
  }
  for (const [topicId, destinations] of [...byGold].sort((a, b) => b[0] && (goldTotals.get(b[0]) ?? 0) - (goldTotals.get(a[0]) ?? 0))) {
    const total = [...destinations.values()].reduce((sum, value) => sum + value, 0);
    const top = [...destinations].sort((a, b) => b[1] - a[1]).slice(0, 5).map(([name, value]) => `${name} ${value}`) ;
    console.log(`  ${title(topicId)}（${total} 次有结果）→ ${top.join("；")}`);
  }

  // ③ 多归的：答案里没有、Holo 却归了
  console.log("\n【多归】答案里没有这个主题、Holo 却归了（轮次累计，前 15）");
  const extras = new Map();
  for (const record of thoughts) {
    for (const round of record.rounds) {
      for (const topicId of round.committed) {
        if (!record.gold.includes(topicId)) count(extras, `${record.gold.map(title).sort().join(" + ") || "（无标签）"} → ${title(topicId)}`);
      }
    }
  }
  [...extras].sort((a, b) => b[1] - a[1]).slice(0, 15).forEach(([pair, value]) => console.log(`  ${String(value).padStart(4)}  ${pair}`));

  // ④ 每条想法被归了几个；三轮之间是否一致
  console.log("\n【归属个数与稳定性】");
  const sizes = new Map();
  const unstable = new Map();
  for (const record of thoughts) {
    const valid = record.rounds.filter((round) => round.error === null);
    for (const round of valid) count(sizes, round.committed.length);
    if (rounds > 1 && valid.length === rounds) {
      const sets = valid.map((round) => [...round.committed].sort().join(","));
      count(unstable, new Set(sets).size === 1 ? "三轮完全一致" : "三轮之间有变化");
    }
  }
  console.log("  每条被归入的主题数:", Object.fromEntries([...sizes].sort((a, b) => a[0] - b[0])));
  console.log("  ", Object.fromEntries(unstable));
}

main().catch((error) => {
  console.error("整理失败:", error.message);
  process.exit(1);
});
