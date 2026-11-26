// 想法主题归类评测 · 本机后端 HTTP 客户端
//
// 打四个端点：/v1/ai/embeddings（向量）、/v1/thoughts/semantic-relate（归属判定）、
// /v1/thoughts/topic-name（自动发现主题时给一簇笔记起名）、/v1/thoughts/category-brief（类别理解）。
// 限流与重试口径对齐客户端：同设备号每分钟 20 次；模型输出无效 / 限流 / 5xx 可重试，
// 4xx 终态；连续 5 次仍失败转终态（ThoughtSemanticRetryPolicy + C1 重试封顶）。

import { setTimeout as sleep } from "node:timers/promises";

import { randomOperationId } from "./text.mjs";

/** 设备号用非 UUID 形态：后端统计按 36 位 UUID 甄别真实用户，评测流量不计入。 */
export const EVAL_DEVICE_PREFIX = "eval-topic";

/** 后端以 4xx 稳定错误码拒绝的请求——客户端视为终态，这条想法本轮不重试。 */
export class BackendRejectedError extends Error {
  constructor(status, code) {
    super(`后端拒绝请求：HTTP ${status} ${code}`);
    this.name = "BackendRejectedError";
    this.status = status;
    this.code = code;
  }
}

/** 费用护栏拦截（当日额度用完）：继续跑只会整场空转，必须立刻停。 */
export class BackendBudgetExhaustedError extends BackendRejectedError {}

const BUDGET_EXHAUSTED_CODES = new Set(["BUDGET_EXCEEDED", "BACKGROUND_BUDGET_EXCEEDED", "DAILY_RATE_LIMITED"]);

export class BackendClient {
  #nextSlotByDevice = new Map();

  constructor({ base, minIntervalMs = 3_100, maxAttempts = 5, retryDelayMs = 1_500, timeoutMs = 90_000 }) {
    this.base = base.replace(/\/+$/, "");
    this.minIntervalMs = minIntervalMs;
    this.maxAttempts = maxAttempts;
    this.retryDelayMs = retryDelayMs;
    this.timeoutMs = timeoutMs;
  }

  /** 先占时间片再等待：并发的同设备请求不会读到同一个「下一格」。 */
  async #pacedSend(path, body, deviceId) {
    const now = Date.now();
    const startAt = Math.max(now, this.#nextSlotByDevice.get(deviceId) ?? 0);
    this.#nextSlotByDevice.set(deviceId, startAt + this.minIntervalMs);
    if (startAt > now) await sleep(startAt - now);
    const response = await fetch(`${this.base}${path}`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-holo-device-id": deviceId },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(this.timeoutMs),
    });
    const json = await response.json().catch(() => null);
    return { status: response.status, json };
  }

  async embed(texts, deviceId) {
    const { status, json } = await this.#pacedSend("/v1/ai/embeddings", { purpose: "thought_embedding", texts }, deviceId);
    if (status !== 200) {
      throw new Error(`embeddings 失败：HTTP ${status} ${json?.error?.code ?? ""}`);
    }
    // 与客户端同款校验：模型名与维度写死，换模型即视为向量不可用
    if (json?.model !== "text-embedding-v3" || json.dimensions !== 1024 || json.vectors?.length !== texts.length) {
      throw new Error("embeddings 响应不符：客户端要求 text-embedding-v3 / 1024 维");
    }
    return json.vectors;
  }

  /** 模型类端点共用的一套重试；返回 { response, attempts }。 */
  async #request(path, body, deviceId) {
    let attempts = 0;
    for (;;) {
      attempts += 1;
      let status;
      let json;
      try {
        ({ status, json } = await this.#pacedSend(path, body, deviceId));
      } catch (error) {
        if (attempts >= this.maxAttempts) throw error;
        await sleep(this.retryDelayMs);
        continue;
      }
      if (status === 200) return { response: json, attempts };
      const code = json?.error?.code ?? `HTTP_${status}`;
      if (BUDGET_EXHAUSTED_CODES.has(code)) throw new BackendBudgetExhaustedError(status, code);
      if (status >= 400 && status <= 428 && status !== 409) throw new BackendRejectedError(status, code);
      if (attempts >= this.maxAttempts) throw new Error(`${path} 重试 ${attempts} 次仍失败：HTTP ${status} ${code}`);
      await sleep(this.retryDelayMs);
    }
  }

  /** 归属判定（schema 3）。 */
  relate(request, deviceId) {
    return this.#request("/v1/thoughts/semantic-relate", request, deviceId);
  }

  /** 自动发现主题：给一簇候选笔记起名（schema 2）。成员证据是否逐字回源由后端校验。 */
  async topicName(representatives, deviceId) {
    const { response, attempts } = await this.#request("/v1/thoughts/topic-name", {
      schemaVersion: 2,
      operationId: randomOperationId(),
      engineVersion: "thought_semantic_v3.2",
      representatives,
    }, deviceId);
    if (response.schemaVersion !== 2 || !["topic", "no_topic"].includes(response.outcome)) {
      throw new BackendRejectedError(502, "topic_envelope");
    }
    return { response, attempts };
  }

  /** 类别理解：给没有用户规则的归档类别起草「这个主题收什么」。 */
  async categoryBrief(payload, deviceId) {
    const { response, attempts } = await this.#request("/v1/thoughts/category-brief", {
      schemaVersion: 1,
      operationId: randomOperationId(),
      engineVersion: "thought_semantic_v3.2",
      ...payload,
    }, deviceId);
    if (typeof response.brief?.definition !== "string" || response.brief.definition.length === 0) {
      throw new BackendRejectedError(502, "brief_envelope");
    }
    return { brief: response.brief, attempts };
  }
}
