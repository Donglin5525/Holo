// 想法主题归类评测 · 自动发现主题的聚簇
//
// ThoughtTopicClusterEngine 的 JS 移植：把「互相相近、又不属于任何主题」的想法聚成候选簇。
//   · 每条孤儿想法在孤儿集合内找 8 个近邻，相似度 ≥ 召回阈值（种子值 0.55）连边；
//   · 并查集连通分量成簇，成员 ≥3 才够格；
//   · 内聚度 = 簇内全部边的平均相似度；按成员数升序、内聚度降序排。
// 与真机的已知差异：近邻用精确余弦代替 USearch 的近似检索。

import { createHash } from "node:crypto";

import { cosine } from "./text.mjs";

/** ThoughtTopicClusterEngine.minClusterSize */
export const MIN_CLUSTER_SIZE = 3;
const NEIGHBOR_TOP_K = 8;
const ENGINE_VERSION = "thought_semantic_v3.1";

/** ThoughtTopicClusterEngine.clusterComponents。neighborLookup 返回该想法在孤儿集合内的近邻。 */
export function clusterComponents(ids, vectors, threshold, minSize, neighborLookup) {
  if (ids.length < minSize) return [];
  const indexOf = new Map(ids.map((id, index) => [id, index]));
  const parent = ids.map((_, index) => index);
  const find = (x) => {
    let root = x;
    while (parent[root] !== root) root = parent[root];
    while (parent[x] !== root) {
      const next = parent[x];
      parent[x] = root;
      x = next;
    }
    return root;
  };

  // 边先收集、并查集全量合并后再按最终根聚合内聚度
  const edges = [];
  const seenPairs = new Set();
  for (const id of ids) {
    if (!vectors.has(id)) continue;
    const i = indexOf.get(id);
    for (const neighbor of neighborLookup(id)) {
      if (neighbor.id === id || neighbor.similarity < threshold) continue;
      if (!indexOf.has(neighbor.id) || !vectors.has(neighbor.id)) continue;
      const j = indexOf.get(neighbor.id);
      const pair = `${Math.min(i, j)}:${Math.max(i, j)}`;
      if (seenPairs.has(pair)) continue;
      seenPairs.add(pair);
      parent[find(j)] = find(i);
      edges.push([i, neighbor.similarity]);
    }
  }

  const byRoot = new Map();
  ids.forEach((id, index) => {
    const root = find(index);
    byRoot.set(root, [...(byRoot.get(root) ?? []), id]);
  });
  const aggregated = new Map();
  for (const [i, similarity] of edges) {
    const root = find(i);
    const previous = aggregated.get(root) ?? { sum: 0, count: 0 };
    aggregated.set(root, { sum: previous.sum + similarity, count: previous.count + 1 });
  }
  return [...byRoot.values()]
    .filter((members) => members.length >= minSize)
    .map((members) => {
      const { sum, count } = aggregated.get(find(indexOf.get(members[0]))) ?? { sum: 0, count: 0 };
      return { members: [...members].sort(), cohesion: count > 0 ? sum / count : threshold };
    })
    .sort((a, b) => a.members.length - b.members.length || b.cohesion - a.cohesion);
}

/** 每条孤儿在孤儿集合内的近邻（线上取 8 个近邻建边）。 */
export function orphanAdjacency(ids, vectors) {
  const adjacency = new Map();
  ids.forEach((id, index) => {
    const vector = vectors.get(id);
    const neighbors = [];
    ids.forEach((other, otherIndex) => {
      if (otherIndex !== index) neighbors.push({ id: other, similarity: cosine(vector, vectors.get(other)) });
    });
    neighbors.sort((a, b) => b.similarity - a.similarity);
    adjacency.set(id, neighbors.slice(0, NEIGHBOR_TOP_K));
  });
  return adjacency;
}

/** ThoughtTopicClusterEngine.fingerprint：成员 id 排序后连同引擎版本取 SHA-256 前 16 字节。 */
export function fingerprint(memberIds) {
  return createHash("sha256")
    .update([...memberIds].sort().join("|"), "utf8")
    .update(ENGINE_VERSION, "utf8")
    .digest("hex")
    .slice(0, 32);
}
