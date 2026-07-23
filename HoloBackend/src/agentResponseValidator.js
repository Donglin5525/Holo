// Agent Loop 响应契约：服务端返回 200 前，必须保证内容可被 iOS 的 Codable 模型解码。
// 生产仅修复明确白名单内的结构漂移，并返回非敏感 repair 标签；无法安全修复时返回 invalid。

const AGENT_STATUSES = new Set(["need_tools", "need_more_analysis", "final_claims"]);
const FILTER_OPERATIONS = new Set([
  "equal", "notEqual", "greaterThan", "greaterThanOrEqual",
  "lessThan", "lessThanOrEqual", "contains", "oneOf",
]);
const FIELD_TYPES = new Set(["number", "text", "date", "boolean"]);
const GROUP_TYPES = new Set(["day", "week", "month", "weekend", "field"]);
const AGGREGATION_OPERATIONS = new Set(["count", "sum", "average", "min", "max", "distinctCount"]);
const DERIVATION_OPERATIONS = new Set([
  "difference", "ratio", "percentageChange", "rate", "perDay", "linearTrend", "coverage",
]);
const SORT_DIRECTIONS = new Set(["ascending", "descending"]);
const CROSS_DOMAIN_OPERATIONS = new Set(["correlation", "conditionalAverage", "groupComparison"]);

const ENUM_ALIASES = new Map([
  ["not_equal", "notEqual"],
  ["greater_than", "greaterThan"],
  ["greater_than_or_equal", "greaterThanOrEqual"],
  ["less_than", "lessThan"],
  ["less_than_or_equal", "lessThanOrEqual"],
  ["one_of", "oneOf"],
  ["distinct_count", "distinctCount"],
  ["percentage_change", "percentageChange"],
  ["per_day", "perDay"],
  ["linear_trend", "linearTrend"],
  ["asc", "ascending"],
  ["desc", "descending"],
  ["conditional_average", "conditionalAverage"],
  ["group_comparison", "groupComparison"],
]);

/**
 * 校验并规范化 agent_loop 响应内容。
 * @param {string} content - LLM 返回的原始文本
 * @returns {{ valid: boolean, error?: string, parsed?: any, content?: string, repairs?: string[] }}
 */
export function validateAgentLoopContent(content) {
  const cleaned = extractJSONObject(String(content));
  let parsed;
  try {
    parsed = JSON.parse(cleaned);
  } catch (error) {
    return { valid: false, error: `Invalid JSON: ${error.message}` };
  }

  if (!isObject(parsed)) {
    return { valid: false, error: "Invalid or missing JSON object" };
  }
  if (!AGENT_STATUSES.has(parsed.status)) {
    return { valid: false, error: "Invalid or missing status" };
  }

  const repairs = [];
  parsed.toolRequests ??= [];
  parsed.claims ??= [];
  parsed.warnings ??= [];
  if (typeof parsed.reasoning !== "string") {
    parsed.reasoning = "";
    repairs.push("reasoning_defaulted");
  }

  if (!Array.isArray(parsed.toolRequests)) {
    return { valid: false, error: "toolRequests must be an array" };
  }
  if (!Array.isArray(parsed.claims)) {
    return { valid: false, error: "claims must be an array" };
  }
  if (parsed.status === "need_tools" && parsed.toolRequests.length === 0) {
    return { valid: false, error: "need_tools requires at least one tool request" };
  }

  for (const [index, request] of parsed.toolRequests.entries()) {
    const error = normalizeToolRequest(request, index, repairs);
    if (error) return { valid: false, error };
  }

  for (const [index, claim] of parsed.claims.entries()) {
    const error = normalizeClaim(claim, index, parsed.status, repairs);
    if (error) return { valid: false, error };
  }

  if (!Array.isArray(parsed.warnings)) {
    return { valid: false, error: "warnings must be an array" };
  }
  parsed.warnings = parsed.warnings.filter((warning) => typeof warning === "string");

  return {
    valid: true,
    parsed,
    content: JSON.stringify(parsed),
    repairs: [...new Set(repairs)],
  };
}

