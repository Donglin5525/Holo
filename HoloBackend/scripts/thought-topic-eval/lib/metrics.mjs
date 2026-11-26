// 想法主题归类评测 · 指标
//
// 方案 §P0.4 规定的七项指标全部给出，另加几项归因用的过程指标——
// 一条金标没归上，要能分清是「没召回来」「召回了但模型判否」「判对了但被落库规则截掉」。

import { AUTO_ATTRIBUTION_LIMIT } from "./legacy.mjs";

/** qwen3.7-flash 牌价（元 / 百万 tokens）；线上归类路由用的就是它。 */
export const MODEL_PRICING_CNY_PER_MILLION = Object.freeze({ input: 0.2, output: 0.8 });

const rate = (numerator, denominator) => (denominator === 0 ? null : numerator / denominator);

function topicStat(byTopic, topicId) {
  let entry = byTopic.get(topicId);
  if (entry === undefined) {
    entry = { gold: 0, recalled: 0, judgedPositive: 0, committed: 0, hits: 0 };
    byTopic.set(topicId, entry);
  }
  return entry;
}

function evaluateSet(records, rounds) {
  let autoPairs = 0;
  let autoHits = 0;
  let goldPairs = 0;
  let goldCovered = 0;
  let goldRecalled = 0;
  let goldJudgedPositive = 0;
  let positivePairs = 0;
  let positiveNonGold = 0;
  let pendingThoughtRounds = 0;
  let pendingPairs = 0;
  let pendingHits = 0;
  let goldNonEmptyThoughtRounds = 0;
  let emptyThoughtRounds = 0;
  let stableThoughts = 0;
  let flipPairs = 0;
  let truncatedThoughts = 0;
  let goldLostToTruncation = 0;
  let supersedeThoughts = 0;
  let supersededPairs = 0;
  let negativeThoughts = 0;
  let negativeFalselyAssigned = 0;
  const errors = new Map();
  const usage = { requests: 0, retriedAttempts: 0, inputTokens: 0, outputTokens: 0 };
  const byTopic = new Map();

  for (const record of records) {
    const gold = new Set(record.gold);
    const committedCounts = new Map();
    let anyTruncation = false;
    let anySupersede = false;
    let anyAssigned = false;
    for (const round of record.rounds) {
      const committed = new Set(round.committed);
      const suggested = new Set(round.suggestedAdd);
      autoPairs += committed.size;
      for (const topicId of committed) {
        if (gold.has(topicId)) autoHits += 1;
        committedCounts.set(topicId, (committedCounts.get(topicId) ?? 0) + 1);
      }
      positivePairs += round.positives.length;
      for (const topicId of round.positives) {
        if (!gold.has(topicId)) positiveNonGold += 1;
      }
      for (const topicId of gold) {
        goldPairs += 1;
        if (committed.has(topicId) || suggested.has(topicId)) goldCovered += 1;
        if (round.candidates.includes(topicId)) goldRecalled += 1;
        if (round.positives.includes(topicId)) goldJudgedPositive += 1;
      }
      pendingPairs += suggested.size;
      for (const topicId of suggested) {
        if (gold.has(topicId)) pendingHits += 1;
      }
      if (suggested.size > 0) pendingThoughtRounds += 1;
      if (gold.size > 0) {
        goldNonEmptyThoughtRounds += 1;
        if (committed.size + suggested.size === 0) emptyThoughtRounds += 1;
      }
      if (round.positives.length > AUTO_ATTRIBUTION_LIMIT) anyTruncation = true;
      goldLostToTruncation += round.truncated.filter((topicId) => gold.has(topicId)).length;
      supersededPairs += round.superseded.length;
      if (round.superseded.length > 0) anySupersede = true;
      if (committed.size > 0) anyAssigned = true;
      if (round.error !== null) errors.set(round.error, (errors.get(round.error) ?? 0) + 1);
      if (round.usage !== null) {
        usage.requests += 1;
        usage.retriedAttempts += round.attempts - 1;
        usage.inputTokens += round.usage.inputTokens;
        usage.outputTokens += round.usage.outputTokens;
      }
      for (const topicId of gold) {
        const entry = topicStat(byTopic, topicId);
        entry.gold += 1;
        if (round.candidates.includes(topicId)) entry.recalled += 1;
        if (round.positives.includes(topicId)) entry.judgedPositive += 1;
        if (committed.has(topicId)) entry.hits += 1;
      }
      for (const topicId of committed) topicStat(byTopic, topicId).committed += 1;
    }
    let recordFlipPairs = 0;
    for (const count of committedCounts.values()) {
      if (count < rounds) recordFlipPairs += 1;
    }
    flipPairs += recordFlipPairs;
    if (recordFlipPairs === 0) stableThoughts += 1;
    if (anyTruncation) truncatedThoughts += 1;
    if (anySupersede) supersedeThoughts += 1;
    if (gold.size === 0) {
      negativeThoughts += 1;
      if (anyAssigned) negativeFalselyAssigned += 1;
    }
  }

  // 失败重试的那几次用量后端不回传，这里的费用是下限
  const costCNY = (usage.inputTokens * MODEL_PRICING_CNY_PER_MILLION.input
    + usage.outputTokens * MODEL_PRICING_CNY_PER_MILLION.output) / 1_000_000;
  return {
    thoughts: records.length,
    rounds,
    goldPairs,
    autoPairs,
    autoPrecision: rate(autoHits, autoPairs),
    recall: rate(goldCovered, goldPairs),
    pendingRate: rate(pendingThoughtRounds, records.length * rounds),
    pendingHitRate: rate(pendingHits, pendingPairs),
    pendingPairs,
    stability: rounds > 1 ? rate(stableThoughts, records.length) : null,
    emptyRate: rate(emptyThoughtRounds, goldNonEmptyThoughtRounds),
    negativeThoughts,
    negativeFalseAssignRate: rate(negativeFalselyAssigned, negativeThoughts),
    recallStageCoverage: rate(goldRecalled, goldPairs),
    judgeStageRecall: rate(goldJudgedPositive, goldRecalled),
    positiveNonGoldRate: rate(positiveNonGold, positivePairs),
    positivePairs,
    truncatedThoughts,
    goldLostToTruncation,
    flipPairs,
    supersedeThoughts,
    supersededPairs,
    errors: Object.fromEntries([...errors].sort()),
    usage: {
      ...usage,
      avgInputTokens: rate(usage.inputTokens, usage.requests),
      avgOutputTokens: rate(usage.outputTokens, usage.requests),
      costCNY,
      costPerThousandThoughtsCNY: records.length === 0 ? null : (costCNY / records.length / rounds) * 1_000,
    },
    topics: [...byTopic].map(([topicId, entry]) => ({ topicId, ...entry, missed: entry.gold - entry.hits }))
      .sort((a, b) => b.missed - a.missed || a.topicId.localeCompare(b.topicId)),
  };
}

