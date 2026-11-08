import { GatewayError, createErrorResponse } from "../errors.js";
import { injectServerPrompt } from "../prompts/serverPromptPolicy.js";
import { getPrompt } from "../prompts/promptRegistry.js";
import { backgroundSubject } from "../usage/backgroundCostGuard.js";
import { createHash } from "node:crypto";

/**
 * 「一个发现」v3 选题端点（2026-11-08 方案 §5.2，东林拍板）。
 *
 * 形态与本文件的前任（discoveryController 的 runs/candidates/verify 批链路，
 * 已于 1.1.6 退役）不同：本机权威——观察事实由手机上的确定性挖掘器算好，
 * 服务端只做一次「选题 + 文案填空」模型调用，算完即忘：
 * - 输入是纯「形状」（域/命题类型/方向/周数计数），无金额、无健康数值、无正文；
 * - 输出是带空位的文案模板（{weeks} 等），数字由客户端回填真值；
 * - 结果只短存于幂等账本（discovery_requests.result_meta，取件即焚语义），
 *   不落任何用户内容；日志只记 observationId / reasonCode / 拒因码。
 *
 * 护栏分两层：模型 prompt 内自检清单（qwen 对 checklist 遵从好，v4-v6 验证），
 * 加本文件的服务端确定性校验与修复层（不信任模型自觉）。
 */

const PURPOSE = "discovery_topic_v1";
const PROMPT_TYPE = "discovery_topic_v1";

const DOMAIN_ENUM = new Set(["thought", "task", "habit", "goal", "finance", "health", "conversation"]);
const DIRECTION_ENUM = new Set(["higher", "lower", "contrast", "divergent"]);
const ANGLE_ENUM = new Set(["change", "repeat", "contrast", "unusual"]);
const REASON_CODE_ENUM = new Set(["recent_change", "new_pattern", "relevant_now", "counter_intuitive"]);
const NONE_REASON_ENUM = new Set(["none_worthwhile", "all_stale", "insufficient_shape"]);
const LANGUAGE_ENUM = new Set(["zh-Hans", "zh-Hant", "en"]);

/** direction 反向词禁令：模板含与 direction 相反的定性词 → 拒（方向正确性由客户端终审）。 */
const OPPOSITE_DIRECTION_WORDS = {
  higher: ["低于", "更少", "变少", "下降", "回落", "less"],
  lower: ["高于", "更多", "更频繁", "变多", "上涨", "更高", "爬高", "more"],
  contrast: [],
  divergent: [],
};

const SLOT_NAME_RE = /^[a-zA-Z_][a-zA-Z0-9_]{0,23}$/;
const CN_NUMERAL_RE = /[0-9０-９零一二两三四五六七八九十百千万亿几分之]/;
const TEMPLATE_SLOT_RE = /\{([a-zA-Z_][a-zA-Z0-9_]*)\}/g;

/** 模板长度口径：槽位按 2 字估（回填后客户端按真值校验 14/80 终限）。 */
function templateWeight(text) {
  return text.replace(TEMPLATE_SLOT_RE, "！！").length;
}

function sha256Hex(value) {
  return createHash("sha256").update(value).digest("hex");
}

