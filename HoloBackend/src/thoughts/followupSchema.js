import { GatewayError } from "../errors.js";
import { alignQuoteToSource } from "./quoteAlignment.js";

/**
 * 想法脉络核对 /v1/thoughts/verify-followup 输入/输出契约
 * （2026-11-16 想法主题与脉络方案 §6 C2 新端点契约 + §5 B1 预算边界）。
 *
 * 校验器是纯函数：只做结构、长度、枚举与逐字证据校验，不触碰网络与存储。
 * JS 字符串下标即 UTF-16 单位，与协议的 rangeUTF16 语义天然一致。
 *
 * 隐私边界（§2 A13 / §6 C2）：请求不含笔记、主题真实 ID、整库目录或未取样全文；
 * ref 是本次请求内的短编号，scopeTitle 只是核对背景（≤32 UTF-16），不提供给模型当共同证据。
 */

export const FOLLOWUP_LIMITS = Object.freeze({
  requestBodyMaxBytes: 32 * 1024,
  notesMinCount: 2,
  notesMaxCount: 5,
  scopeTitleMaxUTF16: 32,
  refMaxUTF16: 64,
  policyVersionMaxUTF16: 64,
  windowsPerNoteMax: 2,
  windowTextMaxUTF16: 600,
  totalTextMaxUTF16: 6000,
  quoteMaxUTF16: 120,
  reasonMaxUTF16: 100,
  threadTitleMinUTF16: 2,
  threadTitleMaxUTF16: 32,
  threadQuestionMinUTF16: 4,
  threadQuestionMaxUTF16: 100,
  threadMembersMin: 3,
  threadMembersMax: 5,
});

export const THOUGHT_FOLLOWUP_POLICY_VERSION = "thought-followup-1";

export const FOLLOWUP_RELATIONS = Object.freeze(new Set([
  "continues", "adds_example", "contrasts", "revises", "none", "insufficient",
]));
// 四种成立关系（§6 C1 表格）：双侧证据必填；none/insufficient 三字段必须全 null。
export const ESTABLISHED_RELATIONS = Object.freeze(new Set([
  "continues", "adds_example", "contrasts", "revises",
]));

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
 * 校验并归一化 verify-followup 请求体（§6 C2 JSON 示例形状）。
 * 返回 { schemaVersion, operationId, policyVersion, scopeTitle, anchorRef, notes }，
 * notes[0] 恒为锚点便于服务组装；非法请求抛 4xx GatewayError。
 */
