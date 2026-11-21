import { GatewayError } from "../errors.js";

/**
 * 「一个发现」v4 洞察质量闸门（2026-11-20 方案 02-B3，纯函数、零 app 依赖、可单测）。
 *
 * 双端契约真源（与 iOS Services/AI/Discovery/V4/DiscoveryInsightContract.swift 对齐）：
 * - 输入 InsightInputPacket（总纲 §5.1）：去标识化画像 + 特征 + 用户意图；
 * - 输出 InsightDraft（总纲 §5.2）：headline/insight 无数字，evidence 模板带 {slot}。
 *
 * 闸门六检查（顺序固定）：schema/长度 → 数字禁令 → 引用合法性 → 复述启发式
 * → 角度去重 → 安全词表。失败先轻量修复（去多余字段/截断超长）再重校验，
 * 两次失败由调用方返回 gate_rejected（HTTP 200，不 5xx——沿用 v3 口径）。
 */

// 数字纪律：裸字符集（阿拉伯/全角/中文数字，含「两」「半」数量词）+ 复合模式「几分之」。
// 注意不含裸「之/几/分」——v3 字符集把它们并入单字符类，导致「之前/几乎/部分」整句误杀
// （2026-11-20 实测「入睡时间比之前更晚」误报）；v4 判断句高频用「比之前」，必须拆开。
// iOS 侧同口径见 InsightNumberDiscipline，测试样例双端共用。
export const CN_NUMERAL_RE = /[0-9０-９零一二两三四五六七八九十百千万亿半]/;
export const CN_NUMERAL_PHRASE_RE = /几分之/;

export function containsNumerals(text) {
  return CN_NUMERAL_RE.test(text) || CN_NUMERAL_PHRASE_RE.test(text);
}
export const TEMPLATE_SLOT_RE = /\{([a-zA-Z_][a-zA-Z0-9_]*)\}/g;
const SLOT_NAME_RE = /^[a-zA-Z_][a-zA-Z0-9_]{0,23}$/;

// 长度红线（总纲 §5.2；iOS 端侧终检同值）。
export const INSIGHT_LIMITS = Object.freeze({
  headline: 18,
  insight: 90,
  evidenceTemplate: 40,
  prompt: 30,
  evidenceMin: 1,
  evidenceMax: 3,
  criteriaMin: 2,
});

// 数量上限（总纲 §5.1；端侧 CandidateBuilder 同值截断）。
export const PACKET_LIMITS = Object.freeze({
  portrait: 12,
  features: 30,
  userIntents: 10,
});

const DIMENSION_ENUM = new Set(["crossDomainInsight", "recentState", "longTermPattern", "preference", "identity"]);
const CONFIDENCE_ENUM = new Set(["confirmed", "inferred"]);
const FEATURE_DOMAIN_ENUM = new Set(["finance", "health", "habit", "thought", "task", "goal", "profile"]);
const FEATURE_DIRECTION_ENUM = new Set(["up", "down", "stable", "divergent"]);
const INTENT_SOURCE_ENUM = new Set(["goal", "habit", "thought"]);
const MODEL_NONE_REASON_ENUM = new Set(["none_worthwhile", "insufficient_data"]);
const CRITERIA_ENUM = new Set(["D1", "D2", "D3", "D4"]);

// 安全词表：从 iOS PortraitSafetyGate.bannedPatterns 移植最小集（02-B3 第 6 条；
// 核实记录：后端原本无画像安全词表，portrait_synthesis 的安全底线在端侧）。
const SAFETY_PATTERNS = [
  { pattern: /抑郁症|焦虑症|确诊|诊断为|建议就医|患者/, label: "医疗化断言" },
  { pattern: /懒惰|自律差|缺乏毅力|拖延症|社恐|孤僻|上瘾|成瘾|自制力差/, label: "道德或人格贬损" },
];

// 复述启发式（B3 第 4 条，规则启发式不追求完美）：
// insight 出现方向词、且无任何因果/对照连接词、且 criteria < 2 → 判纯复述。
const DIRECTION_WORDS = ["涨", "跌", "增加", "减少", "变多", "变少", "更多", "更少", "高于", "低于", "上升", "下降", "频繁"];
const CAUSAL_CONTRAST_WORDS = ["可能", "也许", "像是", "似乎", "因为", "由于", "相比", "同期", "同时", "跟着", "顺带", "反而", "却", "而", "但", "每当"];

function isNonEmptyString(value, max) {
  return typeof value === "string" && value.length > 0 && (max === undefined || value.length <= max);
}

/**
 * 输入包校验（ingress 闸）：字段、枚举、数量上限。非法直接 400。
 * 返回归一化 packet（只保留白名单字段）。
 */
