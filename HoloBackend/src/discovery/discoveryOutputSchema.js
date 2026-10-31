import { GatewayError } from "../errors.js";

/**
 * 「一个发现」模型输出严格校验器（实施包 02 §10 / ai-output.schema.json 的代码化）。
 *
 * 不引入 JSON Schema 依赖：按 ai-output.schema.json v1 逐条手写同等约束——
 * 顶层 oneOf（candidates/verification）、字段白名单（additionalProperties:false）、
 * 必填、长度/数量边界、枚举、ID pattern、uniqueItems、allOf 条件约束
 * （type↔scopeKind、comparisonPeriods、noFindingReason、supported→supportEvidenceIDs、
 * accept→全 claim supported）。
 *
 * 已知取舍：`format: date-time` 只做可解析校验（不做 RFC3339 全量语法检查），
 * 语义/引用存在性校验仍归客户端发布门禁（实施包 02 §10：schema 通过后还要执行
 * 引用存在、ID 全覆盖、事件独立和权限等跨字段验证）。
 */

const ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9:_-]*$/;
const ID_MAX = 80;

const CANDIDATE_TYPES = new Set(["two_episodes", "bounded_pattern", "change_over_time"]);
const SCOPE_KINDS = new Set(["two_episodes", "bounded_events", "compared_periods"]);
const SENSITIVITY = new Set(["non_sensitive", "sensitive", "uncertain"]);
const CLAIM_KINDS = new Set(["fact", "observation"]);
const NO_FINDING_REASONS = new Set([
  "none", "no_material", "no_nontrivial_observation",
  "insufficient_independence", "insufficient_coverage", "sensitive_inference",
]);
const VERDICTS = new Set(["supported", "unsupported", "contradicted", "insufficient"]);
const CANDIDATE_VERDICTS = new Set(["accept", "reject"]);
const REASON_CODES = new Set([
  "insufficient_independence", "insufficient_coverage", "unknown_event_time",
  "unsupported_generalization", "unsupported_causality", "contradicting_evidence",
  "irrelevant_citation", "quote_mismatch", "numeric_mismatch", "wrong_subject",
  "sensitive_inference", "injection_attempt", "limited_scope",
]);
const DOMAINS = new Set(["thought", "task", "habit"]);

/**
 * 校验模型输出。
 * @param {string} rawText 上游 content 原文
 * @param {{ expectedKind: "candidates"|"verification", expectedRunID: string }} expect
 * @returns {{ ok: true, envelope: object }} 通过；失败抛 GatewayError(DISCOVERY_MODEL_OUTPUT_INVALID, 502, {reason})
 */
export function validateDiscoveryOutput(rawText, { expectedKind, expectedRunID }) {
  try {
    return validateDiscoveryOutputInner(rawText, { expectedKind, expectedRunID });
  } catch (error) {
    const isFormatError = error instanceof GatewayError && error.code === "DISCOVERY_MODEL_OUTPUT_INVALID";
    if (!isFormatError) throw error;
    // 2026-11-01 程序化修复层：qwen3.7-flash 的格式失误以机械性错为主（实测拒因：
    // scopeKind 映射错/漏 noFindingReason/漏 titleClaimID/漏 metricIDs/claims 越界——
    // 前四类占多数且属确定性可修）。修复只做查表映射与补默认值，绝不生成/改写内容；
    // 修完重验，仍不过才报错。这层把「模型性格」从链路可靠性里剥离。
    const reason = error.details?.reason ?? "";
    if (REPAIRABLE.has(reason.split(":")[0])) {
      let parsed;
      try { parsed = JSON.parse(extractJsonPayload(String(rawText))); } catch { throw enrichRaw(error, rawText); }
      if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
        const repaired = repairEnvelope(parsed);
        try {
          return validateDiscoveryOutputInner(JSON.stringify(repaired), { expectedKind, expectedRunID });
        } catch {
          throw enrichRaw(error, rawText);
        }
      }
    }
    throw enrichRaw(error, rawText);
  }
}

function enrichRaw(error, rawText) {
  if (error.details && error.details.rawTail) return error;
  return new GatewayError(error.code, error.message, 502,
    { ...(error.details ?? {}), rawTail: String(rawText).slice(-300) });
}

/** 可程序化修复的拒因（确定性查表/补默认可修，不涉内容生成）。 */
const REPAIRABLE = new Set([
  "scopeKind", "scope_kind_for_change", "scope_kind_for_pattern", "scope_kind_for_two_episodes",
  "no_finding_reason", "empty_with_no_reason", "candidates_with_reason",
  "titleClaimID", "title_claim_id", "body_claim_id",
  "claim_missing", "envelope_missing",
]);

