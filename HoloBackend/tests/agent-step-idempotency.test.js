import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { createStepIdempotencyStore } from "../src/agent/stepIdempotencyStore.js";
import {
  AgentStepEncryptionError,
  createStepResponseCipher,
} from "../src/agent/stepResponseCipher.js";
import { GatewayError } from "../src/errors.js";

const TEST_ENCRYPTION_KEY = Buffer.alloc(32, 0x11).toString("base64");

function makeCipher(primaryKey = TEST_ENCRYPTION_KEY, previousKeys = []) {
  return createStepResponseCipher({ primaryKey, previousKeys });
}

function makeStore(database, primaryKey = TEST_ENCRYPTION_KEY, previousKeys = []) {
  return createStepIdempotencyStore(database.db, {
    responseCipher: makeCipher(primaryKey, previousKeys),
  });
}

const AGENT_CONTENT = JSON.stringify({
  status: "need_more_analysis",
  reasoning: "测试幂等响应",
  toolRequests: [],
  claims: [],
  warnings: [],
});

function makeAgentCompletion(id = "agent-completion-1", content = AGENT_CONTENT) {
  return {
    id,
    provider: "fake",
    model: "agent-model",
    choices: [
      {
        index: 0,
        message: { role: "assistant", content },
        finish_reason: "stop",
      },
    ],
    usage: { prompt_tokens: 11, completion_tokens: 7, total_tokens: 18 },
  };
}

function createTestApp(provider, overrides = {}) {
  return createApp({
    database: createDatabase({ dbPath: ":memory:" }),
    auth: { enforceAppAttest: false },
    limits: { chatRequestsPerMinute: 100, chatRequestsPerDay: 1000 },
    aiCallLogs: { enabled: false },
    routes: {
      agent_loop: { provider: "fake", model: "agent-model", temperature: 0, maxTokens: 1024 },
    },
    providerOverrides: new Map([["fake", provider]]),
    agentStepIdempotencyEncryptionKey: TEST_ENCRYPTION_KEY,
    runtimeEnvironment: "test",
    ...overrides,
  });
}

function sendAgentStep(app, { runId, stepId, requestHash } = {}) {
  const body = {
    purpose: "agent_loop",
    stream: false,
    messages: [{ role: "user", content: "分析我的睡眠" }],
  };
  if (runId !== undefined) body.runId = runId;
  if (stepId !== undefined) body.stepId = stepId;
  if (requestHash !== undefined) body.requestHash = requestHash;
  return app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "device-a",
    },
    body: JSON.stringify(body),
  });
}

test("真实事故形状经过接口后返回可解码的同级 dynamicPlan", async () => {
  const nestedPlanContent = JSON.stringify({
    status: "need_tools",
    reasoning: "比较本月和上月分类支出",
    toolRequests: [{
      id: "finance-comparison",
      tool: "finance",
      query: "dynamic_query",
      parameters: {
        dynamicPlan: {
          source: "finance.transactions",
          timeRange: {
            label: "本月",
            start: "2026-07-01",
            end: "2026-08-01",
          },
          filters: [{
            field: "type",
            operation: "equal",
            value: { type: "text", text: "expense" },
          }],
          groupBy: [{ type: "field", field: "category" }],
          aggregations: [{
            id: "category_amount",
            operation: "sum",
            field: "amount",
            unit: "元",
          }],
          derivations: [],
          limit: "3",
        },
        retry: 1,
      },
    }],
    claims: [],
    warnings: [],
  });
  const provider = {
    async complete() {
      return makeAgentCompletion("incident-shape", nestedPlanContent);
    },
  };
  const app = createTestApp(provider);

  const response = await sendAgentStep(app, {
    runId: "incident-run",
    stepId: "llm-1-1",
    requestHash: "incident-hash",
  });

  assert.equal(response.status, 200);
  const body = await response.json();
  const content = JSON.parse(body.choices[0].message.content);
  const request = content.toolRequests[0];
  assert.equal(request.dynamicPlan.source, "finance.transactions");
  assert.equal(request.dynamicPlan.timeRange, null);
  assert.equal(request.dynamicPlan.limit, 3);
  assert.equal(request.parameters.retry, "1");
  assert.equal(request.parameters.dynamicPlan, undefined);
});

