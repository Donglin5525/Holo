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

test("完成后输入侧立即销毁；结果领取不删、ack 后删、未 ack 可重领（R1 确认制）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });

  const task = store.create({ deviceId: "device-a", question: "敏感问题原文" });
  assert.ok(store.attachSnapshot({ id: task.id, snapshot: '{"finance":{}}' }));
  assert.ok(store.transition(task.id, "running"));
  assert.ok(store.complete({ id: task.id, result: '{"title":"分析结论"}' }));

  // 完成即焚：问题与快照密文清空，结果仍在（等待领取）
  assert.ok(store.isDataDestroyed(task.id));
  assert.ok(store.hasResult(task.id));

  // 领取（GET）不删：响应丢失后可再次领取同一结果
  const first = store.getDecrypted(task.id);
  assert.equal(JSON.parse(first.result).title, "分析结论");
  assert.ok(store.hasResult(task.id));
  const second = store.getDecrypted(task.id);
  assert.equal(JSON.parse(second.result).title, "分析结论");

  // ack 确认后销毁；问题密文已焚为 null（不留副本）
  store.consumeResult(task.id);
  assert.ok(!store.hasResult(task.id));
  assert.equal(store.getDecrypted(task.id).question, null);
});

test("孤儿 running 任务启动重置回 queued（R2：进程重启不卡死）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const task = store.create({ deviceId: "device-a", question: "q" });
  store.attachSnapshot({ id: task.id, snapshot: "{}" });
  assert.ok(store.transition(task.id, "running"));

  // 模拟进程重启：running 且快照仍在 → 重置回 queued 供启动扫描重跑
  assert.equal(store.requeueOrphanRunning(), 1);
  assert.equal(store.get(task.id).status, "queued");
  assert.deepEqual(store.listQueued(), [task.id]);
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


// —— 任务类型（2026-09-01 周期回放云端化）——
test("start 端点：taskType 白名单校验与落库", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const app = createTestApp({ database, cloudAnalysisTaskStore: store });

  const bad = await app.request("/v1/ai/agent/cloud/start", {
    method: "POST", headers: headers(), body: JSON.stringify({ question: "q", taskType: "evil" }),
  });
  assert.equal(bad.status, 400);

  const replay = await app.request("/v1/ai/agent/cloud/start", {
    method: "POST", headers: headers(), body: JSON.stringify({ question: "本月", taskType: "period_replay" }),
  });
  assert.equal(replay.status, 200);
  const { taskId } = await replay.json();
  assert.equal(store.get(taskId).task_type, "period_replay");

  // replay_digest（2026-09-05 摘要云端化）：白名单内，独立落库
  const digest = await app.request("/v1/ai/agent/cloud/start", {
    method: "POST", headers: headers(), body: JSON.stringify({ question: "replay_digest", taskType: "replay_digest" }),
  });
  assert.equal(digest.status, 200);
  const { taskId: digestId } = await digest.json();
  assert.equal(store.get(digestId).task_type, "replay_digest");

  // 不传 taskType：默认 deep_analysis（存量客户端兼容）
  const def = await app.request("/v1/ai/agent/cloud/start", {
    method: "POST", headers: headers(), body: JSON.stringify({ question: "分析一下" }),
  });
  assert.equal(def.status, 200);
  const { taskId: defId } = await def.json();
  assert.equal(store.get(defId).task_type, "deep_analysis");
});
// —— 阶段推进（context_plan 阶段流，2026-09-09 方案 §5.3）——

test("updateStage：revision 单调递增；行不存在返回 false", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const task = store.create({ deviceId: "d1", question: "q", taskType: "context_plan" });

  assert.ok(store.updateStage(task.id, { stage: "cloudPlanning" }));
  assert.ok(store.updateStage(task.id, { stage: "draftReady" }));
  const row = store.get(task.id);
  assert.equal(row.stage, "draftReady");
  assert.equal(row.stage_revision, 2);
  assert.ok(row.updated_at_ms > 0);

  assert.equal(store.updateStage("no-such-task", { stage: "failed" }), false);
});

test("create：阶段列初始为 null、revision 0（非 context_plan 任务不受阶段语义影响）", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const task = store.create({ deviceId: "d1", question: "q", taskType: "deep_analysis" });
  const row = store.get(task.id);
  assert.equal(row.stage, null);
  assert.equal(row.stage_revision, 0);
});

// —— context_plan 路由契约（2026-09-09 方案 §5.3）：白名单放行 + GET 返回阶段 ——

test("context_plan：start 白名单放行；快照上传后 GET 返回 stage/stageRevision", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const app = createTestApp({ database, cloudAnalysisTaskStore: store });

  const start = await app.request("/v1/ai/agent/cloud/start", {
    method: "POST",
    headers: headers("device-plan"),
    body: JSON.stringify({ question: "要去日本旅行，要提前做什么准备", taskType: "context_plan" }),
  });
  assert.equal(start.status, 200, "context_plan 必须在任务类型白名单内");
  const startBody = await start.json();

  await app.request(`/v1/ai/agent/cloud/${startBody.taskId}/snapshot`, {
    method: "PUT",
    headers: headers("device-plan"),
    body: JSON.stringify({ prompt: "规划请求全文" }),
  });

  // 执行器是 no-op：手动推进阶段后，GET 必须把阶段快照带给轮询兜底通道
  store.updateStage(startBody.taskId, { stage: "cloudPlanning" });
  const poll = await app.request(`/v1/ai/agent/cloud/${startBody.taskId}`, {
    headers: headers("device-plan"),
  });
  assert.equal(poll.status, 200);
  const pollBody = await poll.json();
  assert.equal(pollBody.stage, "cloudPlanning");
  assert.ok(pollBody.stageRevision >= 1);
  assert.ok(pollBody.stageUpdatedAt > 0);
});

test("context_plan：未知任务类型仍然拒绝（白名单没有放水）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const app = createTestApp({ database, cloudAnalysisTaskStore: store });

  const start = await app.request("/v1/ai/agent/cloud/start", {
    method: "POST",
    headers: headers("device-x"),
    body: JSON.stringify({ question: "q", taskType: "context_plan_v2" }),
  });
  assert.equal(start.status, 400);
});
