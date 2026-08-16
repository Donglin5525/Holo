import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

// P2（方案 §5.2）：thought_embedding 批量端点测试
// 每个测试使用独立的内存数据库

function createEmbeddingTestApp(overrides = {}) {
  return createApp({
    database: createDatabase({ dbPath: `:memory:` }),
    auth: { enforceAppAttest: false },
    routes: {
      thought_embedding: {
        provider: "mock",
        model: "mock-embedding",
        dimensions: 64,
        requestLimits: { perMinute: 20, perDay: 120 },
      },
    },
    ...overrides,
  });
}

test("POST /v1/ai/embeddings returns deterministic vectors for texts", async () => {
  const app = createEmbeddingTestApp();

  const response = await app.request("/v1/ai/embeddings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ purpose: "thought_embedding", texts: ["今天复盘了项目进度", "和客户对了埋点口径"] }),
  });

  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.model, "mock-embedding");
  assert.equal(body.vectors.length, 2);
  assert.equal(body.vectors[0].length, 64);
  // mock 向量已归一化
  const norm = body.vectors[0].reduce((sum, v) => sum + v * v, 0);
  assert.ok(Math.abs(norm - 1) < 1e-6);
  // 同文本重放确定性
  const replay = await app.request("/v1/ai/embeddings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ purpose: "thought_embedding", texts: ["今天复盘了项目进度"] }),
  });
  const replayBody = await replay.json();
  assert.deepEqual(replayBody.vectors[0], body.vectors[0]);
});

test("POST /v1/ai/embeddings rejects invalid texts", async () => {
  const app = createEmbeddingTestApp();

  for (const texts of [[], ["", "ok"], [123], new Array(17).fill("x")]) {
    const response = await app.request("/v1/ai/embeddings", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ texts }),
    });
    assert.equal(response.status, 400, `texts=${JSON.stringify(texts).slice(0, 30)} should be rejected`);
  }
});

test("POST /v1/ai/embeddings rejects unknown purpose", async () => {
  const app = createEmbeddingTestApp();

  const response = await app.request("/v1/ai/embeddings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ purpose: "chat", texts: ["hello"] }),
  });

  assert.equal(response.status, 400);
});

test("POST /v1/ai/embeddings enforces per-minute rate limit", async () => {
  const app = createEmbeddingTestApp({
    routes: {
      thought_embedding: {
        provider: "mock",
        model: "mock-embedding",
        dimensions: 64,
        requestLimits: { perMinute: 2, perDay: 10 },
      },
    },
  });

  for (let i = 0; i < 2; i += 1) {
    const response = await app.request("/v1/ai/embeddings", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ texts: ["第一条"] }),
    });
    assert.equal(response.status, 200);
  }

  const limited = await app.request("/v1/ai/embeddings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ texts: ["第三条"] }),
  });
  assert.equal(limited.status, 429);
});

test("POST /v1/ai/embeddings does not consume chat rate limit bucket", async () => {
  // embedding 独立限流桶：chat 限额为 1 且已被 chat 消耗时，embedding 仍可用
  const app = createEmbeddingTestApp({
    limits: { chatRequestsPerMinute: 1, chatRequestsPerDay: 1 },
    routes: {
      chat: { provider: "mock", model: "holo-mock", temperature: 0.2, maxTokens: 64 },
      thought_embedding: {
        provider: "mock",
        model: "mock-embedding",
        dimensions: 64,
        requestLimits: { perMinute: 5, perDay: 10 },
      },
    },
  });

  const chatResponse = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ purpose: "chat", messages: [{ role: "user", content: "hi" }] }),
  });
  assert.equal(chatResponse.status, 200);

  const embeddingResponse = await app.request("/v1/ai/embeddings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ texts: ["独立桶验证"] }),
  });
  assert.equal(embeddingResponse.status, 200);
});

test("POST /v1/ai/embeddings returns 503 when provider lacks embed", async () => {
  const app = createEmbeddingTestApp({
    routes: {
      thought_embedding: {
        provider: "not-exists",
        model: "x",
        requestLimits: { perMinute: 5, perDay: 10 },
      },
    },
  });

  const response = await app.request("/v1/ai/embeddings", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ texts: ["x"] }),
  });
  assert.equal(response.status, 503);
});