/** 确定性修复：查表映射+补默认，不生成内容。返回修复后的可变副本。 */
function repairEnvelope(envelope) {
  const SCOPE_BY_TYPE = {
    two_episodes: "two_episodes",
    bounded_pattern: "bounded_events",
    change_over_time: "compared_periods",
  };
  for (const candidate of Array.isArray(envelope.candidates) ? envelope.candidates : []) {
    if (candidate && typeof candidate === "object") {
      if (typeof candidate.type === "string" && SCOPE_BY_TYPE[candidate.type]
        && candidate.scopeKind !== SCOPE_BY_TYPE[candidate.type]) {
        candidate.scopeKind = SCOPE_BY_TYPE[candidate.type];
      }
      const claims = Array.isArray(candidate.claims) ? candidate.claims : [];
      const observation = claims.find((claim) => claim && claim.kind === "observation");
      if (!candidate.titleClaimID && observation && observation.claimID) {
        candidate.titleClaimID = observation.claimID;
      }
      if (!Array.isArray(candidate.bodyClaimIDs) || candidate.bodyClaimIDs.length === 0) {
        const bodyIDs = claims
          .filter((claim) => claim && claim.claimID && claim.claimID !== candidate.titleClaimID)
          .map((claim) => claim.claimID);
        if (bodyIDs.length > 0) candidate.bodyClaimIDs = bodyIDs;
      }
      for (const claim of claims) {
        if (claim && typeof claim === "object" && !Array.isArray(claim.metricIDs)) {
          claim.metricIDs = [];
        }
      }
    }
  }
  if (envelope.noFindingReason === undefined || envelope.noFindingReason === null) {
    envelope.noFindingReason = (Array.isArray(envelope.candidates) && envelope.candidates.length > 0)
      ? "none" : "no_material";
  }
  return envelope;
}

function validateDiscoveryOutputInner(rawText, { expectedKind, expectedRunID }) {
  let parsed;
  try {
    parsed = JSON.parse(extractJsonPayload(rawText));
  } catch {
    throw invalid("json_unparseable");
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw invalid("not_object");
  }
  requireExactKeys(parsed, ["schemaVersion", "kind", "runID", ...(expectedKind === "candidates" ? ["candidates", "noFindingReason"] : ["candidateResults"])], "envelope");
  if (parsed.schemaVersion !== 1) throw invalid("schema_version");
  if (parsed.kind !== expectedKind) throw invalid("kind_mismatch");
  if (!isID(parsed.runID)) throw invalid("runID");
  if (parsed.runID !== expectedRunID) throw invalid("runID_mismatch");

  if (expectedKind === "candidates") validateCandidateEnvelope(parsed);
  else validateVerificationEnvelope(parsed);
  return { ok: true, envelope: parsed };
}

function validateCandidateEnvelope(envelope) {
  if (!Array.isArray(envelope.candidates)) throw invalid("candidates_not_array");
  if (envelope.candidates.length > 3) throw invalid("candidates_too_many");
  if (!NO_FINDING_REASONS.has(envelope.noFindingReason)) throw invalid("no_finding_reason");
  for (const candidate of envelope.candidates) validateCandidate(candidate);
  // allOf：空 candidates ⇔ noFindingReason != none
  if (envelope.candidates.length === 0 && envelope.noFindingReason === "none") {
    throw invalid("empty_with_no_reason");
  }
  if (envelope.candidates.length > 0 && envelope.noFindingReason !== "none") {
    throw invalid("candidates_with_reason");
  }
}

