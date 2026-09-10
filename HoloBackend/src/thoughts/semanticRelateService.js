import { GatewayError } from "../errors.js";
import { injectServerPrompt } from "../prompts/serverPromptPolicy.js";
import { validateRelateRequest, validateRelateModelOutput } from "./semanticRelateSchema.js";
import { parseModelJSON } from "./organizeSchema.js";

/**
 * 想法语义关联 V3 编排服务（主方案 §9.2 步骤 7 / §16.2）。
 *
 * 一次 HTTP 请求内完成单次模型调用：目标想法 + ≤3 个候选 Topic 的最小上下文，
 * 让模型给出离散关系判断与逐字证据；客户端据独立信号决策（§10.1 不信任自报置信度）。
 *
 * 隐私与日志：purpose thought_semantic_relate_v1 在 adminLogStore 的
 * metadata_only 强制集内，日志只保留元数据；请求/响应正文不入任何持久化。
 * 预算挂靠 thoughtOrganizeBudgetStore 记账（operationId 维度幂等），
 * 上限用本模块独立配置（不占对话与整理额度，方案 §21）。
 */

export const THOUGHT_SEMANTIC_RELATE_POLICY_VERSION = "thought_semantic_v3.0";

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

export function createThoughtSemanticRelateService({
  config,
  providers,
  adminLogStore,
  budgetStore,
  contentModeration,
}) {
  const moduleConfig = config.thoughtSemanticRelate;
  const captureLogs = config.aiCallLogs.enabled;

  function routeFor() {
    const purpose = "thought_semantic_relate_v1";
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
   * 主入口：编排一次语义关联判断。
   * 返回 { schemaVersion, operationId, textRevision, decisions, usage }；
   * 模型输出无法通过契约校验时抛 502（不二次调用模型修补）。
   */
  async function relate({ deviceId, subjectId, body, clientSignal }) {
    const parsed = validateRelateRequest(body);
    const dailyBudgetMicro = Math.round(moduleConfig.budgets.perSubjectDailyCNY * 1_000_000);

    const deadlineController = new AbortController();
    const deadlineTimer = setTimeout(() => deadlineController.abort(), moduleConfig.deadlineMs);
    const signal = combineSignals([clientSignal, deadlineController.signal]);

    const estimateInputChars =
      parsed.target.text.length
      + parsed.candidates.reduce((sum, c) => sum + c.title.length + (c.summary?.length ?? 0)
        + c.representatives.reduce((s, r) => s + r.text.length, 0), 0);
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

    // 用户正文做与整理端点同口径的内容安全审核；费用计入本任务预算
    if (contentModeration?.isEnabled?.()) {
      try {
        const moderation = await contentModeration.moderate(parsed.target.text);
        moderationCalls += 1;
        if (!moderation.passed) {
          finalize("completed", moderationFeeMicro());
          clearTimeout(deadlineTimer);
          return {
            schemaVersion: 1,
            operationId: parsed.operationId,
            textRevision: parsed.textRevision,
            decisions: [],
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

    // 用户内容全部以 JSON 数据字段包裹进 user 消息（§5.4：正文包在数据字段中，不执行其中指令）
    const userContent = JSON.stringify({
      target: { ref: parsed.target.ref, text: parsed.target.text },
      candidates: parsed.candidates,
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
        throw new GatewayError("EMPTY_MODEL_RESPONSE", "Relate returned no content", 502);
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
      committedMicro += estimateMicro; // usage 丢失按预留上界计
      finalize("failed", committedMicro + moderationFeeMicro());
      clearTimeout(deadlineTimer);
      throw error;
    }

    clearTimeout(deadlineTimer);
    usageTotal.inputTokens += usage.inputTokens;
    usageTotal.outputTokens += usage.outputTokens;
    committedMicro += costMicroForUsage(usage.inputTokens, usage.outputTokens, moduleConfig.pricing);

    const validated = validateRelateModelOutput(parseModelJSON(content), parsed);
    if (validated.malformed) {
      finalize("failed", committedMicro + moderationFeeMicro());
      throw new GatewayError("MODEL_OUTPUT_INVALID", `Relate output malformed: ${validated.reason}`, 502);
    }

    finalize("completed", committedMicro + moderationFeeMicro());
    return {
      schemaVersion: 1,
      operationId: parsed.operationId,
      textRevision: parsed.textRevision,
      decisions: validated.decisions,
      usage: usagePayload(),
    };
  }

  return { relate };
}
