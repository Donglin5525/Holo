import { GatewayError } from "../errors.js";

/**
 * 想法主题洞察 V3 /v1/thoughts/topic-name 与 /v1/thoughts/topic-summary 输入/输出契约
 * （主方案 docs/thoughts/plans/2026-09-10-Holo想法本地语义图谱V3-完整实施方案-GLM.md §5.2/§4.4/§4.5）。
 *
 * 最小发送原则（§5.2）：新 Topic 命名最多 8 条代表想法；Topic 摘要最多 12 条
 * 代表想法（大主题分层摘要，永不一次上传全部）。代表片段 ≤240 UTF-16。
 *
 * 校验器是纯函数：只做结构、长度与逐字证据校验，不触碰网络与存储。
 * JS 字符串下标即 UTF-16 单位，与协议的 rangeUTF16 语义天然一致。
 */

export const TOPIC_NAME_LIMITS = Object.freeze({
  requestBodyMaxBytes: 48 * 1024,
  representativeMaxCount: 8,
  representativeTextMaxUTF16: 240,
  nameMaxUTF16: 32,
  idMaxUTF16: 64,
});

export const TOPIC_SUMMARY_LIMITS = Object.freeze({
  requestBodyMaxBytes: 64 * 1024,
  topicTitleMaxUTF16: 32,
  representativeMaxCount: 12,
  representativeTextMaxUTF16: 240,
  summaryMaxUTF16: 240,
  viewpointMaxCount: 4,
  viewpointQuoteMaxUTF16: 120,
  idMaxUTF16: 64,
});

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

/** 代表想法数组：ref 白名单原料 + 逐字证据的对齐目标。 */
function parseRepresentatives(value, limits, label, errorFactory) {
  if (!Array.isArray(value) || value.length === 0) {
    throw errorFactory(`${label} must be a non-empty array`);
  }
  if (value.length > limits.representativeMaxCount) {
    throw errorFactory(`${label} exceed ${limits.representativeMaxCount}`);
  }
  const refs = new Set();
  return value.map((rep, index) => {
    if (!rep || typeof rep !== "object" || !isCleanShortString(rep.ref, limits.idMaxUTF16)) {
      throw errorFactory(`${label}[${index}].ref invalid`);
    }
    if (refs.has(rep.ref)) {
      throw errorFactory(`duplicate representative ref ${rep.ref}`);
    }
    refs.add(rep.ref);
    if (!isBoundedText(rep.text, limits.representativeTextMaxUTF16)) {
      throw errorFactory(`${label}[${index}].text exceeds ${limits.representativeTextMaxUTF16} UTF-16 units`);
    }
    return { ref: rep.ref, text: rep.text };
  });
}

function requireEnvelope(body, limits, errorFactory) {
  if (!body || typeof body !== "object") {
    throw errorFactory("Request body must be an object");
  }
  if (body.schemaVersion !== 1) {
    throw errorFactory("schemaVersion must be 1");
  }
  if (!isCleanShortString(body.operationId, limits.idMaxUTF16)) {
    throw errorFactory("operationId must be 1-64 clean chars");
  }
  if (!isCleanShortString(body.engineVersion, limits.idMaxUTF16)) {
    throw errorFactory("engineVersion must be 1-64 clean chars");
  }
}

/**
 * 校验并归一化 /v1/thoughts/topic-name 请求体。
 * 返回 { schemaVersion, operationId, engineVersion, representatives }；非法请求抛 4xx。
 */
export function validateTopicNameRequest(body) {
  const fail = (message) => new GatewayError("INVALID_REQUEST", message, 400);
  requireEnvelope(body, TOPIC_NAME_LIMITS, fail);
  const representatives = parseRepresentatives(
    body.representatives, TOPIC_NAME_LIMITS, "representatives", fail,
  );
  return {
    schemaVersion: 1,
    operationId: body.operationId,
    engineVersion: body.engineVersion,
    representatives,
  };
}

/**
 * 校验命名模型输出。规则：name 必须是 1-32 干净字符；
 * 不得原样复制任何代表片段（命名是归纳，不是搬运）。
 * 返回 { name } 或 { malformed, reason }。
 */