function normalizeToolRequest(request, index, repairs) {
  if (!isObject(request)) return `toolRequests[${index}] must be an object`;
  for (const key of ["id", "tool", "query"]) {
    if (typeof request[key] !== "string" || request[key].length === 0) {
      return `toolRequests[${index}].${key} must be a non-empty string`;
    }
  }

  if (!isObject(request.parameters)) {
    request.parameters = {};
    repairs.push("parameters_defaulted");
  }
  for (const planKey of ["dynamicPlan", "crossDomainPlan"]) {
    if (request[planKey] == null && isObject(request.parameters[planKey])) {
      request[planKey] = request.parameters[planKey];
      delete request.parameters[planKey];
      repairs.push(`${planKey}_promoted_from_parameters`);
    }
  }
  request.parameters = Object.fromEntries(
    Object.entries(request.parameters)
      .filter(([key]) => key !== "dynamicPlan" && key !== "crossDomainPlan")
      .map(([key, value]) => [key, stringParameter(value)])
      .filter(([, value]) => value != null),
  );
  request.requiredMetrics = normalizeStringArray(request.requiredMetrics);
  request.timeRange = normalizeTimeRange(request.timeRange);
  request.baseline = normalizeTimeRange(request.baseline);

  if (request.dynamicPlan != null) {
    const error = normalizeDynamicPlan(request.dynamicPlan, `toolRequests[${index}].dynamicPlan`);
    if (error) return error;
  }
  if (request.crossDomainPlan != null) {
    const error = normalizeCrossDomainPlan(
      request.crossDomainPlan,
      `toolRequests[${index}].crossDomainPlan`,
    );
    if (error) return error;
  }
  if (request.query === "dynamic_query" && request.dynamicPlan == null) {
    return `toolRequests[${index}] dynamic_query requires sibling dynamicPlan`;
  }
  if (request.tool === "cross_domain" && request.query === "aligned_analysis"
      && request.crossDomainPlan == null) {
    return `toolRequests[${index}] aligned_analysis requires sibling crossDomainPlan`;
  }
  return null;
}

function normalizeDynamicPlan(plan, path) {
  if (!isObject(plan)) return `${path} must be an object`;
  if (typeof plan.source !== "string" || plan.source.length === 0) {
    return `${path}.source must be a non-empty string`;
  }
  if (!Array.isArray(plan.aggregations) || plan.aggregations.length === 0) {
    return `${path}.aggregations must be a non-empty array`;
  }

  plan.timeRange = normalizeTimeRange(plan.timeRange);
  plan.baseline = normalizeTimeRange(plan.baseline);
  plan.filters ??= [];
  plan.groupBy ??= [];
  plan.derivations ??= [];
  plan.sort ??= null;
  plan.limit = positiveInteger(plan.limit, 20);
  plan.evidenceLimit = positiveInteger(plan.evidenceLimit, 20);

  if (!Array.isArray(plan.filters)) return `${path}.filters must be an array`;
  if (!Array.isArray(plan.groupBy)) return `${path}.groupBy must be an array`;
  if (!Array.isArray(plan.derivations)) return `${path}.derivations must be an array`;

  for (const [index, filter] of plan.filters.entries()) {
    const error = normalizeFilter(filter, `${path}.filters[${index}]`);
    if (error) return error;
  }
  plan.groupBy = plan.groupBy.map((group) => {
    if (typeof group === "string") return { type: group, field: null };
    return group;
  });
  for (const [index, group] of plan.groupBy.entries()) {
    if (!isObject(group) || !GROUP_TYPES.has(group.type)) {
      return `${path}.groupBy[${index}] has invalid type`;
    }
    group.field ??= null;
    if (group.type === "field" && typeof group.field !== "string") {
      return `${path}.groupBy[${index}].field is required`;
    }
  }
  for (const [index, aggregation] of plan.aggregations.entries()) {
    if (!isObject(aggregation) || typeof aggregation.id !== "string") {
      return `${path}.aggregations[${index}] is invalid`;
    }
    aggregation.operation = canonicalEnum(aggregation.operation);
    if (!AGGREGATION_OPERATIONS.has(aggregation.operation)) {
      return `${path}.aggregations[${index}].operation is invalid`;
    }
    aggregation.field ??= null;
    aggregation.unit ??= null;
    aggregation.filters ??= [];
    if (!Array.isArray(aggregation.filters)) {
      return `${path}.aggregations[${index}].filters must be an array`;
    }
    for (const [filterIndex, filter] of aggregation.filters.entries()) {
      const error = normalizeFilter(
        filter,
        `${path}.aggregations[${index}].filters[${filterIndex}]`,
      );
      if (error) return error;
    }
  }
  for (const [index, derivation] of plan.derivations.entries()) {
    if (!isObject(derivation)
        || typeof derivation.id !== "string"
        || typeof derivation.metricID !== "string") {
      return `${path}.derivations[${index}] is invalid`;
    }
    derivation.operation = canonicalEnum(derivation.operation);
    if (!DERIVATION_OPERATIONS.has(derivation.operation)) {
      return `${path}.derivations[${index}].operation is invalid`;
    }
    derivation.denominatorMetricID ??= null;
    derivation.unit ??= null;
  }
  if (plan.sort != null) {
    if (!isObject(plan.sort) || typeof plan.sort.metricID !== "string") {
      return `${path}.sort is invalid`;
    }
    plan.sort.direction = canonicalEnum(plan.sort.direction);
    if (!SORT_DIRECTIONS.has(plan.sort.direction)) {
      return `${path}.sort.direction is invalid`;
    }
  }
  return null;
}

