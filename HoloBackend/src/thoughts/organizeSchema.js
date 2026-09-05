import { GatewayError } from "../errors.js";

/**
 * 想法自动整理 V2 输入/输出契约（方案 docs/thoughts/plans/2026-09-05-想法自动整理V2实施方案-GLM.md §6）。
 *
 * 校验器是纯函数：只做结构、长度、编号与逐字证据校验，不触碰网络与存储。
 * JS 字符串下标即 UTF-16 单位，与协议的 rangeUTF16 语义天然一致。
 */

export const ORGANIZE_LIMITS = Object.freeze({
  requestBodyMaxBytes: 128 * 1024,
  textMaxUTF16Length: 8_000,
  catalogMaxEntries: 2_000,
  nameMaxLength: 32,
  definitionMaxLength: 80,
  aliasMaxCount: 3,
  pathMaxLength: 120,
  revisionMaxLength: 64,
  operationIdMaxLength: 64,
  blockedNameMaxCount: 50,
  anchorsMaxCount: 3,
  anchorQuoteMaxUTF16: 80,
  assignmentsMaxCount: 2,
  recallMaxRefs: 12,
});

const PRIORITY_VALUES = new Set(["primary", "secondary"]);

/** 名称与修订号等短字符串的合法性：拒绝空串、控制字符与换行（防路径注入/协议注入）。 */
function isCleanShortString(value, maxLength) {
  if (typeof value !== "string" || value.length === 0 || value.length > maxLength) return false;
  // eslint-disable-next-line no-control-regex
  return !/[\u0000-\u001f\u007f]/.test(value);
}

/** 概念名称约束（方案 §5.3）：拒绝控制字符、换行与 "/"。 */
export function isValidConceptName(name) {
  return isCleanShortString(name, ORGANIZE_LIMITS.nameMaxLength) && !name.includes("/");
}

/** 大小写不敏感的名称归一（blockedNames 匹配用；不做全角折叠，宁可漏杀不可误杀）。 */
function normalizeNameForMatch(name) {
  return name.trim().toLowerCase();
}

/**
 * 校验并归一化 /v1/thoughts/organize 请求体。
 * 返回可直接进入编排的干净结构；非法请求抛 4xx GatewayError。
 */
export function validateOrganizeRequest(body) {
  if (!body || typeof body !== "object") {
    throw new GatewayError("INVALID_REQUEST", "Request body must be an object", 400);
  }
  if (body.schemaVersion !== 2) {
    throw new GatewayError("INVALID_REQUEST", "schemaVersion must be 2", 400);
  }
  if (!isCleanShortString(body.operationId, ORGANIZE_LIMITS.operationIdMaxLength)) {
    throw new GatewayError("INVALID_REQUEST", "operationId must be 1-64 clean chars", 400);
  }
  for (const field of ["textRevision", "catalogRevision"]) {
    const value = body[field];
    if (typeof value !== "string" || value.length === 0 || value.length > ORGANIZE_LIMITS.revisionMaxLength) {
      throw new GatewayError("INVALID_REQUEST", `${field} must be 1-64 chars`, 400);
    }
  }

  const text = body.text;
  if (typeof text !== "string" || text.length === 0) {
    throw new GatewayError("INVALID_REQUEST", "text must be a non-empty string", 400);
  }
  if (text.length > ORGANIZE_LIMITS.textMaxUTF16Length) {
    throw new GatewayError("INPUT_TOO_LARGE", `text exceeds ${ORGANIZE_LIMITS.textMaxUTF16Length} UTF-16 units`, 413);
  }
  if (!text.trim()) {
    // 纯空白/标点由客户端跳过；服务器同样按终态拒绝，不消耗模型调用。
    throw new GatewayError("INVALID_REQUEST", "text has no analyzable content", 400);
  }

  const catalog = validateCatalog(body.catalog);
  const refSet = new Set(catalog.map((entry) => entry.ref));

  const blockedRefs = validateBlockedRefs(body.blockedRefs, refSet);
  const blockedNames = validateBlockedNames(body.blockedNames);

  return {
    operationId: body.operationId,
    textRevision: body.textRevision,
    catalogRevision: body.catalogRevision,
    text,
    catalog,
    blockedRefs,
    blockedNames,
  };
}

