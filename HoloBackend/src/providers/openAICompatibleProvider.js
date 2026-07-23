import { GatewayError } from "../errors.js";

export function createOpenAICompatibleProvider(config) {
  return {
    passesThroughSSE: true,

    async complete(request) {
      const response = await callUpstream(config, {
        model: request.model,
        messages: request.messages,
        temperature: request.temperature,
        max_tokens: request.maxTokens,
        response_format: request.responseFormat,
        stream: false,
      }, request.clientSignal);

      return response.json();
    },

    async *stream(request) {
      const response = await callUpstream(config, {
        model: request.model,
        messages: request.messages,
        temperature: request.temperature,
        max_tokens: request.maxTokens,
        response_format: request.responseFormat,
        stream: true,
      }, request.clientSignal);

      if (!response.body) {
        throw new GatewayError("MODEL_UNAVAILABLE", "Upstream response has no body", 503);
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        yield decoder.decode(value, { stream: true });
      }
    },

    /// 用流式从上游拉取（保持连接活跃、120s 超时），收集完整响应后拼成与非流式 complete 相同的结构返回。
    /// 解决非流式请求因长时间无数据传输被中间网络设备在 30s 切断的问题（中国 ECS → deepseek）。
    /// 调用方（app.js）对返回值无感——结构和 complete() 一致。
    async completeViaStream(request) {
      const response = await callUpstream(config, {
        model: request.model,
        messages: request.messages,
        temperature: request.temperature,
        max_tokens: request.maxTokens,
        response_format: request.responseFormat,
        // stream_options 让上游在最后一个 chunk 返回 usage，与非流式行为一致
        stream: true,
        stream_options: { include_usage: true },
      }, request.clientSignal);

      if (!response.body) {
        throw new GatewayError("MODEL_UNAVAILABLE", "Upstream response has no body", 503);
      }

      const reader = response.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";
      let contentParts = [];
      let reasoningParts = [];
      let finishReason = null;
      let usage = null;
      let sawDone = false;
      // P0-D SSE 可观测性：记录坏帧、空帧、残余 buffer 等异常，不静默吞掉
      let sseStats = {
        totalFrames: 0,
        badFrames: 0,
        emptyFrames: 0,
        hasRemainingBuffer: false,
        doneReceived: false,
        finishReasonReceived: false,
        usageReceived: false,
      };

      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        buffer += decoder.decode(value, { stream: true });
        // SSE 按 \n\n 分帧（兼容 CRLF：先统一换行）
        const normalizedBuffer = buffer.replace(/\r\n/g, "\n");
        const frames = normalizedBuffer.split("\n\n");
        buffer = frames.pop(); // 最后一段可能不完整，留到下次
        for (const frame of frames) {
          sseStats.totalFrames++;
          if (!frame.trim()) {
            sseStats.emptyFrames++;
            continue;
          }
          // 一个 SSE event 可以同时包含注释与多行 data；按规范拼接 data 后再解析。
          const payload = extractSSEData(frame);
          if (payload == null) continue;
          if (payload === "[DONE]") {
            sawDone = true;
            sseStats.doneReceived = true;
            continue;
          }
          if (!payload) {
            sseStats.emptyFrames++;
            continue;
          }
          let parsed;
          try {
            parsed = JSON.parse(payload);
          } catch {
            sseStats.badFrames++;
            throw new GatewayError(
              "UPSTREAM_SSE_INVALID_FRAME",
              "Upstream SSE contained an invalid JSON frame",
              502
            );
          }
          const delta = parsed.choices?.[0]?.delta;
          if (delta?.content) contentParts.push(delta.content);
          if (delta?.reasoning_content) reasoningParts.push(delta.reasoning_content);
          if (parsed.choices?.[0]?.finish_reason) {
            finishReason = parsed.choices[0].finish_reason;
            sseStats.finishReasonReceived = true;
          }
          if (parsed.usage) {
            usage = parsed.usage;
            sseStats.usageReceived = true;
          }
        }
      }

      // P0-D：流结束时 flush decoder 并处理残余 buffer，不静默丢弃多字节 UTF-8 尾字节
      const remainingDecoded = decoder.decode(); // flush=true 默认
      if (remainingDecoded) {
        buffer += remainingDecoded;
      }
      // 处理残余 buffer 中可能完整的最后一帧
      const remainingFrame = buffer.trim();
      const remainingPayload = extractSSEData(remainingFrame);
      if (remainingPayload != null) {
        sseStats.hasRemainingBuffer = true;
        if (remainingPayload === "[DONE]") {
          sawDone = true;
          sseStats.doneReceived = true;
        } else if (remainingPayload) {
          try {
            const parsed = JSON.parse(remainingPayload);
            const delta = parsed.choices?.[0]?.delta;
            if (delta?.content) contentParts.push(delta.content);
            if (delta?.reasoning_content) reasoningParts.push(delta.reasoning_content);
            if (parsed.choices?.[0]?.finish_reason) {
              finishReason = parsed.choices[0].finish_reason;
              sseStats.finishReasonReceived = true;
            }
            if (parsed.usage) {
              usage = parsed.usage;
              sseStats.usageReceived = true;
            }
          } catch {
            sseStats.badFrames++;
            throw new GatewayError(
              "UPSTREAM_SSE_INVALID_FRAME",
              "Upstream SSE ended with an invalid JSON frame",
              502
            );
          }
        }
      } else if (remainingFrame) {
        sseStats.hasRemainingBuffer = true;
      }

      // P0-D：内容完整性不确定时返回明确 upstream incomplete/error，
      // 不合成 finish_reason=stop 掩盖异常。
      // 只有在确实收到 finishReason 或 [DONE] 且有内容时才算正常完成。
      const hasContent = contentParts.length > 0 || reasoningParts.length > 0;
      const streamCompletedNormally =
        (finishReason !== null || sawDone) &&
        hasContent &&
        sseStats.badFrames === 0;

      if (finishReason === "length") {
        throw new GatewayError(
          "TRUNCATED_MODEL_RESPONSE",
          "Upstream response hit the output token limit",
          502
        );
      }

      if (!streamCompletedNormally) {
        // 流未正常结束：可能是网络截断、上游坏帧过多、或无内容
        const reasons = [];
        if (!hasContent) reasons.push("no content received");
        if (finishReason === null && !sawDone) reasons.push("no finish_reason or [DONE]");
        if (sseStats.badFrames > 0) reasons.push(`${sseStats.badFrames} bad frames`);
        if (sseStats.hasRemainingBuffer) reasons.push("unprocessed remaining buffer");

        // 即使已有部分内容也不得返回 200：半截 JSON 偶尔恰好可解析，
        // 会把不完整计划伪装成正常完成并永久写入 step 幂等缓存。
        throw new GatewayError(
          "UPSTREAM_SSE_INCOMPLETE",
          `SSE stream incomplete: ${reasons.join(", ")}`,
          502
        );
      }

      return {
        choices: [{
          index: 0,
          message: {
            role: "assistant",
            content: contentParts.join(""),
            ...(reasoningParts.length > 0 ? { reasoning_content: reasoningParts.join("") } : {}),
          },
          finish_reason: finishReason ?? "stop",
        }],
        usage: usage ?? {
          prompt_tokens: 0,
          completion_tokens: 0,
          total_tokens: 0,
        },
        // P0-D 可观测性元数据（非敏感，仅在异常时附加）
        ...(sseStats.badFrames > 0 || sseStats.hasRemainingBuffer ? {
          _sseStats: sseStats,
        } : {}),
      };
    },
  };
}

