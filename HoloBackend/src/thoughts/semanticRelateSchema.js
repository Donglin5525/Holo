import { GatewayError } from "../errors.js";

/**
 * 想法语义关联 V3 /v1/thoughts/semantic-relate 输入/输出契约
 * （主方案 docs/thoughts/plans/2026-09-10-Holo想法本地语义图谱V3-完整实施方案-GLM.md §16.2）。
 *
 * 校验器是纯函数：只做结构、长度、枚举与逐字证据校验，不触碰网络与存储。
 * JS 字符串下标即 UTF-16 单位，与协议的 rangeUTF16 语义天然一致。
 */

export const RELATE_LIMITS = Object.freeze({
  requestBodyMaxBytes: 64 * 1024,
  targetTextMaxUTF16: 4_000,
  candidateMaxCount: 3,
  titleMaxUTF16: 32,
  summaryMaxUTF16: 240,
  representativeMaxCount: 3,
  representativeTextMaxUTF16: 240,
  decisionsMaxCount: 3,
  quoteMaxUTF16: 120,
  idMaxUTF16: 64,
});

export const RELATION_VALUES = Object.freeze(new Set(["same_thread", "related", "none", "insufficient"]));

/** 短标识串：拒绝空串、控制字符与换行（防协议/路径注入）。 */
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
 * 校验并归一化 /v1/thoughts/semantic-relate 请求体。
 * 返回 { schemaVersion, operationId, textRevision, engineVersion, target, candidates }；
 * 非法请求抛 4xx GatewayError。
 */
export function validateRelateRequest(body) {
  if (!body || typeof body !== "object") {
    throw new GatewayError("INVALID_REQUEST", "Request body must be an object", 400);
  }
  if (body.schemaVersion !== 1) {
    throw new GatewayError("INVALID_REQUEST", "schemaVersion must be 1", 400);
  }
  if (!isCleanShortString(body.operationId, RELATE_LIMITS.idMaxUTF16)) {
    throw new GatewayError("INVALID_REQUEST", "operationId must be 1-64 clean chars", 400);
  }
  for (const field of ["textRevision", "engineVersion"]) {
    if (!isCleanShortString(body[field], RELATE_LIMITS.idMaxUTF16)) {
      throw new GatewayError("INVALID_REQUEST", `${field} must be 1-64 clean chars`, 400);
    }
  }
  const target = body.target;
  if (!target || typeof target !== "object" || !isCleanShortString(target.ref, RELATE_LIMITS.idMaxUTF16)) {
    throw new GatewayError("INVALID_REQUEST", "target.ref must be 1-64 clean chars", 400);
  }
  if (!isBoundedText(target.text, RELATE_LIMITS.targetTextMaxUTF16)) {
    throw new GatewayError("INVALID_REQUEST", `target.text must be 1-${RELATE_LIMITS.targetTextMaxUTF16} UTF-16 units`, 400);
  }

  if (!Array.isArray(body.candidates) || body.candidates.length === 0) {
    throw new GatewayError("INVALID_REQUEST", "candidates must be a non-empty array", 400);
  }
  if (body.candidates.length > RELATE_LIMITS.candidateMaxCount) {
    throw new GatewayError("INVALID_REQUEST", `candidates exceed ${RELATE_LIMITS.candidateMaxCount}`, 400);
  }
  const allowedRefs = new Set([target.ref]);
  const candidates = body.candidates.map((candidate, index) => {
    if (!candidate || typeof candidate !== "object") {
      throw new GatewayError("INVALID_REQUEST", `candidates[${index}] must be an object`, 400);
    }
    if (!isCleanShortString(candidate.ref, RELATE_LIMITS.idMaxUTF16)) {
      throw new GatewayError("INVALID_REQUEST", `candidates[${index}].ref must be 1-64 clean chars`, 400);
    }
    if (allowedRefs.has(candidate.ref)) {
      throw new GatewayError("INVALID_REQUEST", `duplicate candidate ref ${candidate.ref}`, 400);
    }
    allowedRefs.add(candidate.ref);
    if (!isBoundedText(candidate.title, RELATE_LIMITS.titleMaxUTF16)) {
      throw new GatewayError("INVALID_REQUEST", `candidates[${index}].title must be 1-${RELATE_LIMITS.titleMaxUTF16} UTF-16 units`, 400);
    }
    if (candidate.summary !== undefined && candidate.summary !== null
        && !isBoundedText(candidate.summary, RELATE_LIMITS.summaryMaxUTF16)) {
      throw new GatewayError("INVALID_REQUEST", `candidates[${index}].summary exceeds ${RELATE_LIMITS.summaryMaxUTF16} UTF-16 units`, 400);
    }
    if (!Array.isArray(candidate.representatives) || candidate.representatives.length === 0) {
      throw new GatewayError("INVALID_REQUEST", `candidates[${index}].representatives must be non-empty`, 400);
    }
    if (candidate.representatives.length > RELATE_LIMITS.representativeMaxCount) {
      throw new GatewayError("INVALID_REQUEST", `candidates[${index}].representatives exceed ${RELATE_LIMITS.representativeMaxCount}`, 400);
    }
    const representatives = candidate.representatives.map((rep, rIndex) => {
      if (!rep || typeof rep !== "object" || !isCleanShortString(rep.ref, RELATE_LIMITS.idMaxUTF16)) {
        throw new GatewayError("INVALID_REQUEST", `candidates[${index}].representatives[${rIndex}].ref invalid`, 400);
      }
      if (!isBoundedText(rep.text, RELATE_LIMITS.representativeTextMaxUTF16)) {
        throw new GatewayError("INVALID_REQUEST", `candidates[${index}].representatives[${rIndex}].text exceeds ${RELATE_LIMITS.representativeTextMaxUTF16} UTF-16 units`, 400);
      }
      return { ref: rep.ref, text: rep.text };
    });
    return {
      ref: candidate.ref,
      title: candidate.title,
      summary: candidate.summary ?? null,
      representatives,
    };
  });

  return {
    schemaVersion: 1,
    operationId: body.operationId,
    textRevision: body.textRevision,
    engineVersion: body.engineVersion,
    target: { ref: target.ref, text: target.text },
    candidates,
  };
}