function validateCatalog(catalog) {
  if (!Array.isArray(catalog)) {
    throw new GatewayError("INVALID_REQUEST", "catalog must be an array", 400);
  }
  if (catalog.length > ORGANIZE_LIMITS.catalogMaxEntries) {
    throw new GatewayError("INVALID_REQUEST", `catalog exceeds ${ORGANIZE_LIMITS.catalogMaxEntries} entries`, 400);
  }
  const seenRefs = new Set();
  const clean = [];
  for (const entry of catalog) {
    if (!entry || typeof entry !== "object") {
      throw new GatewayError("INVALID_REQUEST", "catalog entry must be an object", 400);
    }
    const ref = entry.ref;
    if (!Number.isInteger(ref) || ref < 1 || ref > ORGANIZE_LIMITS.catalogMaxEntries) {
      throw new GatewayError("INVALID_REQUEST", "catalog ref must be an integer in [1, 2000]", 400);
    }
    if (seenRefs.has(ref)) {
      throw new GatewayError("INVALID_REQUEST", `catalog ref ${ref} is duplicated`, 400);
    }
    seenRefs.add(ref);
    if (!isValidConceptName(entry.name)) {
      throw new GatewayError("INVALID_REQUEST", `catalog ref ${ref} name is invalid`, 400);
    }
    if (entry.definition !== undefined && entry.definition !== null
      && (typeof entry.definition !== "string" || entry.definition.length > ORGANIZE_LIMITS.definitionMaxLength)) {
      throw new GatewayError("INVALID_REQUEST", `catalog ref ${ref} definition exceeds limit`, 400);
    }
    if (entry.path !== undefined && entry.path !== null
      && (typeof entry.path !== "string" || entry.path.length > ORGANIZE_LIMITS.pathMaxLength)) {
      throw new GatewayError("INVALID_REQUEST", `catalog ref ${ref} path exceeds limit`, 400);
    }
    const aliases = entry.aliases ?? [];
    if (!Array.isArray(aliases) || aliases.length > ORGANIZE_LIMITS.aliasMaxCount
      || aliases.some((alias) => !isCleanShortString(alias, ORGANIZE_LIMITS.nameMaxLength))) {
      throw new GatewayError("INVALID_REQUEST", `catalog ref ${ref} aliases are invalid`, 400);
    }
    clean.push({
      ref,
      name: entry.name,
      definition: typeof entry.definition === "string" && entry.definition.length > 0 ? entry.definition : null,
      path: typeof entry.path === "string" && entry.path.length > 0 ? entry.path : null,
      aliases,
      userNamed: entry.userNamed === true,
    });
  }
  return clean;
}

function validateBlockedRefs(blockedRefs, refSet) {
  if (blockedRefs === undefined || blockedRefs === null) return [];
  if (!Array.isArray(blockedRefs) || blockedRefs.some((ref) => !refSet.has(ref))) {
    throw new GatewayError("INVALID_REQUEST", "blockedRefs must reference catalog refs", 400);
  }
  return [...new Set(blockedRefs)];
}

function validateBlockedNames(blockedNames) {
  if (blockedNames === undefined || blockedNames === null) return [];
  if (!Array.isArray(blockedNames) || blockedNames.length > ORGANIZE_LIMITS.blockedNameMaxCount
    || blockedNames.some((name) => !isCleanShortString(name, ORGANIZE_LIMITS.nameMaxLength))) {
    throw new GatewayError("INVALID_REQUEST", "blockedNames are invalid", 400);
  }
  return blockedNames.map(normalizeNameForMatch).filter(Boolean);
}

/**
 * 解析模型输出 JSON：只允许移除外层 markdown 代码围栏一次，然后严格 JSON.parse。
 * 不做「再让模型修 JSON」的二次调用（方案 §6.2）。
 */
export function parseModelJSON(content) {
  if (typeof content !== "string" || content.trim().length === 0) return null;
  let text = content.trim();
  const fence = text.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/);
  if (fence) {
    text = fence[1].trim();
  }
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

/**
 * 阶段 A 输出校验（方案 §5.1）。
 * quote 必须是原文的连续逐字片段；不合规的候选直接丢弃，不整体失败。
 * 返回 { anchors: [{surface, meaning, quote, priority}] }；anchors 为空表示无证据。
 */
export function validateStageAOutput(parsed, text) {
  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.anchors)) {
    return { anchors: [], malformed: true };
  }
  const anchors = [];
  for (const raw of parsed.anchors.slice(0, ORGANIZE_LIMITS.anchorsMaxCount)) {
    if (!raw || typeof raw !== "object") continue;
    const quote = typeof raw.quote === "string" ? raw.quote : "";
    if (quote.length === 0 || quote.length > ORGANIZE_LIMITS.anchorQuoteMaxUTF16) continue;
    if (!text.includes(quote)) continue; // 逐字证据：原文中必须连续出现
    const surface = typeof raw.surface === "string" ? raw.surface.trim() : "";
    if (surface.length === 0 || surface.length > ORGANIZE_LIMITS.nameMaxLength) continue;
    const meaning = typeof raw.meaning === "string" ? raw.meaning.trim() : "";
    if (meaning.length > ORGANIZE_LIMITS.definitionMaxLength) continue;
    const priority = PRIORITY_VALUES.has(raw.priority) ? raw.priority : "secondary";
    anchors.push({ surface, meaning, quote, priority });
  }
  return { anchors, malformed: false };
}

/**
 * 阶段 R（目录筛选）输出校验：refs 必须存在于本次目录，去重并截断到上限。
 */
