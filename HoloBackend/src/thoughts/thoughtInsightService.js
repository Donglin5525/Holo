import { GatewayError } from "../errors.js";
import { injectServerPrompt } from "../prompts/serverPromptPolicy.js";
import { parseModelJSON } from "./organizeSchema.js";

/**
 * 想法按需洞察服务（2026-09-24 方案 §5.1「帮我想想」）。
 *
 * 用户主动触发：单条笔记原文 → 具体问题/另一种思路/下一步探索建议。
 * 回答结构化区分「原文观察（observations.quote 须贴原文）」与「AI 推测（perspectives）」，
 * 客户端逐条回源展示。
 *
 * 隐私与日志：purpose thought_insight_v1 走 adminLogStore metadata-only 集，
 * 请求/响应正文不入任何持久化；预算挂 thoughtOrganizeBudgetStore 记账，
 * 上限用本模块独立配置（不占对话与整理额度）。
 */

export const THOUGHT_INSIGHT_POLICY_VERSION = "thought_insight_v1";

function combineSignals(signals) {
  const controller = new AbortController();
  for (const signal of signals) {
    if (!signal) continue;
    if (signal.aborted) {
      controller.abort();
      break;
    }
    signal.addEventListener("abort", () => controller.abort(), { once: true });
  }
  return controller.signal;
}

function normalizeUpstreamUsage(usage) {
  const input = Number(usage?.prompt_tokens);
  const output = Number(usage?.completion_tokens);
  return {
    inputTokens: Number.isFinite(input) ? input : 0,
    outputTokens: Number.isFinite(output) ? output : 0,
  };
}

function costMicroForUsage(inputTokens, outputTokens, pricing) {
  return Math.round(
    inputTokens * pricing.inputPerMillionCNY + outputTokens * pricing.outputPerMillionCNY,
  );
}

function validateInsightRequest(body) {
  if (!body || typeof body !== "object") {
    throw new GatewayError("INVALID_REQUEST", "Body must be a JSON object", 400);
  }
  const { schemaVersion, operationId, textRevision, text } = body;
  if (schemaVersion !== 1) {
    throw new GatewayError("INVALID_REQUEST", "Unsupported schemaVersion", 400);
  }
  if (typeof operationId !== "string" || operationId.length < 8) {
    throw new GatewayError("INVALID_REQUEST", "operationId required", 400);
  }
  if (typeof textRevision !== "string" || textRevision.length === 0) {
    throw new GatewayError("INVALID_REQUEST", "textRevision required", 400);
  }
  if (typeof text !== "string" || text.trim().length === 0) {
    throw new GatewayError("INVALID_REQUEST", "text required", 400);
  }
  if (text.length > 8_000) {
    throw new GatewayError("INPUT_TOO_LARGE", "text exceeds 8000 chars", 413);
  }
  return { schemaVersion: 1, operationId, textRevision, text: text.slice(0, 8_000) };
}

function validateInsightModelOutput(parsed, request) {
  if (!parsed || typeof parsed !== "object") return { malformed: true, reason: "not_object" };
  const observations = Array.isArray(parsed.observations) ? parsed.observations : [];
  const perspectives = Array.isArray(parsed.perspectives) ? parsed.perspectives : [];
  const cleanObservations = observations
    .filter((o) => o && typeof o === "object")
    .map((o) => ({
      quote: typeof o.quote === "string" ? o.quote.slice(0, 200) : "",
      note: typeof o.note === "string" ? o.note.slice(0, 300) : "",
    }))
    .slice(0, 3);
  const cleanPerspectives = perspectives
    .filter((p) => typeof p === "string" && p.trim().length > 0)
    .map((p) => p.slice(0, 500))
    .slice(0, 3);
  // observations 的 quote 必须贴原文（子串判定，容忍空白差异）；
  // 不贴原文的观察丢弃而不是整体失败（推测部分不受影响）
  const flatText = request.text.replace(/\s+/g, "");
  const verbatimObservations = cleanObservations.filter((o) => {
    if (!o.quote) return false;
    return flatText.includes(o.quote.replace(/\s+/g, ""));
  });
  if (cleanPerspectives.length === 0 && verbatimObservations.length === 0) {
    return { malformed: true, reason: "empty_output" };
  }
  const nextStep = typeof parsed.nextStep === "string" && parsed.nextStep.trim().length > 0
    ? parsed.nextStep.slice(0, 200)
    : null;
  return {
    malformed: false,
    output: { observations: verbatimObservations, perspectives: cleanPerspectives, nextStep },
  };
}