test("坏 Agent JSON 返回可恢复继续轮且幂等重放，不提前终止旧客户端任务", async () => {
  let calls = 0;
  const provider = {
    async complete() {
      calls += 1;
      return makeAgentCompletion("invalid-agent-json", "{\"status\":\"final_claims\"");
    },
  };
  const app = createTestApp(provider);
  const step = {
    runId: "recovery-run",
    stepId: "llm-2-2",
    requestHash: "recovery-hash",
  };

  const first = await sendAgentStep(app, step);
  assert.equal(first.status, 200);
  const firstBody = await first.json();
  const recovery = JSON.parse(firstBody.choices[0].message.content);
  assert.equal(recovery.status, "need_more_analysis");
  assert.deepEqual(recovery.toolRequests, []);
  assert.deepEqual(recovery.claims, []);
  assert.match(recovery.reasoning, /HOLO_AGENT_RESPONSE_RECOVERY_V1/);
  assert.deepEqual(recovery.warnings, ["response_contract_recovery"]);

  const replay = await sendAgentStep(app, step);
  assert.equal(replay.status, 200);
  assert.equal(replay.headers.get("x-holo-step-idempotency"), "hit");
  assert.deepEqual(await replay.json(), firstBody);
  assert.equal(calls, 1);
});

test("same runId+stepId+requestHash retry returns identical response, provider called once", async () => {
  let calls = 0;
  const provider = {
    async complete() {
      calls += 1;
      return makeAgentCompletion();
    },
  };
  const app = createTestApp(provider);
  const step = { runId: "run-1", stepId: "llm-0-1", requestHash: "hash-a" };

  const first = await sendAgentStep(app, step);
  assert.equal(first.status, 200);
  const firstBody = await first.json();

  const second = await sendAgentStep(app, step);
  assert.equal(second.status, 200);
  assert.equal(second.headers.get("x-holo-step-idempotency"), "hit");
  const secondBody = await second.json();

  assert.equal(calls, 1);
  assert.deepEqual(secondBody, firstBody);
});

test("same step with different requestHash returns 409 STEP_ID_CONFLICT", async () => {
  let calls = 0;
  const provider = {
    async complete() {
      calls += 1;
      return makeAgentCompletion();
    },
  };
  const app = createTestApp(provider);

  const first = await sendAgentStep(app, { runId: "run-1", stepId: "llm-0-1", requestHash: "hash-a" });
  assert.equal(first.status, 200);

  const conflict = await sendAgentStep(app, { runId: "run-1", stepId: "llm-0-1", requestHash: "hash-b" });
  assert.equal(conflict.status, 409);
  assert.equal((await conflict.json()).error.code, "STEP_ID_CONFLICT");
  assert.equal(calls, 1);
});

test("retry while step is processing returns 409 STEP_IN_PROGRESS", async () => {
  let calls = 0;
  let release;
  const gate = new Promise((resolve) => {
    release = resolve;
  });
  const provider = {
    async complete() {
      calls += 1;
      await gate;
      return makeAgentCompletion();
    },
  };
  const app = createTestApp(provider);
  const step = { runId: "run-2", stepId: "llm-1-1", requestHash: "hash-c" };

  const firstPromise = sendAgentStep(app, step);
  while (calls === 0) {
    await new Promise((resolve) => setImmediate(resolve));
  }

  const second = await sendAgentStep(app, step);
  assert.equal(second.status, 409);
  assert.equal((await second.json()).error.code, "STEP_IN_PROGRESS");

  release();
  const first = await firstPromise;
  assert.equal(first.status, 200);
  assert.equal(calls, 1);
});

test("retryable provider failure allows controlled retry, provider called twice", async () => {
  let calls = 0;
  const provider = {
    async complete() {
      calls += 1;
      if (calls === 1) {
        throw new GatewayError("UPSTREAM_ERROR", "boom", 502);
      }
      return makeAgentCompletion("agent-completion-retry");
    },
  };
  const app = createTestApp(provider);
  const step = { runId: "run-3", stepId: "llm-2-1", requestHash: "hash-d" };

  const first = await sendAgentStep(app, step);
  assert.equal(first.status, 502);
  assert.equal((await first.json()).error.code, "UPSTREAM_ERROR");

  const second = await sendAgentStep(app, step);
  assert.equal(second.status, 200);
  assert.equal((await second.json()).id, "agent-completion-retry");
  assert.equal(calls, 2);
});

test("terminal provider failure replays same error without calling provider again", async () => {
  let calls = 0;
  const provider = {
    async complete() {
      calls += 1;
      throw new GatewayError("UPSTREAM_AUTH_FAILED", "bad key", 401);
    },
  };
  const app = createTestApp(provider);
  const step = { runId: "run-4", stepId: "llm-3-1", requestHash: "hash-e" };

  const first = await sendAgentStep(app, step);
  assert.equal(first.status, 401);
  const firstBody = await first.json();
  assert.equal(firstBody.error.code, "UPSTREAM_AUTH_FAILED");

  const second = await sendAgentStep(app, step);
  assert.equal(second.status, 401);
  assert.deepEqual(await second.json(), firstBody);
  assert.equal(calls, 1);
});