function validateCandidate(candidate) {
  if (!candidate || typeof candidate !== "object" || Array.isArray(candidate)) throw invalid("candidate_not_object");
  requireExactKeys(candidate, [
    "candidateID", "type", "subjectKey", "scopeKind", "timeRange", "claims",
    "titleClaimID", "bodyClaimIDs", "supportEvidenceIDs", "counterSearch",
    "sensitivity", "comparisonPeriods",
  ], "candidate");
  if (!isID(candidate.candidateID)) throw invalid("candidateID");
  if (!CANDIDATE_TYPES.has(candidate.type)) throw invalid("candidate_type");
  if (!isID(candidate.subjectKey)) throw invalid("subjectKey");
  if (!SCOPE_KINDS.has(candidate.scopeKind)) throw invalid("scopeKind");
  validateTimeRange(candidate.timeRange);
  if (!Array.isArray(candidate.claims) || candidate.claims.length < 2 || candidate.claims.length > 4) {
    throw invalid("claims_count");
  }
  const claimIDs = new Set();
  for (const claim of candidate.claims) {
    validateClaim(claim);
    if (claimIDs.has(claim.claimID)) throw invalid("duplicate_claim_id");
    claimIDs.add(claim.claimID);
  }
  if (!claimIDs.has(candidate.titleClaimID)) throw invalid("title_claim_id");
  if (!isID(candidate.titleClaimID)) throw invalid("titleClaimID");
  validateIDList(candidate.bodyClaimIDs, 1, 3);
  for (const bodyClaimID of candidate.bodyClaimIDs) {
    if (bodyClaimID === candidate.titleClaimID) throw invalid("body_claim_is_title");
    if (!claimIDs.has(bodyClaimID)) throw invalid("body_claim_id");
  }
  validateIDList(candidate.supportEvidenceIDs, 2, 12);
  if (!Array.isArray(candidate.counterSearch) || candidate.counterSearch.length > 3) {
    throw invalid("counter_search_count");
  }
  for (const search of candidate.counterSearch) validateCounterSearch(search);
  if (!SENSITIVITY.has(candidate.sensitivity)) throw invalid("sensitivity");
  if (!Array.isArray(candidate.comparisonPeriods) || candidate.comparisonPeriods.length > 2) {
    throw invalid("comparison_periods_count");
  }
  for (const period of candidate.comparisonPeriods) validateTimeRange(period);

  // allOf 条件约束
  if (candidate.type === "change_over_time") {
    if (candidate.scopeKind !== "compared_periods") throw invalid("scope_kind_for_change");
    if (candidate.comparisonPeriods.length !== 2) throw invalid("comparison_periods_for_change");
  } else if (candidate.comparisonPeriods.length !== 0) {
    throw invalid("comparison_periods_for_non_change");
  }
  if (candidate.type === "two_episodes" && candidate.scopeKind !== "two_episodes") throw invalid("scope_kind_for_two_episodes");
  if (candidate.type === "bounded_pattern" && candidate.scopeKind !== "bounded_events") throw invalid("scope_kind_for_pattern");
}

function validateClaim(claim) {
  if (!claim || typeof claim !== "object" || Array.isArray(claim)) throw invalid("claim_not_object");
  requireExactKeys(claim, ["claimID", "kind", "text", "citations", "metricIDs"], "claim");
  if (!isID(claim.claimID)) throw invalid("claimID");
  if (!CLAIM_KINDS.has(claim.kind)) throw invalid("claim_kind");
  if (typeof claim.text !== "string" || claim.text.length < 2 || claim.text.length > 180) throw invalid("claim_text");
  if (!Array.isArray(claim.citations) || claim.citations.length < 1 || claim.citations.length > 6) {
    throw invalid("citations_count");
  }
  for (const citation of claim.citations) validateCitation(citation);
  validateIDList(claim.metricIDs, 0, 24);
}

function validateCitation(citation) {
  if (!citation || typeof citation !== "object" || Array.isArray(citation)) throw invalid("citation_not_object");
  requireExactKeys(citation, ["evidenceID", "quote"], "citation");
  if (!isID(citation.evidenceID)) throw invalid("evidenceID");
  if (typeof citation.quote !== "string" || citation.quote.length < 2 || citation.quote.length > 400) {
    throw invalid("quote");
  }
}

function validateCounterSearch(search) {
  if (!search || typeof search !== "object" || Array.isArray(search)) throw invalid("counter_search_not_object");
  requireExactKeys(search, ["domains", "anchorRefs", "keywords"], "counterSearch");
  if (!Array.isArray(search.domains) || search.domains.length < 1 || search.domains.length > 3) {
    throw invalid("counter_search_domains");
  }
  if (new Set(search.domains).size !== search.domains.length) throw invalid("counter_search_domains");
  for (const domain of search.domains) {
    if (!DOMAINS.has(domain)) throw invalid("counter_search_domain");
  }
  validateIDList(search.anchorRefs, 0, 24);
  if (!Array.isArray(search.keywords) || search.keywords.length > 4) throw invalid("counter_search_keywords");
  for (const keyword of search.keywords) {
    if (typeof keyword !== "string" || keyword.length < 1 || keyword.length > 24) throw invalid("keyword");
  }
}

