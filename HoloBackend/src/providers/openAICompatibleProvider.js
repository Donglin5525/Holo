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
      });

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
      });

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
  };
}

async function callUpstream(config, body) {
  if (!config.apiKey) {
    throw new GatewayError("UPSTREAM_AUTH_FAILED", "Provider API key is not configured", 503);
  }

  const controller = new AbortController();
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