test("legacy agent_loop request without step identity keeps original behavior", async () => {
  let calls = 0;
  const provider = {
    async complete() {
      calls += 1;
      return makeAgentCompletion(`legacy-${calls}`);
    },
  };
  const app = createTestApp(provider);

  const first = await sendAgentStep(app, {});
  assert.equal(first.status, 200);
  const firstBody = await first.json();

  const second = await sendAgentStep(app, {});
  assert.equal(second.status, 200);
  assert.equal(second.headers.get("x-holo-step-idempotency"), null);
  const secondBody = await second.json();

  assert.equal(calls, 2);
  assert.notDeepEqual(secondBody, firstBody);
});

test("partial step identity is rejected with 400 INVALID_REQUEST", async () => {
  let calls = 0;
  const provider = {
    async complete() {
      calls += 1;
      return makeAgentCompletion();
    },
  };
  const app = createTestApp(provider);

  const response = await sendAgentStep(app, { runId: "run-5", stepId: "llm-4-1" });
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, "INVALID_REQUEST");
  assert.equal(calls, 0);
});

test("expired record is treated as missing and the step runs again", async () => {
  let calls = 0;
  const provider = {
    async complete() {
      calls += 1;
      return makeAgentCompletion(`fresh-${calls}`);
    },
  };
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createTestApp(provider, { database });

  // 直接写入一条已过期的 completed 记录（ttl 为负 → expires_at 在过去）
  const store = makeStore(database);
  store.createProcessing("run-6", "llm-5-1", "hash-f", -1);
  store.markCompleted("run-6", "llm-5-1", makeAgentCompletion("stale"), null);
  assert.equal(store.get("run-6", "llm-5-1"), null);

  const response = await sendAgentStep(app, { runId: "run-6", stepId: "llm-5-1", requestHash: "hash-f" });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).id, "fresh-1");
  assert.equal(calls, 1);
});

test("createProcessing returns false on duplicate step (unique constraint)", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = makeStore(database);

  assert.equal(store.createProcessing("run-x", "llm-0-1", "hash-x", 60), true);
  assert.equal(store.createProcessing("run-x", "llm-0-1", "hash-x", 60), false);

  database.close();
});

test("purgeExpired removes only expired records", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = makeStore(database);

  store.createProcessing("run-old", "llm-0-1", "hash-old", -1);
  store.createProcessing("run-live", "llm-0-1", "hash-live", 3600);

  const purged = store.purgeExpired(Date.now());
  assert.equal(purged, 1);

  const live = store.get("run-live", "llm-0-1");
  assert.ok(live);
  assert.equal(live.status, "processing");

  database.close();
});