function canonicalJson(value) {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(",")}]`;
  const keys = Object.keys(value).sort();
  return `{${keys.map((k) => `${JSON.stringify(k)}:${canonicalJson(value[k])}`).join(",")}}`;
}

function requireFields(body, fields) {
  for (const f of fields) {
    if (body[f] === undefined || body[f] === null || body[f] === "") {
      throw new GatewayError("INVALID_REQUEST", `Missing field: ${f}`, 400);
    }
  }
}

/** 输入闸：candidates ≤30 条，字段形状白名单校验（防注入、防超量）。 */
function validateCandidates(raw) {
  if (!Array.isArray(raw) || raw.length === 0 || raw.length > 30) {
    throw new GatewayError("INVALID_REQUEST", "candidates must be an array of 1-30 items", 400);
  }
  return raw.map((c) => {
    if (!c || typeof c !== "object") throw new GatewayError("INVALID_REQUEST", "candidate must be an object", 400);
    const { id, domain, kind, direction, label, freshness, slots, topicKey } = c;
    if (typeof id !== "string" || !/^[A-Za-z0-9:_-]{1,64}$/.test(id)) {
      throw new GatewayError("INVALID_REQUEST", `candidate.id invalid: ${String(id).slice(0, 16)}`, 400);
    }
    if (!DOMAIN_ENUM.has(domain)) throw new GatewayError("INVALID_REQUEST", `candidate.domain invalid: ${id}`, 400);
    if (typeof kind !== "string" || !/^[a-zA-Z_][a-zA-Z0-9_-]{0,31}$/.test(kind)) {
      throw new GatewayError("INVALID_REQUEST", `candidate.kind invalid: ${id}`, 400);
    }
    if (!DIRECTION_ENUM.has(direction)) throw new GatewayError("INVALID_REQUEST", `candidate.direction invalid: ${id}`, 400);
    if (label !== undefined && (typeof label !== "string" || label.length > 16)) {
      throw new GatewayError("INVALID_REQUEST", `candidate.label invalid: ${id}`, 400);
    }
    if (freshness !== undefined && !["new", "seen"].includes(freshness)) {
      throw new GatewayError("INVALID_REQUEST", `candidate.freshness invalid: ${id}`, 400);
    }
    const slotList = Array.isArray(slots) ? slots : [];
    if (slotList.length > 8 || slotList.some((s) => typeof s !== "string" || !SLOT_NAME_RE.test(s))) {
      throw new GatewayError("INVALID_REQUEST", `candidate.slots invalid: ${id}`, 400);
    }
    if (topicKey !== undefined && (typeof topicKey !== "string" || topicKey.length > 64)) {
      throw new GatewayError("INVALID_REQUEST", `candidate.topicKey invalid: ${id}`, 400);
    }
    return { id, domain, kind, direction, label, freshness, slots: slotList, topicKey };
  });
}

/** 服务端预过滤：已展示命题方向（recentTopics）直接从输入剔除，模型不可见。 */
function filterRecent(candidates, recentTopics) {
  if (!Array.isArray(recentTopics) || recentTopics.length === 0) return candidates;
  const seen = new Set(recentTopics.filter((t) => typeof t === "string" && t.length <= 64).slice(0, 20));
  return candidates.filter((c) => !(c.topicKey && seen.has(c.topicKey)));
}

/**
 * 服务端确定性校验（七条护栏）。返回 { ok, reason }；不修改输入。
 */
function validateSelection(selection, candidates) {
  if (!selection || typeof selection !== "object") return { ok: false, reason: "shape" };
  const { observationId, angle, reasonCode, titleTemplate, bodyTemplate } = selection;
  if (typeof observationId !== "string" || !candidates.some((c) => c.id === observationId)) {
    return { ok: false, reason: "unknown_observation" };
  }
  if (!ANGLE_ENUM.has(angle)) return { ok: false, reason: "angle" };
  if (reasonCode !== undefined && !REASON_CODE_ENUM.has(reasonCode)) return { ok: false, reason: "reason_code" };
  if (typeof titleTemplate !== "string" || typeof bodyTemplate !== "string") return { ok: false, reason: "shape" };
  const candidate = candidates.find((c) => c.id === observationId);
  const allowed = new Set(candidate.slots);
  const used = new Set();
  for (const m of `${titleTemplate}\n${bodyTemplate}`.matchAll(TEMPLATE_SLOT_RE)) {
    used.add(m[1]);
    if (!allowed.has(m[1])) return { ok: false, reason: `slot_not_allowed:${m[1]}` };
  }
  // 裸数字禁令：槽位之外的任何数字（阿拉伯/全角/中文数字）都拒。
  const stripped = `${titleTemplate}\n${bodyTemplate}`.replace(TEMPLATE_SLOT_RE, "");
  if (CN_NUMERAL_RE.test(stripped)) return { ok: false, reason: "bare_number" };
  // 长度（槽位按 2 字估；终限 14/80 由客户端回填真值后校验）。
  if (templateWeight(titleTemplate) > 16) return { ok: false, reason: "title_length" };
  if (templateWeight(bodyTemplate) > 90) return { ok: false, reason: "body_length" };
  // 方向反向词禁令：direction=higher 却写「低于/更少」→ 拒。
  const opposite = OPPOSITE_DIRECTION_WORDS[candidate.direction] || [];
  if (opposite.some((w) => bodyTemplate.includes(w) || titleTemplate.includes(w))) {
    return { ok: false, reason: "direction_conflict" };
  }
  return { ok: true, reason: null, usedSlots: [...used] };
}

/** 确定性修复层：剥离槽位外的裸数字与越界槽位（零生成，修复后必须重校验）。 */
function repairTemplates(selection) {
  const fix = (text) => {
    let out = text.replace(TEMPLATE_SLOT_RE, (full, name) => (SLOT_NAME_RE.test(name) ? full : ""));
    out = out.replace(CN_NUMERAL_RE, "");
    return out.replace(/\s{2,}/g, " ").trim();
  };
  return {
    ...selection,
    titleTemplate: fix(selection.titleTemplate),
    bodyTemplate: fix(selection.bodyTemplate),
  };
}

function extractModelJson(text) {
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

function parseModelEnvelope(raw) {
  const parsed = extractModelJson(raw);
  if (!parsed || typeof parsed !== "object") return { ok: false, reason: "not_json" };
  if (parsed.selected === null || parsed.selected === undefined) {
    if (!NONE_REASON_ENUM.has(parsed.noneReason)) return { ok: false, reason: "none_reason" };
    return { ok: true, none: true, noneReason: parsed.noneReason };
  }
  return { ok: true, none: false, selection: parsed.selected };
}

export function registerTopicSelectionRoutes(app, deps) {
  const { config, providers, database, getDeviceId, entitlementStore, backgroundCostGuard } = deps;
  const db = database.db;

  app.post("/v1/discovery/topic", async (context) => {
    try {
      return await handleTopicRequest(context);
    } catch (error) {
      return createErrorResponse(context, error);
    }
  });

  async function handleTopicRequest(context) {
    // 独立 kill switch：旧批链路开关（discovery.enabled）已关闸退役，新端点单独灰度。
    if (config.discovery?.topicEnabled !== true) {
      throw new GatewayError("DISCOVERY_TOPIC_DISABLED", "Topic selection is not enabled", 503);
    }
    const body = await context.req.json().catch(() => null);
    if (!body || typeof body !== "object") throw new GatewayError("INVALID_REQUEST", "Body must be an object", 400);
    requireFields(body, ["requestId", "candidates"]);
    if (typeof body.requestId !== "string" || body.requestId.length > 64) {
      throw new GatewayError("INVALID_REQUEST", "requestId invalid", 400);
    }
    if (body.language !== undefined && !LANGUAGE_ENUM.has(body.language)) {
      throw new GatewayError("INVALID_REQUEST", "language invalid", 400);
    }
    if (body.poolFingerprint !== undefined && !/^[a-f0-9]{8,64}$/.test(body.poolFingerprint)) {
      throw new GatewayError("INVALID_REQUEST", "poolFingerprint invalid", 400);
    }
    const allCandidates = validateCandidates(body.candidates);
    const deviceId = await getDeviceId(context, config);
    const subject = backgroundSubject(deviceId, entitlementStore.get(deviceId));

    const recent = Array.isArray(body.recentTopics) ? body.recentTopics : [];
    const candidates = filterRecent(allCandidates, recent);
    const requestHash = sha256Hex(canonicalJson({ v: 1, candidates, language: body.language ?? "zh-Hans", recent }));

    // 幂等账本（复用 discovery_requests）：同 requestId 同 hash → 重放既有结果，不重复调模型。
    const existing = db
      .prepare("SELECT request_hash, status, result_meta FROM discovery_requests WHERE request_id = ?")
      .get(body.requestId);
    if (existing) {
      if (existing.request_hash !== requestHash) {
        throw new GatewayError("DISCOVERY_REQUEST_CONFLICT", "requestId already used with different body", 409);
      }
      if (existing.status === "completed" && existing.result_meta) {
        const replay = JSON.parse(existing.result_meta);
        return context.json({ ...replay, requestId: body.requestId, replayed: true });
      }
    }
    const now = Date.now();
    if (!existing) {
      db.prepare(
        "INSERT INTO discovery_requests (request_id, subject, kind, request_hash, status, result_meta, created_at, updated_at) VALUES (?, ?, 'topic_selection', ?, 'pending', NULL, ?, ?)"
      ).run(body.requestId, subject, requestHash, now, now);
    }

    if (candidates.length === 0) {
      const payload = { protocolVersion: 1, status: "completed", selection: null, noneReason: "all_stale", promptVersion: getPrompt(PROMPT_TYPE)?.version ?? 1 };
      db.prepare("UPDATE discovery_requests SET status = 'completed', result_meta = ?, updated_at = ? WHERE request_id = ?")
        .run(JSON.stringify(payload), Date.now(), body.requestId);
      return context.json({ ...payload, requestId: body.requestId });
    }

    const route = config.routes[PURPOSE];
    const provider = providers.get(route.provider);
    if (!provider) throw new GatewayError("MODEL_UNAVAILABLE", `Provider unavailable: ${route.provider}`, 503);

    // 上游请求摊平（预算 wrap 层要求 maxTokens/messages 等平铺在请求上，
    // 与旧 callModel 同款；响应格式沿用发现通道 env 口径）。
    const buildMessages = (retryHint) => injectServerPrompt(PURPOSE, [{
      role: "user",
      content: JSON.stringify({
        language: body.language ?? "zh-Hans",
        candidates,
        ...(retryHint ? { retryHint } : {}),
      }),
    }], { language: body.language }).messages;
    const upstreamRequest = {
      purpose: PURPOSE,
      stream: false,
      model: route.model,
      temperature: route.temperature,
      maxTokens: route.maxTokens,
      reasoningEffort: route.reasoningEffort,
      responseFormat: config.discovery?.responseFormat ?? { type: "json_object" },
    };
    const invoke = typeof provider.completeViaStream === "function"
      ? provider.completeViaStream.bind(provider)
      : provider.complete.bind(provider);
    const callUpstream = async (messages) => {
      const result = backgroundCostGuard
        ? await backgroundCostGuard.run(subject, () => invoke({ ...upstreamRequest, messages }))
        : await invoke({ ...upstreamRequest, messages });
      return result?.choices?.[0]?.message?.content ?? "";
    };

    // 格式失败带拒因重试 1 次（qwen 教训：盲重试同错率高，拒因注入促改写）。
    let lastReason = "not_json";
    let accepted = null;
    for (let attempt = 0; attempt < 2 && !accepted; attempt += 1) {
      const messages = attempt === 0
        ? buildMessages(null)
        : buildMessages(`上一次输出被拒，拒因=${lastReason}。请修复后重新输出完整 JSON。`);
      const raw = await callUpstream(messages);
      const parsed = parseModelEnvelope(raw);
      if (!parsed.ok) { lastReason = parsed.reason; continue; }
      if (parsed.none) { accepted = { none: true, noneReason: parsed.noneReason }; break; }
      let check = validateSelection(parsed.selection, candidates);
      if (!check.ok) {
        const repaired = repairTemplates(parsed.selection);
        check = validateSelection(repaired, candidates);
        if (check.ok) parsed.selection = repaired;
      }
      if (!check.ok) { lastReason = check.reason; continue; }
      accepted = { none: false, selection: parsed.selection };
    }

    if (!accepted) {
      // 两次都坏：按无合格选题落账（客户端降级本机规则选题），不 5xx——选题失败不阻塞功能。
      const payload = { protocolVersion: 1, status: "completed", selection: null, noneReason: "insufficient_shape", degraded: true, promptVersion: getPrompt(PROMPT_TYPE)?.version ?? 1 };
      db.prepare("UPDATE discovery_requests SET status = 'completed', result_meta = ?, updated_at = ? WHERE request_id = ?")
        .run(JSON.stringify(payload), Date.now(), body.requestId);
      // 日志只记拒因码（零正文纪律）。
      console.log(JSON.stringify({ evt: "topic_selection_degraded", requestId: body.requestId, reason: lastReason }));
      return context.json({ ...payload, requestId: body.requestId });
    }

    const payload = accepted.none
      ? { protocolVersion: 1, status: "completed", selection: null, noneReason: accepted.noneReason, promptVersion: getPrompt(PROMPT_TYPE)?.version ?? 1 }
      : {
          protocolVersion: 1,
          status: "completed",
          selection: {
            observationId: accepted.selection.observationId,
            angle: accepted.selection.angle,
            reasonCode: accepted.selection.reasonCode ?? "relevant_now",
            titleTemplate: accepted.selection.titleTemplate,
            bodyTemplate: accepted.selection.bodyTemplate,
          },
          noneReason: null,
          promptVersion: getPrompt(PROMPT_TYPE)?.version ?? 1,
        };
    db.prepare("UPDATE discovery_requests SET status = 'completed', result_meta = ?, updated_at = ? WHERE request_id = ?")
      .run(JSON.stringify(payload), Date.now(), body.requestId);
    return context.json({ ...payload, requestId: body.requestId });
  }
}
