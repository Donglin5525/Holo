// Agent Loop 响应校验：确保 LLM 返回的 agent_loop 内容是合法 JSON，
// 且 status / toolRequests / claims 结构符合协议。校验失败由 app.js 转 502。

const AGENT_STATUSES = new Set(["need_tools", "need_more_analysis", "final_claims"]);

/**
 * 校验 agent_loop 响应内容。
 * @param {string} content - LLM 返回的原始文本
 * @returns {{ valid: boolean, error?: string, parsed?: any }}
 */
export function validateAgentLoopContent(content) {
  let parsed;
  try {
    parsed = JSON.parse(content);
  } catch (error) {
    return { valid: false, error: `Invalid JSON: ${error.message}` };
  }

  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    return { valid: false, error: "Invalid or missing JSON object" };
  }

  if (!AGENT_STATUSES.has(parsed.status)) {
    return { valid: false, error: "Invalid or missing status" };
  }

  if (parsed.status === "need_tools" && !Array.isArray(parsed.toolRequests)) {
    return { valid: false, error: "need_tools requires toolRequests array" };
  }

  if (parsed.status === "final_claims" && !Array.isArray(parsed.claims)) {
    return { valid: false, error: "final_claims requires claims array" };
  }

  return { valid: true, parsed };
}
