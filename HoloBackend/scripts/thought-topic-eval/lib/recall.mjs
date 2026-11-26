// 想法主题归类评测 · 候选召回
//
// ThoughtTopicCandidateEngine.recall（schema 3 路径）的 JS 移植：
//   · 类别通道：用户启用的归档类别全量直达（≤9），按有效成员数降序、标题升序；
//   · 脉络通道：质心 Top3 + 近邻 Top20 投票，合并去重后 ≤3；主题总数 ≤3 时全部进候选；
//   · 用户拒绝过的墓碑压召回。
// 向量只决定「谁来当候选」，不直接决定归属。
// 与真机的已知差异：近邻检索用精确余弦代替 USearch 的 HNSW 近似检索。
//
// excludeThoughtId（评测用）：把正在评测的想法从各主题的成员里去掉，量的是「这条想法刚写完、
// 还没有任何归属」时的归类——否则它自己的标签会经质心与成员数泄漏给自己。

import { compareCodePoints, cosine, normalize } from "./text.mjs";
import { effectiveActiveThoughtCount, isEffectiveMember } from "./projection.mjs";

/** ThoughtSemanticCalibration.seed：仓库内没有校准 JSON，生效的就是这组种子值。 */
export const CALIBRATION_SEED = Object.freeze({
  recallMinCosine: 0.55,
  neighborVoteMinCount: 2,
});

export const CATEGORY_CHANNEL_LIMIT = 9;
const CENTROID_TOP = 3;
const THREAD_CANDIDATE_LIMIT = 3;
const NEIGHBOR_TOP_K = 20;
const PROFILE_MIN_COSINE = 0.3;

export function prepareRecallState(dataset, vectors) {
  const visible = [...dataset.topics.values()].filter((topic) => topic.isVisible);
  return {
    topics: dataset.topics,
    thoughts: dataset.thoughts,
    vectors,
    categoryTopics: visible.filter((topic) => topic.isClassification),
    threadTopics: visible.filter((topic) => !topic.isClassification)
      .map((topic) => ({ id: topic.id, title: topic.title, definition: topic.categoryDefinition ?? "" })),
    memberCountById: new Map(visible.map((topic) => [topic.id, effectiveActiveThoughtCount(dataset.thoughts, topic.id)])),
    calibration: CALIBRATION_SEED,
  };
}

/** 类别通道顺序：有效成员数降序、标题升序；正在评测的想法不计入成员数。 */
function orderedCategories(state, excludeThoughtId) {
  const excluded = excludeThoughtId === null ? undefined : state.thoughts.find((thought) => thought.id === excludeThoughtId);
  return state.categoryTopics
    .map((topic) => ({
      topic,
      count: state.memberCountById.get(topic.id)
        - (excluded !== undefined && !excluded.archived && isEffectiveMember(excluded, topic.id) ? 1 : 0),
    }))
    .sort((a, b) => b.count - a.count || compareCodePoints(a.topic.title, b.topic.title))
    .map((entry) => entry.topic);
}

/** 主题质心：有效成员向量的平均后归一化；无成员向量为 null。 */
function centroidVector(state, topicId, excludeThoughtId) {
  let sum = null;
  let count = 0;
  for (const thought of state.thoughts) {
    if (thought.id === excludeThoughtId || thought.archived || !isEffectiveMember(thought, topicId)) continue;
    const vector = state.vectors.get(thought.contentHash);
    if (vector === null) continue;
    if (sum === null) sum = new Float64Array(vector.length);
    for (let i = 0; i < vector.length; i += 1) sum[i] += vector[i];
    count += 1;
  }
  return count > 0 ? normalize(sum) : null;
}

/** topicsForThoughts：一条想法的有效主题（active 行 + 投影有效 + 主题可见）。 */
function effectiveVisibleTopics(state, thought) {
  const result = [];
  for (const link of thought.links) {
    if (link.state !== "active") continue;
    const topic = state.topics.get(link.topicId);
    if (topic.isVisible && isEffectiveMember(thought, topic.id)) result.push(topic);
  }
  return result;
}

/** 近邻 Top20：已归档想法照常占名额但不投票（与客户端口径一致）。 */
function nearestNeighbors(state, target, targetVector) {
  const neighbors = [];
  for (const thought of state.thoughts) {
    if (thought.id === target.id) continue;
    const vector = state.vectors.get(thought.contentHash);
    if (vector !== null) neighbors.push({ thought, similarity: cosine(targetVector, vector) });
  }
  neighbors.sort((a, b) => b.similarity - a.similarity);
  return neighbors.slice(0, NEIGHBOR_TOP_K);
}