export function validateFollowupRequest(body) {
  if (!body || typeof body !== "object") {
    throw new GatewayError("INVALID_REQUEST", "Request body must be an object", 400);
  }
  if (body.schemaVersion !== 1) {
    throw new GatewayError("INVALID_REQUEST", "schemaVersion must be 1", 400);
  }
  if (typeof body.operationId !== "string" || !UUID_PATTERN.test(body.operationId)) {
    throw new GatewayError("INVALID_REQUEST", "operationId must be a UUID", 400);
  }
  if (body.policyVersion !== THOUGHT_FOLLOWUP_POLICY_VERSION) {
    throw new GatewayError("INVALID_REQUEST", "policyVersion is not supported", 400);
  }
  if (typeof body.scopeTitle !== "string" || body.scopeTitle.length > FOLLOWUP_LIMITS.scopeTitleMaxUTF16) {
    throw new GatewayError("INVALID_REQUEST", `scopeTitle must be a string of at most ${FOLLOWUP_LIMITS.scopeTitleMaxUTF16} UTF-16 units`, 400);
  }
  if (!isCleanShortString(body.anchorRef, FOLLOWUP_LIMITS.refMaxUTF16)) {
    throw new GatewayError("INVALID_REQUEST", "anchorRef must be 1-64 clean chars", 400);
  }
  if (!Array.isArray(body.notes)
      || body.notes.length < FOLLOWUP_LIMITS.notesMinCount
      || body.notes.length > FOLLOWUP_LIMITS.notesMaxCount) {
    throw new GatewayError("INVALID_REQUEST", `notes must be ${FOLLOWUP_LIMITS.notesMinCount}-${FOLLOWUP_LIMITS.notesMaxCount} entries`, 400);
  }

  const seenRefs = new Set();
  const notes = body.notes.map((note, index) => {
    if (!note || typeof note !== "object") {
      throw new GatewayError("INVALID_REQUEST", `notes[${index}] must be an object`, 400);
    }
    if (!isCleanShortString(note.ref, FOLLOWUP_LIMITS.refMaxUTF16)) {
      throw new GatewayError("INVALID_REQUEST", `notes[${index}].ref must be 1-64 clean chars`, 400);
    }
    if (seenRefs.has(note.ref)) {
      throw new GatewayError("INVALID_REQUEST", `duplicate note ref ${note.ref}`, 400);
    }
    seenRefs.add(note.ref);
    if (!Number.isInteger(note.createdAtMs) || note.createdAtMs < 0) {
      throw new GatewayError("INVALID_REQUEST", `notes[${index}].createdAtMs must be a non-negative integer (UTC Unix ms)`, 400);
    }
    if (!Array.isArray(note.windows) || note.windows.length === 0 || note.windows.length > FOLLOWUP_LIMITS.windowsPerNoteMax) {
      throw new GatewayError("INVALID_REQUEST", `notes[${index}].windows must be 1-${FOLLOWUP_LIMITS.windowsPerNoteMax} entries`, 400);
    }
    const seenWindowRefs = new Set();
    const windows = note.windows.map((window, wIndex) => {
      if (!window || typeof window !== "object") {
        throw new GatewayError("INVALID_REQUEST", `notes[${index}].windows[${wIndex}] must be an object`, 400);
      }
      if (!isCleanShortString(window.ref, FOLLOWUP_LIMITS.refMaxUTF16)) {
        throw new GatewayError("INVALID_REQUEST", `notes[${index}].windows[${wIndex}].ref must be 1-64 clean chars`, 400);
      }
      if (seenWindowRefs.has(window.ref)) {
        throw new GatewayError("INVALID_REQUEST", `duplicate window ref ${window.ref} in note ${note.ref}`, 400);
      }
      seenWindowRefs.add(window.ref);
      if (!isBoundedText(window.text, FOLLOWUP_LIMITS.windowTextMaxUTF16)) {
        throw new GatewayError("INVALID_REQUEST", `notes[${index}].windows[${wIndex}].text must be 1-${FOLLOWUP_LIMITS.windowTextMaxUTF16} UTF-16 units`, 400);
      }
      return { ref: window.ref, text: window.text };
    });
    return { ref: note.ref, createdAtMs: note.createdAtMs, windows };
  });

  if (!notes.some((note) => note.ref === body.anchorRef)) {
    throw new GatewayError("INVALID_REQUEST", "anchorRef must match one of the notes", 400);
  }
  const totalText = notes.reduce(
    (sum, note) => sum + note.windows.reduce((s, w) => s + w.text.length, 0),
    0,
  );
  if (totalText > FOLLOWUP_LIMITS.totalTextMaxUTF16) {
    throw new GatewayError("INVALID_REQUEST", `total window text exceeds ${FOLLOWUP_LIMITS.totalTextMaxUTF16} UTF-16 units`, 400);
  }

  return {
    schemaVersion: 1,
    operationId: body.operationId,
    policyVersion: body.policyVersion,
    scopeTitle: body.scopeTitle,
    anchorRef: body.anchorRef,
    // 锚点排首位，其余保持输入顺序（模型入参确定性）
    notes: [...notes.filter((note) => note.ref === body.anchorRef), ...notes.filter((note) => note.ref !== body.anchorRef)],
  };
}