export function validateRecallOutput(parsed, catalog) {
  const validRefs = new Set(catalog.map((entry) => entry.ref));
  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.refs)) return [];
  const refs = [];
  const seen = new Set();
  for (const ref of parsed.refs) {
    if (!Number.isInteger(ref) || !validRefs.has(ref) || seen.has(ref)) continue;
    seen.add(ref);
    refs.push(ref);
    if (refs.length >= ORGANIZE_LIMITS.recallMaxRefs) break;
  }
  return refs;
}

/**
 * 阶段 B 输出校验（方案 §5.2 / §6.1）。
 * 每个结果绑定阶段 A 候选编号；existingRef 与 newConcept 二选一；
 * 拒绝目录外编号、用户拒绝概念、伪造证据与重复概念。
 * 返回 { assignments, malformed }。
 */
export function validateStageBOutput(parsed, { text, anchors, catalog, blockedRefs, blockedNames }) {
  if (!parsed || typeof parsed !== "object" || !Array.isArray(parsed.assignments)) {
    return { assignments: [], malformed: true };
  }
  const refSet = new Set(catalog.map((entry) => entry.ref));
  const blockedRefSet = new Set(blockedRefs);
  const blockedNameSet = new Set(blockedNames);
  const assignments = [];
  const usedRefs = new Set();
  const usedNames = new Set();
  for (const raw of parsed.assignments) {
    if (assignments.length >= ORGANIZE_LIMITS.assignmentsMaxCount) break;
    if (!raw || typeof raw !== "object") continue;
    const anchorIndex = raw.anchorRef;
    if (!Number.isInteger(anchorIndex) || anchorIndex < 0 || anchorIndex >= anchors.length) continue;
    // 只有 equivalent 才构成标签关系；模型标注的 broader/narrower/related/none 均不是采用依据
    if (raw.relation !== undefined && raw.relation !== "equivalent") continue;

    const quote = typeof raw.quote === "string" ? raw.quote : "";
    if (quote.length === 0 || quote.length > ORGANIZE_LIMITS.anchorQuoteMaxUTF16) continue;
    const location = text.indexOf(quote);
    if (location < 0) continue;

    const hasExisting = raw.existingRef !== undefined && raw.existingRef !== null;
    const hasNew = raw.newConcept !== undefined && raw.newConcept !== null && typeof raw.newConcept === "object";
    if (hasExisting === hasNew) continue; // 二选一

    if (hasExisting) {
      const ref = raw.existingRef;
      if (!Number.isInteger(ref) || !refSet.has(ref)) continue;
      if (blockedRefSet.has(ref)) continue;
      if (usedRefs.has(ref)) continue;
      usedRefs.add(ref);
      assignments.push({
        anchorRef: anchorIndex,
        existingRef: ref,
        relation: "equivalent",
        quote,
        rangeUTF16: [location, quote.length],
      });
      continue;
    }

    const concept = raw.newConcept;
    const name = typeof concept.name === "string" ? concept.name.trim() : "";
    if (!isValidConceptName(name)) continue;
    const normalized = normalizeNameForMatch(name);
    if (blockedNameSet.has(normalized)) continue;
    if (usedNames.has(normalized)) continue;
    const definition = typeof concept.definition === "string"
      ? concept.definition.trim().slice(0, ORGANIZE_LIMITS.definitionMaxLength)
      : "";
    usedNames.add(normalized);
    assignments.push({
      anchorRef: anchorIndex,
      newConcept: { name, definition },
      relation: "equivalent",
      quote,
      rangeUTF16: [location, quote.length],
    });
  }
  return { assignments, malformed: false };
}

/**
 * 完整目录与名称目录的字符预算测算（方案 §5.5 路径分级）。
 * 返回两个序列化长度，供 service 选择 full / recall / deferred。
 */
export function measureCatalogBudgets(catalog) {
  let fullChars = 0;
  let nameChars = 0;
  for (const entry of catalog) {
    fullChars += JSON.stringify({
      ref: entry.ref,
      name: entry.name,
      definition: entry.definition ?? "",
      aliases: entry.aliases,
      path: entry.path ?? "",
      userNamed: entry.userNamed,
    }).length;
    nameChars += JSON.stringify({
      ref: entry.ref,
      name: entry.name,
      path: entry.path ?? "",
      aliases: entry.aliases.slice(0, 1),
    }).length;
  }
  return { fullChars, nameChars };
}

/**
 * 显式命中补充（方案 §5.5 路径 2）：候选 surface 与目录名称/别名完全一致时，
 * 无需依赖模型召回，服务器直接补充进 R 结果，避免确定性命中被漏召回。
 */
export function explicitNameHits(anchors, catalog) {
  const surfaces = new Set(anchors.map((anchor) => normalizeNameForMatch(anchor.surface)));
  const hits = [];
  for (const entry of catalog) {
    const names = [entry.name, ...entry.aliases].map(normalizeNameForMatch);
    if (names.some((name) => surfaces.has(name))) {
      hits.push(entry.ref);
    }
  }
  return hits;
}
