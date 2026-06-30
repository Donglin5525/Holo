// Agent Loop 响应校验：确保 LLM 返回的 agent_loop 内容是合法 JSON，
// 且 status / toolRequests / claims 结构符合协议。校验失败由 app.js 转 502。

const AGENT_STATUSES = new Set(["need_tools", "need_more_analysis", "final_claims"]);

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

  if (parsed.toolRequests == null) {
    parsed.toolRequests = [];
  }
  if (parsed.claims == null) {
    parsed.claims = [];
  }
  if (parsed.warnings == null) {
    parsed.warnings = [];
  }
  if (typeof parsed.reasoning !== "string") {
    parsed.reasoning = "";
  }

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

  for (const [index, claim] of parsed.claims.entries()) {
    if (!claim || typeof claim !== "object" || Array.isArray(claim)) {
      return { valid: false, error: "claim must be an object" };
    }
    if (typeof claim.displayText !== "string" || claim.displayText.length === 0) {
      claim.displayText = typeof claim.text === "string" ? claim.text : "";
    }
    if (parsed.status === "final_claims" && claim.displayText.length === 0) {
      return { valid: false, error: "final_claims claim requires displayText" };
    }
    if (!claim.id) {
      claim.id = `claim-${index + 1}`;
    }
    if (!claim.type) {
      claim.type = "observation";
    }
    if (!Array.isArray(claim.metricAssertions)) {
      claim.metricAssertions = [];
    }
    if (!Array.isArray(claim.evidenceIDs) && Array.isArray(claim.evidenceIds)) {
      claim.evidenceIDs = claim.evidenceIds;
    }
    if (!Array.isArray(claim.evidenceIDs)) {
      claim.evidenceIDs = [];
    }
    if (!Array.isArray(claim.prohibitedInferences)) {
      claim.prohibitedInferences = [];
    }
    if (typeof claim.confidence !== "number") {
      claim.confidence = 0.5;
    }

    for (const assertion of claim.metricAssertions) {
      if (assertion && typeof assertion === "object" && !Array.isArray(assertion.evidenceIDs) && Array.isArray(assertion.evidenceIds)) {
        assertion.evidenceIDs = assertion.evidenceIds;
      }
      if (assertion && typeof assertion === "object" && !Array.isArray(assertion.evidenceIDs)) {
        assertion.evidenceIDs = [];
      }
    }
  }

  return { valid: true, parsed, content: JSON.stringify(parsed) };
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