function validateVerificationEnvelope(envelope) {
  if (!Array.isArray(envelope.candidateResults) || envelope.candidateResults.length < 1
    || envelope.candidateResults.length > 3) {
    throw invalid("candidate_results_count");
  }
  const candidateIDs = new Set();
  for (const result of envelope.candidateResults) {
    if (!result || typeof result !== "object" || Array.isArray(result)) throw invalid("candidate_result_not_object");
    requireExactKeys(result, ["candidateID", "verdict", "claimResults", "reasonCodes"], "candidateResult");
    if (!isID(result.candidateID)) throw invalid("candidateID");
    if (candidateIDs.has(result.candidateID)) throw invalid("duplicate_candidate_result");
    candidateIDs.add(result.candidateID);
    if (!CANDIDATE_VERDICTS.has(result.verdict)) throw invalid("candidate_verdict");
    if (!Array.isArray(result.claimResults) || result.claimResults.length < 2 || result.claimResults.length > 4) {
      throw invalid("claim_results_count");
    }
    const claimIDs = new Set();
    for (const claimResult of result.claimResults) {
      validateClaimResult(claimResult);
      if (claimIDs.has(claimResult.claimID)) throw invalid("duplicate_claim_result");
      claimIDs.add(claimResult.claimID);
    }
    validateReasonCodes(result.reasonCodes);
    // allOf：accept ⇒ 所有 claimResult.verdict 都是 supported
    if (result.verdict === "accept") {
      for (const claimResult of result.claimResults) {
        if (claimResult.verdict !== "supported") throw invalid("accept_with_unsupported_claim");
      }
    }
  }
}

function validateClaimResult(claimResult) {
  requireExactKeys(claimResult, ["claimID", "verdict", "reasonCodes", "supportEvidenceIDs", "counterEvidenceIDs"], "claimResult");
  if (!isID(claimResult.claimID)) throw invalid("claimID");
  if (!VERDICTS.has(claimResult.verdict)) throw invalid("verdict");
  validateReasonCodes(claimResult.reasonCodes);
  validateIDList(claimResult.supportEvidenceIDs, 0, 24);
  validateIDList(claimResult.counterEvidenceIDs, 0, 24);
  // allOf：supported ⇒ supportEvidenceIDs ≥ 1
  if (claimResult.verdict === "supported" && claimResult.supportEvidenceIDs.length < 1) {
    throw invalid("supported_without_evidence");
  }
}

function validateReasonCodes(codes) {
  if (!Array.isArray(codes) || codes.length > 8) throw invalid("reason_codes");
  if (new Set(codes).size !== codes.length) throw invalid("reason_codes");
  for (const code of codes) {
    if (!REASON_CODES.has(code)) throw invalid(`reason_code:${code}`);
  }
}

function validateTimeRange(range) {
  if (!range || typeof range !== "object" || Array.isArray(range)) throw invalid("time_range");
  requireExactKeys(range, ["start", "end"], "timeRange");
  for (const key of ["start", "end"]) {
    const value = range[key];
    if (value === null) continue;
    if (typeof value !== "string" || Number.isNaN(Date.parse(value))) throw invalid("time_range_value");
  }
}

function validateIDList(list, min, max) {
  if (!Array.isArray(list) || list.length < min || list.length > max) throw invalid("id_list");
  if (new Set(list).size !== list.length) throw invalid("id_list");
  for (const item of list) {
    if (!isID(item)) throw invalid("id_list_item");
  }
}

function requireExactKeys(object, keys, label) {
  for (const key of keys) {
    if (!Object.hasOwn(object, key)) throw invalid(`${label}_missing:${key}`);
  }
  const allowed = new Set(keys);
  for (const key of Object.keys(object)) {
    if (!allowed.has(key)) throw invalid(`${label}_extra:${key}`);
  }
}

function isID(value) {
  return typeof value === "string" && value.length >= 1 && value.length <= ID_MAX && ID_PATTERN.test(value);
}

/** 上游可能包裹 ```json 围栏或前后杂文本：截取首个 { 到末个 } 之间内容再解析 */
function extractJsonPayload(rawText) {
  const text = String(rawText ?? "");
  const start = text.indexOf("{");
  const end = text.lastIndexOf("}");
  if (start === -1 || end <= start) return text;
  return text.slice(start, end + 1);
}

function invalid(reason, rawContent = null) {
  // rawTail：仅用于服务端容器日志定位模型格式失误（2026-11-01 真实材料调优），
  // 不进 HTTP 响应正文的关键字段。
  const rawTail = typeof rawContent === "string" ? rawContent.slice(-300) : null;
  return new GatewayError("DISCOVERY_MODEL_OUTPUT_INVALID", "Model output failed contract validation", 502, { reason, ...(rawTail ? { rawTail } : {}) });
}