/** 证据对象协议校验 + 逐字回源；成功返回 canonical 证据，失败返回 null（调用方判协议错误）。 */
function canonicalEvidence(rawEvidence, note, reason) {
  if (!rawEvidence || typeof rawEvidence !== "object") return null;
  const window = note.windows.find((w) => w.ref === rawEvidence.windowRef);
  if (!window) return null;
  if (typeof rawEvidence.quote !== "string" || rawEvidence.quote.length === 0) return null;
  // 逐字回源：只允许 quoteAlignment 已定义的轻微排版对齐（空白/大小写/引号形态），
  // 拼接两个窗口或改写一律对不上 → 拒绝（§6 C2 / R17 跨窗拼接）。
  let quote = alignQuoteToSource(rawEvidence.quote, window.text);
  if (!quote) return null;
  // 长度属于传输规范：完整引用先确认逐字成立，再规范到协议上限（不使已核对证据无限重试）
  if (quote.length > FOLLOWUP_LIMITS.quoteMaxUTF16) {
    quote = quote.slice(0, FOLLOWUP_LIMITS.quoteMaxUTF16);
    if (/[\uD800-\uDBFF]$/.test(quote)) quote = quote.slice(0, -1);
  }
  const start = window.text.indexOf(quote);
  const range = [start, start + quote.length];
  // rangeUTF16 必填且形状合法（窗口内半开区间）；数值本身由服务端从 canonical quote 重算
  // （与 semantic-relate v2+ 同口径：模型给的值仅作结构检查，避免错位号烧整批预算；
  //  Swift 端再按同一窗口核对范围与逐字内容，双端一致）。
  const modelRange = rawEvidence.rangeUTF16;
  if (!Array.isArray(modelRange) || modelRange.length !== 2
      || !Number.isInteger(modelRange[0]) || !Number.isInteger(modelRange[1])
      || modelRange[0] < 0 || modelRange[1] > window.text.length || modelRange[0] > modelRange[1]) {
    return null;
  }
  return { windowRef: window.ref, quote, rangeUTF16: range, reason };
}

function isExplicitNull(value) {
  return value === null || value === undefined;
}

/**
 * 校验模型输出（已在调用方解析为对象）。规则（§6 C2 逐条）：
 * - 每个非锚点 ref 恰好一个决定，ref 不得自造或重复；
 * - relation 只允许六枚举；四种成立关系双侧证据必填；
 * - none/insufficient 的 reason 与两侧证据必须 null；
 * - thread 为 null 或对象（title 2-32、question 4-100、memberRefs 3-5 唯一且含锚点，
 *   其余成员逐条有成立关系）；
 * - 任何结构性/证据协议错 → { malformed, reason } 整批失败，禁止降级成 no_result。
 * 返回 { decisions, thread } 或 { malformed, reason }。
 */
