import assert from "node:assert/strict";
import { test } from "node:test";
import { createOpenAICompatibleProvider } from "../src/providers/openAICompatibleProvider.js";
import { createSqliteUsageStore } from "../src/usage/sqliteUsageStore.js";
import { createInMemoryUsageStore } from "../src/usage/inMemoryUsageStore.js";
import { createDatabase } from "../src/db/database.js";
import { createThoughtOrganizeBudgetStore } from "../src/thoughts/thoughtOrganizeBudgetStore.js";
import { loadConfig } from "../src/config.js";

test("16 条客户端批次拆成通义允许的 10+6，维度与顺序保持不变", async () => {
  const originalFetch = globalThis.fetch;
  const sizes = [];
  globalThis.fetch = async (_, init) => {
    const body = JSON.parse(init.body);
    assert.equal(body.dimensions, 2);
    assert.equal(body.encoding_format, "float");
    assert.ok(body.input.length <= 10, "供应商批次不能超过 10 条");
    sizes.push(body.input.length);
    return { ok: true, status: 200, json: async () => ({
      data: body.input.map((text, index) => ({ index, embedding: [Number(text), 1] })).reverse(),
    }) };
  };
  try {
    const provider = createOpenAICompatibleProvider({ baseURL: "https://test.invalid", apiKey: "test", embeddingBatchSize: 10 });
    const result = await provider.embed({ model: "text-embedding-v3", dimensions: 2,
      texts: Array.from({ length: 16 }, (_, i) => String(i)) });
    assert.deepEqual(sizes, [10, 6]);
    assert.deepEqual(result.vectors.map(v => v[0]), Array.from({ length: 16 }, (_, i) => i));
  } finally { globalThis.fetch = originalFetch; }
});

test("关闭日次数上限后历史回填继续，分钟保护与费用台账仍有效", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  for (const usage of [createSqliteUsageStore(database.db), createInMemoryUsageStore()]) {
    for (let i = 0; i < 125; i++) {
      assert.equal(usage.consume({ deviceId: "history", purpose: "thought_embedding", minuteLimit: 125, dailyLimit: 0 }).allowed, true);
    }
    assert.equal(usage.consume({ deviceId: "history", purpose: "thought_embedding", minuteLimit: 125, dailyLimit: 0 }).reason, "minute_limit");
  }
  const store = createThoughtOrganizeBudgetStore(database.db);
  assert.equal(store.beginOperation({ subjectId: "history", operationId: "no-cap", estimateMicro: 1_000_000, dailyBudgetMicro: 0 }).allowed, true);
  assert.equal(store.reserveMore({ operationId: "no-cap", estimateMicro: 1_000_000, dailyBudgetMicro: 0 }), true);
  store.settleOperation({ operationId: "no-cap", estimateMicro: 2_000_000, actualMicro: 1_500_000, status: "completed" });
  assert.equal(store.dailySnapshot("history").committedMicro, 1_500_000);
  assert.equal(store.dailySnapshot("history").reservedMicro, 0);
  database.db.close();
});

test("默认想法索引、归类和主题生成不设日次数或日金额上限", () => {
  const config = loadConfig();
  assert.equal(config.providers.qwen.embeddingBatchSize, 10);
  assert.equal(config.routes.thought_embedding.requestLimits.perDay, 0);
  assert.equal(config.thoughtSemanticRelate.requestLimits.perDay, 0);
  assert.equal(config.thoughtSemanticRelate.budgets.perSubjectDailyCNY, 0);
  assert.equal(config.thoughtTopicInsight.requestLimits.perDay, 0);
  assert.equal(config.thoughtTopicInsight.budgets.perSubjectDailyCNY, 0);
});
