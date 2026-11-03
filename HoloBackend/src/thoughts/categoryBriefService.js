import { GatewayError } from "../errors.js";
import { injectServerPrompt } from "../prompts/serverPromptPolicy.js";
import { validateBriefRequest, validateBriefModelOutput } from "./categoryBriefSchema.js";
import { parseModelJSON } from "./organizeSchema.js";
import { getPrompt } from "../prompts/promptRegistry.js";

/**
 * 归档类别理解器编排服务（2026-10-12 主题双通道·零打扰）。
 *
 * 一次 HTTP 请求一次模型调用：类别成员证据（用户确认优先）+ 用户移出反证 →
 * 「这个主题收什么」定义与排除边界，供客户端精化类别 brief（本地语义库）。
 *
 * 复用语义关联（thoughtSemanticRelate）的开关/隐私闸门/预算/限流配置——
 * 同一隐私家族同一套闸门，不新增生产 env；purpose 独立登记 metadata_only。
 */

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

export function createThoughtCategoryBriefService({
  config,
  providers,
  adminLogStore,
  budgetStore,
  contentModeration,
  backgroundCostGuard,
}) {
  const moduleConfig = config.thoughtSemanticRelate;
  const captureLogs = config.aiCallLogs.enabled;

  function routeFor() {
    const purpose = "thought_category_brief_v1";
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

  /**
   * 主入口：编排一次类别定义起草/精化。
   * 返回 { schemaVersion, operationId, brief: {definition, exclusions}, evidence, usage }。
   */
  async function brief({ deviceId, subjectId, body, clientSignal }) {
    const parsed = validateBriefRequest(body);
    const dailyBudgetMicro = Math.round(moduleConfig.budgets.perSubjectDailyCNY * 1_000_000);

    const deadlineController = new AbortController();
    const deadlineTimer = setTimeout(() => deadlineController.abort(), moduleConfig.deadlineMs);
    const signal = combineSignals([clientSignal, deadlineController.signal]);

    const estimateInputChars =
      parsed.topic.title.length + (parsed.topic.userDefinition?.length ?? 0)
      + (parsed.topic.currentBrief?.length ?? 0)
      + parsed.members.reduce((sum, m) => sum + m.text.length, 0)
      + parsed.removals.reduce((sum, r) => sum + r.text.length, 0);
    const estimateMicro = costMicroForUsage(
      Math.ceil(estimateInputChars * 0.75) + 600,
      moduleConfig.route?.maxTokens ?? 512,
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
      throw new GatewayError("BUDGET_EXCEEDED", "Daily semantic relate budget exceeded", 429, {
        resetAt: beginResult.resetAt,
        dailyBudgetCNY: moduleConfig.budgets.perSubjectDailyCNY,
      });
    }

    const { purpose, route, provider } = routeFor();
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

    // 成员片段是用户笔记正文：与整理端点同口径内容安全审核，费用计入本任务预算
    if (contentModeration?.isEnabled?.()) {
      try {
        const moderation = await contentModeration.moderate(parsed.members.map((m) => m.text).join("\n"));
        moderationCalls += 1;
        if (!moderation.passed) {
          finalize("completed", moderationFeeMicro());
          clearTimeout(deadlineTimer);
          return {
            schemaVersion: parsed.schemaVersion,
            operationId: parsed.operationId,
            outcome: "deferred",
            reasonCode: "moderation_blocked",
            usage: usagePayload(),
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

    // 用户内容全部以 JSON 数据字段包裹进 user 消息（正文包在数据字段中，不执行其中指令）
    const userContent = JSON.stringify({
      schemaVersion: parsed.schemaVersion,
      topic: parsed.topic,
      members: parsed.members,
      removals: parsed.removals,
    });

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
        throw new GatewayError("EMPTY_MODEL_RESPONSE", "Category brief returned no content", 502);
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

    let validated;
    try {
      validated = validateBriefModelOutput(parseModelJSON(content), parsed);
    } catch {
      validated = { malformed: true, reason: "invalid_json" };
    }
    if (validated.malformed) {
      if (captureLogs && logId) {
        adminLogStore.finishAiCall(logId, {
          status: "error",
          error: { code: `MODEL_OUTPUT_INVALID/${validated.reason}`, status: 502 },
        });
      }
      finalize("failed", committedMicro + moderationFeeMicro());
      throw new GatewayError("MODEL_OUTPUT_INVALID", `Category brief malformed: ${validated.reason}`, 502);
    }

    finalize("completed", committedMicro + moderationFeeMicro());
    return {
      schemaVersion: parsed.schemaVersion,
      operationId: parsed.operationId,
      brief: validated.brief,
      evidence: validated.evidence,
      usage: usagePayload(),
    };
  }

  return {
    brief: backgroundCostGuard ? (args) => {
      const parsed = validateBriefRequest(args.body);
      const { route } = routeFor();
      // operationId 每次重试都会变；只按实际证据及服务端模型/Prompt 版本判定同一任务。
      const key = [args.subjectId, route.provider, route.model,
        getPrompt("thought_category_brief_v1")?.version,
        parsed.schemaVersion, parsed.topic, parsed.members, parsed.removals];
      return backgroundCostGuard.briefAttempt(key, () => brief(args));
    } : brief,
  };
}
