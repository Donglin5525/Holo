// 想法主题归类评测 · 线上现状路径（schema 3，legacy）
//
// ThoughtTopicVerifier.evaluateLegacy 的 JS 移植，分三步：
//   ① buildLegacyRequests：按客户端口径组装候选（标题 / AI 摘要 / 类别定义 / ≤3 条代表例）；
//   ② acceptLegacyResponse：客户端的二次校验（信封、候选、引文逐字、主题侧依据）；
//   ③ commitLegacy：现状落库规则——判正项按主题 UUID 字母序截断到 3，
//      没被选中的既有 AI 归属整批撤销（方案 §2 F2 指出的「乱动」来源，基线要原样复现）。

import {
  chunks, compareCodePoints, prefix, quoteMatches, randomOperationId, redactForUpload,
} from "./text.mjs";
import { canRecordAIV3Decision, categorySampleRank, existingAIActiveTopicIds, isEffectiveMember } from "./projection.mjs";

export const LEGACY_SCHEMA_VERSION = 3;
export const LEGACY_ENGINE_VERSION = "thought_semantic_v3.2";
export const AUTO_ATTRIBUTION_LIMIT = 3;

const COMMITTING_RELATIONS = new Set(["same_thread", "fits_category"]);
const ALLOWED_RELATIONS = new Set(["same_thread", "fits_category", "related", "none", "insufficient"]);
const TARGET_CHUNK_MAX_UTF16 = 4_000;
const REPRESENTATIVE_LIMIT = 3;

/** 客户端复核不过的响应（终端错误：这条想法本轮不归属，也不重试）。 */
export class ContractViolationError extends Error {
  constructor(reason) {
    super(`客户端复核不通过：${reason}`);
    this.name = "ContractViolationError";
    this.reason = reason;
  }
}

function topicMembers(state, target, topicId) {
  const members = [];
  for (const thought of state.thoughts) {
    // 候选代表成员正文会上传：排除「不参与 AI」标签的想法，也不带目标自己
    if (thought.id === target.id || thought.archived || !thought.aiVisible) continue;
    if (isEffectiveMember(thought, topicId)) members.push(thought);
  }
  return members;
}

/** 候选载荷：类别定义 = 用户规则，缺失时回退本机 AI 类别理解（brief）。 */
export function buildLegacyCandidates(state, target, recallOutcome) {
  const candidates = [];
  const topicByRef = {};
  for (const candidate of recallOutcome.candidates) {
    const topic = state.topics.get(candidate.topicId);
    const ref = `P${candidates.length}`;
    const members = topicMembers(state, target, topic.id);
    // 类别代表例「用户确认优先」；脉络候选维持最近优先
    members.sort((a, b) => (candidate.kind === "category"
      ? categorySampleRank(a, topic.id) - categorySampleRank(b, topic.id)
      : 0) || b.updatedAtMs - a.updatedAtMs);
    const definition = topic.categoryDefinition ?? topic.briefDefinition;
    candidates.push({
      ref,
      title: prefix(topic.title, 32),
      ...(topic.summary === null ? {} : { summary: prefix(topic.summary, 240) }),
      kind: candidate.kind,
      ...(candidate.kind === "category" && definition !== null ? { definition: prefix(definition, 240) } : {}),
      representatives: members.slice(0, REPRESENTATIVE_LIMIT)
        .map((member) => ({ ref: member.id, text: prefix(redactForUpload(member.text), 240) }))
        .filter((representative) => representative.text.length > 0),
    });
    topicByRef[ref] = topic.id;
  }
  return { candidates, topicByRef };
}

/** 正文脱敏后按 4000 UTF-16 分段，每段一次请求，候选相同。 */
export function buildLegacyRequests(target, candidates) {
  return chunks(redactForUpload(target.text), TARGET_CHUNK_MAX_UTF16).map((chunk) => ({
    chunkText: chunk.text,
    request: {
      schemaVersion: LEGACY_SCHEMA_VERSION,
      operationId: randomOperationId(),
      textRevision: target.contentHash,
      engineVersion: LEGACY_ENGINE_VERSION,
      target: { ref: "T0", text: chunk.text },
      candidates,
    },
  }));
}

/** 客户端二次校验；返回本轮每个候选的判定码，以及通过双侧证据核对的正项。 */
export function acceptLegacyResponse({ request, chunkText }, topicByRef, response) {
  if (response.schemaVersion !== request.schemaVersion || response.operationId !== request.operationId
    || response.textRevision !== request.textRevision) {
    throw new ContractViolationError("envelope");
  }
  // 审核未过：客户端按 CONTENT_DEFERRED（400）终态处理，这条想法本轮不归属
  if (response.outcome === "deferred") throw new ContractViolationError(`deferred:${response.reasonCode ?? ""}`);
  if (response.decisions.length !== request.candidates.length) throw new ContractViolationError("decisions_missing");
  const seen = new Set();
  const verdicts = {};
  const positives = [];
  for (const decision of response.decisions) {
    const topicId = topicByRef[decision.candidateRef];
    const candidate = request.candidates.find((item) => item.ref === decision.candidateRef);
    if (topicId === undefined || seen.has(decision.candidateRef) || candidate === undefined
      || !ALLOWED_RELATIONS.has(decision.relation)) {
      throw new ContractViolationError("candidate");
    }
    seen.add(decision.candidateRef);
    verdicts[topicId] = decision.relation;
    // 归属判定要求双侧逐字证据；类别判定不要求共同对象，但主题侧依据必须逐字可回源
    if (!COMMITTING_RELATIONS.has(decision.relation) || typeof decision.quote !== "string"
      || !quoteMatches(decision.quote, chunkText, decision.rangeUTF16)
      || typeof decision.representativeRef !== "string"
      || typeof decision.representativeQuote !== "string" || decision.representativeQuote.length === 0) {
      continue;
    }
    if (decision.relation === "same_thread" && !(decision.sharedSubject ?? "").trim()) continue;
    const basis = decision.representativeRef === "definition"
      ? (candidate.definition ?? candidate.summary ?? candidate.title)
      : candidate.representatives.find((item) => item.ref === decision.representativeRef)?.text;
    if (basis === undefined || !basis.includes(decision.representativeQuote)) {
      throw new ContractViolationError("representative_quote");
    }
    positives.push({ topicId, relation: decision.relation });
  }
  return { verdicts, positives };
}

/**
 * 现状落库规则：判正项按主题 UUID 字母序截断到 3；既有 AI 归属里没被选中的整批撤销。
 * 用户拒绝墓碑 / 用户手动关系让位（recordAIV3Decision 守卫），用户关系永不被撤销。
 */
export function commitLegacy(target, positives) {
  const ranked = [...positives]
    .sort((a, b) => compareCodePoints(a.topicId, b.topicId))
    .slice(0, AUTO_ATTRIBUTION_LIMIT);
  const selected = new Set(ranked.map((item) => item.topicId));
  return {
    committed: ranked.filter((item) => canRecordAIV3Decision(target, item.topicId)).map((item) => item.topicId),
    // 被字母序截断掉的正项：判对了也落不了库
    truncated: positives.filter((item) => !selected.has(item.topicId)).map((item) => item.topicId),
    superseded: existingAIActiveTopicIds(target).filter((topicId) => !selected.has(topicId)),
  };
}