function normalizeCrossDomainPlan(plan, path) {
  if (!isObject(plan)) return `${path} must be an object`;
  for (const key of ["leftSource", "leftField", "rightSource", "rightField"]) {
    if (typeof plan[key] !== "string" || plan[key].length === 0) {
      return `${path}.${key} must be a non-empty string`;
    }
  }
  plan.operation = canonicalEnum(plan.operation);
  if (!CROSS_DOMAIN_OPERATIONS.has(plan.operation)) {
    return `${path}.operation is invalid`;
  }
  plan.leftFilters ??= [];
  plan.rightFilters ??= [];
  plan.threshold = finiteNumber(plan.threshold);
  plan.minimumAlignedDays = positiveInteger(plan.minimumAlignedDays, 5);
  plan.timeRange = normalizeTimeRange(plan.timeRange);
  for (const side of ["leftFilters", "rightFilters"]) {
    if (!Array.isArray(plan[side])) return `${path}.${side} must be an array`;
    for (const [index, filter] of plan[side].entries()) {
      const error = normalizeFilter(filter, `${path}.${side}[${index}]`);
      if (error) return error;
    }
  }
  return null;
}

function normalizeFilter(filter, path) {
  if (!isObject(filter) || typeof filter.field !== "string") {
    return `${path} must contain field`;
  }
  filter.operation = canonicalEnum(filter.operation);
  if (!FILTER_OPERATIONS.has(filter.operation)) {
    return `${path}.operation is invalid`;
  }
  if (!isQueryValue(filter.value)) return `${path}.value is invalid`;
  filter.values ??= [];
  if (!Array.isArray(filter.values) || !filter.values.every(isQueryValue)) {
    return `${path}.values is invalid`;
  }
  return null;
}

function isQueryValue(value) {
  if (!isObject(value) || !FIELD_TYPES.has(value.type)) return false;
  switch (value.type) {
  case "number": return Number.isFinite(Number(value.number));
  case "text": return typeof value.text === "string";
  case "date": return typeof value.date === "number";
  case "boolean": return typeof value.boolean === "boolean";
  default: return false;
  }
}

function normalizeClaim(claim, index, status, repairs) {
  if (!isObject(claim)) return `claims[${index}] must be an object`;
  if (typeof claim.displayText !== "string" || claim.displayText.length === 0) {
    claim.displayText = typeof claim.text === "string" ? claim.text : "";
  }
  if (status === "final_claims" && claim.displayText.length === 0) {
    return `claims[${index}] requires displayText`;
  }
  claim.id ||= `claim-${index + 1}`;
  claim.type ||= "observation";
  claim.metricAssertions ??= [];
  claim.evidenceIDs = normalizeStringArray(claim.evidenceIDs ?? claim.evidenceIds);
  claim.prohibitedInferences = normalizeStringArray(claim.prohibitedInferences);
  claim.confidence = finiteNumber(claim.confidence) ?? 0.5;
  if (!Array.isArray(claim.metricAssertions)) {
    return `claims[${index}].metricAssertions must be an array`;
  }
  for (const [assertionIndex, assertion] of claim.metricAssertions.entries()) {
    if (!isObject(assertion) || typeof assertion.metricKey !== "string") {
      return `claims[${index}].metricAssertions[${assertionIndex}] is invalid`;
    }
    assertion.evidenceIDs = normalizeStringArray(assertion.evidenceIDs ?? assertion.evidenceIds);
    assertion.value = finiteNumber(assertion.value);
    assertion.baselineValue = finiteNumber(assertion.baselineValue);
    assertion.unit = optionalString(assertion.unit);
    assertion.comparison = optionalString(assertion.comparison);
  }
  if (claim.evidenceIds != null) repairs.push("claim_evidenceIds_normalized");
  return null;
}

function normalizeTimeRange(value) {
  if (!isObject(value)
      || typeof value.label !== "string"
      || typeof value.start !== "number"
      || typeof value.end !== "number") {
    return null;
  }
  return {
    label: value.label,
    start: value.start,
    end: value.end,
  };
}

function normalizeStringArray(value) {
  if (typeof value === "string") return [value];
  if (!Array.isArray(value)) return [];
  return value.filter((item) => typeof item === "string");
}

function stringParameter(value) {
  if (typeof value === "string") return value;
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (value == null) return null;
  try {
    return JSON.stringify(value);
  } catch {
    return null;
  }
}

function canonicalEnum(value) {
  return ENUM_ALIASES.get(value) ?? value;
}

function finiteNumber(value) {
  if (value == null || value === "") return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function positiveInteger(value, fallback) {
  const number = Number(value);
  return Number.isInteger(number) && number > 0 ? number : fallback;
}

function optionalString(value) {
  return typeof value === "string" ? value : null;
}

function isObject(value) {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

function extractJSONObject(content) {
  const cleaned = content
    .replace(/```json/gi, "")
    .replace(/```/g, "")
    .trim();

  const firstBrace = cleaned.indexOf("{");
  if (firstBrace < 0) return cleaned;

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
    if (inString) continue;
    if (char === "{") {
      depth += 1;
    } else if (char === "}") {
      depth -= 1;
      if (depth === 0) return cleaned.slice(firstBrace, index + 1).trim();
    }
  }
  return cleaned;
}