export function validateTopicNameOutput(output, parsedRequest) {
  if (!output || typeof output !== "object") return { malformed: true, reason: "not_object" };
  const name = output.name;
  if (!isCleanShortString(name, TOPIC_NAME_LIMITS.nameMaxUTF16)) {
    return { malformed: true, reason: "name_shape" };
  }
  const normalized = name.trim();
  if (normalized.length === 0) return { malformed: true, reason: "name_shape" };
  for (const rep of parsedRequest.representatives) {
    if (rep.text.includes(normalized)) {
      return { malformed: true, reason: "name_copies_representative" };
    }
  }
  return { name: normalized };
}

/**
 * 校验并归一化 /v1/thoughts/topic-summary 请求体。
 * 返回 { schemaVersion, operationId, engineVersion, topic, representatives }。
 */
export function validateTopicSummaryRequest(body) {
  const fail = (message) => new GatewayError("INVALID_REQUEST", message, 400);
  requireEnvelope(body, TOPIC_SUMMARY_LIMITS, fail);
  if (!body.topic || typeof body.topic !== "object"
      || !isCleanShortString(body.topic.title, TOPIC_SUMMARY_LIMITS.topicTitleMaxUTF16)) {
    throw fail(`topic.title must be 1-${TOPIC_SUMMARY_LIMITS.topicTitleMaxUTF16} clean chars`);
  }
  const representatives = parseRepresentatives(
    body.representatives, TOPIC_SUMMARY_LIMITS, "representatives", fail,
  );
  return {
    schemaVersion: 1,
    operationId: body.operationId,
    engineVersion: body.engineVersion,
    topic: { title: body.topic.title },
    representatives,
  };
}

/**
 * 校验摘要模型输出（方案 §4.5：摘要 + 反复出现的观点，均可溯源）。
 * 规则：
 * - summary 必须是 1-240 UTF-16 的正文文本；
 * - viewpoints 只允许请求中的 ref（拒绝模型自造来源）；
 * - quote 必须是所指代表片段的逐字子串且 rangeUTF16 严格对齐；
 * - viewpoints 缺失视为空（合法——主题可能太新没有反复观点）。
 * 返回 { summary, viewpoints } 或 { malformed, reason }。
 */
export function validateTopicSummaryOutput(output, parsedRequest) {
  if (!output || typeof output !== "object") return { malformed: true, reason: "not_object" };
  const summary = output.summary;
  if (!isBoundedText(summary, TOPIC_SUMMARY_LIMITS.summaryMaxUTF16)) {
    return { malformed: true, reason: "summary_shape" };
  }
  const raw = output.viewpoints;
  if (raw === undefined || raw === null) {
    return { summary, viewpoints: [] };
  }
  if (!Array.isArray(raw) || raw.length > TOPIC_SUMMARY_LIMITS.viewpointMaxCount) {
    return { malformed: true, reason: "viewpoints_shape" };
  }
  const byRef = new Map(parsedRequest.representatives.map((rep) => [rep.ref, rep.text]));
  const seen = new Set();
  const viewpoints = [];
  for (const item of raw) {
    if (!item || typeof item !== "object") return { malformed: true, reason: "viewpoint_not_object" };
    if (typeof item.ref !== "string" || !byRef.has(item.ref)) {
      return { malformed: true, reason: "viewpoint_ref_not_allowed" };
    }
    if (seen.has(item.ref)) return { malformed: true, reason: "viewpoint_ref_duplicated" };
    seen.add(item.ref);
    if (typeof item.quote !== "string" || item.quote.length === 0
        || item.quote.length > TOPIC_SUMMARY_LIMITS.viewpointQuoteMaxUTF16) {
      return { malformed: true, reason: "quote_shape" };
    }
    const text = byRef.get(item.ref);
    const start = text.indexOf(item.quote);
    if (start < 0) return { malformed: true, reason: "quote_not_verbatim" };
    const range = item.rangeUTF16;
    if (!Array.isArray(range) || range.length !== 2
        || !Number.isInteger(range[0]) || !Number.isInteger(range[1])
        || range[0] !== start || range[1] !== start + item.quote.length) {
      return { malformed: true, reason: "range_mismatch" };
    }
    viewpoints.push({ ref: item.ref, quote: item.quote, rangeUTF16: [start, start + item.quote.length] });
  }
  return { summary, viewpoints };
}
