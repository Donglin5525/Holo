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

      while (true) {
        const { done, value } = await reader.read();
        if (done) {
          break;
        }
        buffer += decoder.decode(value, { stream: true });
        // SSE 按 \n\n 分帧
        const frames = buffer.split("\n\n");
        buffer = frames.pop(); // 最后一段可能不完整，留到下次
        for (const frame of frames) {
          const line = frame.trim();
          if (!line.startsWith("data:")) continue;
          const payload = line.slice("data:".length).trim();
          if (payload === "[DONE]") continue;
          let parsed;
          try { parsed = JSON.parse(payload); } catch { continue; }
          const delta = parsed.choices?.[0]?.delta;
          if (delta?.content) contentParts.push(delta.content);
          if (delta?.reasoning_content) reasoningParts.push(delta.reasoning_content);
          if (parsed.choices?.[0]?.finish_reason) {
            finishReason = parsed.choices[0].finish_reason;
          }
          if (parsed.usage) {
            usage = parsed.usage;
          }
        }
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
      };
    },
  };
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
