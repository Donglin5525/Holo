import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import {
  completionReplayKey,
  createCompletionReplayCache,
} from "../src/usage/completionReplayCache.js";

const completion = (content = "{\"candidates\":[]}") => ({
  id: "c1",
  model: "m",
  choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
  usage: { prompt_tokens: 3000, completion_tokens: 600, total_tokens: 3600 },
});

const baseRequest = { purpose: "personal_context_extraction", model: "m", messages: [{ role: "user", content: "包 A" }] };

test("重放缓存：同指纹第二次命中，不再调用上游", async () => {
  const cache = createCompletionReplayCache();
  let calls = 0;
  const key = completionReplayKey({ deviceId: "d1", request: baseRequest });
  const first = await cache.run(key, async () => { calls++; return completion(); });
  const second = await cache.run(key, async () => { calls++; return completion(); });
  assert.equal(first.source, "upstream");
  assert.equal(second.source, "cache");
  assert.equal(calls, 1);
});

test("重放缓存：返回深拷贝，调用方改写不污染缓存", async () => {
  const cache = createCompletionReplayCache();
  const key = completionReplayKey({ deviceId: "d1", request: baseRequest });
  const first = await cache.run(key, async () => completion("原文"));
  first.result.choices[0].message.content = "被审核改写";
  const second = await cache.run(key, async () => completion("不该被调用"));
  assert.equal(second.result.choices[0].message.content, "原文");
});

test("重放缓存：同指纹并发合并为一次上游调用", async () => {
  const cache = createCompletionReplayCache();
  let calls = 0;
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const key = completionReplayKey({ deviceId: "d1", request: baseRequest });
  const compute = async () => { calls++; await gate; return completion(); };
  const a = cache.run(key, compute);
  const b = cache.run(key, compute);
  release();
  const [ra, rb] = await Promise.all([a, b]);
  assert.equal(calls, 1);
  assert.deepEqual([ra.source, rb.source].sort(), ["inflight", "upstream"]);
});

test("重放缓存：失败不缓存，下次重新调用", async () => {
  const cache = createCompletionReplayCache();
  let calls = 0;
  const key = completionReplayKey({ deviceId: "d1", request: baseRequest });
  await assert.rejects(cache.run(key, async () => { calls++; throw new Error("上游失败"); }));
  const retry = await cache.run(key, async () => { calls++; return completion(); });
  assert.equal(retry.source, "upstream");
  assert.equal(calls, 2);
});

test("重放缓存：过期后重新调用；设备或内容不同不串用", async () => {
  let clock = 0;
  const cache = createCompletionReplayCache({ ttlMs: 1000, now: () => clock });
  let calls = 0;
  const compute = async () => { calls++; return completion(); };
  const key = completionReplayKey({ deviceId: "d1", request: baseRequest });
  await cache.run(key, compute);
  clock = 1001;
  assert.equal((await cache.run(key, compute)).source, "upstream");
  const otherDevice = completionReplayKey({ deviceId: "d2", request: baseRequest });
  const otherContent = completionReplayKey({
    deviceId: "d1",
    request: { ...baseRequest, messages: [{ role: "user", content: "包 B" }] },
  });
  assert.notEqual(otherDevice, key);
  assert.notEqual(otherContent, key);
  assert.equal(calls, 2);
});

test("重放缓存：超出容量淘汰最早条目", async () => {
  const cache = createCompletionReplayCache({ maxEntries: 2 });
  for (const n of [1, 2, 3]) await cache.run(`k${n}`, async () => completion(String(n)));
  assert.equal(cache.size(), 2);
  let calls = 0;
  assert.equal((await cache.run("k1", async () => { calls++; return completion(); })).source, "upstream");
  assert.equal(calls, 1);
});

function makeApp() {
  const seen = [];
  const app = createApp({
    database: createDatabase({ dbPath: ":memory:" }),
    auth: { enforceAppAttest: false, enforceDeviceSession: false },
    aiCallLogs: { enabled: false },
    routes: {
      personal_context_extraction: { provider: "stub", model: "m", maxTokens: 100 },
      chat: { provider: "stub", model: "m", maxTokens: 100 },
    },
    providerOverrides: new Map([["stub", {
      async complete(request) { seen.push(request); return completion(); },
    }]]),
    runtimeEnvironment: "test",
  });
  return { app, seen };
}

function post(app, body) {
  return app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "user-agent": "Holo/99", "x-holo-device-id": "replay-test" },
    body: JSON.stringify(body),
  });
}

test("HTTP：萃取重发同一包命中重放缓存，且上游请求不绑定客户端断开信号", async () => {
  const { app, seen } = makeApp();
  const body = { purpose: "personal_context_extraction", messages: [{ role: "user", content: "包 A" }] };
  const first = await post(app, body);
  const second = await post(app, body);
  assert.equal(first.status, 200);
  assert.equal(second.status, 200);
  assert.equal(second.headers.get("x-holo-replay"), "cache");
  assert.equal(seen.length, 1);
  assert.equal(seen[0].clientSignal, undefined);
  assert.deepEqual(await second.json(), await first.json());
});

test("HTTP：普通对话不走重放缓存，断开信号照常透传", async () => {
  const { app, seen } = makeApp();
  const body = { purpose: "chat", messages: [{ role: "user", content: "你好" }] };
  await post(app, body);
  const second = await post(app, body);
  assert.equal(second.headers.get("x-holo-replay"), null);
  assert.equal(seen.length, 2);
  assert.ok(seen[0].clientSignal);
});
