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
  log = (...args) => console.log("[cloud-analysis]", ...args),
} = {}) {
  const engine = createCloudAnalysisQueryEngine();
  const provider = providers.get(route.provider);
  if (!provider) {
    throw new Error(`CLOUD_ANALYSIS_PROVIDER_MISSING: ${route.provider}`);
  }

  function executeToolRequests(toolRequests, snapshot) {
    return toolRequests.map((request) => {
      const id = request.id ?? "tool";
      const tool = request.tool;
      try {
        // validateAgentLoopContent 会把 parameters.dynamicPlan 规范化提升到请求顶层；两种位置都接受
        const plan = request.dynamicPlan ?? request.parameters?.dynamicPlan;
        if (plan) {
          const result = engine.execute(plan, snapshot);
          if (result.error) {
            return { id, tool, ok: false, error: result.error };
          }
          return { id, tool, ok: true, query: "dynamic_query", result };
        }
        const statics = snapshot?.statics ?? {};
        if (Object.prototype.hasOwnProperty.call(statics, tool)) {
          return { id, tool, ok: true, query: request.query ?? "static", result: statics[tool] };
        }
        if (request.query === "dynamic_query") {
          return { id, tool, ok: false, error: "INVALID_PLAN: dynamic_query 缺少 dynamicPlan" };
        }
        return {
          id,
          tool,
          ok: false,
          error: `NOT_SUPPORTED_BY_CLOUD: 固定 query「${request.query}」未在快照中预取；请改用 dynamic_query+dynamicPlan，或使用静态块 ${Object.keys(statics).join("、 ") || "（无）"}`,
        };
      } catch (error) {
        return { id, tool, ok: false, error: `TOOL_ERROR: ${error?.message ?? error}` };
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

      for (let round = 1; round <= maxRounds; round += 1) {
        const response = await callProvider(messages);
        const content = response?.choices?.[0]?.message?.content ?? "";
        const validation = validateAgentLoopContent(content);
        if (!validation.valid) {
          // 契约故障按一轮消耗处理后继续（与网关侧同策略：不提前终止任务）
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
            completedAt: new Date().toISOString(),
            engine: "cloud-m2a",
          };
          taskStore.complete({ id: taskId, result: JSON.stringify(result) });
          log(`任务完成 taskId=${taskId} rounds=${round} claims=${result.claims.length}`);
          return "completed";
        }

        const toolRequests = Array.isArray(output.toolRequests) ? output.toolRequests : [];
        if (toolRequests.length > 0) {
          const toolResults = executeToolRequests(toolRequests, snapshot);
          const failures = toolResults.filter((r) => !r.ok).map((r) => `${r.tool}:${r.error}`);
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
