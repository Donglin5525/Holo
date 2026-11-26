// 想法主题归类评测 · 单条想法的评测
//
// 召回 → 按客户端口径组装请求 → 问模型 → 客户端复核 → 现状落库规则。
// 跑批入口 run.mjs 与并发对照实验 concurrency-probe.mjs 共用这一份，保证两边走的是同一条路。

import { BackendBudgetExhaustedError, BackendRejectedError } from "./backend-client.mjs";
import {
  ContractViolationError, acceptLegacyResponse, buildLegacyCandidates, buildLegacyRequests, commitLegacy,
} from "./legacy.mjs";
import { recall } from "./recall.mjs";

/** 向量可用且脱敏后还有正文：线上只有这种想法会进入语义核对。 */
export const isJudgeable = (vectors, thought) => thought.processable && vectors.get(thought.contentHash) !== null;

/**
 * 给每条待评测想法定下候选与请求（确定性，只做一次；多轮只重复「问模型」）。
 * leaveOneOut：按「这条想法刚写完、还没有任何归属」来判，它自己的关系不参与召回与落库。
 */
export async function buildPlan(state, vectors, targets, { leaveOneOut }) {
  const plan = [];
  for (const target of targets) {
    const view = leaveOneOut ? { ...target, links: [] } : target;
    const excludeThoughtId = leaveOneOut ? target.id : null;
    const outcome = isJudgeable(vectors, target)
      ? await recall(state, view, { excludeThoughtId })
      : { candidates: [], reason: "vector_or_text_unavailable" };
    const { candidates, topicByRef } = buildLegacyCandidates(state, view, outcome);
    plan.push({
      target: view,
      outcome,
      candidates,
      topicByRef,
      requests: outcome.candidates.length > 0 ? buildLegacyRequests(view, candidates) : [],
    });
  }
  return plan;
}

// 无候选的想法线上不发请求、也不归属：每轮都记一条空结果，指标里照常计入分母
export const emptyRound = (entry) => ({
  candidates: entry.candidates.map((candidate) => entry.topicByRef[candidate.ref]),
  positives: [], committed: [], truncated: [], suggestedAdd: [], superseded: [],
  verdicts: {}, error: null, attempts: 0, usage: null, latencyMs: 0,
});

function addUsage(total, usage) {
  return {
    inputTokens: (total?.inputTokens ?? 0) + usage.inputTokens,
    outputTokens: (total?.outputTokens ?? 0) + usage.outputTokens,
  };
}

function describeError(error) {
  if (error instanceof BackendRejectedError) return `rejected:${error.code}`;
  if (error instanceof ContractViolationError) return `contract:${error.reason}`;
  return `transport:${String(error.message).slice(0, 80)}`;
}

/** 一条想法的一轮：所有分段都成功才算完成（与客户端一致，不把半篇结果当结果）。 */
export async function evaluateOnce(client, entry, deviceId) {
  const result = emptyRound(entry);
  if (entry.requests.length === 0) return result;
  const positives = [];
  const startedAt = Date.now();
  try {
    for (const chunk of entry.requests) {
      const { response, attempts } = await client.relate(chunk.request, deviceId);
      result.attempts += attempts;
      result.usage = addUsage(result.usage, response.usage);
      const accepted = acceptLegacyResponse(chunk, entry.topicByRef, response);
      Object.assign(result.verdicts, accepted.verdicts);
      // 多段时同一主题只认第一次判正（客户端 resultsByTopic 首次写入）
      for (const positive of accepted.positives) {
        if (!positives.some((item) => item.topicId === positive.topicId)) positives.push(positive);
      }
    }
  } catch (error) {
    // 费用护栏拦截不是单条想法的问题：原样上抛，整场评测停下
    if (error instanceof BackendBudgetExhaustedError) throw error;
    result.error = describeError(error);
    return result;
  }
  Object.assign(result, commitLegacy(entry.target, positives), {
    positives: positives.map((item) => item.topicId),
    latencyMs: Date.now() - startedAt,
  });
  return result;
}
