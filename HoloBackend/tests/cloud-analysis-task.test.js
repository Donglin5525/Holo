import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes } from "node:crypto";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { createCloudAnalysisTaskStore } from "../src/agent/cloudAnalysisTaskStore.js";

const TEST_KEY = randomBytes(32).toString("base64");

function createTestApp(overrides = {}) {
  const database = createDatabase({ dbPath: ":memory:" });
  return createApp({
    database,
    auth: { enforceAppAttest: false },
    limits: {
      chatRequestsPerMinute: 100,
      chatRequestsPerDay: 1000,
      cloudAnalysisStartsPerMinute: 100,
      cloudAnalysisStartsPerDay: 1000,
    },
    aiCallLogs: { enabled: false },
    runtimeEnvironment: "test",
    cloudAnalysisEncryptionKey: TEST_KEY,
    // no-op 执行器：上传后不自动跑（密文销毁是执行器行为，端点测试只验证存取契约）
    cloudAnalysisExecutor: { run: async () => "queued" },
    ...overrides,
  });
}

function headers(deviceId = "device-a") {
  return {
    "content-type": "application/json",
    "x-holo-device-id": deviceId,
  };
}

test("任务全生命周期：创建→上传快照→queued；快照与问题密文落存", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const app = createTestApp({ database, cloudAnalysisTaskStore: store });

  const start = await app.request("/v1/ai/agent/cloud/start", {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({ question: "分析我上个月的支出结构" }),
  });
  assert.equal(start.status, 200);
  const { taskId, status } = await start.json();
  assert.equal(status, "uploading");

  const snapshot = JSON.stringify({
    version: 1,
    finance: { transactions: [{ amount: -42.5, category: "餐饮" }] },
    tasks: [],
  });
  const put = await app.request(`/v1/ai/agent/cloud/${taskId}/snapshot`, {
    method: "PUT",
    headers: { ...headers(), "content-type": "application/json" },
    body: snapshot,
  });
  assert.equal(put.status, 200);
  assert.equal((await put.json()).status, "queued");

  // 密文落盘断言：裸表行中不出现明文问题与明文快照内容
  const row = store.get(taskId);
  assert.ok(!row.question_ciphertext.includes("支出结构"));
  assert.ok(!row.snapshot_ciphertext.includes("餐饮"));
  assert.equal(store.getDecrypted(taskId).question, "分析我上个月的支出结构");
});

test("密钥未配置时端点优雅禁用（503），服务正常启动", async () => {
  const app = createTestApp({ cloudAnalysisEncryptionKey: "" });
  const res = await app.request("/v1/ai/agent/cloud/start", {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({ question: "x" }),
  });
  assert.equal(res.status, 503);
});

test("跨设备访问 404（所有权隔离）", async () => {
  const app = createTestApp();
  const start = await app.request("/v1/ai/agent/cloud/start", {
    method: "POST",
    headers: headers("device-a"),
    body: JSON.stringify({ question: "q" }),
  });
  const { taskId } = await start.json();

  assert.equal((await app.request(`/v1/ai/agent/cloud/${taskId}`, {
    headers: headers("device-b"),
  })).status, 404);
  assert.equal((await app.request(`/v1/ai/agent/cloud/${taskId}/snapshot`, {
    method: "PUT",
    headers: headers("device-b"),
    body: "{}",
  })).status, 404);
  assert.equal((await app.request(`/v1/ai/agent/cloud/${taskId}`, {
    method: "DELETE",
    headers: headers("device-b"),
  })).status, 404);
});

test("完成后输入侧数据立即销毁；结果回传一次后销毁（隐私契约代码化）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });

  const task = store.create({ deviceId: "device-a", question: "敏感问题原文" });
  assert.ok(store.attachSnapshot({ id: task.id, snapshot: '{"finance":{}}' }));
  assert.ok(store.transition(task.id, "running"));
  assert.ok(store.complete({ id: task.id, result: '{"title":"分析结论"}' }));

  // 完成即焚：问题与快照密文清空，结果仍在（等待回传）
  assert.ok(store.isDataDestroyed(task.id));
  const after = store.get(task.id);
  assert.notEqual(after.result_ciphertext, null);

  // 回传一次：结果解密正确且随后销毁
  const fetched = store.getDecrypted(task.id);
  assert.equal(JSON.parse(fetched.result).title, "分析结论");
  store.consumeResult(task.id);
  assert.equal(store.get(task.id).result_ciphertext, null);
  // 问题密文已焚，再解密问题应得 null（不留副本）
  assert.equal(store.getDecrypted(task.id).question, null);
});

test("失败路径同样销毁输入侧数据，失败原因密文可回传", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const task = store.create({ deviceId: "device-a", question: "q" });
  store.attachSnapshot({ id: task.id, snapshot: "{}" });
  assert.ok(store.fail({ id: task.id, reason: "上游模型不可用" }));

  assert.ok(store.isDataDestroyed(task.id));
  const row = store.getDecrypted(task.id);
  assert.equal(row.failureReason, "上游模型不可用");
  assert.equal(row.question, null);
});

test("用户取消：整行销毁", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const task = store.create({ deviceId: "device-a", question: "q" });
  store.cancel(task.id);
  assert.equal(store.get(task.id), null);
});

test("7 天过期兜底清理", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const now = Date.now();
  const stale = store.create({ deviceId: "d", question: "q", now: now - 8 * 24 * 3600 * 1000 });
  const fresh = store.create({ deviceId: "d", question: "q", now });
  const purged = store.purgeExpired(now);
  assert.equal(purged, 1);
  assert.equal(store.get(stale.id), null);
  assert.notEqual(store.get(fresh.id), null);
});

test("重复上传快照与非法快照被拒", async () => {
  const app = createTestApp();
  const start = await app.request("/v1/ai/agent/cloud/start", {
    method: "POST",
    headers: headers(),
    body: JSON.stringify({ question: "q" }),
  });
  const { taskId } = await start.json();

  assert.equal((await app.request(`/v1/ai/agent/cloud/${taskId}/snapshot`, {
    method: "PUT", headers: headers(), body: "not-json{",
  })).status, 400);
  assert.equal((await app.request(`/v1/ai/agent/cloud/${taskId}/snapshot`, {
    method: "PUT", headers: headers(), body: "[1,2]",
  })).status, 400);

  assert.equal((await app.request(`/v1/ai/agent/cloud/${taskId}/snapshot`, {
    method: "PUT", headers: headers(), body: '{"tasks":[]}',
  })).status, 200);
  // 已接收后再传：409
  assert.equal((await app.request(`/v1/ai/agent/cloud/${taskId}/snapshot`, {
    method: "PUT", headers: headers(), body: '{"tasks":[]}',
  })).status, 409);
});