test("idempotency records survive database reopen (container restart semantics)", () => {
  const dir = mkdtempSync(join(tmpdir(), "holo-step-idem-"));
  const dbPath = join(dir, "test.db");
  try {
    const first = createDatabase({ dbPath });
    const storeA = makeStore(first);
    storeA.createProcessing("run-7", "llm-6-1", "hash-g", 3600);
    storeA.markCompleted("run-7", "llm-6-1", makeAgentCompletion("persisted"), { total_tokens: 18 });
    first.close();

    const second = createDatabase({ dbPath });
    const storeB = makeStore(second);
    const record = storeB.get("run-7", "llm-6-1");
    assert.ok(record);
    assert.equal(record.status, "completed");
    assert.equal(record.requestHash, "hash-g");
    assert.equal(JSON.parse(record.response).id, "persisted");
    assert.equal(record.usage.total_tokens, 18);
    second.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("completed response is AES-GCM ciphertext at rest and still replays identically", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = makeStore(database);
  const response = makeAgentCompletion("encrypted-at-rest");

  store.createProcessing("run-encrypted", "llm-0-1", "hash-encrypted", 3600);
  store.markCompleted("run-encrypted", "llm-0-1", response, { total_tokens: 18 });

  const raw = database.db.prepare(`
    SELECT response FROM agent_step_idempotency
    WHERE run_id = ? AND step_id = ?
  `).get("run-encrypted", "llm-0-1").response;
  assert.match(raw, /^holo-agent-step:v1:/);
  assert.equal(raw.includes("encrypted-at-rest"), false);
  assert.equal(raw.includes(AGENT_CONTENT), false);

  const record = store.get("run-encrypted", "llm-0-1");
  assert.deepEqual(JSON.parse(record.response), response);
  assert.deepEqual(record.usage, { total_tokens: 18 });
  assert.deepEqual(store.encryptionMetadata(), { algorithm: "aes-256-gcm-v1" });
  database.close();
});

test("legacy plaintext response is encrypted transactionally on store startup", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const now = Date.now();
  const plaintext = JSON.stringify(makeAgentCompletion("legacy-plaintext"));
  database.db.prepare(`
    INSERT INTO agent_step_idempotency
      (run_id, step_id, request_hash, status, response, created_at, updated_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).run(
    "run-legacy",
    "llm-1-1",
    "hash-legacy",
    "completed",
    plaintext,
    now,
    now,
    now + 3600_000,
  );

  const store = makeStore(database);
  assert.deepEqual(store.migrationSummary, { migrated: 1, rotated: 0 });
  const raw = database.db.prepare(`
    SELECT response FROM agent_step_idempotency WHERE run_id = ? AND step_id = ?
  `).get("run-legacy", "llm-1-1").response;
  assert.match(raw, /^holo-agent-step:v1:/);
  assert.equal(raw.includes("legacy-plaintext"), false);
  assert.equal(store.get("run-legacy", "llm-1-1").response, plaintext);
  database.close();
});

test("key rotation decrypts with previous key and rewraps with the active key", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const oldKey = Buffer.alloc(32, 0x22).toString("base64");
  const newKey = Buffer.alloc(32, 0x33).toString("base64");
  const oldStore = makeStore(database, oldKey);
  oldStore.createProcessing("run-rotate", "llm-2-1", "hash-rotate", 3600);
  oldStore.markCompleted(
    "run-rotate",
    "llm-2-1",
    makeAgentCompletion("rotate-me"),
    null,
  );
  const before = database.db.prepare(`
    SELECT response FROM agent_step_idempotency WHERE run_id = ? AND step_id = ?
  `).get("run-rotate", "llm-2-1").response;

  const newStore = makeStore(database, newKey, [oldKey]);
  assert.deepEqual(newStore.migrationSummary, { migrated: 0, rotated: 1 });
  const after = database.db.prepare(`
    SELECT response FROM agent_step_idempotency WHERE run_id = ? AND step_id = ?
  `).get("run-rotate", "llm-2-1").response;
  assert.notEqual(after, before);
  assert.equal(JSON.parse(newStore.get("run-rotate", "llm-2-1").response).id, "rotate-me");
  assert.throws(
    () => createStepIdempotencyStore(database.db, { responseCipher: makeCipher(oldKey) }),
    (error) => error instanceof AgentStepEncryptionError
      && error.code === "AGENT_STEP_ENCRYPTION_KEY_UNAVAILABLE",
  );
  database.close();
});

test("tampered ciphertext fails closed instead of becoming a cache miss", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = makeStore(database);
  store.createProcessing("run-tamper", "llm-3-1", "hash-tamper", 3600);
  store.markCompleted("run-tamper", "llm-3-1", makeAgentCompletion("tamper"), null);

  const raw = database.db.prepare(`
    SELECT response FROM agent_step_idempotency WHERE run_id = ? AND step_id = ?
  `).get("run-tamper", "llm-3-1").response;
  const parts = raw.split(":");
  const firstTagCharacter = parts[4][0];
  parts[4] = `${firstTagCharacter === "A" ? "B" : "A"}${parts[4].slice(1)}`;
  const tampered = parts.join(":");
  database.db.prepare(`
    UPDATE agent_step_idempotency SET response = ? WHERE run_id = ? AND step_id = ?
  `).run(tampered, "run-tamper", "llm-3-1");

  assert.throws(
    () => store.get("run-tamper", "llm-3-1"),
    (error) => error instanceof AgentStepEncryptionError
      && error.code === "AGENT_STEP_ENCRYPTION_AUTH_FAILED",
  );
  database.close();
});

test("cipher rejects missing, malformed, and wrong-identity keys", () => {
  assert.throws(
    () => createStepResponseCipher({ allowEphemeral: false }),
    (error) => error.code === "AGENT_STEP_ENCRYPTION_KEY_MISSING",
  );
  assert.throws(
    () => createStepResponseCipher({ primaryKey: "not-a-32-byte-key" }),
    (error) => error.code === "AGENT_STEP_ENCRYPTION_KEY_INVALID",
  );

  const cipher = makeCipher(randomBytes(32).toString("base64"));
  const identity = { runId: "run-aad", stepId: "llm-4-1", requestHash: "hash-aad" };
  const encrypted = cipher.encrypt("sensitive-response", identity);
  assert.equal(cipher.decrypt(encrypted, identity), "sensitive-response");
  assert.throws(
    () => cipher.decrypt(encrypted, { ...identity, stepId: "llm-4-2" }),
    (error) => error.code === "AGENT_STEP_ENCRYPTION_AUTH_FAILED",
  );
});

test("production app fails before opening storage when the encryption key is missing", () => {
  assert.throws(
    () => createApp({
      runtimeEnvironment: "production",
      agentStepIdempotencyEncryptionKey: "",
    }),
    (error) => error instanceof AgentStepEncryptionError
      && error.code === "AGENT_STEP_ENCRYPTION_KEY_MISSING",
  );
});
