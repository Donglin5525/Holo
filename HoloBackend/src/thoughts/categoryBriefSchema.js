import { GatewayError } from "../errors.js";

/**
 * 归档类别理解器 /v1/thoughts/category-brief 输入/输出契约
 * （2026-10-12 主题双通道·零打扰：AI 代写/精化 classification 主题的「收什么」定义）。
 *
 * 校验器是纯函数：结构、长度、枚举与逐字证据校验，不触网络与存储。
 * 与 relate 同纪律：成员片段是用户笔记正文，purpose 一律 metadata_only。
 */

export const BRIEF_LIMITS = Object.freeze({
  requestBodyMaxBytes: 64 * 1024,
  titleMaxUTF16: 32,
  userDefinitionMaxUTF16: 240,
  briefDefinitionMaxUTF16: 240,
  exclusionMaxUTF16: 40,
  exclusionMaxCount: 6,
  memberMaxCount: 10,
  memberMinCount: 3,
  removalMaxCount: 3,
  memberTextMaxUTF16: 240,
  quoteMaxUTF16: 80,
  evidenceMaxCount: 4,
  idMaxUTF16: 64,
});

const MEMBER_SOURCES = Object.freeze(new Set(["user", "ai", "legacy"]));

/** 短标识串：拒绝空串、控制字符与换行。 */
function isCleanShortString(value, maxLength) {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) return false;
  // eslint-disable-next-line no-control-regex
  return !/[\u0000-\u001f\u007f]/.test(value);
}

/** 正文类字符串：允许换行，拒绝其他控制字符，长度受限。 */
function isBoundedText(value, maxLength) {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) return false;
  // eslint-disable-next-line no-control-regex
  return !/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/.test(value);
}

/**
 * 校验并归一化请求体。返回
 * { schemaVersion, operationId, engineVersion, topic: {title, userDefinition, currentBrief},
 *   members: [{ref, text, source}], removals: [{ref, text}] }。
 */
export function validateBriefRequest(body) {
  if (!body || typeof body !== "object") {
    throw new GatewayError("INVALID_REQUEST", "Request body must be an object", 400);
  }
  if (body.schemaVersion !== 1) {
    throw new GatewayError("INVALID_REQUEST", "schemaVersion must be 1", 400);
  }
  if (!isCleanShortString(body.operationId, BRIEF_LIMITS.idMaxUTF16)
      || !isCleanShortString(body.engineVersion, BRIEF_LIMITS.idMaxUTF16)) {
    throw new GatewayError("INVALID_REQUEST", "operationId/engineVersion must be 1-64 clean chars", 400);
  }
  const topic = body.topic;
  if (!topic || typeof topic !== "object" || !isBoundedText(topic.title, BRIEF_LIMITS.titleMaxUTF16)) {
    throw new GatewayError("INVALID_REQUEST", "topic.title must be 1-32 UTF-16 units", 400);
  }
  for (const field of ["userDefinition", "currentBrief"]) {
    if (topic[field] !== undefined && topic[field] !== null
        && !isBoundedText(topic[field], BRIEF_LIMITS.userDefinitionMaxUTF16)) {
      throw new GatewayError("INVALID_REQUEST", `topic.${field} exceeds ${BRIEF_LIMITS.userDefinitionMaxUTF16} UTF-16 units`, 400);
    }
  }
  if (!Array.isArray(body.members) || body.members.length < BRIEF_LIMITS.memberMinCount
      || body.members.length > BRIEF_LIMITS.memberMaxCount) {
    throw new GatewayError("INVALID_REQUEST", `members must be ${BRIEF_LIMITS.memberMinCount}-${BRIEF_LIMITS.memberMaxCount} items`, 400);
  }
  const refs = new Set();
  const members = body.members.map((member, index) => {
    if (!member || typeof member !== "object" || !isCleanShortString(member.ref, BRIEF_LIMITS.idMaxUTF16)) {
      throw new GatewayError("INVALID_REQUEST", `members[${index}].ref must be 1-64 clean chars`, 400);
    }
    if (refs.has(member.ref)) {
      throw new GatewayError("INVALID_REQUEST", `duplicate member ref ${member.ref}`, 400);
    }
    refs.add(member.ref);
    if (!isBoundedText(member.text, BRIEF_LIMITS.memberTextMaxUTF16)) {
      throw new GatewayError("INVALID_REQUEST", `members[${index}].text exceeds ${BRIEF_LIMITS.memberTextMaxUTF16} UTF-16 units`, 400);
    }
    if (!MEMBER_SOURCES.has(member.source)) {
      throw new GatewayError("INVALID_REQUEST", `members[${index}].source must be user/ai/legacy`, 400);
    }
    return { ref: member.ref, text: member.text, source: member.source };
  });
  const removalsRaw = body.removals ?? [];
  if (!Array.isArray(removalsRaw) || removalsRaw.length > BRIEF_LIMITS.removalMaxCount) {
    throw new GatewayError("INVALID_REQUEST", `removals must be ≤${BRIEF_LIMITS.removalMaxCount} items`, 400);
  }
  const removals = removalsRaw.map((item, index) => {
    if (!item || typeof item !== "object" || !isCleanShortString(item.ref, BRIEF_LIMITS.idMaxUTF16)) {
      throw new GatewayError("INVALID_REQUEST", `removals[${index}].ref must be 1-64 clean chars`, 400);
    }
    if (!isBoundedText(item.text, BRIEF_LIMITS.memberTextMaxUTF16)) {
      throw new GatewayError("INVALID_REQUEST", `removals[${index}].text exceeds ${BRIEF_LIMITS.memberTextMaxUTF16} UTF-16 units`, 400);
    }
    return { ref: item.ref, text: item.text };
  });
  return {
    schemaVersion: 1,
    operationId: body.operationId,
    engineVersion: body.engineVersion,
    topic: { title: topic.title, userDefinition: topic.userDefinition ?? null, currentBrief: topic.currentBrief ?? null },
    members,
    removals,
  };
}