export function validateInsightPacket(raw) {
  if (!raw || typeof raw !== "object") {
    throw new GatewayError("INVALID_REQUEST", "insight packet must be an object", 400);
  }
  const { schemaVersion, kind, requestId, window, portrait, features, userIntents, recentTopics, rejectedAngles } = raw;
  if (schemaVersion !== 1) {
    throw new GatewayError("INVALID_REQUEST", "insight packet schemaVersion must be 1", 400);
  }
  if (kind !== undefined && kind !== "insightInput") {
    throw new GatewayError("INVALID_REQUEST", "insight packet kind invalid", 400);
  }
  if (!isNonEmptyString(requestId, 64) || !/^[A-Za-z0-9-]+$/.test(requestId)) {
    throw new GatewayError("INVALID_REQUEST", "insight packet requestId invalid", 400);
  }
  if (!window || typeof window !== "object" || !Number.isInteger(window.days) || window.days < 7 || window.days > 90) {
    throw new GatewayError("INVALID_REQUEST", "insight packet window.days invalid", 400);
  }

  const checkArray = (value, limit, name) => {
    if (!Array.isArray(value)) throw new GatewayError("INVALID_REQUEST", `insight packet ${name} must be an array`, 400);
    if (value.length > limit) throw new GatewayError("INVALID_REQUEST", `insight packet ${name} exceeds ${limit}`, 400);
    return value;
  };

  const normalizedPortrait = checkArray(portrait, PACKET_LIMITS.portrait, "portrait").map((p) => {
    if (!p || typeof p !== "object") throw new GatewayError("INVALID_REQUEST", "portrait item invalid", 400);
    if (!isNonEmptyString(p.id, 64) || !isNonEmptyString(p.statement, 120)) {
      throw new GatewayError("INVALID_REQUEST", "portrait item id/statement invalid", 400);
    }
    if (!DIMENSION_ENUM.has(p.dimension) || !CONFIDENCE_ENUM.has(p.confidence)) {
      throw new GatewayError("INVALID_REQUEST", `portrait item enum invalid: ${p.id}`, 400);
    }
    return {
      id: p.id,
      dimension: p.dimension,
      confidence: p.confidence,
      statement: p.statement,
      evidenceSummary: typeof p.evidenceSummary === "string" ? p.evidenceSummary.slice(0, 120) : "",
      sourceDomains: Array.isArray(p.sourceDomains) ? p.sourceDomains.slice(0, 7) : [],
    };
  });

  const normalizedFeatures = checkArray(features, PACKET_LIMITS.features, "features").map((f) => {
    if (!f || typeof f !== "object") throw new GatewayError("INVALID_REQUEST", "feature item invalid", 400);
    if (!isNonEmptyString(f.id, 64) || !isNonEmptyString(f.description, 160)) {
      throw new GatewayError("INVALID_REQUEST", "feature item id/description invalid", 400);
    }
    if (!FEATURE_DOMAIN_ENUM.has(f.domain) || !FEATURE_DIRECTION_ENUM.has(f.direction)) {
      throw new GatewayError("INVALID_REQUEST", `feature item enum invalid: ${f.id}`, 400);
    }
    const slots = (Array.isArray(f.slots) ? f.slots : []).map((s) => {
      if (!s || typeof s !== "object" || !SLOT_NAME_RE.test(String(s.name ?? ""))) {
        throw new GatewayError("INVALID_REQUEST", `feature slots invalid: ${f.id}`, 400);
      }
      return { name: String(s.name), unit: typeof s.unit === "string" ? s.unit.slice(0, 16) : "" };
    });
    if (slots.length > 8) throw new GatewayError("INVALID_REQUEST", `feature slots exceed 8: ${f.id}`, 400);
    return { id: f.id, domain: f.domain, description: f.description, direction: f.direction, slots };
  });

  const normalizedIntents = checkArray(userIntents, PACKET_LIMITS.userIntents, "userIntents").map((u) => {
    if (!u || typeof u !== "object" || !isNonEmptyString(u.id, 64) || !INTENT_SOURCE_ENUM.has(u.source) || !isNonEmptyString(u.text, 80)) {
      throw new GatewayError("INVALID_REQUEST", "userIntent item invalid", 400);
    }
    return { id: u.id, source: u.source, text: u.text };
  });

  const stringList = (value, limit) => (
    Array.isArray(value)
      ? value.filter((t) => typeof t === "string" && t.length <= 64).slice(0, limit)
      : []
  );

  return {
    schemaVersion: 1,
    kind: "insightInput",
    requestId,
    window: { days: window.days },
    portrait: normalizedPortrait,
    features: normalizedFeatures,
    userIntents: normalizedIntents,
    recentTopics: stringList(recentTopics, 30),
    rejectedAngles: stringList(rejectedAngles, 30),
  };
}