export function validateFollowupModelOutput(output, parsedRequest) {
  if (!output || typeof output !== "object") return { malformed: true, reason: "not_object" };
  const decisionsRaw = output.decisions;
  if (!Array.isArray(decisionsRaw)) return { malformed: true, reason: "decisions_shape" };

  const anchorNote = parsedRequest.notes[0];
  const otherNotes = parsedRequest.notes.slice(1);
  const expectedRefs = new Set(otherNotes.map((note) => note.ref));
  if (decisionsRaw.length !== otherNotes.length) {
    return { malformed: true, reason: "decisions_incomplete" };
  }
  const seenRefs = new Set();
  const decisions = [];
  const relationByRef = new Map();
  for (const item of decisionsRaw) {
    if (!item || typeof item !== "object") return { malformed: true, reason: "decision_not_object" };
    const otherRef = item.otherRef;
    if (typeof otherRef !== "string" || !expectedRefs.has(otherRef)) {
      return { malformed: true, reason: "other_ref_not_allowed" };
    }
    if (seenRefs.has(otherRef)) return { malformed: true, reason: "other_ref_duplicated" };
    seenRefs.add(otherRef);
    if (!FOLLOWUP_RELATIONS.has(item.relation)) {
      return { malformed: true, reason: "relation_enum" };
    }
    if (item.confidence !== undefined && item.confidence !== null) {
      return { malformed: true, reason: "confidence_forbidden" };
    }

    if (!ESTABLISHED_RELATIONS.has(item.relation)) {
      // none/insufficient：reason 与两侧证据必须全 null（显式非 null 即协议错误）
      if (!isExplicitNull(item.reason) || !isExplicitNull(item.anchorEvidence) || !isExplicitNull(item.otherEvidence)) {
        return { malformed: true, reason: "negative_decision_fields_not_null" };
      }
      decisions.push({ otherRef, relation: item.relation, reason: null, anchorEvidence: null, otherEvidence: null });
      continue;
    }

    if (!isBoundedText(item.reason, FOLLOWUP_LIMITS.reasonMaxUTF16)) {
      return { malformed: true, reason: "reason_shape" };
    }
    // 双侧证据逐字回源：锚点证据引用锚点窗口，对方证据引用对应笔记窗口
    const anchorEvidence = canonicalEvidence(item.anchorEvidence, anchorNote, item.reason);
    if (!anchorEvidence) return { malformed: true, reason: "anchor_evidence_invalid" };
    const otherNote = otherNotes.find((note) => note.ref === otherRef);
    const otherEvidence = canonicalEvidence(item.otherEvidence, otherNote, item.reason);
    if (!otherEvidence) return { malformed: true, reason: "other_evidence_invalid" };

    relationByRef.set(otherRef, item.relation);
    decisions.push({
      otherRef,
      relation: item.relation,
      reason: item.reason,
      anchorEvidence: { windowRef: anchorEvidence.windowRef, quote: anchorEvidence.quote, rangeUTF16: anchorEvidence.rangeUTF16 },
      otherEvidence: { windowRef: otherEvidence.windowRef, quote: otherEvidence.quote, rangeUTF16: otherEvidence.rangeUTF16 },
    });
  }

  let thread = null;
  if (!isExplicitNull(output.thread)) {
    const rawThread = output.thread;
    if (!rawThread || typeof rawThread !== "object" || Array.isArray(rawThread)) {
      return { malformed: true, reason: "thread_shape" };
    }
    if (!isBoundedText(rawThread.title, FOLLOWUP_LIMITS.threadTitleMaxUTF16)
        || rawThread.title.length < FOLLOWUP_LIMITS.threadTitleMinUTF16) {
      return { malformed: true, reason: "thread_title_shape" };
    }
    if (!isBoundedText(rawThread.question, FOLLOWUP_LIMITS.threadQuestionMaxUTF16)
        || rawThread.question.length < FOLLOWUP_LIMITS.threadQuestionMinUTF16) {
      return { malformed: true, reason: "thread_question_shape" };
    }
    if (!Array.isArray(rawThread.memberRefs)
        || rawThread.memberRefs.length < FOLLOWUP_LIMITS.threadMembersMin
        || rawThread.memberRefs.length > FOLLOWUP_LIMITS.threadMembersMax) {
      return { malformed: true, reason: "thread_member_count" };
    }
    const inputRefs = new Set(parsedRequest.notes.map((note) => note.ref));
    const members = [];
    for (const ref of rawThread.memberRefs) {
      if (typeof ref !== "string" || !inputRefs.has(ref)) {
        return { malformed: true, reason: "thread_member_ref_not_allowed" };
      }
      if (members.includes(ref)) return { malformed: true, reason: "thread_member_duplicated" };
      members.push(ref);
    }
    if (!members.includes(parsedRequest.anchorRef)) {
      return { malformed: true, reason: "thread_missing_anchor" };
    }
    // 其余成员必须逐条有成立关系（§6 C2：其余必须逐条有有效关系）
    const nonAnchorMembers = members.filter((ref) => ref !== parsedRequest.anchorRef);
    if (nonAnchorMembers.some((ref) => !ESTABLISHED_RELATIONS.has(relationByRef.get(ref)))) {
      return { malformed: true, reason: "thread_member_relation_invalid" };
    }
    thread = {
      title: rawThread.title,
      question: rawThread.question,
      memberRefs: members,
    };
  }

  return { decisions, thread };
}

/**
 * 组织能力口（GET organization-capabilities）200 封套（§6 C2）。
 * 字段固定：schemaVersion=1、categoryRulesVersion 0|4、followupVersion 0|1、policyVersion。
 * 版本 0 = 对应能力关闭；followup 还要求主体在试点白名单内（仅配置的可信主体，
 * 客户端自报设备 ID 不算数）。错误路径不回显配置或主体标识。
 */
export function organizationCapabilities(config, { pilotSubject }) {
  const followup = config.thoughtFollowup ?? {};
  const pilotSubjects = Array.isArray(followup.pilotSubjects) ? followup.pilotSubjects : [];
  const pilotAllowed = pilotSubjects.length > 0
    && typeof pilotSubject === "string"
    && pilotSubjects.includes(pilotSubject);
  return {
    schemaVersion: 1,
    categoryRulesVersion: config.thoughtScopeRules?.enabled ? 4 : 0,
    followupVersion: followup.enabled === true && pilotAllowed ? 1 : 0,
    policyVersion: THOUGHT_FOLLOWUP_POLICY_VERSION,
  };
}
