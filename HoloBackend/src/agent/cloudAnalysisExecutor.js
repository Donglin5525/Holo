/**
 * 云端分析执行器（二期 M2a）
 * 快照齐备（queued）的任务在服务端跑完整 Agent 循环：LLM 多轮（need_tools→工具执行→
 * final_claims）→ 结果密文落库 → complete() 即焚（M1 store 已内置）。
 * - 模型调用复用 agent_loop route/provider 基建；输出校验复用 validateAgentLoopContent。
 * - 工具执行：dynamicPlan 走云端查询引擎（快照数据集）；预取静态块直读。
 * - 调度：单实例进程内 fire-and-forget + 启动扫描 queued 孤儿重跑（LLM 重算是
 *   成本问题不是正确性问题，任务级重跑即幂等）。
 * - 消息结构为协议最小循环（system+question+toolResults 轮）；iOS 端的记忆/策略
 *   增强上下文在 M2b 对齐。
 */

import { injectServerPrompt } from "../prompts/serverPromptPolicy.js";
import { insightMaxTokensFor } from "../config.js";
import { validateAgentLoopContent } from "../agentResponseValidator.js";
import { createCloudAnalysisQueryEngine, buildCloudToolCatalog } from "./cloudAnalysisQueryEngine.js";

const MAX_LLM_ROUNDS = 12;
const MAX_PROVIDER_RETRIES = 3;

/** 与查询引擎同构的 sanitize（metricKey/rows 证据 ID 的规范段）。 */
function sanitizeToken(value) {
  return String(value ?? "").toLowerCase().replace(/[^a-z0-9]/g, "_");
}

/**
 * 冻结回答任务（AnalysisAnswerTaskV1 的服务端归一化，2026-09-19 方案任务2）。
 * 客户端在快照 JSON 顶层附带 answerTask（scenarioID/问题类型/主时间范围等）；
 * 旧客户端不附带时按保守默认任务运行，不破坏旧协议。字段缺省用 unknown/空，
 * 不让模型补猜——任务范围由代码冻结，模型只负责在范围内工作。
 */
function normalizeAnswerTask(snapshot, fallbackQuestion) {
  const raw = snapshot?.answerTask;
  const cutoffISO = snapshot?.generatedAt ?? null;
  const questionKindWhitelist = new Set(["fact", "comparison", "diagnosis", "correlation", "decision", "general"]);
  const task = {
    scenarioID: typeof raw?.scenarioID === "string" && raw.scenarioID ? raw.scenarioID : null,
    userQuestion: typeof raw?.userQuestion === "string" && raw.userQuestion.trim()
      ? raw.userQuestion.trim()
      : fallbackQuestion,
    questionKind: questionKindWhitelist.has(raw?.questionKind) ? raw.questionKind : "general",
    primaryTimeRange: null,
    snapshotCutoffAt: cutoffISO,
    requestedDomains: Array.isArray(raw?.requestedDomains)
      ? raw.requestedDomains.filter((d) => typeof d === "string")
      : [],
    answerChecklist: Array.isArray(raw?.answerChecklist)
      ? raw.answerChecklist.filter((item) => typeof item === "string" && item.trim())
      : [],
  };
  const range = raw?.primaryTimeRange;
  const toMs = (value) => {
    const n = Number(value);
    if (!Number.isFinite(n)) return null;
    if (n >= 1e11) return n;
    if (n >= 1e8) return n * 1000;
    return null;
  };
  const startMs = toMs(range?.start);
  const endMs = toMs(range?.end);
  if (startMs != null && endMs != null && startMs < endMs) {
    task.primaryTimeRange = {
      label: typeof range.label === "string" ? range.label : "分析范围",
      startMs,
      endMs,
    };
  }
  return task;
}

/** 冻结任务段文案（拼进 system prompt）：用户可见问题原样保留，范围/类型/清单
 * 由代码声明，模型不得改写。旧客户端无 answerTask 时退化为最小任务（仅问题+
 * 快照截止），行为与旧版一致。taskType（deep_analysis 等）由代码声明，
 * 供 v23 契约的「深度分析展开豁免」做确定性识别，不靠模型从问句猜。 */
function buildFrozenTaskBlock(task, availableSources, taskType) {
  const fmt = (ms) => new Date(ms).toISOString().slice(0, 16).replace("T", " ");
  const lines = [
    "【本轮冻结任务（系统生成，范围不得改写）】",
    `用户问题（原话）：${task.userQuestion}`,
    `问题类型：${task.questionKind}`,
  ];
  if (taskType) lines.push(`任务类型：${taskType}`);
  if (task.scenarioID) lines.push(`场景：${task.scenarioID}`);
  if (task.primaryTimeRange) {
    lines.push(`主时间范围：${fmt(task.primaryTimeRange.startMs)} 至 ${fmt(task.primaryTimeRange.endMs)}（${task.primaryTimeRange.label}；Unix 秒 ${Math.floor(task.primaryTimeRange.startMs / 1000)}-${Math.floor(task.primaryTimeRange.endMs / 1000)}；dynamicPlan.timeRange 优先引用此范围）`);
  }
  if (task.snapshotCutoffAt) lines.push(`快照截止：${task.snapshotCutoffAt}（历史查询不得越过）`);
  if (task.availableSourcesHint) lines.push(`可用数据源：${task.availableSourcesHint}`);
  else if (availableSources.length > 0) lines.push(`可用数据源：${availableSources.join("、")}`);
  if (task.answerChecklist.length > 0) {
    lines.push(`回答清单（逐项回答，缺证据的项明确说不能判断）：${task.answerChecklist.map((item, i) => `(${i + 1})${item}`).join("；")}`);
  }
  return lines.join("\n");
}

