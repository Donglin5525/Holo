// Agent Loop 响应校验：确保 LLM 返回的 agent_loop 内容是合法 JSON，
// 且 status / toolRequests / claims 结构符合协议。校验失败由 app.js 转 502。

const AGENT_STATUSES = new Set(["need_tools", "need_more_analysis", "final_claims"]);
const CLAIM_TYPES = new Set(["observation", "change", "pattern", "correlation", "suggestion"]);

/**
 * 校验 agent_loop 响应内容。
 * @param {string} content - LLM 返回的原始文本
 * @returns {{ valid: boolean, error?: string, parsed?: any }}
 */
export function validateAgentLoopContent(content) {
  const cleaned = extractJSONObject(String(content));
  let parsed;
  try {
    parsed = JSON.parse(cleaned);
  } catch (error) {
    return { valid: false, error: `Invalid JSON: ${error.message}` };
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { valid: false, error: "Invalid or missing JSON object" };
  }

  if (!AGENT_STATUSES.has(parsed.status)) {
    return { valid: false, error: "Invalid or missing status" };
  }

  if (typeof parsed.reasoning !== "string") return invalid("reasoning must be a string");

  if (parsed.status === "need_tools" && !Array.isArray(parsed.toolRequests)) {
    return { valid: false, error: "need_tools requires toolRequests array" };
  }

  if (parsed.status === "final_claims" && !Array.isArray(parsed.claims)) {
    return { valid: false, error: "final_claims requires claims array" };
  }

  if (!Array.isArray(parsed.toolRequests)) {
    return { valid: false, error: "toolRequests must be an array" };
  }

  if (!Array.isArray(parsed.claims)) {
    return { valid: false, error: "claims must be an array" };
  }

  if (!Array.isArray(parsed.warnings) || !parsed.warnings.every(isString)) {
    return invalid("warnings must be a string array");
  }

  if (parsed.status === "need_tools" && parsed.toolRequests.length === 0) {
    return invalid("need_tools requires at least one toolRequest");
  }
  if (parsed.status === "final_claims" && parsed.toolRequests.length > 0) {
    return invalid("final_claims requires empty toolRequests");
  }
  if (parsed.status === "need_more_analysis" && (parsed.toolRequests.length > 0 || parsed.claims.length > 0)) {
    return invalid("need_more_analysis cannot include toolRequests or claims");
  }

  for (const request of parsed.toolRequests) {
    if (!isPlainObject(request)) return invalid("toolRequest must be an object");
    if (!isNonEmptyString(request.id) || !isNonEmptyString(request.tool) || !isNonEmptyString(request.query)) {
      return invalid("toolRequest requires non-empty id, tool, and query");
    }
    if (!isPlainObject(request.parameters)) return invalid("toolRequest parameters must be an object");
  }

  for (const [index, claim] of parsed.claims.entries()) {
    if (!isPlainObject(claim)) {
      return { valid: false, error: "claim must be an object" };
    }
    if (typeof claim.displayText !== "string" || claim.displayText.length === 0) {
      claim.displayText = typeof claim.text === "string" ? claim.text : "";
    }
    if (parsed.status === "final_claims" && claim.displayText.length === 0) {
      return { valid: false, error: "final_claims claim requires displayText" };
    }
    if (!isNonEmptyString(claim.id)) return invalid(`claim[${index}] requires id`);
    if (!CLAIM_TYPES.has(claim.type)) return invalid(`claim[${index}] type is invalid`);
    if (!Array.isArray(claim.metricAssertions) || claim.metricAssertions.length === 0) {
      return invalid(`claim[${index}] requires metricAssertions`);
    }
    if (!Array.isArray(claim.evidenceIDs) && Array.isArray(claim.evidenceIds)) {
      claim.evidenceIDs = claim.evidenceIds;
    }
    if (!isNonEmptyStringArray(claim.evidenceIDs)) return invalid(`claim[${index}] requires evidenceIDs`);
    if (!Array.isArray(claim.prohibitedInferences) || !claim.prohibitedInferences.every(isString)) {
      return invalid(`claim[${index}] prohibitedInferences must be a string array`);
    }
    if (!Number.isFinite(claim.confidence) || claim.confidence < 0 || claim.confidence > 1) {
      return invalid(`claim[${index}] confidence must be between 0 and 1`);
    }

    for (const [assertionIndex, assertion] of claim.metricAssertions.entries()) {
      if (!isPlainObject(assertion) || !isNonEmptyString(assertion.metricKey)) {
        return invalid(`claim[${index}].metricAssertions[${assertionIndex}] requires metricKey`);
      }
      if (assertion && typeof assertion === "object" && !Array.isArray(assertion.evidenceIDs) && Array.isArray(assertion.evidenceIds)) {
        assertion.evidenceIDs = assertion.evidenceIds;
      }
      if (!isNonEmptyStringArray(assertion.evidenceIDs)) {
        return invalid(`claim[${index}].metricAssertions[${assertionIndex}] requires evidenceIDs`);
      }
      for (const key of ["value", "baselineValue"]) {
        if (assertion[key] != null && !Number.isFinite(assertion[key])) {
          return invalid(`claim[${index}].metricAssertions[${assertionIndex}].${key} must be finite`);
        }
      }
      for (const key of ["unit", "comparison"]) {
        if (assertion[key] != null && typeof assertion[key] !== "string") {
          return invalid(`claim[${index}].metricAssertions[${assertionIndex}].${key} must be a string`);
        }
      }
    }
  }

  return { valid: true, parsed, content: JSON.stringify(parsed) };
}

function invalid(error) {
  return { valid: false, error };
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

function isString(value) {
  return typeof value === "string";
}

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

function isNonEmptyStringArray(value) {
  return Array.isArray(value) && value.length > 0 && value.every(isNonEmptyString);
}

function extractJSONObject(content) {
  const cleaned = content
    .replace(/```json/gi, "")
    .replace(/```/g, "")
    .trim();

  const firstBrace = cleaned.indexOf("{");
  if (firstBrace < 0) {
    return cleaned;
  }

  let depth = 0;
  let inString = false;
  let escaped = false;

  for (let index = firstBrace; index < cleaned.length; index += 1) {
    const char = cleaned[index];

    if (escaped) {
      escaped = false;
      continue;
    }
    if (char === "\\") {
      escaped = true;
      continue;
    }
    if (char === "\"") {
      inString = !inString;
      continue;
    }
    if (inString) {
      continue;
    }
    if (char === "{") {
      depth += 1;
    } else if (char === "}") {
      depth -= 1;
      if (depth === 0) {
        return cleaned.slice(firstBrace, index + 1).trim();
      }
    }
  }

  return cleaned;
}