export async function recall(state, target, { excludeThoughtId = null } = {}) {
  const { calibration, threadTopics, vectors } = state;
  const categoryTopics = orderedCategories(state, excludeThoughtId);
  const rejected = new Set(target.links.filter((link) => link.state === "rejected").map((link) => link.topicId));
  const targetVector = vectors.get(target.contentHash);

  // 脉络通道 ①：质心相似 ≥ recallMinCosine；无质心的手动主题用标题/定义向量（门槛 0.3）
  const centroidScores = [];
  for (const topic of threadTopics) {
    if (rejected.has(topic.id)) continue;
    const centroid = centroidVector(state, topic.id, excludeThoughtId);
    if (centroid !== null) {
      const score = cosine(targetVector, centroid);
      if (score >= calibration.recallMinCosine) centroidScores.push({ topicId: topic.id, cosine: score });
      continue;
    }
    if (threadTopics.length <= 3) continue;
    const profile = await vectors.topicProfile(topic.title, topic.definition);
    const score = cosine(targetVector, profile);
    if (score >= PROFILE_MIN_COSINE) centroidScores.push({ topicId: topic.id, cosine: score });
  }
  centroidScores.sort((a, b) => b.cosine - a.cosine);

  // 脉络通道 ②：全局近邻 Top20 → 其有效主题投票（类别主题不参与）
  const excluded = new Set([...rejected, ...categoryTopics.map((topic) => topic.id)]);
  const voteScores = new Map();
  for (const neighbor of nearestNeighbors(state, target, targetVector)) {
    if (neighbor.thought.archived) continue;
    for (const topic of effectiveVisibleTopics(state, neighbor.thought)) {
      if (excluded.has(topic.id)) continue;
      const entry = voteScores.get(topic.id) ?? { votes: 0, cosineSum: 0 };
      entry.votes += 1;
      entry.cosineSum += neighbor.similarity;
      voteScores.set(topic.id, entry);
    }
  }

  // 脉络通道 ③：合并，票数达标且均分 ≥ recallMinCosine 者入选，按综合分取 ≤3
  const merged = new Map();
  for (const entry of centroidScores.slice(0, CENTROID_TOP)) {
    merged.set(entry.topicId, { centroidCosine: entry.cosine, votes: 0, mean: 0 });
  }
  for (const [topicId, entry] of voteScores) {
    const mean = entry.cosineSum / entry.votes;
    if (entry.votes < calibration.neighborVoteMinCount || mean < calibration.recallMinCosine) continue;
    const existing = merged.get(topicId);
    if (existing) {
      existing.votes = entry.votes;
      existing.mean = mean;
    } else {
      merged.set(topicId, { centroidCosine: null, votes: entry.votes, mean });
    }
  }
  // 脉络主题很少时，即便没有成员也全部进语义核对，不能因无质心永远不被采用
  if (threadTopics.length > 0 && threadTopics.length <= 3) {
    for (const topic of threadTopics) {
      if (!rejected.has(topic.id) && !merged.has(topic.id)) {
        merged.set(topic.id, { centroidCosine: null, votes: 0, mean: 0 });
      }
    }
  }
  const recallScore = (entry) => Math.max(entry.centroidCosine ?? 0, entry.votes > 0 ? entry.mean : 0);
  const threadCandidates = [...merged.entries()]
    .sort((a, b) => recallScore(b[1]) - recallScore(a[1]) || compareCodePoints(a[0], b[0]))
    .slice(0, THREAD_CANDIDATE_LIMIT);

  // 类别通道：启用的归档类别全量核对，不做相似度筛选、不与脉络争名额
  const candidates = [
    ...categoryTopics
      .filter((topic) => !rejected.has(topic.id))
      .slice(0, CATEGORY_CHANNEL_LIMIT)
      .map((topic) => ({ topicId: topic.id, kind: "category", recallScore: 0, centroidCosine: null, votes: 0, mean: 0 })),
    ...threadCandidates.map(([topicId, entry]) => ({
      topicId, kind: "thread", recallScore: recallScore(entry),
      centroidCosine: entry.centroidCosine, votes: entry.votes, mean: entry.votes > 0 ? entry.mean : 0,
    })),
  ];
  const hasVisibleTopics = categoryTopics.length > 0 || threadTopics.length > 0;
  return {
    candidates,
    reason: candidates.length > 0 ? null : (hasVisibleTopics ? "below_recall_threshold" : "no_visible_topics"),
  };
}
