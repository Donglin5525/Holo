#!/usr/bin/env node
// 想法主题归类评测 · Holo 独立整理一版（不用任何既有标签）
//
// 用法（在 HoloBackend 目录下，先起 serve.sh）：
//   node scripts/thought-topic-eval/independent-run.mjs --dataset <无标签数据集.json> --presets none|default
//        [--chunk 16] [--lanes 8] [--limit N] [--max-calls 8000] [--tag 标签]
//
// 想法按时间先后一批批「写进 Holo」，由 Holo 自己整理：
//   · 每条想法按线上口径判一次归属（候选 = 归档类别 + 已有的内容主题）；
//   · 归档类别攒够 5 个成员后，由线上同款模型起草一份「这个主题收什么」（类别理解）；
//   · 每处理一批就把「自动发现」跑到没有新主题为止：没归属的想法里找相似簇（≥3 条），
//     按内聚度从高到低每轮给最多 2 簇起名；起名成功就建主题，并把模型点名的成员直接归进去；
//   · 全部写完后按最终主题目录把所有想法重判一遍（线上每建一个主题都会全库重判）。
// --presets none：不带任何归档类别（引导页默认一个都不勾），主题全靠 Holo 自己长；
// --presets default：带上引导页预设的前四个归档类别。
//
// 与线上的差别（为省调用和时间做的近似，都不改变单次判定的口径）：
//   · 近邻用精确余弦代替 USearch 的近似检索；
//   · 建主题后只重判「新主题进了候选」的未归属想法，而不是全库；
//   · 起名失败、或模型判「不足以成主题」的簇，同一簇最多试三轮（线上会一直留在候选池里反复核对）；
//     类别理解每类只起草一次；起名与重试都比线上快。
//
// 产出与 run.mjs 同构的结果文件（答案留空），人工标注后用 rescore.mjs 评分。

import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

import { parseArgs } from "./lib/args.mjs";
import { EVAL_DEVICE_PREFIX, BackendBudgetExhaustedError, BackendClient } from "./lib/backend-client.mjs";
import { loadDataset } from "./lib/dataset.mjs";
import { MIN_CLUSTER_SIZE, clusterComponents, fingerprint, orphanAdjacency } from "./lib/discovery.mjs";
import { buildPlan, evaluateOnce } from "./lib/evaluate.mjs";
import { runLanes } from "./lib/lanes.mjs";
import { LEGACY_ENGINE_VERSION, LEGACY_SCHEMA_VERSION } from "./lib/legacy.mjs";
import { compareCodePoints, prefix, redactForUpload, stableUuid } from "./lib/text.mjs";
import { RESULTS_DIR, VECTORS_DIR, assertGitIgnored } from "./lib/paths.mjs";
import { categorySampleRank, isEffectiveMember, membershipSource } from "./lib/projection.mjs";
import { CALIBRATION_SEED, prepareRecallState, recall } from "./lib/recall.mjs";
import { VectorStore } from "./lib/vectors.mjs";

const DEFAULT_BASE = "http://127.0.0.1:8797";
const EMBED_LANES = 4;
// 引导页预设主题的前四个（ThoughtThemeConstraint.defaultPresetTopics）
const DEFAULT_PRESETS = ["工作与事业", "个人成长", "灵感创意", "生活与健康"];
// ThoughtCategoryBriefMaintainer.draftMinMembers / memberSampleLimit
const BRIEF_DRAFT_MIN_MEMBERS = 5;
const BRIEF_SAMPLE_LIMIT = 10;
// ThoughtAutomaticTopicDiscovery：命名素材取最近 8 条；线上每轮串行给至多 2 簇起名、失败下一轮再问，
// 这里一批并发 4 簇、同一簇的 3 次尝试也并发
const NAME_SAMPLE_LIMIT = 8;
const NAME_BATCH = 4;
const NAME_ATTEMPT_ROUNDS = 3;

/** 主题标题判重（TopicRepository.normalizedKey 的近似）：去空白与标点后小写。 */
const normalizeTitle = (title) => title.toLowerCase().replace(/[\s\p{P}\p{S}]+/gu, "");

