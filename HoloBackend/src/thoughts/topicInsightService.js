import { GatewayError } from "../errors.js";
import { injectServerPrompt } from "../prompts/serverPromptPolicy.js";
import {
  validateTopicNameRequest,
  validateTopicNameOutput,
  validateTopicSummaryRequest,
  validateTopicSummaryOutput,
} from "./topicInsightSchema.js";
import { parseModelJSON } from "./organizeSchema.js";

/**
 * 想法主题洞察 V3 编排服务（主方案 §4.4 新主题命名 / §4.5 主题摘要）。
 *
 * 两个端点共用同一模块配置与预算池（都是 Phase 5 低频事件）：
 * - topic-name：候选簇 ≤8 条代表想法 → 一个主题名（用户可改名，titleSource=user 后 AI 永不改名）；
 * - topic-summary：主题 ≤12 条代表想法 → 一段摘要 + ≤4 个可溯源的反复观点。
 *
 * 隐私与日志：purpose thought_topic_name_v1 / thought_topic_summary_v1 在
 * adminLogStore 的 metadata_only 强制集内，日志只保留元数据；请求/响应正文
 * 不入任何持久化。预算挂靠 thoughtOrganizeBudgetStore（operationId 幂等），
 * 上限独立（不占对话与整理额度，方案 §21）。
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

export function createThoughtTopicInsightService({
  config,
  providers,
  adminLogStore,
  budgetStore,
  contentModeration,
}) {
  const moduleConfig = config.thoughtTopicInsight;

  function routeFor(purpose) {
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
   * 共用编排：校验 → 预算 → 审核 → 单次模型调用 → 契约校验。
   * kind = "name" | "summary"，各字段差异用 spec 描述。
   */
  async function run({ kind, purpose, deviceId, subjectId, body, clientSignal, parseRequest, validateOutput, userPayload, estimateOutputTokens }) {
    const parsed = parseRequest(body);
    const dailyBudgetMicro = Math.round(moduleConfig.budgets.perSubjectDailyCNY * 1_000_000);

    const deadlineController = new AbortController();
    const deadlineTimer = setTimeout(() => deadlineController.abort(), moduleConfig.deadlineMs);
    const signal = combineSignals([clientSignal, deadlineController.signal]);

    const inputChars = kind === "name"
      ? parsed.representatives.reduce((sum, r) => sum + r.text.length, 0)
      : parsed.topic.title.length + parsed.representatives.reduce((sum, r) => sum + r.text.length, 0);
    const estimateMicro = costMicroForUsage(
      Math.ceil(inputChars * 0.75) + 400,
      estimateOutputTokens,
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
      throw new GatewayError("BUDGET_EXCEEDED", "Daily topic insight budget exceeded", 429, {
        resetAt: beginResult.resetAt,
        dailyBudgetCNY: moduleConfig.budgets.perSubjectDailyCNY,
      });
    }

    const { route, provider } = routeFor(purpose);
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
      const moderationInput = kind === "name"
        ? parsed.representatives.map((r) => r.text).join("\n")
        : `${parsed.topic.title}\n${parsed.representatives.map((r) => r.text).join("\n")}`;
      try {
        const moderation = await contentModeration.moderate(moderationInput);
        moderationCalls += 1;
        if (!moderation.passed) {
          finalize("completed", moderationFeeMicro());
          clearTimeout(deadlineTimer);
          return {
            schemaVersion: 1,
            operationId: parsed.operationId,
            outcome: "deferred",
            reasonCode: "moderation_blocked",
            ...(kind === "name" ? {} : { summary: null, viewpoints: [] }),
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
    const userContent = JSON.stringify(userPayload(parsed));

    const logId = config.aiCallLogs.enabled
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
      if (config.aiCallLogs.enabled && logId) {
        adminLogStore.finishAiCall(logId, {
          status: "success",
          response: { finishReason: result?.choices?.[0]?.finish_reason ?? null },
          usage: result?.usage ?? null,
        });
      }
      if (typeof content !== "string" || content.trim().length === 0) {
        throw new GatewayError("EMPTY_MODEL_RESPONSE", "Topic insight returned no content", 502);
      }
    } catch (error) {
      if (config.aiCallLogs.enabled && logId) {
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

    const validated = validateOutput(parseModelJSON(content), parsed);
    if (validated.malformed) {
      finalize("failed", committedMicro + moderationFeeMicro());
      throw new GatewayError("MODEL_OUTPUT_INVALID", `Topic insight output malformed: ${validated.reason}`, 502);
    }

    finalize("completed", committedMicro + moderationFeeMicro());
    if (kind === "name") {
      return {
        schemaVersion: 1,
        operationId: parsed.operationId,
        name: validated.name,
        usage: usagePayload(),
      };
    }
    return {
      schemaVersion: 1,
      operationId: parsed.operationId,
      summary: validated.summary,
      viewpoints: validated.viewpoints,
      usage: usagePayload(),
    };
  }

  async function nameTopic({ deviceId, subjectId, body, clientSignal }) {
    return run({
      kind: "name",
      purpose: "thought_topic_name_v1",
      deviceId,
      subjectId,
      body,
      clientSignal,
      parseRequest: validateTopicNameRequest,
      validateOutput: validateTopicNameOutput,
      userPayload: (parsed) => ({ representatives: parsed.representatives }),
      estimateOutputTokens: 200,
    });
  }

  async function summarizeTopic({ deviceId, subjectId, body, clientSignal }) {
    return run({
      kind: "summary",
      purpose: "thought_topic_summary_v1",
      deviceId,
      subjectId,
      body,
      clientSignal,
      parseRequest: validateTopicSummaryRequest,
      validateOutput: validateTopicSummaryOutput,
      userPayload: (parsed) => ({
        topic: parsed.topic,
        representatives: parsed.representatives,
      }),
      estimateOutputTokens: 800,
    });
  }

  return { nameTopic, summarizeTopic };
}