/** 数值一致性核验用的数字提取：忽略个位数与年份（1900-2099），其余须能在
 * 已核验数字集合中找到（±2% 或 ×100/÷100 的百分比换算），否则视为叙事编数。 */
function extractCheckableNumbers(text) {
  const matches = String(text ?? "").match(/\d+(?:\.\d+)?/g) ?? [];
  const numbers = [];
  for (const match of matches) {
    const value = Number(match);
    if (!Number.isFinite(value)) continue;
    if (value < 10) continue;
    const asInt = Math.round(value);
    if (Number.isInteger(value) && asInt >= 1900 && asInt <= 2099 && match.length === 4) continue;
    numbers.push(value);
  }
  return numbers;
}

function numberMatchesAllowed(value, allowed) {
  for (const allowedValue of allowed) {
    if (Math.abs(Math.abs(value) - Math.abs(allowedValue)) <= Math.max(0.05, Math.abs(allowedValue) * 0.02)) return true;
    if (Math.abs(value * 100 - allowedValue) <= Math.max(0.05, Math.abs(allowedValue) * 0.02)) return true;
    if (Math.abs(value - allowedValue * 100) <= Math.max(0.05, Math.abs(allowedValue) * 0.02)) return true;
  }
  return false;
}

/**
 * 交付核验（2026-09-19 方案任务1 §3.4）：final_claims 落库/提交额度/推送「完成」
 * 之前的云端专用闸门。「JSON 合法」不等于「可交付」：
 * - 空 claims 不允许完成（可解释缺口必须以 claim 形式说出，或走诚实失败）；
 * - 每条数字断言必须与本次工具 Ledger 一致（metricKey 存在 + 数值对上），
 *   对不上的断言降级剥离并记 warning，不回退为「整个证据池都当依据」；
 * - 引用不存在的 evidence ID 直接剥离；
 * - title/narrativeSummary/keyInsight 出现 Ledger 与 claims 都不支持的数字时清空
 *   该叙事字段（iOS 端有 claims 拼接回退，不丢事实）。
 * 返回 { claims, warnings, title, narrativeSummary, keyInsight, emptyClaims }。
 */
function verifyDelivery(output, { metricLedger, validEvidenceIDs }) {
  const warnings = [];
  const ledgerHasMetrics = metricLedger.size > 0;
  // 同 metricKey 可能对应多个分组（中文分组 sanitize 撞名），断言与任一分组值对上即通过
  const ledgerByMetricKey = new Map();
  for (const entry of metricLedger.values()) {
    if (!ledgerByMetricKey.has(entry.metricKey)) ledgerByMetricKey.set(entry.metricKey, []);
    ledgerByMetricKey.get(entry.metricKey).push(entry);
  }
  const claims = [];
  // claimTitle（v23 点破式标题）数字核验的白名单底座：Ledger 已核验值 +
  // 本条 claim 正文/断言的数字。claimTitle 自身不进白名单（自证无核验意义）。
  const ledgerNumbers = [];
  for (const metric of metricLedger.values()) {
    ledgerNumbers.push(metric.value);
    if (metric.baselineValue != null) ledgerNumbers.push(metric.baselineValue);
  }
  for (const claim of output.claims ?? []) {
    const sanitized = { ...claim };
    // 数字断言逐条对账
    const keptAssertions = [];
    for (const assertion of sanitized.metricAssertions ?? []) {
      const candidates = ledgerByMetricKey.get(assertion.metricKey) ?? [];
      if (candidates.length === 0) {
        warnings.push(`METRIC_UNKNOWN:${assertion.metricKey}`);
        continue;
      }
      const valueOk = assertion.value == null
        || candidates.some((c) => Math.abs(assertion.value - c.value) <= Math.max(0.05, Math.abs(c.value) * 0.02));
      const baselineOk = assertion.baselineValue == null
        || candidates.some((c) => c.baselineValue == null
          || Math.abs(assertion.baselineValue - c.baselineValue) <= Math.max(0.05, Math.abs(c.baselineValue) * 0.02));
      if (!valueOk || !baselineOk) {
        warnings.push(`METRIC_MISMATCH:${assertion.metricKey}`);
        continue;
      }
      keptAssertions.push(assertion);
    }
    sanitized.metricAssertions = keptAssertions;
    // 引用剥离：不在本轮证据池的 ID 一律剔除
    if (Array.isArray(sanitized.evidenceIDs) && sanitized.evidenceIDs.length > 0) {
      const keptIDs = sanitized.evidenceIDs.filter((id) => validEvidenceIDs.has(id));
      if (keptIDs.length !== sanitized.evidenceIDs.length) {
        warnings.push(`EVIDENCE_DROPPED:${sanitized.id ?? "claim"}`);
      }
      sanitized.evidenceIDs = keptIDs;
    }
    const hasAssertion = (sanitized.metricAssertions ?? []).length > 0;
    const hasEvidence = (sanitized.evidenceIDs ?? []).length > 0;
    const text = `${sanitized.displayText ?? ""}${sanitized.summary ?? ""}`;
    // 已有工具证据的会话里，含数字的 claim 既无断言也无引用 = 未经核验的数字，
    // 剥离（定性 claim 保留）。整场没查到任何指标的会话按降级保留并警告。
    if (ledgerHasMetrics && !hasAssertion && !hasEvidence && extractCheckableNumbers(text).length > 0) {
      warnings.push(`NUMERIC_CLAIM_UNVERIFIED:${sanitized.id ?? "claim"}`);
      continue;
    }
    // claimTitle 数字一致性：标题里出现的数字必须被本条正文/断言或 Ledger 支持，
    // 对不上清空该标题（编数标题宁缺毋滥，iOS 端有短句回退不丢卡）。
    if (typeof sanitized.claimTitle === "string" && sanitized.claimTitle.trim()) {
      const claimAllowed = [...ledgerNumbers, ...extractCheckableNumbers(sanitized.displayText), ...extractCheckableNumbers(sanitized.summary)];
      for (const assertion of sanitized.metricAssertions ?? []) {
        if (assertion.value != null) claimAllowed.push(assertion.value);
        if (assertion.baselineValue != null) claimAllowed.push(assertion.baselineValue);
      }
      const badTitleNumbers = extractCheckableNumbers(sanitized.claimTitle).filter((n) => !numberMatchesAllowed(n, claimAllowed));
      if (badTitleNumbers.length > 0) {
        warnings.push(`CLAIM_TITLE_INCONSISTENT:${sanitized.id ?? "claim"}`);
        sanitized.claimTitle = null;
      }
    }
    claims.push(sanitized);
  }
  if (ledgerHasMetrics === false && claims.length > 0) {
    warnings.push("NO_TOOL_EVIDENCE");
  }

  // 叙事字段数字一致性：只允许出现 claims 文本/断言/Ledger 支持的数字
  const allowedNumbers = [];
  for (const metric of metricLedger.values()) {
    allowedNumbers.push(metric.value);
    if (metric.baselineValue != null) allowedNumbers.push(metric.baselineValue);
  }
  for (const claim of claims) {
    allowedNumbers.push(...extractCheckableNumbers(claim.displayText), ...extractCheckableNumbers(claim.summary));
    for (const assertion of claim.metricAssertions ?? []) {
      if (assertion.value != null) allowedNumbers.push(assertion.value);
      if (assertion.baselineValue != null) allowedNumbers.push(assertion.baselineValue);
    }
  }
  const narrativeFields = ["title", "narrativeSummary", "keyInsight"];
  for (const field of narrativeFields) {
    const text = output[field];
    if (typeof text !== "string" || !text.trim()) continue;
    const badNumbers = extractCheckableNumbers(text).filter((n) => !numberMatchesAllowed(n, allowedNumbers));
    if (badNumbers.length > 0) {
      warnings.push(`NARRATIVE_INCONSISTENT:${field}`);
      output[field] = null;
    }
  }

  return {
    claims,
    warnings: [...new Set(warnings)],
    title: output.title ?? null,
    narrativeSummary: output.narrativeSummary ?? null,
    keyInsight: output.keyInsight ?? null,
    emptyClaims: claims.length === 0,
  };
}

