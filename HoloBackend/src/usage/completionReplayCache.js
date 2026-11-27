import { createHash } from "node:crypto";

// 后台萃取类请求的「断开不白付」重放缓存（2026-11-27 降本）。
//
// 背景：情境萃取/核验、领域萃取是 iOS 后台批处理，App 切后台或被系统回收时连接断开（nginx 499）。
// 此前断开即取消上游，已处理的输入 token 照付、结果丢弃，游标不动 → 下次同一包原样重发再付一次
//（近 14 天萃取 9%、领域萃取 14% 的调用如此作废）。
// 现在：这些 purpose 断开后让上游算完，成功结果按「设备 + purpose + 模型 + 完整请求」指纹缓存；
// 客户端重发同一包直接命中，不再调模型。同指纹并发请求合并为一次上游调用。
//
// 只放进程内存（含用户内容，不落盘）；TTL 内有效，进程重启即清空——丢缓存只退化为原行为。

export const REPLAYABLE_COMPLETION_PURPOSES = new Set([
  "personal_context_extraction",
  "personal_context_verification",
  "memory_domain_extraction",
]);

const DEFAULT_TTL_MS = 6 * 60 * 60 * 1000;
const DEFAULT_MAX_ENTRIES = 500;

export function completionReplayKey({ deviceId, request }) {
  const material = JSON.stringify([
    deviceId,
    request.purpose,
    request.model,
    request.temperature ?? null,
    request.maxTokens ?? null,
    request.reasoningEffort ?? null,
    request.responseFormat ?? null,
    request.messages,
  ]);
  return createHash("sha256").update(material).digest("hex");
}

export function createCompletionReplayCache({
  ttlMs = DEFAULT_TTL_MS,
  maxEntries = DEFAULT_MAX_ENTRIES,
  now = () => Date.now(),
} = {}) {
  const completed = new Map(); // key → { result, expiresAt }；Map 插入序即 LRU 淘汰序
  const inflight = new Map(); // key → Promise<result>

  function readCompleted(key) {
    const entry = completed.get(key);
    if (!entry) return null;
    if (entry.expiresAt <= now()) {
      completed.delete(key);
      return null;
    }
    return entry.result;
  }

  function store(key, result) {
    completed.delete(key);
    completed.set(key, { result, expiresAt: now() + ttlMs });
    while (completed.size > maxEntries) {
      completed.delete(completed.keys().next().value);
    }
  }

  /// 返回 { result, source }：source = "upstream" | "cache" | "inflight"。
  /// 返回的 result 是深拷贝，调用方可就地修改（输出审核会改写 content）。
  async function run(key, compute) {
    const cached = readCompleted(key);
    if (cached) return { result: structuredClone(cached), source: "cache" };

    const pending = inflight.get(key);
    if (pending) return { result: structuredClone(await pending), source: "inflight" };

    const promise = compute();
    inflight.set(key, promise);
    try {
      const result = await promise;
      store(key, result);
      return { result: structuredClone(result), source: "upstream" };
    } finally {
      inflight.delete(key);
    }
  }

  return { run, size: () => completed.size };
}