function extractSSEData(frame) {
  if (!frame) return null;
  const dataLines = frame
    .replace(/\r\n/g, "\n")
    .split("\n")
    .filter((line) => line.startsWith("data:"))
    .map((line) => line.slice("data:".length).replace(/^ /, ""));
  if (dataLines.length === 0) return null;
  return dataLines.join("\n").trim();
}

async function callUpstream(config, body, clientSignal) {
  if (!config.apiKey) {
    throw new GatewayError("UPSTREAM_AUTH_FAILED", "Provider API key is not configured", 503);
  }

  const controller = new AbortController();
  // 客户端断开时同步 abort 上游请求，避免浪费 token（Phase 4 §6.2 断连治理）
  if (clientSignal) {
    if (clientSignal.aborted) {
      controller.abort();
    } else {
      clientSignal.addEventListener("abort", () => controller.abort(), { once: true });
    }
  }
  const timeout = setTimeout(() => controller.abort(), body.stream ? 120_000 : 60_000);

  try {
    const response = await fetch(`${config.baseURL.replace(/\/$/, "")}/chat/completions`, {
      method: "POST",
      headers: {
        "authorization": `Bearer ${config.apiKey}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });

    if (response.status === 401 || response.status === 403) {
      throw new GatewayError("UPSTREAM_AUTH_FAILED", "Upstream authentication failed", 503);
    }

    if (!response.ok) {
      throw new GatewayError("MODEL_UNAVAILABLE", `Upstream returned ${response.status}`, 503);
    }

    return response;
  } catch (error) {
    if (error.name === "AbortError") {
      throw new GatewayError("UPSTREAM_TIMEOUT", "Upstream request timed out", 504);
    }

    if (error instanceof GatewayError) {
      throw error;
    }

    throw new GatewayError("MODEL_UNAVAILABLE", "Upstream request failed", 503);
  } finally {
    clearTimeout(timeout);
  }
}