/**
 * 校验模型输出（已在调用方解析为对象）。
 * 规则（方案 §16.2/§10.1）：
 * - decisions 只允许请求中的 candidateRef（拒绝模型自造 Topic）；
 * - relation 只允许 same_thread/related/none/insufficient；
 * - quote 必须是目标正文逐字片段且 rangeUTF16 与之一致；
 * - 任何 decision 出现数值 confidence 即整体 malformed；
 * - decisions 缺失视为 insufficient 空结果（允许空）。
 * 返回 { decisions } 或 { malformed, reason }。
 */
export function validateRelateModelOutput(output, parsedRequest) {
  if (!output || typeof output !== "object") return { malformed: true, reason: "not_object" };
  const allowedRefs = new Set(parsedRequest.candidates.map((c) => c.ref));
  const decisionsRaw = output.decisions;
  if (decisionsRaw === undefined || decisionsRaw === null) {
    return { decisions: [] };
  }
  if (!Array.isArray(decisionsRaw) || decisionsRaw.length > RELATE_LIMITS.decisionsMaxCount) {
    return { malformed: true, reason: "decisions_shape" };
  }
  const seen = new Set();
  const decisions = [];
  for (const item of decisionsRaw) {
    if (!item || typeof item !== "object") return { malformed: true, reason: "decision_not_object" };
    if (typeof item.candidateRef !== "string" || !allowedRefs.has(item.candidateRef)) {
      return { malformed: true, reason: "candidate_ref_not_allowed" };
    }
    if (seen.has(item.candidateRef)) return { malformed: true, reason: "candidate_ref_duplicated" };
    seen.add(item.candidateRef);
    if (!RELATION_VALUES.has(item.relation)) {
      return { malformed: true, reason: "relation_enum" };
    }
    if (item.confidence !== undefined && item.confidence !== null) {
      return { malformed: true, reason: "confidence_forbidden" };
    }
    if (item.relation === "none" || item.relation === "insufficient") {
      decisions.push({ candidateRef: item.candidateRef, relation: item.relation, quote: null, rangeUTF16: null });
      continue;
    }
    // same_thread / related 必须携带可核对证据
    if (typeof item.quote !== "string" || item.quote.length === 0
        || item.quote.length > RELATE_LIMITS.quoteMaxUTF16) {
      return { malformed: true, reason: "quote_shape" };
    }
    const text = parsedRequest.target.text;
    const start = text.indexOf(item.quote);
    if (start < 0) return { malformed: true, reason: "quote_not_verbatim" };
    const range = item.rangeUTF16;
    if (!Array.isArray(range) || range.length !== 2
        || !Number.isInteger(range[0]) || !Number.isInteger(range[1])
        || range[0] !== start || range[1] !== start + item.quote.length) {
      return { malformed: true, reason: "range_mismatch" };
    }
    decisions.push({ candidateRef: item.candidateRef, relation: item.relation, quote: item.quote, rangeUTF16: [range[0], range[1]] });
  }
  return { decisions };
}
