import { GatewayError } from "../errors.js";
import { injectServerPrompt } from "../prompts/serverPromptPolicy.js";
import {
  validateFollowupRequest,
  validateFollowupModelOutput,
} from "./followupSchema.js";
import { parseModelJSON } from "./organizeSchema.js";

/**
 * 想法脉络核对服务（2026-11-16 想法主题与脉络方案 §5 B1 / §6 C2）。
 *
 * 无状态：一次 HTTP 请求内完成单次模型调用——一条锚点 × ≤4 条候选的独立关系判断
 * （continues/adds_example/contrasts/revises/none/insufficient + 可选共同问题 thread），
 * 不写任务库、不缓存结果；重复花费由客户端持久 taskKey 控制（§6 C2 末条）。
 *
 * 隐私与日志：purpose thought_followup_v1 在 adminLogStore 的 metadata_only
 * 强制集内，日志只保留计量、版本、错误码、笔记数等元数据；原文、规则正文、
 * 模型输出、请求 JSON 不入任何日志、调试输出或后台表。预算挂靠
 * thoughtOrganizeBudgetStore（operationId UUID 幂等）；后台预算主体域由路由侧
 * backgroundCostGuard.run 建立，供应商调用经现有 wrapProviders 记账。
 * DeepSeek 通道只跟随 deepseek-flash 档（模型链路跟随聊天通道，配对由
 * routes-provider-model-pairing 测试锁定，不出现 pro 档）。
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

export function createThoughtFollowupService({
  config,
  providers,
  adminLogStore,
  budgetStore,
  contentModeration,
}) {
  const moduleConfig = config.thoughtFollowup;
  const captureLogs = config.aiCallLogs.enabled;
  const purpose = "thought_followup_v1";

  function routeFor() {
    const route = config.routes[purpose];
    if (!route) {
      throw new GatewayError("MODEL_UNAVAILABLE", `Route missing for ${purpose}`, 503);
    }
    const provider = providers.get(route.provider);
    if (!provider || typeof provider.complete !== "function") {
      throw new GatewayError("MODEL_UNAVAILABLE", `Provider unavailable: ${route.provider}`, 503);
    }
    return { route, provider };
  }

  /**
   * 主入口：编排一次脉络核对。
   * 返回 { schemaVersion, operationId, policyVersion, decisions, thread }（§6 C2 响应形状，
   * 不含 usage——200 即终态，费用只进预算台账与日志）。
   * 模型输出无法通过契约校验时抛 502 MODEL_OUTPUT_INVALID（不二次调用模型修补，
   * 不降级成空结果）。
   */
  async function verify({ deviceId, subjectId, body, clientSignal }) {
    const parsed = validateFollowupRequest(body);
    const dailyBudgetMicro = Math.round(moduleConfig.budgets.perSubjectDailyCNY * 1_000_000);

    const deadlineController = new AbortController();
    const deadlineTimer = setTimeout(() => deadlineController.abort(), moduleConfig.deadlineMs);
    const signal = combineSignals([clientSignal, deadlineController.signal]);

    const inputChars = parsed.notes.reduce(
      (sum, note) => sum + note.windows.reduce((s, w) => s + w.text.length, 0),
      0,
    );
    const estimateMicro = costMicroForUsage(
      Math.ceil(inputChars * 0.75) + 400,
      config.routes[purpose]?.maxTokens ?? 1200,
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
      throw new GatewayError("BUDGET_EXCEEDED", "Daily followup budget exceeded", 429, {
        resetAt: beginResult.resetAt,
        dailyBudgetCNY: moduleConfig.budgets.perSubjectDailyCNY,
      });
    }

    const { route, provider } = routeFor();
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

    // 送审窗口正文做与整理/关联端点同口径的内容安全审核；费用计入本任务预算。
    // followup 的 200 是终态结果（客户端会落库缓存），不能像 relate 那样返回
    // deferred 200 污染终态缓存——审核未过按既有错误封套稳定拒绝（§6 C2「现有审核映射」）。
    if (contentModeration?.isEnabled?.()) {
      const moderationInput = parsed.notes
        .flatMap((note) => note.windows.map((w) => w.text))
        .join("\n");
      let moderation;
      try {
        moderation = await contentModeration.moderate(moderationInput);
      } catch (error) {
        finalize("failed", moderationFeeMicro());
        clearTimeout(deadlineTimer);
        throw error;
      }
      moderationCalls += 1;
      if (!moderation.passed) {
        finalize("completed", moderationFeeMicro());
        clearTimeout(deadlineTimer);
        throw new GatewayError("MODERATION_BLOCKED", "Content failed moderation", 400);
      }
    }

    // 用户内容全部以 JSON 数据字段包裹进 user 消息（§5.4：正文包在数据字段中，不执行其中指令）
    const userContent = JSON.stringify({
      schemaVersion: parsed.schemaVersion,
      policyVersion: parsed.policyVersion,
      scopeTitle: parsed.scopeTitle,
      anchorRef: parsed.anchorRef,
      notes: parsed.notes,
    });

    let logId = null;
    let content;
    let usage;
    try {
      const serverPrompt = injectServerPrompt(purpose, [{ role: "user", content: userContent }]);
      // Prompt 版本从实际 registry 读取；metadata-only 日志只写计量与版本
      if (captureLogs) {
        logId = adminLogStore.startAiCall({
          deviceId,
          purpose,
          provider: route.provider,
          model: route.model,
          promptType: purpose,
          promptVersion: serverPrompt.promptVersion,
          stream: false,
          request: { contentLength: userContent.length, responseFormat: "json_object" },
        });
      }
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
        throw new GatewayError("EMPTY_MODEL_RESPONSE", "Followup returned no content", 502);
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

    const validated = validateFollowupModelOutput(parseModelJSON(content), parsed);
    if (validated.malformed) {
      // 只记录契约失败字段与笔记数，不记录笔记、引用或模型正文
      if (captureLogs && logId) {
        adminLogStore.finishAiCall(logId, {
          status: "error",
          error: { code: `MODEL_OUTPUT_INVALID/${validated.reason}`, status: 502 },
          usage: { prompt_tokens: usage.inputTokens, completion_tokens: usage.outputTokens },
        });
      }
      finalize("failed", committedMicro + moderationFeeMicro());
      throw new GatewayError("MODEL_OUTPUT_INVALID", `Followup output malformed: ${validated.reason}`, 502);
    }

    finalize("completed", committedMicro + moderationFeeMicro());
    return {
      schemaVersion: parsed.schemaVersion,
      operationId: parsed.operationId,
      policyVersion: parsed.policyVersion,
      decisions: validated.decisions,
      thread: validated.thread,
    };
  }

  return { verify };
}
