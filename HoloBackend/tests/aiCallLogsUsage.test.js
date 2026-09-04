import test from "node:test";
import assert from "node:assert/strict";
import { createDatabase } from "../src/db/database.js";
import { createAdminLogStore } from "../src/admin/adminLogStore.js";

// 2026-09-04 成本计量：token 用量落 ai_call_logs 独立列（migration 19）。
// 此前 usage 只藏在 response_summary 里，超 50KB 截断的调用（insight/长 agent 轮）
// usage 随之丢失，成本核算存在盲区——这条测试锁定「usage 必须走独立通道落库」。

function makeStore() {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createAdminLogStore({
    db: database.db,
    contentCaptureEnabled: false,
  });
  return { store, db: database.db };
}

test("finishAiCall 把上游 usage 落到独立 token 列", () => {
  const { store, db } = makeStore();

  const id = store.startAiCall({
    deviceId: "device-usage-1",
    purpose: "insight",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    stream: true,
    request: { messageCount: 2 },
  });
  store.finishAiCall(id, {
    status: "success",
    response: { text: "…" },
    usage: {
      prompt_tokens: 13213,
      completion_tokens: 1844,
      total_tokens: 15057,
      prompt_tokens_details: { cached_tokens: 13184 },
      completion_tokens_details: { reasoning_tokens: 1500 },
    },
  });

  const row = db.prepare("SELECT prompt_tokens, completion_tokens, cached_tokens, reasoning_tokens FROM ai_call_logs WHERE rowid = 1").get();
  assert.equal(row.prompt_tokens, 13213);
  assert.equal(row.completion_tokens, 1844);
  assert.equal(row.cached_tokens, 13184);
  assert.equal(row.reasoning_tokens, 1500);

  const detail = store.get(id);
  assert.deepEqual(detail.usage, {
    promptTokens: 13213,
    completionTokens: 1844,
    cachedTokens: 13184,
    reasoningTokens: 1500,
  });
});

test("无 usage（如调用失败）时 token 列保持 NULL，不影响日志主流程", () => {
  const { store, db } = makeStore();

  const id = store.startAiCall({
    deviceId: "device-usage-2",
    purpose: "agent_loop",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    stream: true,
    request: { messageCount: 3 },
  });
  store.finishAiCall(id, {
    status: "error",
    response: null,
    error: { code: "CLIENT_ABORTED", message: "Client disconnected before completion" },
    usage: null,
  });

  const row = db.prepare("SELECT prompt_tokens, completion_tokens, error_message FROM ai_call_logs WHERE rowid = 1").get();
  assert.equal(row.prompt_tokens, null);
  assert.equal(row.completion_tokens, null);
  assert.match(row.error_message, /CLIENT_ABORTED/);
});

test("usage 形状异常（缺 token 数字段）时静默记 NULL，不炸调用方", () => {
  const { store, db } = makeStore();

  const id = store.startAiCall({
    deviceId: "device-usage-3",
    purpose: "intent",
    provider: "deepseek",
    model: "deepseek-v4-flash",
    stream: false,
    request: { messageCount: 1 },
  });
  store.finishAiCall(id, { status: "success", response: { text: "ok" }, usage: { total_tokens: 100 } });

  const row = db.prepare("SELECT prompt_tokens, completion_tokens FROM ai_call_logs WHERE rowid = 1").get();
  assert.equal(row.prompt_tokens, null);
  assert.equal(row.completion_tokens, null);
});