export function createThoughtInsightService({
  config,
  providers,
  adminLogStore,
  budgetStore,
  contentModeration,
}) {
  const moduleConfig = config.thoughtInsight;
  const captureLogs = config.aiCallLogs.enabled;

  function routeFor() {
    const purpose = "thought_insight_v1";
    const route = config.routes[purpose];
    if (!route) {
      throw new GatewayError("MODEL_UNAVAILABLE", `Route missing for ${purpose}`, 503);
    }
    const provider = providers.get(route.provider);
    if (!provider || typeof provider.complete !== "function") {
      throw new GatewayError("MODEL_UNAVAILABLE", `Provider unavailable: ${route.provider}`, 503);
    }
    return { purpose, route, provider };
  }

  /** 主入口：一次「帮我想想」。 */
  async function insight({ deviceId, subjectId, body, clientSignal }) {
    const parsed = validateInsightRequest(body);
    const dailyBudgetMicro = Math.round(moduleConfig.budgets.perSubjectDailyCNY * 1_000_000);

    const deadlineController = new AbortController();
    const deadlineTimer = setTimeout(() => deadlineController.abort(), moduleConfig.deadlineMs);
    const signal = combineSignals([clientSignal, deadlineController.signal]);

    const { purpose, route, provider } = routeFor();
    const estimateMicro = costMicroForUsage(
      Math.ceil(parsed.text.length * 0.75) + 600,
      route.maxTokens ?? 900,
      moduleConfig.pricing,
    );

    const beginResult = budgetStore.beginOperation({
      subjectId,
      operationId: parsed.operationId,
      estimateMicro,
      dailyBudgetMicro,
    });
    if (!beginResult.allowed) {
      clearTimeout(deadlineTimer);
      if (beginResult.reason === "in_progress") {
        throw new GatewayError("OPERATION_IN_PROGRESS", "This operation is already running", 409);
      }
      throw new GatewayError("BUDGET_EXCEEDED", "Daily thought insight budget exceeded", 429, {
        resetAt: beginResult.resetAt,
        dailyBudgetCNY: moduleConfig.budgets.perSubjectDailyCNY,
      });
    }

    const finalize = (status, actualMicro) => {
      budgetStore.settleOperation({
        operationId: parsed.operationId,
        estimateMicro,
        actualMicro: actualMicro ?? estimateMicro,
        status,
      });
    };

    const usageTotal = { inputTokens: 0, outputTokens: 0 };
    let committedMicro = 0;
    let moderationCalls = 0;
    const moderationFeeMicro = () =>
      moderationCalls * Math.round(moduleConfig.budgets.moderationPerCallCNY * 1_000_000);

    if (contentModeration?.isEnabled?.()) {
      try {
        const moderation = await contentModeration.moderate(parsed.text);
        moderationCalls += 1;
        if (!moderation.passed) {
          finalize("completed", moderationFeeMicro());
          clearTimeout(deadlineTimer);
          return {
            schemaVersion: 1,
            operationId: parsed.operationId,
            textRevision: parsed.textRevision,
            observations: [],
            perspectives: [],
            nextStep: null,
            outcome: "deferred",
            reasonCode: "moderation_blocked",
          };
        }
      } catch (error) {
        finalize("failed", moderationFeeMicro());
        clearTimeout(deadlineTimer);
        throw error;
      }
    }

    function usagePayload() {
      return {
        inputTokens: usageTotal.inputTokens,
        outputTokens: usageTotal.outputTokens,
        estimatedCostCNY: Number(((committedMicro + moderationFeeMicro()) / 1_000_000).toFixed(6)),
        dailyBudgetCNY: moduleConfig.budgets.perSubjectDailyCNY,
      };
    }

    const userContent = JSON.stringify({ text: parsed.text });

    const logId = captureLogs
      ? adminLogStore.startAiCall({
          deviceId,
          purpose,
          provider: route.provider,
          model: route.model,
          promptType: purpose,
          promptVersion: "v1",
          stream: false,
          request: { contentLength: userContent.length, responseFormat: "json_object" },
        })
      : null;

    let content;
    let usage;
    try {
      const serverPrompt = injectServerPrompt(purpose, [{ role: "user", content: userContent }]);
      const result = await provider.complete({
        purpose,
        messages: serverPrompt.messages,
        stream: false,
        model: route.model,
        temperature: route.temperature,
        maxTokens: route.maxTokens,
        responseFormat: { type: "json_object" },
        reasoningEffort: route.reasoningEffort,
        clientSignal: signal,
      });
      content = result?.choices?.[0]?.message?.content;
      usage = normalizeUpstreamUsage(result?.usage);
      if (captureLogs && logId) {
        adminLogStore.finishAiCall(logId, {
          status: "success",
          response: { finishReason: result?.choices?.[0]?.finish_reason ?? null },
          usage: result?.usage ?? null,
        });
      }
      if (typeof content !== "string" || content.trim().length === 0) {
        throw new GatewayError("EMPTY_MODEL_RESPONSE", "Insight returned no content", 502);
      }
    } catch (error) {
      if (captureLogs && logId) {
        adminLogStore.finishAiCall(logId, {
          status: "error",
          error: error instanceof GatewayError
            ? { code: error.code, status: error.status }
            : { code: "UPSTREAM_ERROR" },
        });
      }
      committedMicro += estimateMicro;
      finalize("failed", committedMicro + moderationFeeMicro());
      clearTimeout(deadlineTimer);
      throw error;
    }

    clearTimeout(deadlineTimer);
    usageTotal.inputTokens += usage.inputTokens;
    usageTotal.outputTokens += usage.outputTokens;
    committedMicro += costMicroForUsage(usage.inputTokens, usage.outputTokens, moduleConfig.pricing);

    const validated = validateInsightModelOutput(parseModelJSON(content), parsed);
    if (validated.malformed) {
      finalize("failed", committedMicro + moderationFeeMicro());
      throw new GatewayError("MODEL_OUTPUT_INVALID", `Insight output malformed: ${validated.reason}`, 502);
    }

    finalize("completed", committedMicro + moderationFeeMicro());
    return {
      schemaVersion: 1,
      operationId: parsed.operationId,
      textRevision: parsed.textRevision,
      ...validated.output,
      usage: usagePayload(),
    };
  }

  return { insight };
}