export function createCloudAnalysisExecutor({
  taskStore,
  providers,
  route,
  // 周期回放单轮生成使用的 insight 路由（模型/温度与 Agent 循环不同）；
  // 缺省回落 agent_loop 路由（同 provider 时行为一致）
  insightRoute = null,
  // 回放摘要归纳使用的 replayDigest 路由（2026-09-05 摘要云端化）；
  // 缺省回落 insight 路由再回落 agent_loop 路由
  digestRoute = null,
  // 个人情境规划（context_plan）单轮生成路由（2026-09-09 方案 §5.3）：
  // 与端点层 personal_context_planning 同一模型档位/温度/思考档；缺省回落 agent_loop 路由
  contextPlanRoute = null,
  providerRetries = MAX_PROVIDER_RETRIES,
  maxRounds = MAX_LLM_ROUNDS,
  pushNotifier = null,
  // 周期回放（period_replay）任务的额度台账与权益解析：消耗 memoryInsight 池，
  // 预订-提交语义（生成失败自动释放），与端点层同一套真相源。
  quotaLedger = null,
  entitlementResolver = null,
  // token 用量记账（adminLogStore 同接口）：云端任务的 AI 调用此前完全不入
  // ai_call_logs，成本核算存在盲区。purpose 用 cloud_* 前缀与端点侧调用区分。
  aiCallLogger = null,
  log = (...args) => console.log("[cloud-analysis]", ...args),
} = {}) {
  const engine = createCloudAnalysisQueryEngine();
  const provider = providers.get(route.provider);
  if (!provider) {
    throw new Error(`CLOUD_ANALYSIS_PROVIDER_MISSING: ${route.provider}`);
  }

  // 工具结果统一为 iOS HoloDataToolResult 同构信封（错误也走 error 字段），
  // 模型按提示词约定解析，不出现自造结构。
  // 工具参数行为日志（2026-09-21 时间过滤静默失效事故补件）：故障时只有参数
  // 摘要才有第一手证据（当轮 ai_call_logs 不存请求体、任务内容端到端加密）。
  // 隐私边界：只记结构与时间值原样，filters 只记字段名+操作符，不记筛选值
  // （value 可能含「猫砂」等用户数据关键词）。
  function describeToolRequest(request) {
    const plan = request.dynamicPlan ?? request.parameters?.dynamicPlan;
    if (plan) {
      const aggs = (plan.aggregations ?? []).map((a) => a.operation).join("/") || "-";
      const filters = (plan.filters ?? []).map((f) => `${f.field}:${f.operation}`).join(",") || "-";
      const raw = (value) => { try { return JSON.stringify(value) ?? "-"; } catch { return "-"; } };
      return `source=${plan.source} aggs=${aggs} filters=${filters} timeRange=${raw(plan.timeRange)} baseline=${raw(plan.baseline)}`;
    }
    if (request.tool === "snapshot_rows") {
      const params = request.parameters ?? {};
      // parameters 非 dynamicPlan 的值经 validateAgentLoopContent 规范化全是字符串
      // （与引擎 normalizeRowsPlan 同一协议），filters 到此已是 JSON 字符串
      let rawFilters = params.filters;
      if (typeof rawFilters === "string") {
        try { rawFilters = JSON.parse(rawFilters); } catch { rawFilters = []; }
      }
      const filters = (Array.isArray(rawFilters) ? rawFilters : [])
        .map((f) => `${f.field}:${f.operation}`).join(",") || "-";
      return `source=${params.source} filters=${filters} sortBy=${params.sortBy ?? "-"} limit=${params.limit ?? "-"}`;
    }
    return `query=${request.query ?? "-"}`;
  }

  function executeToolRequests(toolRequests, snapshot, logContext = null) {
    return toolRequests.map((request) => {
      const id = request.id ?? "tool";
      const tool = request.tool;
      log(`工具参数 taskId=${logContext?.taskId ?? "-"} round=${logContext?.round ?? "-"} tool=${tool} ${describeToolRequest(request)}`);
      const envelope = (fields) => ({ toolRequestID: id, tool, coverage: null, warnings: [], ...fields });
      try {
        if (tool === "snapshot_rows") {
          // 行明细取样：parameters 整体即取样计划（source/filters/sortBy/sortDirection/limit）
          return engine.sampleRows(request.parameters ?? {}, snapshot, { toolRequestID: id, tool });
        }
        // validateAgentLoopContent 会把 parameters.dynamicPlan 规范化提升到请求顶层；两种位置都接受
        const plan = request.dynamicPlan ?? request.parameters?.dynamicPlan;
        if (plan) {
          return engine.execute(plan, snapshot, { toolRequestID: id, tool });
        }
        const statics = snapshot?.statics ?? {};
        if (Object.prototype.hasOwnProperty.call(statics, tool)) {
          return envelope({ status: "success", metrics: [], events: [], result: statics[tool] });
        }
        if (request.query === "dynamic_query") {
          return envelope({
            status: "error",
            metrics: [],
            events: [],
            error: { code: "INVALID_PLAN", message: "dynamic_query 缺少 dynamicPlan", recoverable: true },
          });
        }
        return envelope({
          status: "error",
          metrics: [],
          events: [],
          error: {
            code: "NOT_SUPPORTED_BY_CLOUD",
            message: `固定 query「${request.query}」未在快照中预取；请改用 dynamic_query+dynamicPlan，或使用静态块 ${Object.keys(statics).join("、 ") || "（无）"}`,
            recoverable: true,
          },
        });
      } catch (error) {
        return envelope({
          status: "error",
          metrics: [],
          events: [],
          error: { code: "TOOL_ERROR", message: String(error?.message ?? error), recoverable: true },
        });
      }
    });
  }

  async function callProvider(messages, forRoute = route, logContext = null) {
    let lastError = null;
    const upstreamRoute = forRoute ?? route;
    // 每次调用一条 ai_call_logs：重试只记最终成功/失败一次，usage 取自成功响应
    const logId = aiCallLogger && logContext
      ? aiCallLogger.startAiCall({
          deviceId: logContext.deviceId,
          purpose: logContext.purpose,
          provider: upstreamRoute.provider,
          model: upstreamRoute.model,
          stream: false,
          request: {
            taskId: logContext.taskId ?? null,
            round: logContext.round ?? null,
            messageCount: messages.length,
          },
        })
      : null;
    try {
      for (let attempt = 1; attempt <= providerRetries; attempt += 1) {
        try {
          const upstream = {
            purpose: "agent_loop",
            messages,
            stream: false,
            model: upstreamRoute.model,
            temperature: upstreamRoute.temperature,
            maxTokens: upstreamRoute.maxTokens,
            reasoningEffort: upstreamRoute.reasoningEffort,
          };
          const response = await provider.complete(upstream);
          if (logId) {
            aiCallLogger.finishAiCall(logId, {
              status: "success",
              response: null,
              usage: response?.usage ?? null,
            });
          }
          return response;
        } catch (error) {
          lastError = error;
          log(`provider 调用失败 attempt=${attempt}: ${error?.message ?? error}`);
          await new Promise((resolve) => setTimeout(resolve, 1000 * attempt));
        }
      }
      throw lastError ?? new Error("PROVIDER_FAILED");
    } catch (error) {
      if (logId) {
        aiCallLogger.finishAiCall(logId, {
          status: "error",
          response: null,
          error: { code: error?.code ?? "UPSTREAM_ERROR", message: String(error?.message ?? error) },
        });
      }
      throw error;
    }
  }

  /** 完成推送（fire-and-forget）：文案随任务类型；失败只记日志不影响任务终态。 */
  function pushTaskCompleted(deviceId, { title, body }) {
    if (!pushNotifier) return;
    pushNotifier.notifyTaskCompleted(deviceId, { title, body }).catch((error) => {
      log(`完成推送发送失败: ${error?.message ?? error}`);
    });
  }

  /**
   * 周期回放（period_replay）：单轮生成。
   * - 素材 = iOS 聚合的回放上下文 JSON（复用快照密文列，含健康摘要——2026-09-01
   *   东林拍板方案 C：健康数据允许随回放任务上云，即焚语义不变）
   * - 生成走 insight 服务端提示词（与端点层 memory_insight_generation 同一模板）
   * - 额度消耗 memoryInsight 池：预订-提交，失败自动释放
   * - 结果只轻校验（非空文本），MemoryInsight 完整 schema 校验以 iOS 解析器为真相源
   */
  async function runPeriodReplay(taskId, task) {
    const contextJSON = typeof task.snapshot === "string" ? task.snapshot.trim() : "";
    if (!contextJSON) {
      taskStore.fail({ id: taskId, reason: "回放素材缺失或为空" });
      return "failed";
    }
    if (!taskStore.transition(taskId, "running")) {
      return taskStore.get(taskId)?.status ?? "conflict";
    }

    let reservation = null;
    if (quotaLedger && entitlementResolver) {
      const entitlement = entitlementResolver.resolve(task.device_id);
      const attempt = quotaLedger.reserve({
        subjectId: entitlement.usageSubjectId,
        tier: entitlement.tier,
        quotaType: "memoryInsight",
        actionId: `cloud-period-replay-${taskId}`,
      });
      if (!attempt.allowed) {
        taskStore.fail({ id: taskId, reason: attempt.userMessage ?? "洞察额度已用完" });
        return "failed";
      }
      reservation = attempt;
    }

    try {
      // 取消检查点：取消即整行删除（cancel 是 DELETE），行已不存在就不再调用模型
      if (!taskStore.get(taskId)) {
        if (reservation) quotaLedger.release(reservation);
        log(`回放任务已取消（行已删除），停止执行 taskId=${taskId}`);
        return "cancelled";
      }
      const systemPrompted = injectServerPrompt("insight", [
        { role: "user", content: contextJSON },
      ]);
      // 输出预算按周期档位分档（口径见 config.insightMaxTokensFor）：
      // 素材里的 periodType 是分档依据（快照由 iOS 组装，字段可信）。
      let periodType = null;
      try {
        periodType = JSON.parse(contextJSON)?.periodType ?? null;
      } catch {
        periodType = null;
      }
      const replayRoute = insightRoute ?? route;
      const replayCallRoute = {
        ...replayRoute,
        maxTokens: insightMaxTokensFor(periodType, replayRoute.maxTokens),
      };
      const response = await callProvider(
        [
          { role: "system", content: systemPrompted.messages[0]?.content ?? "" },
          { role: "user", content: contextJSON },
        ],
        replayCallRoute,
        { taskId, deviceId: task.device_id, purpose: "cloud_period_replay", round: 1 },
      );
      const content = response?.choices?.[0]?.message?.content ?? "";
      if (!content.trim()) {
        throw new Error("回放生成为空输出");
      }
      const result = {
        kind: "period_replay",
        output: content,
        completedAt: new Date().toISOString(),
        engine: "cloud-m2a-replay",
      };
      const completed = taskStore.complete({ id: taskId, result: JSON.stringify(result) });
      if (!completed) {
        // 行已在执行中被取消/删除：结果无处落地，不提交额度、不发推送
        if (reservation) quotaLedger.release(reservation);
        log(`回放任务已取消（落库未生效）taskId=${taskId}`);
        return "cancelled";
      }
      if (reservation) quotaLedger.commit(reservation);
      pushTaskCompleted(task.device_id, { title: "回放已生成", body: "点按查看这段时光的回顾" });
      log(`回放任务完成 taskId=${taskId} chars=${content.length}`);
      return "completed";
    } catch (error) {
      if (reservation) quotaLedger.release(reservation);
      const reason = `云端回放生成失败：${error?.message ?? error}`;
      try {
        taskStore.fail({ id: taskId, reason });
      } catch (failError) {
        log(`fail 落库也失败 taskId=${taskId}: ${failError?.message ?? failError}`);
      }
      log(`回放任务失败 taskId=${taskId}: ${error?.message ?? error}`);
      return "failed";
    }
  }

  /**
   * 个人情境规划（context_plan）：单轮生成（2026-09-09 一致性与可信交互方案 §5.3）。
   * - 素材 = iOS 检索后组装的 planPrompt 全文（复用快照密文列；即焚语义与深度分析一致）
   * - 生成走 personal_context_planning 服务端提示词与路由（与端点层同步调用同一模板、
   *   同一模型档位；结构校验仍以 iOS 端 HoloContextPlanDraftParser/Validator 为真相源）
   * - 额度消耗 chat 池（与同步路径同一池）：预订-提交，失败自动释放
   * - 阶段推进写 stage 列（cloudPlanning→draftReady/failed），revision 服务端单调
   */
  async function runContextPlan(taskId, task) {
    // 快照列是 JSON 对象（上传路由强制），prompt 在 .prompt 字段
    let prompt = "";
    if (typeof task.snapshot === "string") {
      try {
        prompt = String(JSON.parse(task.snapshot)?.prompt ?? "").trim();
      } catch {
        prompt = task.snapshot.trim();
      }
    }
    if (!prompt) {
      log(
        `规划 prompt 为空 taskId=${taskId} snapshotType=${typeof task.snapshot} ` +
        `snapshotLen=${typeof task.snapshot === "string" ? task.snapshot.length : -1} ` +
        `snapshotHead=${typeof task.snapshot === "string" ? task.snapshot.slice(0, 120) : String(task.snapshot)}`
      );
      taskStore.fail({ id: taskId, reason: "规划请求缺失或为空" });
      taskStore.updateStage(taskId, { stage: "failed" });
      return "failed";
    }
    if (!taskStore.transition(taskId, "running")) {
      return taskStore.get(taskId)?.status ?? "conflict";
    }
    taskStore.updateStage(taskId, { stage: "cloudPlanning" });

    let reservation = null;
    if (quotaLedger && entitlementResolver) {
      const entitlement = entitlementResolver.resolve(task.device_id);
      const attempt = quotaLedger.reserve({
        subjectId: entitlement.usageSubjectId,
        tier: entitlement.tier,
        quotaType: "chat",
        actionId: `cloud-context-plan-${taskId}`,
      });
      if (!attempt.allowed) {
        taskStore.fail({ id: taskId, reason: attempt.userMessage ?? "AI 额度已用完" });
        taskStore.updateStage(taskId, { stage: "failed" });
        return "failed";
      }
      reservation = attempt;
    }

    try {
      // 取消检查点：取消即整行删除，行已不存在就不再调用模型
      if (!taskStore.get(taskId)) {
        if (reservation) quotaLedger.release(reservation);
        log(`规划任务已取消（行已删除），停止执行 taskId=${taskId}`);
        return "cancelled";
      }
      const systemPrompted = injectServerPrompt("personal_context_planning", [
        { role: "user", content: prompt },
      ]);
      const response = await callProvider(
        [
          { role: "system", content: systemPrompted.messages[0]?.content ?? "" },
          { role: "user", content: prompt },
        ],
        contextPlanRoute ?? route,
        { taskId, deviceId: task.device_id, purpose: "cloud_context_plan", round: 1 },
      );
      const content = response?.choices?.[0]?.message?.content ?? "";
      if (!content.trim()) {
        throw new Error("规划生成为空输出");
      }
      const result = {
        kind: "context_plan",
        output: content,
        completedAt: new Date().toISOString(),
        engine: "cloud-m2-context-plan",
      };
      const completed = taskStore.complete({ id: taskId, result: JSON.stringify(result) });
      if (!completed) {
        // 行已在执行中被取消/删除：结果无处落地，不提交额度、不发推送
        if (reservation) quotaLedger.release(reservation);
        log(`规划任务已取消（落库未生效）taskId=${taskId}`);
        return "cancelled";
      }
      taskStore.updateStage(taskId, { stage: "draftReady" });
      if (reservation) quotaLedger.commit(reservation);
      pushTaskCompleted(task.device_id, { title: "个性化方案已就绪", body: "回到 Holo 查看你的专属方案" });
      log(`规划任务完成 taskId=${taskId} chars=${content.length}`);
      return "completed";
    } catch (error) {
      if (reservation) quotaLedger.release(reservation);
      const reason = `云端规划生成失败：${error?.message ?? error}`;
      try {
        taskStore.fail({ id: taskId, reason });
        taskStore.updateStage(taskId, { stage: "failed" });
      } catch (failError) {
        log(`fail 落库也失败 taskId=${taskId}: ${failError?.message ?? failError}`);
      }
      log(`规划任务失败 taskId=${taskId}: ${error?.message ?? error}`);
      return "failed";
    }
  }

  /**
   * 回放摘要归纳（replay_digest）：单轮生成（2026-09-05 摘要云端化）。
   * - 素材 = iOS 组装的 ConsolidateRequest JSON（旧累计摘要+本期回放要点），
   *   复用快照密文列，即焚语义与深度分析完全一致
   * - 生成走 replayDigest 服务端提示词与路由（与端点层 direct 调用同一模板、
   *   同一模型档位；成本治理后的 low 思考档在此同样生效）
   * - 不消耗会员额度（与 direct 路径口径一致，仅任务起始限流分桶）；
   *   不打完成推送（后台静默维护，用户无感知）
   * - 结果只轻校验（非空文本）；ReplayDigestAIOutput 的完整解析以 iOS 解析器为真相源
   */
  async function runReplayDigest(taskId, task) {
    const material = typeof task.snapshot === "string" ? task.snapshot.trim() : "";
    if (!material) {
      taskStore.fail({ id: taskId, reason: "摘要素材缺失或为空" });
      return "failed";
    }
    if (!taskStore.transition(taskId, "running")) {
      return taskStore.get(taskId)?.status ?? "conflict";
    }

    try {
      const systemPrompted = injectServerPrompt("replayDigest", [
        { role: "user", content: material },
      ]);
      const upstreamRoute = digestRoute ?? insightRoute ?? route;
      const response = await callProvider(
        [
          { role: "system", content: systemPrompted.messages[0]?.content ?? "" },
          { role: "user", content: material },
        ],
        upstreamRoute,
        { taskId, deviceId: task.device_id, purpose: "cloud_replay_digest", round: 1 },
      );
      const content = response?.choices?.[0]?.message?.content ?? "";
      if (!content.trim()) {
        throw new Error("摘要生成为空输出");
      }
      const result = {
        kind: "replay_digest",
        output: content,
        completedAt: new Date().toISOString(),
        engine: "cloud-digest",
      };
      if (!taskStore.complete({ id: taskId, result: JSON.stringify(result) })) {
        log(`摘要任务已取消（落库未生效）taskId=${taskId}`);
        return "cancelled";
      }
      log(`摘要任务完成 taskId=${taskId} chars=${content.length}`);
      return "completed";
    } catch (error) {
      const reason = `云端摘要归纳失败：${error?.message ?? error}`;
      try {
        taskStore.fail({ id: taskId, reason });
      } catch (failError) {
        log(`fail 落库也失败 taskId=${taskId}: ${failError?.message ?? failError}`);
      }
      log(`摘要任务失败 taskId=${taskId}: ${error?.message ?? error}`);
      return "failed";
    }
  }

  /**
   * 执行一个任务（queued → running → completed/failed）。
   * 返回最终状态；所有异常落 fail() 不上抛（fire-and-forget 调用安全）。
   */
  async function run(taskId) {
    let reservation = null;
    try {
      const task = taskStore.getDecrypted(taskId, ["question", "snapshot"]);
      if (!task) {
        log(`任务不存在 taskId=${taskId}`);
        return "missing";
      }
      if (task.status !== "queued") {
        return task.status;
      }
      // 任务类型分发：period_replay = 周期回放单轮生成（素材复用快照密文列，
      // 不走 Agent 循环）；replay_digest = 回放摘要归纳（同单轮范式）；
      // 其余 = 深度分析多轮循环。
      if (task.task_type === "period_replay") {
        return await runPeriodReplay(taskId, task);
      }
      if (task.task_type === "replay_digest") {
        return await runReplayDigest(taskId, task);
      }
      if (task.task_type === "context_plan") {
        return await runContextPlan(taskId, task);
      }
      let snapshot;
      try {
        snapshot = task.snapshot ? JSON.parse(task.snapshot) : null;
      } catch {
        taskStore.fail({ id: taskId, reason: "快照数据损坏（JSON 解析失败）" });
        return "failed";
      }
      if (!snapshot || typeof snapshot !== "object") {
        taskStore.fail({ id: taskId, reason: "快照缺失或格式非法" });
        return "failed";
      }
      if (!taskStore.transition(taskId, "running")) {
        return taskStore.get(taskId)?.status ?? "conflict";
      }

      // 深度分析与本地 agent_loop 同池（deepAnalysis，free 2/天、plus 10/天）：
      // 预订-提交语义，失败/取消自动释放。此前云端轨道完全绕过会员额度池，
      // 免费用户本地被 2 次/天卡死而云端无限放行，属权益旁路。
      if (quotaLedger && entitlementResolver) {
        const entitlement = entitlementResolver.resolve(task.device_id);
        const attempt = quotaLedger.reserve({
          subjectId: entitlement.usageSubjectId,
          tier: entitlement.tier,
          quotaType: "deepAnalysis",
          actionId: `cloud-deep-analysis-${taskId}`,
        });
        if (!attempt.allowed) {
          taskStore.fail({ id: taskId, reason: attempt.userMessage ?? "今日深度分析额度已用完" });
          return "failed";
        }
        reservation = attempt;
      }

      // 冻结回答任务：客户端快照顶层 answerTask（P1 起）或保守默认任务（旧客户端）。
      // 范围/类型/清单由代码声明进 system prompt，模型不得改写——「用户改写问句
      // 仍保留所选场景」与「九月只算九月」的同一真相源。
      const answerTask = normalizeAnswerTask(snapshot, task.question);
      const messages = [];
      const systemPrompted = injectServerPrompt("agent_loop", [
        { role: "user", content: task.question },
      ]);
      const datasetNames = Object.keys(snapshot.datasets ?? {});
      messages.push({
        role: "system",
        content: `${systemPrompted.messages[0]?.content ?? ""}\n\n${buildCloudToolCatalog(snapshot)}\n\n${buildFrozenTaskBlock(answerTask, datasetNames, task.task_type)}`,
      });
      messages.push({ role: "user", content: task.question });

      // 证据池：跨轮次累积模型查得的指标与行样本，final_claims 时随结果回传设备
      // （iOS 端据此渲染「依据」与数据样例；2026-08-31 验收：此前结果只带 claims，
      // 设备端证据区块永远为空）。metric 按 metricKey 去重，rows 按数据集保留最新一次取样。
      // P0 起 metric 记录 baselineValue/comparison，validEvidenceIDs 收集本轮全部
      // canonical 引用（metricKey + 事件 ID + rows 样本 ID），交付核验按它对账。
      const metricEvidence = new Map();
      const rowsEvidence = new Map();
      const validEvidenceIDs = new Set();

      function collectEvidence(toolRequests, toolResults) {
        toolResults.forEach((result, index) => {
          if (result.status !== "success") return;
          for (const metric of result.metrics ?? []) {
            if (!metric?.metricKey) continue;
            // 复合键防中文分组撞名：餐饮/交通等 sanitize 后同为 "__"，按裸 metricKey
            // 去重会把除首组外的分组证据全丢（生产分类多为中文，实锤命中）。
            const poolKey = `${metric.metricKey}|${metric.comparison ?? "all"}`;
            if (metricEvidence.has(poolKey)) continue;
            metricEvidence.set(poolKey, {
              kind: "metric",
              metricKey: metric.metricKey,
              dataset: metric.dataset ?? null,
              group: metric.comparison ?? null,
              value: metric.value,
              unit: metric.unit ?? null,
              baselineValue: metric.baselineValue ?? null,
              formula: metric.formula ?? null,
              sourceCount: Array.isArray(metric.sourceRecordIDs) ? metric.sourceRecordIDs.length : 0,
            });
            validEvidenceIDs.add(metric.metricKey);
            validEvidenceIDs.add(`dynamic-${metric.metricKey}`);
          }
          for (const event of result.events ?? []) {
            if (typeof event?.id === "string" && event.id) validEvidenceIDs.add(event.id);
          }
          const request = toolRequests[index];
          if (request?.tool === "snapshot_rows" && Array.isArray(result.events)) {
            const dataset = request.parameters?.source ?? null;
            const excerpts = result.events.map((event) => event.excerpt).filter(Boolean);
            if (excerpts.length > 0) {
              rowsEvidence.set(dataset ?? "_", { kind: "rows", dataset, count: excerpts.length, excerpts });
            }
          }
        });
      }

      function evidenceSnapshot() {
        const metrics = [...metricEvidence.values()].slice(-16);
        const rows = [...rowsEvidence.values()].slice(-4);
        return [...metrics, ...rows];
      }

      // 交付核验只给一次修复轮：第一次 final_claims 不过核验时把具体问题喂回
      // 模型重发；第二次仍空 claims 则诚实失败（不包装成普通完成）。
      let deliveryRepairUsed = false;

      for (let round = 1; round <= maxRounds; round += 1) {
        // 取消检查点：取消即整行删除（cancel 是 DELETE），每轮调用模型前查一次，
        // 防止取消后继续白烧剩余轮次（此前最多 12 轮 × 每轮 3 次重试照跑不误）。
        if (!taskStore.get(taskId)) {
          if (reservation) quotaLedger.release(reservation);
          log(`任务已取消（行已删除），停止执行 taskId=${taskId} round=${round}`);
          return "cancelled";
        }
        const response = await callProvider(messages, route, {
          taskId,
          deviceId: task.device_id,
          purpose: "cloud_deep_analysis",
          round,
        });
        const content = response?.choices?.[0]?.message?.content ?? "";
        const validation = validateAgentLoopContent(content);
        if (!validation.valid) {
          // 契约故障按一轮消耗处理后继续（与网关侧同策略：不提前终止任务）
          log(`轮次 ${round}/${maxRounds} taskId=${taskId} status=invalid_json（已请求重发）`);
          messages.push({ role: "assistant", content });
          messages.push({
            role: "user",
            content: "上一轮输出未通过协议校验，请丢弃坏结构并重新输出完整 JSON（status 只能是 need_tools/need_more_analysis/final_claims）。",
          });
          continue;
        }
        let output;
        try {
          output = JSON.parse(validation.content);
        } catch {
          if (reservation) quotaLedger.release(reservation);
          taskStore.fail({ id: taskId, reason: "模型输出解析失败" });
          return "failed";
        }
        messages.push({ role: "assistant", content: validation.content });

        const requestedTools = (Array.isArray(output.toolRequests) ? output.toolRequests : [])
          .map((r) => `${r.tool}${r.query ? `:${r.query}` : ""}${(r.dynamicPlan ?? r.parameters?.dynamicPlan)?.source ? `(${(r.dynamicPlan ?? r.parameters?.dynamicPlan).source})` : ""}`)
          .join(",");
        log(`轮次 ${round}/${maxRounds} taskId=${taskId} status=${output.status} claims=${(output.claims ?? []).length}${requestedTools ? ` tools=${requestedTools}` : ""}`);

        if (output.status === "final_claims") {
          // 交付核验（§3.4）：空 claims 不允许完成；数字断言/引用对不上 Ledger 的
          // 降级剥离并记 warning；叙事字段编数清空。「JSON 合法」不等于「可交付」。
          const verified = verifyDelivery(output, {
            metricLedger: metricEvidence,
            validEvidenceIDs,
          });
          if (verified.emptyClaims && !deliveryRepairUsed) {
            deliveryRepairUsed = true;
            log(`轮次 ${round}/${maxRounds} taskId=${taskId} 交付核验不过（空 claims），请求重发`);
            messages.push({ role: "assistant", content: validation.content });
            messages.push({
              role: "user",
              content: "final_claims 不允许为空：请基于已查到的证据输出至少一条 claim 直接回答用户问题；关键证据不存在时，输出一条说明「缺什么数据、因此哪部分不能判断」的 observation claim，而不是空数组。",
            });
            continue;
          }
          if (verified.emptyClaims) {
            if (reservation) quotaLedger.release(reservation);
            taskStore.fail({ id: taskId, reason: "模型未能产出可核验的结论（无 claim），请换个问法或稍后重试" });
            return "failed";
          }
          const result = {
            title: verified.title,
            // v17/v21 叙事字段（温暖陪伴 P0 契约止损）：Validator 已规范化门控，
            // 此前落库丢弃导致设备端只能拼「发现 N/分号」——温度在这层丢失。
            // 交付核验只清空与 Ledger 冲突的编数字段，不另造叙事。
            narrativeSummary: verified.narrativeSummary,
            keyInsight: verified.keyInsight,
            claims: verified.claims,
            reasoning: output.reasoning ?? "",
            evidence: evidenceSnapshot(),
            warnings: verified.warnings,
            snapshotCutoffAt: answerTask.snapshotCutoffAt,
            taskRange: answerTask.primaryTimeRange
              ? {
                label: answerTask.primaryTimeRange.label,
                start: Math.floor(answerTask.primaryTimeRange.startMs / 1000),
                end: Math.floor(answerTask.primaryTimeRange.endMs / 1000),
              }
              : null,
            completedAt: new Date().toISOString(),
            engine: "cloud-m2a",
          };
          const completed = taskStore.complete({ id: taskId, result: JSON.stringify(result) });
          if (!completed) {
            // 行已在执行中被取消/删除：结果无处落地，不提交额度、不发推送
            if (reservation) quotaLedger.release(reservation);
            log(`任务完成落库未生效（已被取消或删除）taskId=${taskId}`);
            return "cancelled";
          }
          if (reservation) quotaLedger.commit(reservation);
          pushTaskCompleted(task.device_id, { title: "深度分析完成", body: "结果已就绪，点按查看" });
          log(`任务完成 taskId=${taskId} rounds=${round} claims=${result.claims.length} evidence=${result.evidence.length}${verified.warnings.length ? ` warnings=${verified.warnings.join(",")}` : ""}`);
          return "completed";
        }

        const toolRequests = Array.isArray(output.toolRequests) ? output.toolRequests : [];
        if (toolRequests.length > 0) {
          const toolResults = executeToolRequests(toolRequests, snapshot, { taskId, round });
          collectEvidence(toolRequests, toolResults);
          const failures = toolResults
            .filter((r) => r.status === "error")
            .map((r) => `${r.tool}:${r.error?.code}`);
          if (failures.length > 0) {
            log(`工具失败 taskId=${taskId} round=${round}: ${failures.join(" | ").slice(0, 400)}`);
          }
          messages.push({
            role: "user",
            content: `toolResults: ${JSON.stringify(toolResults)}`,
          });
        } else {
          messages.push({
            role: "user",
            content: "继续（need_more_analysis 已收到，请基于现有证据推进或给出 final_claims）。",
          });
        }
      }
      if (reservation) quotaLedger.release(reservation);
      taskStore.fail({ id: taskId, reason: `超过最大轮次（${maxRounds}）未能形成最终结论` });
      return "failed";
    } catch (error) {
      if (reservation) quotaLedger.release(reservation);
      const reason = error?.message ?? String(error);
      try {
        taskStore.fail({ id: taskId, reason: `云端执行失败：${reason}` });
      } catch (failError) {
        log(`fail 落库也失败 taskId=${taskId}: ${failError?.message ?? failError}`);
      }
      log(`任务失败 taskId=${taskId}: ${reason}`);
      return "failed";
    }
  }

  return { run };
}
