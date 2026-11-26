// 想法主题归类评测 · 想法-主题关系投影
//
// ThoughtTopicLinkProjection（APP/Services/Thoughts）的 JS 移植：同 pair 裁决、
// 有效成员、成员来源、类别代表例取样序、落库守卫。客户端读到的「现状归属」全由它决定。

const ACTIVE_RANK_BY_SOURCE = { user: 0, ai: 2, legacy: 3 };
const SAMPLE_RANK_BY_SOURCE = { user: 0, ai: 1, legacy: 2 };

/** ThoughtTopicLink.projectionRank：用户 active 0 > rejected 墓碑 1 > ai/v3 active 2 > legacy active 3 > 其他 4。 */
export function projectionRank(link) {
  if (link.state === "rejected") return 1;
  if (link.state !== "active") return 4;
  return ACTIVE_RANK_BY_SOURCE[link.source] ?? 4;
}

/** 同 pair 多行取投影优先级最高的一行。 */
function winningLink(thought, topicId) {
  let best = null;
  for (const link of thought.links) {
    if (link.topicId !== topicId) continue;
    if (best === null || projectionRank(link) < projectionRank(best)) best = link;
  }
  return best;
}

/** isCurrentActive：ai/v3 关系只对生成它的正文版本有效；用户决定持续有效。 */
function isCurrentActive(link, thought) {
  if (link.state !== "active") return false;
  if (link.source !== "ai") return true;
  return (link.basisTextHash ?? thought.contentHash) === thought.contentHash;
}

export function isEffectiveMember(thought, topicId) {
  const link = winningLink(thought, topicId);
  return link !== null && isCurrentActive(link, thought);
}

export function isUserRejectedPair(thought, topicId) {
  return thought.links.some((link) => link.topicId === topicId && link.state === "rejected");
}

/** membershipSource：user（手动放入/接受建议）/ ai / legacy；非有效成员为 null。 */
export function membershipSource(thought, topicId) {
  const link = winningLink(thought, topicId);
  if (link === null || !isCurrentActive(link, thought)) return null;
  return link.source;
}

/** categorySampleRank：类别代表例取样序，用户决定 > AI 自动归入 > 历史归集 > 非成员。 */
export function categorySampleRank(thought, topicId) {
  return SAMPLE_RANK_BY_SOURCE[membershipSource(thought, topicId)] ?? 3;
}

/** effectiveActiveThoughtCount：有效成员数，排除已删/已归档想法。 */
export function effectiveActiveThoughtCount(thoughts, topicId) {
  let count = 0;
  for (const thought of thoughts) {
    if (!thought.archived && isEffectiveMember(thought, topicId)) count += 1;
  }
  return count;
}

/** recordAIV3Decision 的落库守卫：用户拒绝墓碑不复活、用户 active 关系不降级。 */
export function canRecordAIV3Decision(thought, topicId) {
  if (isUserRejectedPair(thought, topicId)) return false;
  const link = winningLink(thought, topicId);
  return !(link !== null && link.state === "active" && link.source === "user");
}

/** 该想法现有的 ai/v3 active 关系（含正文已改的 stale 行——落库时它们同样会被整批裁决）。 */
export function existingAIActiveTopicIds(thought) {
  return thought.links
    .filter((link) => link.source === "ai" && link.state === "active")
    .map((link) => link.topicId);
}