/**
 * 校验模型输出。规则：
 * - brief.definition 非空且 ≤240 UTF-16；exclusions 每条 ≤40、≤6 条、去空去重；
 * - evidence 1-4 条，ref 必须来自 members，quote 必须是该成员原文的逐字子串；
 * - 任何字段违规返回 { malformed, reason }。
 */
export function validateBriefModelOutput(output, parsedRequest) {
  if (!output || typeof output !== "object") return { malformed: true, reason: "not_object" };
  // operationId 属响应封套，服务端回填请求值（模型回显不影响客户端）；
  // 致命校验只保留内容契约：definition/exclusions/evidence 逐字回源。
  const brief = output.brief;
  if (!brief || typeof brief !== "object") return { malformed: true, reason: "brief_missing" };
  if (!isBoundedText(brief.definition, BRIEF_LIMITS.briefDefinitionMaxUTF16)) {
    return { malformed: true, reason: "definition_shape" };
  }
  const exclusionsRaw = brief.exclusions;
  if (!Array.isArray(exclusionsRaw) || exclusionsRaw.length > BRIEF_LIMITS.exclusionMaxCount) {
    return { malformed: true, reason: "exclusions_shape" };
  }
  const exclusions = [];
  for (const item of exclusionsRaw) {
    if (typeof item !== "string") return { malformed: true, reason: "exclusion_shape" };
    const trimmed = item.trim();
    if (!trimmed) continue;
    if (trimmed.length > BRIEF_LIMITS.exclusionMaxUTF16) return { malformed: true, reason: "exclusion_too_long" };
    if (!exclusions.includes(trimmed)) exclusions.push(trimmed);
  }
  const textByRef = new Map(parsedRequest.members.map((m) => [m.ref, m.text]));
  const evidenceRaw = output.evidence;
  if (!Array.isArray(evidenceRaw) || evidenceRaw.length === 0 || evidenceRaw.length > BRIEF_LIMITS.evidenceMaxCount) {
    return { malformed: true, reason: "evidence_shape" };
  }
  const evidence = [];
  const seenRefs = new Set();
  for (const item of evidenceRaw) {
    if (!item || typeof item !== "object" || typeof item.ref !== "string" || !textByRef.has(item.ref)) {
      return { malformed: true, reason: "evidence_ref_not_allowed" };
    }
    if (seenRefs.has(item.ref)) return { malformed: true, reason: "evidence_ref_duplicated" };
    seenRefs.add(item.ref);
    if (typeof item.quote !== "string" || !item.quote.length || item.quote.length > BRIEF_LIMITS.quoteMaxUTF16) {
      return { malformed: true, reason: "quote_shape" };
    }
    if (!textByRef.get(item.ref).includes(item.quote)) {
      return { malformed: true, reason: "quote_not_verbatim" };
    }
    evidence.push({ ref: item.ref, quote: item.quote });
  }
  return { brief: { definition: brief.definition, exclusions }, evidence };
}
