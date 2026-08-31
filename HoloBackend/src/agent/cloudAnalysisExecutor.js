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
  providerRetries = MAX_PROVIDER_RETRIES,
  maxRounds = MAX_LLM_ROUNDS,
  pushNotifier = null,
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

  async function callProvider(messages) {
    let lastError = null;
    for (let attempt = 1; attempt <= providerRetries; attempt += 1) {
      try {
        const upstream = {
          purpose: "agent_loop",
          messages,
          stream: false,
          model: route.model,
          temperature: route.temperature,
          maxTokens: route.maxTokens,
          reasoningEffort: route.reasoningEffort,
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
          // 分析完成推送（fire-and-forget）：锁屏/离开 App 的用户由此被叫醒；
          // 推送失败不影响任务终态，App 打开后轮询恢复链兜底领取。
          if (pushNotifier) {
            pushNotifier.notifyAnalysisCompleted(task.device_id).catch((error) => {
              log(`完成推送发送失败 taskId=${taskId}: ${error?.message ?? error}`);
            });
          }
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
