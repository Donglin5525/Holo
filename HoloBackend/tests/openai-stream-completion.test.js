import assert from "node:assert/strict";
import { test } from "node:test";

import { createOpenAICompatibleProvider } from "../src/providers/openAICompatibleProvider.js";

const encoder = new TextEncoder();

function streamFromChunks(chunks) {
  return new ReadableStream({
    start(controller) {
      for (const chunk of chunks) controller.enqueue(chunk);
      controller.close();
    },
  });
}

async function withFakeUpstream(chunks, run) {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async () => ({
    ok: true,
    status: 200,
    body: streamFromChunks(chunks),
  });
  try {
    const provider = createOpenAICompatibleProvider({
      baseURL: "https://upstream.invalid",
      apiKey: "test-key",
    });
    return await run(provider);
  } finally {
    globalThis.fetch = originalFetch;
  }
}

function request() {
  return {
    model: "test-model",
    messages: [{ role: "user", content: "test" }],
    temperature: 0,
    maxTokens: 1024,
  };
}

test("agent SSE 支持 CRLF、拆分 UTF-8 和无结尾空行的残余帧", async () => {
  const source = [
    'data: {"choices":[{"delta":{"content":"消费"}}]}\r\n\r\n',
    'data: {"choices":[{"delta":{"content":"完成"},"finish_reason":"stop"}]}\r\n\r\n',
    'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":2,"total_tokens":12}}\r\n\r\n',
    "data: [DONE]",
  ].join("");
  const bytes = encoder.encode(source);
  // 刻意在中文 UTF-8 多字节内部切分。
  const chunks = [
    bytes.slice(0, 45),
    bytes.slice(45, 48),
    bytes.slice(48, 113),
    bytes.slice(113),
  ];

  const result = await withFakeUpstream(
    chunks,
    (provider) => provider.completeViaStream(request()),
  );

  assert.equal(result.choices[0].message.content, "消费完成");
  assert.equal(result.choices[0].finish_reason, "stop");
  assert.equal(result.usage.total_tokens, 12);
});

test("agent SSE 遇到坏 JSON 帧必须失败，不能静默丢帧后返回 200", async () => {
  const chunks = [
    encoder.encode('data: {"choices":[{"delta":{"content":"前半段"}}]}\n\n'),
    encoder.encode("data: {broken-json}\n\n"),
    encoder.encode('data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'),
  ];

  await assert.rejects(
    withFakeUpstream(chunks, (provider) => provider.completeViaStream(request())),
    (error) => error?.code === "UPSTREAM_SSE_INVALID_FRAME",
  );
});

test("agent SSE 支持注释与多行 data event", async () => {
  const chunks = [
    encoder.encode(
      ': heartbeat\n'
      + 'data: {"choices":[\n'
      + 'data: {"delta":{"content":"完整"},"finish_reason":"stop"}]}\n\n'
      + "data: [DONE]\n\n",
    ),
  ];

  const result = await withFakeUpstream(
    chunks,
    (provider) => provider.completeViaStream(request()),
  );

  assert.equal(result.choices[0].message.content, "完整");
  assert.equal(result.choices[0].finish_reason, "stop");
});

test("agent SSE 有部分内容但没有 finish_reason 或 DONE 时必须按截断失败", async () => {
  const chunks = [
    encoder.encode('data: {"choices":[{"delta":{"content":"只有半截"}}]}'),
  ];

  await assert.rejects(
    withFakeUpstream(chunks, (provider) => provider.completeViaStream(request())),
    (error) => error?.code === "UPSTREAM_SSE_INCOMPLETE",
  );
});

test("agent SSE finish_reason=length 必须按 token 截断失败", async () => {
  const chunks = [
    encoder.encode(
      'data: {"choices":[{"delta":{"content":"被截断"},"finish_reason":"length"}]}\n\n'
    ),
    encoder.encode("data: [DONE]\n\n"),
  ];

  await assert.rejects(
    withFakeUpstream(chunks, (provider) => provider.completeViaStream(request())),
    (error) => error?.code === "TRUNCATED_MODEL_RESPONSE",
  );
});
