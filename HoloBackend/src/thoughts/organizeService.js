import { GatewayError } from "../errors.js";
import { injectServerPrompt } from "../prompts/serverPromptPolicy.js";
import {
  ORGANIZE_LIMITS,
  validateOrganizeRequest,
  validateStageAOutput,
  validateStageBOutput,
  validateRecallOutput,
  parseModelJSON,
  measureCatalogBudgets,
  explicitNameHits,
} from "./organizeSchema.js";

/**
 * 想法自动整理 V2 编排服务（方案 §5 / §6）。
 *
 * 一次 HTTP 请求内完成 A（提取概念）→ 可选 R（目录筛选）→ B（词表对齐）三次
 * 模型调用的编排；所有中间结果只存在于本次请求内存，不写任何持久化任务库。
 *
 * 隐私与日志：三个 stage purpose 均在 adminLogStore 的 metadata_only 强制集内，
 * 日志只保留元数据（见 adminLogStore.js）；本服务不向任何存储写入正文或标签。
 */

export const THOUGHT_INDEX_POLICY_VERSION = "thought_index_v2.1";

const STAGE_PURPOSES = Object.freeze({
  a: "thought_organize_a",
  r: "thought_organize_r",
  b: "thought_organize_b",
});

/** 保守 token 上界估算（中文 1 字 ≈ 1 token 偏贵，0.75 为 DeepSeek 实测折中；宁多预留不超支）。 */
function estimateTokensFromChars(chars) {
  return Math.ceil(chars * 0.75) + 16;
}

/** tokens × 每百万单价(CNY) 恰好等于 micro-CNY。 */
function costMicroForUsage(inputTokens, outputTokens, pricing) {
  const input = Number.isFinite(inputTokens) ? inputTokens : 0;
  const output = Number.isFinite(outputTokens) ? outputTokens : 0;
  return Math.round(input * pricing.inputPerMillionCNY + output * pricing.outputPerMillionCNY);
}

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
    inputTokens: Number.isFinite(input) && input > 0 ? Math.round(input) : 0,
    outputTokens: Number.isFinite(output) && output > 0 ? Math.round(output) : 0,
  };
}

