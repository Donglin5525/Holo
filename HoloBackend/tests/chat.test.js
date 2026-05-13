import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";

function createTestApp(overrides = {}) {
  return createApp({
    auth: { enforceAppAttest: false },
    limits: {
      chatRequestsPerMinute: 2,
      chatRequestsPerDay: 10,
    },
    routes: {
      chat: {
        provider: "mock",
        model: "holo-mock",
        temperature: 0.2,
        maxTokens: 512,
      },
    },
    ...overrides,
  });
}

test("GET /v1/health returns gateway status", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/health");

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    service: "holo-ai-gateway",
  });
});

test("POST /v1/ai/chat/completions returns non-streaming model response", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "device-a",
    },
    body: JSON.stringify({
      purpose: "chat",
      stream: false,
      messages: [{ role: "user", content: "你好" }],
    }),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    id: "mock-chat-completion",
    provider: "mock",
    model: "holo-mock",
    choices: [
      {
        index: 0,
        message: {
          role: "assistant",
          content: "Mock response for: 你好",
        },
        finish_reason: "stop",
      },
    ],
  });
});

test("POST /v1/ai/chat/completions streams SSE when stream is true", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "device-b",
    },
    body: JSON.stringify({
      purpose: "chat",
      stream: true,
      messages: [{ role: "user", content: "流式" }],
    }),
  });

  assert.equal(response.status, 200);
  assert.equal(response.headers.get("content-type"), "text/event-stream; charset=UTF-8");
  const text = await response.text();
  assert.match(text, /data: .*Mock/);
  assert.match(text, /data: \[DONE\]/);
});

test("chat endpoint rejects client-supplied provider routing fields", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "device-c",
    },
    body: JSON.stringify({
      purpose: "chat",
      baseURL: "https://attacker.example.com/v1",
      model: "client-chosen-model",
      stream: false,
      messages: [{ role: "user", content: "test" }],
    }),
  });

  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, "INVALID_CLIENT_ROUTING");
});

test("chat endpoint applies per-device minute rate limit", async () => {
  const app = createTestApp();
  const body = JSON.stringify({
    purpose: "chat",
    stream: false,
    messages: [{ role: "user", content: "rate" }],
  });

  for (let index = 0; index < 2; index += 1) {
    const response = await app.request("/v1/ai/chat/completions", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-holo-device-id": "rate-limited-device",
      },
      body,
    });
    assert.equal(response.status, 200);
  }

  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "rate-limited-device",
    },
    body,
  });

  assert.equal(response.status, 429);
  assert.equal((await response.json()).error.code, "RATE_LIMITED");
});