/** 从模型原始输出提取最外层 JSON 对象（容 ```json 围栏）。 */
export function extractModelJson(text) {
  const trimmed = String(text ?? "").trim();
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start === -1 || end === -1 || end <= start) return null;
  try {
    return JSON.parse(trimmed.slice(start, end + 1));
  } catch {
    return null;
  }
}

/** 解析模型输出信封：selected 与 noneReason 二选一。 */
export function parseModelDraft(raw) {
  const parsed = extractModelJson(raw);
  if (!parsed || typeof parsed !== "object") return { ok: false, reason: "not_json" };
  if (parsed.selected === null || parsed.selected === undefined) {
    if (!MODEL_NONE_REASON_ENUM.has(parsed.noneReason)) return { ok: false, reason: "none_reason" };
    return { ok: true, none: true, noneReason: parsed.noneReason };
  }
  if (parsed.selected && typeof parsed.selected !== "object") return { ok: false, reason: "not_json" };
  return { ok: true, none: false, draft: parsed.selected };
}

/**
 * 确定性校验（六检查，不修改输入）。返回 { ok, reason, ... }。
 */
export function evaluateInsightDraft(selected, packet) {
  if (!selected || typeof selected !== "object") return { ok: false, reason: "shape" };
  const { angleKey, headline, insight, evidence, prompt, criteria, sourceDomains } = selected;
  if (!isNonEmptyString(angleKey, 96)) return { ok: false, reason: "angle_key" };
  if (!isNonEmptyString(headline, INSIGHT_LIMITS.headline)) return { ok: false, reason: "headline" };
  if (!isNonEmptyString(insight, INSIGHT_LIMITS.insight)) return { ok: false, reason: "insight" };
  if (prompt !== undefined && prompt !== null && typeof prompt !== "string") return { ok: false, reason: "prompt_type" };
  if (prompt !== undefined && prompt !== null && prompt.length > INSIGHT_LIMITS.prompt) {
    return { ok: false, reason: "prompt_length" };
  }

  // 检查 2：判断句数字禁令（headline / insight / prompt）。
  const judgement = `${headline}\n${insight}\n${prompt ?? ""}`;
  if (containsNumerals(judgement)) return { ok: false, reason: "bare_number" };

  // 检查 3：引用合法性。大括号只能组成完整的 {slot}，槽位必须属于对应 feature。
  if (!Array.isArray(evidence) || evidence.length < INSIGHT_LIMITS.evidenceMin || evidence.length > INSIGHT_LIMITS.evidenceMax) {
    return { ok: false, reason: "evidence_count" };
  }
  const featureById = new Map(packet.features.map((f) => [f.id, f]));
  const portraitIds = new Set(packet.portrait.map((p) => p.id));
  for (const line of evidence) {
    if (!line || typeof line !== "object" || !isNonEmptyString(line.refId, 64)) {
      return { ok: false, reason: "evidence_shape" };
    }
    if (!isNonEmptyString(line.template, INSIGHT_LIMITS.evidenceTemplate)) {
      return { ok: false, reason: "evidence_template_length" };
    }
    const feature = featureById.get(line.refId);
    const isPortraitRef = portraitIds.has(line.refId);
    if (!feature && !isPortraitRef) return { ok: false, reason: `unknown_ref:${line.refId}` };
    if (/[{}]/.test(line.template.replace(TEMPLATE_SLOT_RE, ""))) {
      return { ok: false, reason: "evidence_slot_syntax" };
    }
    const allowedSlots = new Set(feature ? feature.slots.map((s) => s.name) : []);
    for (const m of line.template.matchAll(TEMPLATE_SLOT_RE)) {
      if (!allowedSlots.has(m[1])) return { ok: false, reason: `slot_not_allowed:${m[1]}` };
    }
  }

  // 检查 4：复述启发式——方向词 + 无因果/对照连接词 + criteria 不足。
  // （置于 criteria 数量检查之前：模式命中且 criteria<2 → 报 restatement；
  //  模式命中但 criteria≥2 → 视作已声明对照/解释，放行交由后续检查。）
  const criteriaList = Array.isArray(criteria) ? criteria : [];
  if (criteriaList.length < INSIGHT_LIMITS.criteriaMin
      && DIRECTION_WORDS.some((w) => insight.includes(w))
      && !CAUSAL_CONTRAST_WORDS.some((w) => insight.includes(w))) {
    return { ok: false, reason: "restatement" };
  }

  // 加分维度：至少两项且都在 D1~D4。
  if (criteriaList.length < INSIGHT_LIMITS.criteriaMin
      || criteriaList.some((c) => !CRITERIA_ENUM.has(c))) {
    return { ok: false, reason: "criteria" };
  }
  if (!Array.isArray(sourceDomains) || sourceDomains.length === 0
      || sourceDomains.some((d) => typeof d !== "string" || d.length > 16)) {
    return { ok: false, reason: "source_domains" };
  }

  // 检查 5：角度去重——recentTopics / rejectedAngles 中的角度不得再选。
  const blockedAngles = new Set([...packet.recentTopics, ...packet.rejectedAngles]);
  if (blockedAngles.has(angleKey)) return { ok: false, reason: "angle_recent_or_rejected" };

  // 检查 6：安全词表（headline / insight / prompt）。
  for (const rule of SAFETY_PATTERNS) {
    if (rule.pattern.test(judgement)) return { ok: false, reason: `safety:${rule.label}` };
  }

  return { ok: true, reason: null };
}

