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
import { validateAgentLoopContent } from "../agentResponseValidator.js";
import { createCloudAnalysisQueryEngine, buildCloudToolCatalog } from "./cloudAnalysisQueryEngine.js";

const MAX_LLM_ROUNDS = 12;
const MAX_PROVIDER_RETRIES = 3;

export function createCloudAnalysisExecutor({
  taskStore,
  providers,
  route,
  // 周期回放单轮生成使用的 insight 路由（模型/温度与 Agent 循环不同）；
  // 缺省回落 agent_loop 路由（同 provider 时行为一致）
  insightRoute = null,
  providerRetries = MAX_PROVIDER_RETRIES,
  maxRounds = MAX_LLM_ROUNDS,
  pushNotifier = null,
  // 周期回放（period_replay）任务的额度台账与权益解析：消耗 memoryInsight 池，
  // 预订-提交语义（生成失败自动释放），与端点层同一套真相源。
  quotaLedger = null,
  entitlementResolver = null,
  log = (...args) => console.log("[cloud-analysis]", ...args),
} = {}) {
  const engine = createCloudAnalysisQueryEngine();
  const provider = providers.get(route.provider);
  if (!provider) {
    throw new Error(`CLOUD_ANALYSIS_PROVIDER_MISSING: ${route.provider}`);
  }

  // 工具结果统一为 iOS HoloDataToolResult 同构信封（错误也走 error 字段），
  // 模型按提示词约定解析，不出现自造结构。
  function executeToolRequests(toolRequests, snapshot) {
    return toolRequests.map((request) => {
      const id = request.id ?? "tool";
      const tool = request.tool;
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

  async function callProvider(messages, forRoute = route) {
    let lastError = null;
    const upstreamRoute = forRoute ?? route;
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
        return await provider.complete(upstream);
      } catch (error) {
        lastError = error;
        log(`provider 调用失败 attempt=${attempt}: ${error?.message ?? error}`);
        await new Promise((resolve) => setTimeout(resolve, 1000 * attempt));
      }
    }
    throw lastError ?? new Error("PROVIDER_FAILED");
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
      const systemPrompted = injectServerPrompt("insight", [
        { role: "user", content: contextJSON },
      ]);
      const response = await callProvider(
        [
          { role: "system", content: systemPrompted.messages[0]?.content ?? "" },
          { role: "user", content: contextJSON },
        ],
        insightRoute ?? route,
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
      taskStore.complete({ id: taskId, result: JSON.stringify(result) });
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
   * 执行一个任务（queued → running → completed/failed）。
   * 返回最终状态；所有异常落 fail() 不上抛（fire-and-forget 调用安全）。
   */
  async function run(taskId) {
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
      // 不走 Agent 循环）；其余 = 深度分析多轮循环。
      if (task.task_type === "period_replay") {
        return await runPeriodReplay(taskId, task);
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

      const messages = [];
      const systemPrompted = injectServerPrompt("agent_loop", [
        { role: "user", content: task.question },
      ]);
      messages.push({
        role: "system",
        content: `${systemPrompted.messages[0]?.content ?? ""}\n\n${buildCloudToolCatalog(snapshot)}`,
      });
      messages.push({ role: "user", content: task.question });

      // 证据池：跨轮次累积模型查得的指标与行样本，final_claims 时随结果回传设备
      // （iOS 端据此渲染「依据」与数据样例；2026-08-31 验收：此前结果只带 claims，
      // 设备端证据区块永远为空）。metric 按 metricKey 去重，rows 按数据集保留最新一次取样。
      const metricEvidence = new Map();
      const rowsEvidence = new Map();

      function collectEvidence(toolRequests, toolResults) {
        toolResults.forEach((result, index) => {
          if (result.status !== "success") return;
          for (const metric of result.metrics ?? []) {
            if (!metric?.metricKey || metricEvidence.has(metric.metricKey)) continue;
            metricEvidence.set(metric.metricKey, {
              kind: "metric",
              metricKey: metric.metricKey,
              dataset: metric.dataset ?? null,
              group: metric.comparison ?? null,
              value: metric.value,
              unit: metric.unit ?? null,
              formula: metric.formula ?? null,
              sourceCount: Array.isArray(metric.sourceRecordIDs) ? metric.sourceRecordIDs.length : 0,
            });
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

      for (let round = 1; round <= maxRounds; round += 1) {
        const response = await callProvider(messages);
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
          taskStore.fail({ id: taskId, reason: "模型输出解析失败" });
          return "failed";
        }
        messages.push({ role: "assistant", content: validation.content });

        const requestedTools = (Array.isArray(output.toolRequests) ? output.toolRequests : [])
          .map((r) => `${r.tool}${r.query ? `:${r.query}` : ""}${(r.dynamicPlan ?? r.parameters?.dynamicPlan)?.source ? `(${(r.dynamicPlan ?? r.parameters?.dynamicPlan).source})` : ""}`)
          .join(",");
        log(`轮次 ${round}/${maxRounds} taskId=${taskId} status=${output.status} claims=${(output.claims ?? []).length}${requestedTools ? ` tools=${requestedTools}` : ""}`);

        if (output.status === "final_claims") {
          const result = {
            title: output.title ?? null,
            claims: output.claims ?? [],
            reasoning: output.reasoning ?? "",
            evidence: evidenceSnapshot(),
            completedAt: new Date().toISOString(),
            engine: "cloud-m2a",
          };
          taskStore.complete({ id: taskId, result: JSON.stringify(result) });
          pushTaskCompleted(task.device_id, { title: "深度分析完成", body: "结果已就绪，点按查看" });
          log(`任务完成 taskId=${taskId} rounds=${round} claims=${result.claims.length} evidence=${result.evidence.length}`);
          return "completed";
        }

        const toolRequests = Array.isArray(output.toolRequests) ? output.toolRequests : [];
        if (toolRequests.length > 0) {
          const toolResults = executeToolRequests(toolRequests, snapshot);
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
      taskStore.fail({ id: taskId, reason: `超过最大轮次（${maxRounds}）未能形成最终结论` });
      return "failed";
    } catch (error) {
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