/**
 * records：每条带金标的想法一轮或几轮的结果。
 * 返回 overall + 按 split（dev / holdout）分组的指标。
 */
export function computeMetrics(records, rounds) {
  const groups = {};
  for (const split of new Set(records.map((record) => record.split).filter((split) => split !== null))) {
    groups[split] = evaluateSet(records.filter((record) => record.split === split), rounds);
  }
  return { overall: evaluateSet(records, rounds), bySplit: groups };
}

const percent = (value) => (value === null ? "—" : `${(value * 100).toFixed(1)}%`);
const count = (value) => (value === null ? "—" : String(Math.round(value * 100) / 100));

/** 只含聚合数字（主题只出现 id，不带标题与正文）——报告可入库。 */
export function renderMetricsTable(metrics) {
  return [
    "| 指标 | 数值 | 分子 / 分母 |",
    "|---|---|---|",
    `| 标注想法数 | ${metrics.thoughts} × ${metrics.rounds} 轮 | |`,
    `| 自动正确率 | ${percent(metrics.autoPrecision)} | 判对的自动归入 / 全部自动归入 |`,
    `| 召回（自动 + 待确认） | ${percent(metrics.recall)} | 被覆盖的金标 / 全部金标（${metrics.goldPairs}） |`,
    `| 待确认率 | ${percent(metrics.pendingRate)} | 有待确认的想法轮 / 全部想法轮 |`,
    `| 待确认命中率 | ${percent(metrics.pendingHitRate)} | 待确认里判对的 / 全部待确认（${metrics.pendingPairs}） |`,
    `| 稳定性（${metrics.rounds} 轮） | ${percent(metrics.stability)} | 各轮自动归入完全一致的想法 / 全部想法 |`,
    `| 空归类率 | ${percent(metrics.emptyRate)} | 该归却一条没归的想法轮 / 金标非空的想法轮 |`,
    `| 不该放却被放 | ${percent(metrics.negativeFalseAssignRate)} | 负例中被归入的想法 / 全部负例（${metrics.negativeThoughts}） |`,
    `| 单次用量 | 输入 ${count(metrics.usage.avgInputTokens)} / 输出 ${count(metrics.usage.avgOutputTokens)} tokens | ${metrics.usage.requests} 次成功请求 |`,
    `| 每千条费用 | ¥${count(metrics.usage.costPerThousandThoughtsCNY)} | qwen3.7-flash 牌价，本次合计 ¥${metrics.usage.costCNY.toFixed(4)} |`,
  ].join("\n");
}

export function renderDiagnosticsTable(metrics) {
  const rows = [
    ["金标被召回进候选", metrics.recallStageCoverage, "没进候选的金标，模型根本没机会判"],
    ["召回后模型判正", metrics.judgeStageRecall, "进了候选的金标里，模型给出归属判定的比例"],
    ["判正项不在金标里", metrics.positiveNonGoldRate, "模型判正但与金标不符的比例"],
  ];
  return [
    "| 过程指标 | 数值 | 含义 |",
    "|---|---|---|",
    ...rows.map(([label, value, note]) => `| ${label} | ${percent(value)} | ${note} |`),
    `| 判正超过 ${AUTO_ATTRIBUTION_LIMIT} 项被截断的想法 | ${metrics.truncatedThoughts} | 其中金标被截掉 ${metrics.goldLostToTruncation} 个 |`,
    `| 各轮之间来回变的归属 | ${metrics.flipPairs} 个（想法·主题对） | 一次重判就撤销一次既有归属 |`,
    `| 会被撤销既有 AI 归属的想法 | ${metrics.supersedeThoughts} | 共 ${metrics.supersededPairs} 条归属 |`,
    `| 请求失败（终态） | ${Object.values(metrics.errors).reduce((sum, value) => sum + value, 0)} 次 | ${Object.entries(metrics.errors).map(([reason, value]) => `${reason} ${value}`).join("；") || "无"} |`,
    `| 重试过的请求 | ${metrics.usage.retriedAttempts} 次 | 这些失败尝试的用量后端不回传，费用按下限计 |`,
  ].join("\n");
}