export function createThoughtOrganizeService({
  config,
  providers,
  adminLogStore,
  budgetStore,
  contentModeration,
}) {
  const moduleConfig = config.thoughtOrganize;
  const captureLogs = config.aiCallLogs.enabled;

  function routeFor(stage) {
    const purpose = STAGE_PURPOSES[stage];
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
   * 执行一次模型 stage：注入服务端 prompt → 调 provider → 记录 metadata 日志与 usage。
   * 解析失败/空响应按 502 终止（不允许「再让模型修 JSON」的二次调用）。
   */
  async function runStage(stage, userContent, { deviceId, stageSignal, logMeta }) {
    const { purpose, route, provider } = routeFor(stage);
    const serverPrompt = injectServerPrompt(purpose, [{ role: "user", content: userContent }]);
    const logId = captureLogs
      ? adminLogStore.startAiCall({
          deviceId,
          purpose,
          provider: route.provider,
          model: route.model,
          promptType: serverPrompt.promptType,
          promptVersion: serverPrompt.promptVersion,
          stream: false,
          request: {
            stage,
            contentLength: userContent.length,
            responseFormat: "json_object",
          },
        })
      : null;

    const upstreamRequest = {
      purpose,
      messages: serverPrompt.messages,
      stream: false,
      model: route.model,
      temperature: route.temperature,
      maxTokens: route.maxTokens,
      responseFormat: { type: "json_object" },
      reasoningEffort: route.reasoningEffort,
      clientSignal: stageSignal,
    };

    try {
      const result = await provider.complete(upstreamRequest);
      const content = result?.choices?.[0]?.message?.content;
      const usage = normalizeUpstreamUsage(result?.usage);
      if (captureLogs && logId) {
        adminLogStore.finishAiCall(logId, {
          status: "success",
          response: { ...logMeta, finishReason: result?.choices?.[0]?.finish_reason ?? null },
          usage: result?.usage ?? null,
        });
      }
      if (typeof content !== "string" || content.trim().length === 0) {
        throw new GatewayError("EMPTY_MODEL_RESPONSE", "Stage returned no content", 502);
      }
      return { content, usage };
    } catch (error) {
      if (captureLogs && logId) {
        adminLogStore.finishAiCall(logId, {
          status: "error",
          error: error instanceof GatewayError
            ? { code: error.code, status: error.status }
            : { code: "UPSTREAM_ERROR" },
        });
      }
      throw error;
    }
  }

  function estimateStageMicro(stage, inputChars) {
    const { route } = routeFor(stage);
    return costMicroForUsage(
      estimateTokensFromChars(inputChars) + estimateTokensFromChars(600), // 600：system prompt + JSON 结构开销
      route.maxTokens,
      moduleConfig.pricing,
    );
  }

  /** 审核费按次计入（阿里云文本审核按调用计费，量级 ¥0.0005/次，可 env 调整）。 */
  function moderationCostMicro() {
    return Math.round(moduleConfig.budgets.moderationPerCallCNY * 1_000_000);
  }

  /**
   * 主入口：编排一次整理任务。返回可直接 JSON 化的响应（成功与 deferred 都是 200）。
   * 失败（上游/超时/解析）抛 GatewayError，由路由层转错误响应（不含原文与上游错误详情）。
   */
  async function organize({ deviceId, subjectId, body, clientSignal }) {
    const parsed = validateOrganizeRequest(body);
    const perTaskMaxMicro = Math.round(moduleConfig.budgets.perTaskMaxCNY * 1_000_000);
    const dailyBudgetMicro = Math.round(moduleConfig.budgets.perSubjectDailyCNY * 1_000_000);

    // 总期限：A/R/B 共享一个 60s 截止（不是每阶段各 60s）
    const deadlineController = new AbortController();
    const deadlineTimer = setTimeout(
      () => deadlineController.abort(),
      moduleConfig.deadlineMs,
    );
    const stageSignal = combineSignals([clientSignal, deadlineController.signal]);

    const reservedStages = [];
    let committedMicro = 0;
    const usageTotal = { inputTokens: 0, outputTokens: 0 };
    const startBudget = budgetStore.dailySnapshot(subjectId);

    const reserve = (stage, estimateMicro) => {
      const allowed = budgetStore.reserveMore({
        operationId: parsed.operationId,
        estimateMicro,
        dailyBudgetMicro,
      });
      if (allowed) {
        reservedStages.push({ stage, estimateMicro });
      }
      return allowed;
    };

    const begin = (estimateMicro) => budgetStore.beginOperation({
      subjectId,
      operationId: parsed.operationId,
      estimateMicro,
      dailyBudgetMicro,
    });

    const finalize = (status, extraMicro = 0) => {
      const estTotal = reservedStages.reduce((sum, item) => sum + item.estimateMicro, 0);
      budgetStore.settleOperation({
        operationId: parsed.operationId,
        estimateMicro: estTotal,
        actualMicro: committedMicro + extraMicro,
        status,
      });
    };

    const baseResponse = {
      schemaVersion: 2,
      operationId: parsed.operationId,
      textRevision: parsed.textRevision,
      catalogRevision: parsed.catalogRevision,
      policyVersion: THOUGHT_INDEX_POLICY_VERSION,
    };

    const usagePayload = () => ({
      inputTokens: usageTotal.inputTokens,
      outputTokens: usageTotal.outputTokens,
      estimatedCostCNY: Number(((committedMicro + moderationFeeMicro()) / 1_000_000).toFixed(6)),
      dailyBudgetCNY: moduleConfig.budgets.perSubjectDailyCNY,
      dailyConsumedCNY: Number(((startBudget.committedMicro + startBudget.reservedMicro) / 1_000_000).toFixed(6)),
    });

    let moderationCalls = 0;
    function moderationFeeMicro() {
      return moderationCalls * moderationCostMicro();
    }

    try {
      // —— 阶段 A 预算先行：operation 台账建立后，审核费才能正确入账 ——
      const estimateA = estimateStageMicro("a", parsed.text.length);
      const beginResult = begin(estimateA);
      if (!beginResult.allowed) {
        if (beginResult.reason === "in_progress") {
          throw new GatewayError("OPERATION_IN_PROGRESS", "This operation is already running", 409);
        }
        throw new GatewayError("BUDGET_EXCEEDED", "Daily organize budget exceeded", 429, {
          resetAt: beginResult.resetAt,
          dailyBudgetCNY: moduleConfig.budgets.perSubjectDailyCNY,
        });
      }
      reservedStages.push({ stage: "a", estimateMicro: estimateA });

      // —— 内容安全审核（方案 §6.2：保留既有审核路径；费用计入本任务预算）——
      if (contentModeration?.isEnabled?.()) {
        const moderation = await contentModeration.moderate(parsed.text);
        moderationCalls += 1;
        if (!moderation.passed) {
          finalize("completed", moderationFeeMicro());
          return {
            ...baseResponse,
            outcome: "deferred",
            reasonCode: "moderation_blocked",
            catalogCoverage: "none",
            assignments: [],
            usage: usagePayload(),
          };
        }
      }

      let stageAResult;
      try {
        stageAResult = await runStage("a", parsed.text, {
          deviceId,
          stageSignal,
          logMeta: { stage: "a" },
        });
      } catch (error) {
        committedMicro += estimateA; // usage 丢失时按预留上界计费
        throw error;
      }
      usageTotal.inputTokens += stageAResult.usage.inputTokens;
      usageTotal.outputTokens += stageAResult.usage.outputTokens;
      committedMicro += costMicroForUsage(
        stageAResult.usage.inputTokens,
        stageAResult.usage.outputTokens,
        moduleConfig.pricing,
      );

      const stageA = validateStageAOutput(parseModelJSON(stageAResult.content), parsed.text);
      if (stageA.malformed) {
        finalize("failed", moderationFeeMicro());
        throw new GatewayError("MODEL_OUTPUT_INVALID", "Stage A output malformed", 502);
      }
      if (stageA.anchors.length === 0) {
        // A 明确空数组是合法完成态（方案 §5.4），不需要 B，也不重试
        finalize("completed", moderationFeeMicro());
        return {
          ...baseResponse,
          outcome: "no_evidence",
          catalogCoverage: "none",
          assignments: [],
          usage: usagePayload(),
        };
      }

      // —— 目录分级（方案 §5.5）——
      const { fullChars, nameChars } = measureCatalogBudgets(parsed.catalog);
      let catalogForB = parsed.catalog;
      let catalogCoverage = "full";

      if (fullChars > moduleConfig.catalog.fullCharBudget) {
        if (nameChars > moduleConfig.catalog.nameCharBudget) {
          // 路径 3：连名称目录都超预算。终态返回，客户端不得定时原样重试
          finalize("completed", moderationFeeMicro());
          return {
            ...baseResponse,
            outcome: "deferred",
            reasonCode: "catalog_budget_exceeded",
            catalogCoverage: "none",
            assignments: [],
            usage: usagePayload(),
          };
        }
        // 路径 2：R 云端筛选 + 显式命中补充
        const nameCatalog = parsed.catalog.map((entry) => ({
          ref: entry.ref,
          name: entry.name,
          path: entry.path ?? "",
          aliases: entry.aliases.slice(0, 1),
        }));
        const estimateR = estimateStageMicro("r", JSON.stringify({ anchors: stageA.anchors, catalog: nameCatalog }).length);
        const taskReservedSoFar = reservedStages.reduce((sum, item) => sum + item.estimateMicro, 0);
        if (taskReservedSoFar + estimateR > perTaskMaxMicro
          || !reserve("r", estimateR)) {
          finalize("completed", moderationFeeMicro());
          return {
            ...baseResponse,
            outcome: "deferred",
            reasonCode: "budget_exceeded",
            catalogCoverage: "none",
            assignments: [],
            usage: usagePayload(),
          };
        }
        let stageRResult;
        try {
          stageRResult = await runStage(
            "r",
            JSON.stringify({ anchors: stageA.anchors, catalog: nameCatalog }),
            { deviceId, stageSignal, logMeta: { stage: "r", catalogSize: nameCatalog.length } },
          );
        } catch (error) {
          committedMicro += estimateR;
          throw error;
        }
        usageTotal.inputTokens += stageRResult.usage.inputTokens;
        usageTotal.outputTokens += stageRResult.usage.outputTokens;
        committedMicro += costMicroForUsage(
          stageRResult.usage.inputTokens,
          stageRResult.usage.outputTokens,
          moduleConfig.pricing,
        );
        const recallOutput = validateRecallOutput(parseModelJSON(stageRResult.content), parsed.catalog);
        const recalledRefs = new Set([...recallOutput, ...explicitNameHits(stageA.anchors, parsed.catalog)]);
        catalogForB = parsed.catalog.filter((entry) => recalledRefs.has(entry.ref));
        catalogCoverage = "names_recalled";
      }

      // —— 阶段 B：词表对齐 + 证据复核（方案 §5.2）——
      const blockedRefsForB = parsed.blockedRefs.filter((ref) =>
        catalogForB.some((entry) => entry.ref === ref));
      const estimateB = estimateStageMicro(
        "b",
        JSON.stringify({
          text: parsed.text,
          anchors: stageA.anchors,
          catalog: catalogForB,
          blockedRefs: blockedRefsForB,
          blockedNames: parsed.blockedNames,
        }).length,
      );
      const taskTotal = reservedStages.reduce((sum, item) => sum + item.estimateMicro, 0);
      if (taskTotal + estimateB > perTaskMaxMicro || !reserve("b", estimateB)) {
        finalize("completed", moderationFeeMicro());
        return {
          ...baseResponse,
          outcome: "deferred",
          reasonCode: "budget_exceeded",
          catalogCoverage,
          assignments: [],
          usage: usagePayload(),
        };
      }

      let stageBResult;
      try {
        stageBResult = await runStage(
          "b",
          JSON.stringify({
            text: parsed.text,
            anchors: stageA.anchors,
            catalog: catalogForB,
            blockedRefs: blockedRefsForB,
            blockedNames: parsed.blockedNames,
          }),
          { deviceId, stageSignal, logMeta: { stage: "b", catalogSize: catalogForB.length } },
        );
      } catch (error) {
        committedMicro += estimateB;
        throw error;
      }
      usageTotal.inputTokens += stageBResult.usage.inputTokens;
      usageTotal.outputTokens += stageBResult.usage.outputTokens;
      committedMicro += costMicroForUsage(
        stageBResult.usage.inputTokens,
        stageBResult.usage.outputTokens,
        moduleConfig.pricing,
      );

      const stageB = validateStageBOutput(parseModelJSON(stageBResult.content), {
        text: parsed.text,
        anchors: stageA.anchors,
        catalog: catalogForB,
        blockedRefs: blockedRefsForB,
        blockedNames: parsed.blockedNames,
      });
      if (stageB.malformed) {
        finalize("failed", moderationFeeMicro());
        throw new GatewayError("MODEL_OUTPUT_INVALID", "Stage B output malformed", 502);
      }

      finalize("completed", moderationFeeMicro());
      return {
        ...baseResponse,
        outcome: stageB.assignments.length > 0 ? "tagged" : "no_evidence",
        catalogCoverage,
        assignments: stageB.assignments,
        usage: usagePayload(),
      };
    } catch (error) {
      if (reservedStages.length > 0) {
        finalize("failed", moderationFeeMicro());
      }
      // deadline 到期而客户端未断开 → 按上游超时归类，不误报客户端取消
      if (deadlineController.signal.aborted && !clientSignal?.aborted) {
        throw new GatewayError("UPSTREAM_TIMEOUT", "Organize deadline exceeded", 504);
      }
      throw error;
    } finally {
      clearTimeout(deadlineTimer);
    }
  }

  return { organize };
}