const CLUSTER_OUTCOME_NAMES = {
  topic: "成立主题",
  no_topic: "模型判「不足以成主题」",
  naming_failed: "起不出合规的名字",
  duplicate: "与已有主题重名",
  too_few: "成员已不属于未归类",
};

function createSimulation({ notes, vectors, presetTitles, maxCalls }) {
  const origin = notes[0].createdAtMs;
  const topics = new Map();
  for (const title of presetTitles) {
    const topic = {
      id: stableUuid("holo-preset", title), title, isClassification: true, isVisible: true,
      categoryDefinition: null, briefDefinition: null, briefFailed: false, summary: null,
      source: "preset", createdAtMs: origin, seeds: 0,
    };
    topics.set(topic.id, topic);
  }
  const titleKeys = new Set([...topics.values()].map((topic) => normalizeTitle(topic.title)));
  const arrived = [];
  const clusterStates = new Map();
  const stats = { judgments: 0, requests: 0, judgeFailures: 0, retried: 0, naming: 0, briefs: 0, briefFailures: 0, usage: { inputTokens: 0, outputTokens: 0 } };

  const isOrphan = (note) => !note.links.some((link) => link.state === "active");
  const orphans = () => arrived.filter(isOrphan);
  const currentState = () => prepareRecallState({ topics, thoughts: arrived }, vectors);
  const device = (runTag, role, laneIndex = 0) => `${EVAL_DEVICE_PREFIX}-${runTag}-${role}${laneIndex}`;

  function apply(note, result) {
    stats.judgments += 1;
    stats.requests += result.attempts;
    stats.retried += Math.max(0, result.attempts - 1);
    if (result.usage !== null) {
      stats.usage.inputTokens += result.usage.inputTokens;
      stats.usage.outputTokens += result.usage.outputTokens;
    }
    if (result.error !== null) {
      stats.judgeFailures += 1; // 线上：这次判不出来就保持原状
      return;
    }
    note.links = result.committed.map((topicId) => ({ topicId, source: "ai", state: "active", basisTextHash: note.contentHash }));
  }

  /** 按线上口径判一批想法：召回 → 组请求 → 问模型 → 复核 → 现状落库规则。 */
  async function judge(targets, client, lanes, runTag) {
    if (targets.length === 0) return [];
    if (stats.requests + stats.naming + stats.briefs + targets.length > maxCalls) {
      throw new Error(`已到本次调用上限 ${maxCalls}，停下（可用 --max-calls 调高）`);
    }
    const plan = await buildPlan(currentState(), vectors, targets, { leaveOneOut: false });
    const results = plan.map(() => null);
    await runLanes(plan.map((_, index) => index), lanes, async (index, laneIndex) => {
      results[index] = await evaluateOnce(client, plan[index], device(runTag, "lane", laneIndex));
    });
    plan.forEach((entry, index) => apply(entry.target, results[index]));
    return results;
  }

  /** 线上每建一个主题会全库重判；这里只重判「新主题进了候选」的未归属想法。 */
  async function rejudgeOrphansTouching(newTopics, client, lanes, runTag) {
    const state = currentState();
    const touched = new Set(newTopics.map((topic) => topic.id));
    const affected = [];
    for (const note of orphans()) {
      const outcome = await recall(state, note, {});
      if (outcome.candidates.some((candidate) => touched.has(candidate.topicId))) affected.push(note);
    }
    await judge(affected, client, lanes, runTag);
    return affected.length;
  }

  /** 孤儿集合内聚簇（同文只留第一条参与）。 */
  function components() {
    const unique = [];
    const seenHashes = new Set();
    for (const note of orphans()) {
      if (seenHashes.has(note.contentHash)) continue;
      seenHashes.add(note.contentHash);
      unique.push(note);
    }
    const vectorsById = new Map(unique.map((note) => [note.id, vectors.get(note.contentHash)]));
    const adjacency = orphanAdjacency(unique.map((note) => note.id), vectorsById);
    return clusterComponents(unique.map((note) => note.id), vectorsById, CALIBRATION_SEED.recallMinCosine, MIN_CLUSTER_SIZE,
      (id) => adjacency.get(id) ?? []);
  }

  async function nameCluster(cluster, client, deviceId) {
    const members = cluster.notes.filter(isOrphan).sort((a, b) => b.createdAtMs - a.createdAtMs).slice(0, NAME_SAMPLE_LIMIT);
    if (members.length < MIN_CLUSTER_SIZE) {
      stats.tooFew += 1;
      return { kind: "too_few" };
    }
    stats.naming += 1;
    let response;
    try {
      ({ response } = await client.topicName(
        members.map((member) => ({ ref: member.id, text: prefix(redactForUpload(member.text), 8_000) })),
        deviceId,
      ));
    } catch (error) {
      if (error instanceof BackendBudgetExhaustedError) throw error;
      return { kind: "naming_failed" };
    }
    if (response.outcome === "no_topic") return { kind: "no_topic" };
    const title = response.name.trim();
    if (titleKeys.has(normalizeTitle(title))) return { kind: "duplicate" };
    const byRef = new Map(members.map((member) => [member.id, member]));
    const seeds = response.members.map((member) => byRef.get(member.ref)).filter((member) => member !== undefined && isOrphan(member));
    if (seeds.length < MIN_CLUSTER_SIZE) {
      stats.tooFew += 1;
      return { kind: "too_few" };
    }
    return { kind: "topic", title, definition: response.definition.trim(), seeds };
  }

  /** 把自动发现跑到没有新主题为止（线上每 60 秒一轮，慢速写入时总能追平）。 */
  async function discover(client, lanes, runTag) {
    for (;;) {
      const byId = new Map(arrived.map((note) => [note.id, note]));
      const pending = components()
        .map((component) => ({ ...component, key: fingerprint(component.members), notes: component.members.map((id) => byId.get(id)) }))
        .filter((component) => !clusterStates.has(component.key))
        .sort((a, b) => b.cohesion - a.cohesion); // 线上按内聚度从高到低取
      if (pending.length === 0) return;
      // 线上每轮按内聚度从高到低给至多 2 簇起名，失败的下一轮再问；这里同一批并发问，且把同一簇的三次尝试
      // 也并发发出（每次尝试内部仍按重试规则问到一份有效答复），按先后次序取第一个「成立主题」的结果——
      // 结果与逐轮重试同分布，哪些簇会被处理也不变。
      const batch = pending.slice(0, NAME_BATCH);
      const draws = await Promise.all(batch.map((cluster, position) => Promise.all(
        Array.from({ length: NAME_ATTEMPT_ROUNDS }, (_, round) => nameCluster(cluster, client, device(runTag, "naming", position * NAME_ATTEMPT_ROUNDS + round))),
      )));
      const created = [];
      batch.forEach((cluster, position) => {
        const outcome = draws[position].find((item) => item.kind !== "naming_failed" && item.kind !== "no_topic")
          ?? draws[position].at(-1);
        clusterStates.set(cluster.key, outcome.kind);
        if (outcome.kind !== "topic") return;
        const topic = {
          id: stableUuid("holo-ai-topic", outcome.title, cluster.key), title: outcome.title, isClassification: false, isVisible: true,
          categoryDefinition: null, briefDefinition: null, briefFailed: false, summary: outcome.definition,
          source: "ai", createdAtMs: Date.now(), seeds: outcome.seeds.length,
        };
        topics.set(topic.id, topic);
        titleKeys.add(normalizeTitle(topic.title));
        for (const seed of outcome.seeds) {
          seed.links.push({ topicId: topic.id, source: "ai", state: "active", basisTextHash: seed.contentHash });
        }
        created.push(topic);
      });
      if (created.length > 0) await rejudgeOrphansTouching(created, client, lanes, runTag);
    }
  }

  /** 类别理解：没有用户规则的归档类别，攒够成员后由模型起草定义（线上每拍最多一类）。 */
  async function maintainBriefs(client, runTag) {
    const categories = [...topics.values()]
      .filter((topic) => topic.isClassification && topic.briefDefinition === null && !topic.briefFailed)
      .sort((a, b) => compareCodePoints(a.title, b.title));
    for (const topic of categories) {
      const members = arrived.filter((note) => isEffectiveMember(note, topic.id))
        .sort((a, b) => categorySampleRank(a, topic.id) - categorySampleRank(b, topic.id) || b.updatedAtMs - a.updatedAtMs);
      if (members.length < BRIEF_DRAFT_MIN_MEMBERS) continue;
      const samples = members.slice(0, BRIEF_SAMPLE_LIMIT)
        .map((note) => ({ ref: note.id, text: prefix(redactForUpload(note.text), 240).trim(), source: membershipSource(note, topic.id) }))
        .filter((sample) => sample.text.length > 0);
      if (samples.length < MIN_CLUSTER_SIZE) continue;
      stats.briefs += 1;
      try {
        const { brief } = await client.categoryBrief({
          topic: { title: prefix(topic.title, 32), userDefinition: null, currentBrief: null },
          members: samples,
          removals: [],
        }, device(runTag, "brief"));
        topic.briefDefinition = brief.definition;
      } catch (error) {
        if (error instanceof BackendBudgetExhaustedError) throw error;
        // 线上同一证据失败后冷却 24 小时再试；这里记为失败、不再重试
        stats.briefFailures += 1;
        topic.briefFailed = true;
      }
    }
  }

  return { topics, arrived, stats, orphans, clusterStates, judge, discover, maintainBriefs };
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.dataset === undefined || args.presets === undefined) {
    console.log("用法：node scripts/thought-topic-eval/independent-run.mjs --dataset <无标签数据集.json> --presets none|default [--chunk 16] [--lanes 8] [--limit N] [--max-calls 8000] [--tag 标签]");
    process.exit(1);
  }
  const dataset = await loadDataset(resolve(args.dataset));
  const lanes = Math.max(1, Number(args.lanes ?? 8));
  const chunk = Math.max(1, Number(args.chunk ?? 16));
  const maxCalls = Number(args["max-calls"] ?? 8000);
  const runTag = String(args.tag ?? `presets-${args.presets}`).replace(/[\\/:*?"<>|\s]+/g, "_");
  // 按时间先后「写进来」；抽样试跑时取最近的若干条
  let notes = dataset.thoughts.slice().sort((a, b) => a.createdAtMs - b.createdAtMs);
  if (args.limit !== undefined) notes = notes.slice(-Number(args.limit));
  for (const note of notes) note.links = [];

  // 失败后 0.6 秒就重试（线上 60 秒起）：只影响耗时，不影响每次调用问什么
  const client = new BackendClient({ base: args.base ?? DEFAULT_BASE, retryDelayMs: 600 });
  const vectors = await VectorStore.open({ client, cachePath: join(VECTORS_DIR, "vectors.json"), deviceId: `${EVAL_DEVICE_PREFIX}-embed-${runTag}` });
  await vectors.ensureThoughtVectors(notes, { lanes: EMBED_LANES });
  const sim = createSimulation({ notes, vectors, presetTitles: args.presets === "default" ? DEFAULT_PRESETS : [], maxCalls });

  for (let offset = 0; offset < notes.length; offset += chunk) {
    const batch = notes.slice(offset, offset + chunk);
    sim.arrived.push(...batch);
    await sim.judge(batch, client, lanes, runTag);
    await sim.maintainBriefs(client, runTag);
    await sim.discover(client, lanes, runTag);
    if ((offset / chunk) % 4 === 0 || offset + chunk >= notes.length) {
      const aiTopics = [...sim.topics.values()].filter((topic) => topic.source === "ai").length;
      console.log(`[进度] 已写入 ${Math.min(offset + chunk, notes.length)}/${notes.length} 条 · 主题 ${sim.topics.size} 个（Holo 自己长的 ${aiTopics} 个）· 未归类 ${sim.orphans().length} 条 · 已调用模型 ${sim.stats.requests + sim.stats.naming + sim.stats.briefs} 次`);
    }
  }
  // 全部写完后按最终主题目录重判一遍
  const final = await sim.judge(notes, client, lanes, runTag);

  const holdoutFrom = notes.length - Math.floor(notes.length / 3);
  const thoughts = notes.map((note, index) => ({
    id: note.id,
    split: index >= holdoutFrom ? "holdout" : "dev",
    createdAt: new Date(note.createdAtMs).toISOString(),
    text: note.text,
    candidates: final[index].candidates,
    rounds: [final[index]],
    gold: null,
    unsure: true,
  }));
  const memberCount = (topic) => notes.filter((note) => isEffectiveMember(note, topic.id)).length;
  const topicDetails = [...sim.topics.values()].map((topic) => ({
    id: topic.id,
    title: topic.title,
    kind: topic.isClassification ? "category" : "thread",
    source: topic.source,
    definition: topic.summary ?? topic.briefDefinition ?? null,
    seeds: topic.seeds,
    members: memberCount(topic),
  }));
  const meta = {
    kind: "independent",
    at: new Date().toISOString(),
    dataset: dataset.name,
    presets: args.presets === "default" ? DEFAULT_PRESETS : [],
    schemaVersion: LEGACY_SCHEMA_VERSION,
    engineVersion: LEGACY_ENGINE_VERSION,
    policy: "legacy",
    rounds: 1,
    set: "all",
    leaveOneOut: false,
    tag: `independent-${runTag}`,
    model: { judge: "qwen3.7-flash", embedding: "text-embedding-v3" },
    stats: sim.stats,
  };

  const resultsPath = join(RESULTS_DIR, `${meta.tag}.json`);
  assertGitIgnored(resultsPath);
  mkdirSync(dirname(resultsPath), { recursive: true });
  const topicTitles = Object.fromEntries(topicDetails.map((topic) => [topic.id, topic.title]));
  writeFileSync(resultsPath, JSON.stringify({ meta, topics: topicTitles, topicDetails, thoughts }, null, 2));

  const organized = notes.length - sim.orphans().length;
  const cost = (sim.stats.usage.inputTokens * 0.2 + sim.stats.usage.outputTokens * 0.8) / 1_000_000;
  console.log(`\n完成：${notes.length} 条想法 · 主题 ${topicDetails.length} 个（Holo 自己长的 ${topicDetails.filter((topic) => topic.source === "ai").length} 个）· 有归属 ${organized} 条（${(100 * organized / notes.length).toFixed(0)}%）· 未归类 ${sim.orphans().length} 条`);
  const clusterOutcomes = new Map();
  for (const kind of sim.clusterStates.values()) clusterOutcomes.set(kind, (clusterOutcomes.get(kind) ?? 0) + 1);
  console.log(`调用：归属判定 ${sim.stats.judgments} 次其中真正问了模型 ${sim.stats.requests} 次（重试 ${sim.stats.retried} 次、终态失败 ${sim.stats.judgeFailures} 次）· 起名共问 ${sim.stats.naming} 次 · 类别理解 ${sim.stats.briefs} 次（失败 ${sim.stats.briefFailures}）· 约 ¥${cost.toFixed(2)}`);
  console.log(`起名结果（按簇计）：${[...clusterOutcomes].sort((a, b) => b[1] - a[1]).map(([kind, count]) => `${CLUSTER_OUTCOME_NAMES[kind] ?? kind} ${count}`).join(" · ")}`);
  console.log("\n主题（按成员数）：");
  for (const topic of [...topicDetails].sort((a, b) => b.members - a.members)) {
    console.log(`  ${String(topic.members).padStart(4)}  ${topic.source === "preset" ? "[预设] " : ""}${topic.title}  —  ${topic.definition ?? "（无定义）"}`);
  }
  console.log(`\n结果（含正文，已 gitignore）：${resultsPath}`);
}

main().catch((error) => {
  console.error(error instanceof BackendBudgetExhaustedError
    ? `中止：本机评测后端的费用护栏报「${error.code}」。上调 serve.sh 里的 HOLO_BACKGROUND_* 上限后重跑。`
    : `独立整理失败: ${error.message}`);
  process.exit(1);
});