/**
 * 轻量修复层（零生成）：重建白名单字段、截断超长、剔除引用非法的 evidence 行。
 * 修复后必须重过 evaluateInsightDraft。
 */
/**
 * 判断句裸数字剥除（v3 repairTemplates 同款先例）：qwen none 档对数字纪律遵从弱，
 * 离线评测 bare_number 占拒因大头（6/11）；剥掉数字词后句子通常仍通顺（「最近四周」→「最近」）。
 * 只作用于 headline/insight/prompt；evidence 模板不动（数字只能来自 {slot} 回填）。
 */
export function stripBareNumerals(text) {
  return text
    // 精确剥除：阿拉伯/全角数字任意位置；中文数字只在后随量词时剥（「四周/三杯」→剥，
    // 「半夜/十分/万分抱歉」这类非计数用法不动——CN_NUMERAL_RE 单字符集直接剥会误伤）。
    .replace(/[0-9０-９]+[周天次个块笔杯]?|[零一二两三四五六七八九十百千万亿]+(?:小时|分钟|秒钟|周|天|次|个|月|年|点|杯|笔|条|成|倍)/g, "")
    .replace(/\s{2,}/g, " ")
    .trim();
}

export function repairInsightDraft(selected, packet) {
  const featureById = new Map(packet.features.map((f) => [f.id, f]));
  const portraitIds = new Set(packet.portrait.map((p) => p.id));
  const cleanEvidence = (Array.isArray(selected.evidence) ? selected.evidence : [])
    .filter((line) => line && typeof line === "object" && typeof line.refId === "string"
      && typeof line.template === "string"
      && (featureById.has(line.refId) || portraitIds.has(line.refId)))
    .slice(0, INSIGHT_LIMITS.evidenceMax)
    .map((line) => ({
      refId: line.refId.slice(0, 64),
      // 证据是事实描述，超长交给模型重写。按字符截断可能切开 {slot} 或改掉原意。
      template: line.template,
    }));
  const criteria = Array.isArray(selected.criteria)
    ? selected.criteria.filter((c) => CRITERIA_ENUM.has(c)) : [];
  const sourceDomains = Array.isArray(selected.sourceDomains)
    ? selected.sourceDomains.filter((d) => typeof d === "string" && d.length <= 16) : [];
  return {
    angleKey: typeof selected.angleKey === "string" ? selected.angleKey.slice(0, 96) : "",
    headline: stripBareNumerals(String(selected.headline ?? "").slice(0, INSIGHT_LIMITS.headline)),
    insight: stripBareNumerals(String(selected.insight ?? "").slice(0, INSIGHT_LIMITS.insight)),
    evidence: cleanEvidence,
    prompt: stripBareNumerals(String(selected.prompt ?? "").slice(0, INSIGHT_LIMITS.prompt)),
    criteria: [...new Set(criteria)],
    sourceDomains: [...new Set(sourceDomains)],
  };
}

/** 组装最终 InsightDraft JSON（总纲 §5.2 线上形状；iOS InsightDraft 解码端）。 */
export function buildDraftEnvelope({ selected, noneReason }) {
  return JSON.stringify({
    schemaVersion: 1,
    kind: "insightDraft",
    selected: selected ? {
      angleKey: selected.angleKey,
      headline: selected.headline,
      insight: selected.insight,
      evidence: selected.evidence.map((line) => ({ refId: line.refId, template: line.template })),
      prompt: selected.prompt ?? "",
      criteria: selected.criteria,
      sourceDomains: selected.sourceDomains,
    } : null,
    noneReason: selected ? null : noneReason,
  });
}
