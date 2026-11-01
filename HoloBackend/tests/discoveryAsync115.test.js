// 「一个发现」1.1.5 S3–S6：候选异步作业 + 加密落库 + 重启恢复 + 失败不烧名额。
// 背景（2026-11-02 根因调研）：候选阶段 60–71s 同步长连接，App 必须一直开在前台等结果；
// 中途锁屏/切走/断连 → 结果丢失 + 当日名额烧掉。改为：启动 <1s 返回、服务器后台跑、
// 客户端随时取件；结果 AES-256-GCM 落库（核验完即焚）；服务端原因失败同日可重试（≤3 次）。
import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes, randomUUID } from "node:crypto";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { GatewayError } from "../src/errors.js";
import { createDiscoveryControlStore } from "../src/discovery/discoveryControlStore.js";
import { createDiscoveryRunStore } from "../src/discovery/discoveryRunStore.js";
import { createDiscoveryStageJobStore } from "../src/discovery/discoveryStageJobStore.js";
import { canonicalSha256 } from "../src/discovery/discoveryCanonicalJson.js";
import { backgroundPathPurpose } from "../src/usage/backgroundCostGuard.js";

const DEVICE_A = "11111111-2222-4333-8444-555555555555";
const DEVICE_B = "99999999-8888-4777-8666-555555555555";
const SECRET_MARKER = "ZANQILU-SECRET-MATERIAL-正文标记";
const JOB_KEY = randomBytes(32).toString("base64");

const JOB_STATUS_KEYS = [
  "error", "jobStatus", "leaseExpiresAt", "pollAfterSeconds", "replayed",
  "result", "retryAvailable", "runID", "stage",
];
const SYNC_CANDIDATES_KEYS = [
  "candidatesHash", "envelope", "model", "promptType", "promptVersion", "replayed", "runID", "stage", "usage",
];

// ===== 测试工具（与 discovery.test.js 同构的精简副本）=====

function upstreamResult(content) {
  return {
    id: "stub-discovery",
    choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
    usage: { prompt_tokens: 120, completion_tokens: 30 },
  };
}

/** 立即返回队列内容；队列空时返回 "{}"（格式不合格）；队列项为 Error 时抛出。 */
function scriptedProvider() {
  const calls = [];
  const queue = [];
  return {
    calls,
    enqueue(content) { queue.push(content); },
    provider: {
      async complete(request) {
        calls.push(request);
        const next = queue.length > 0 ? queue.shift() : "{}";
        if (next instanceof Error) throw next;
        return upstreamResult(next);
      },
    },
  };
}

/** 手动放行：complete() 挂起直到测试调用 resolveNext/rejectNext。 */
function deferredProvider() {
  const calls = [];
  const pending = [];
  return {
    calls,
    pendingCount: () => pending.length,
    resolveNext(content) { pending.shift().resolve(upstreamResult(content)); },
    provider: {
      complete(request) {
        calls.push(request);
        return new Promise((resolve, reject) => pending.push({ resolve, reject }));
      },
    },
  };
}

function candidateEnvelope(runID) {
  return {
    schemaVersion: 1,
    kind: "candidates",
    runID,
    noFindingReason: "none",
    candidates: [{
      candidateID: "C01",
      type: "two_episodes",
      subjectKey: "restart",
      scopeKind: "two_episodes",
      timeRange: { start: "2026-10-08T00:00:00+08:00", end: "2026-10-17T00:00:00+08:00" },
      claims: [
        { claimID: "C01-title", kind: "observation", text: "这两次重新开始，你都把第一步变轻了。",
          citations: [{ evidenceID: "E01", quote: "今天先出去走了十分钟" }, { evidenceID: "E02", quote: "今晚只翻了两页" }],
          metricIDs: [] },
        { claimID: "C01-body", kind: "fact", text: "恢复运动时先出去走走，重新阅读时先翻开书。",
          citations: [{ evidenceID: "E02", quote: "今晚只翻了两页" }], metricIDs: [] },
      ],
      titleClaimID: "C01-title",
      bodyClaimIDs: ["C01-body"],
      supportEvidenceIDs: ["E01", "E02"],
      counterSearch: [{ domains: ["thought"], anchorRefs: [], keywords: ["重新开始"] }],
      sensitivity: "non_sensitive",
      comparisonPeriods: [],
    }],
  };
}

function noFindingEnvelope(runID) {
  return { schemaVersion: 1, kind: "candidates", runID, noFindingReason: "no_material", candidates: [] };
}

function verificationEnvelope(runID) {
  return {
    schemaVersion: 1,
    kind: "verification",
    runID,
    candidateResults: [{
      candidateID: "C01",
      verdict: "accept",
      reasonCodes: [],
      claimResults: [
        { claimID: "C01-title", verdict: "supported", reasonCodes: [], supportEvidenceIDs: ["E01", "E02"], counterEvidenceIDs: [] },
        { claimID: "C01-body", verdict: "supported", reasonCodes: [], supportEvidenceIDs: ["E02"], counterEvidenceIDs: [] },
      ],
    }],
  };
}

function stageData(runID) {
  return {
    schemaVersion: 1,
    runID,
    anchorNow: "2026-10-23T10:00:00+08:00",
    timezone: "Asia/Shanghai",
    allowedDomains: ["thought", "task"],
    evidence: [
      { evidenceID: "E01", sourceKind: "thought", sourceBlock: `${SECRET_MARKER} 停了一阵，今天先出去走了十分钟。`,
        occurredRange: { start: "2026-10-08", end: "2026-10-09", precision: "day" },
        recordedAt: "2026-10-08T21:00:00+08:00", lineageGroup: "L01", entityRefs: ["exercise-restart"] },
      { evidenceID: "E02", sourceKind: "thought", sourceBlock: "隔了一周，今晚只翻了两页。",
        occurredRange: { start: "2026-10-16", end: "2026-10-17", precision: "day" },
        recordedAt: "2026-10-16T22:00:00+08:00", lineageGroup: "L02", entityRefs: ["reading-restart"] },
    ],
    coverage: { windowDays: 30, truncated: false, limitations: ["只覆盖已有记录"] },
    computedFacts: [{ metricID: "M01", kind: "independent_episode_count", value: 2 }],
    blockedThemes: [],
  };
}

const VERIFY_DATA = { counterEvidence: [], coverage: { windowDays: 30, truncated: false } };

function createTestApp(overrides = {}, { database, provider, jobKey = JOB_KEY } = {}) {
  const stub = provider ?? scriptedProvider();
  const db = database ?? createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database: db,
    auth: { enforceAppAttest: false },
    routes: {
      discovery_candidate_v1: {
        provider: "stub", model: "holo-mock", temperature: 0.3, maxTokens: 3072, reasoningEffort: "low",
        requestLimits: { perMinute: 100, perDay: 1000 },
      },
      discovery_verify_v1: {
        provider: "stub", model: "holo-mock", temperature: 0, maxTokens: 2048, reasoningEffort: "low",
        requestLimits: { perMinute: 100, perDay: 1000 },
      },
    },
    providerOverrides: [["stub", stub.provider]],
    discovery: { enabled: true, jobEncryptionKey: jobKey },
    ...overrides,
  });
  return { app, database: db, stub };
}

/** 模拟进程重启：同库、全新 store 实例（内存缓存与进程内作业全部丢失）。 */
function restartApp(database, provider) {
  return createTestApp({
    discoveryRunStore: createDiscoveryRunStore(database.db),
    discoveryControlStore: createDiscoveryControlStore(database.db),
    discoveryStageJobStore: createDiscoveryStageJobStore(database.db, { encryptionKey: JOB_KEY }),
  }, { database, provider });
}

function post(app, path, deviceId, body) {
  return app.request(path, {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": deviceId },
    body: JSON.stringify(body),
  });
}

async function enableControl(app, deviceId) {
  const response = await post(app, "/v1/discovery/control/enable", deviceId, {
    expectedRevision: 0, allowedDomains: ["thought", "task"], consentDocVersion: "consent-v1",
    confirmTakeover: false, requestID: randomUUID(),
  });
  assert.equal(response.status, 200);
}

async function createRun(app, deviceId, runID = `run-${randomUUID()}`) {
  const response = await post(app, "/v1/discovery/runs", deviceId, { runID, sourceManifestDigest: "manifest-1" });
  return { response, runID, body: await response.json() };
}

async function startAsync(app, deviceId, runID, runToken, data = stageData(runID)) {
  const response = await post(app, `/v1/discovery/runs/${runID}/candidates/async`, deviceId, { runToken, data });
  return { response, body: await response.json() };
}

async function pollResult(app, deviceId, runID, runToken) {
  const response = await post(app, `/v1/discovery/runs/${runID}/candidates/result`, deviceId, { runToken });
  return { response, body: await response.json() };
}

async function waitForJob(app, deviceId, runID, runToken) {
  for (let i = 0; i < 400; i++) {
    const polled = await pollResult(app, deviceId, runID, runToken);
    if (polled.response.status !== 200 || polled.body.jobStatus !== "running") return polled;
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  throw new Error("job did not settle");
}

function jobRow(database, runID) {
  return database.db.prepare("SELECT * FROM discovery_stage_jobs WHERE run_id = ?").get(runID);
}

// ===== 路径守卫 =====

test("A0 后台入口守卫：candidates/async 归入候选 purpose；result 轮询不是模型调用", () => {
  assert.equal(backgroundPathPurpose("/v1/discovery/runs/run-1/candidates/async"), "discovery_candidate_v1");
  assert.equal(backgroundPathPurpose("/v1/discovery/runs/run-1/candidates/result"), null);
  assert.equal(backgroundPathPurpose("/v1/discovery/runs/run-1/candidates"), "discovery_candidate_v1");
});

// ===== 三态与形状 =====

test("A1 异步启动立即返回 running；放行后取件 completed，result 与同步响应逐字段同形", async () => {
  const deferred = deferredProvider();
  const { app } = createTestApp({}, { provider: deferred });
  await enableControl(app, DEVICE_A);
  const { runID, body: run } = await createRun(app, DEVICE_A);

  const started = await startAsync(app, DEVICE_A, runID, run.runToken);
  assert.equal(started.response.status, 200);
  assert.deepEqual(Object.keys(started.body).sort(), JOB_STATUS_KEYS);
  assert.equal(started.body.jobStatus, "running");
  assert.equal(started.body.stage, "candidates");
  assert.equal(started.body.runID, runID);
  assert.equal(started.body.pollAfterSeconds, 3);
  assert.equal(started.body.result, null);
  assert.equal(started.body.error, null);
  assert.equal(started.body.retryAvailable, false);
  assert.equal(started.body.replayed, false);
  assert.ok(started.body.leaseExpiresAt > run.leaseExpiresAt, "异步启动后租约延长（客户端可稍后取件+核验）");

  const stillRunning = await pollResult(app, DEVICE_A, runID, run.runToken);
  assert.equal(stillRunning.body.jobStatus, "running");
  assert.deepEqual(Object.keys(stillRunning.body).sort(), JOB_STATUS_KEYS);

  deferred.resolveNext(JSON.stringify(candidateEnvelope(runID)));
  const done = await waitForJob(app, DEVICE_A, runID, run.runToken);
  assert.equal(done.body.jobStatus, "completed");
  assert.equal(done.body.pollAfterSeconds, null);
  assert.equal(done.body.error, null);
  assert.deepEqual(Object.keys(done.body.result).sort(), SYNC_CANDIDATES_KEYS);
  assert.equal(done.body.result.stage, "candidates");
  assert.equal(done.body.result.candidatesHash, canonicalSha256(done.body.result.envelope.candidates));
  assert.equal(deferred.calls.length, 1);
});

test("A2 同 run 同 body 重放启动不重调模型（replayed=true）；换 body → 409 STAGE_CONFLICT", async () => {
  const { app, stub } = createTestApp();
  await enableControl(app, DEVICE_A);
  const { runID, body: run } = await createRun(app, DEVICE_A);
  stub.enqueue(JSON.stringify(candidateEnvelope(runID)));
  await startAsync(app, DEVICE_A, runID, run.runToken);
  const replay = await startAsync(app, DEVICE_A, runID, run.runToken);
  assert.equal(replay.response.status, 200);
  assert.equal(replay.body.replayed, true);
  await waitForJob(app, DEVICE_A, runID, run.runToken);
  assert.equal(stub.calls.length, 1, "重放不重复调用模型");

  const changed = stageData(runID);
  changed.coverage.windowDays = 29;
  const conflict = await startAsync(app, DEVICE_A, runID, run.runToken, changed);
  assert.equal(conflict.response.status, 409);
  assert.equal(conflict.body.error.code, "DISCOVERY_STAGE_CONFLICT");
});

// ===== 落库、重启、即焚 =====

test("A3 结果加密落库：重启后仍可取件与核验；核验成功后作业密文即焚", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const first = createTestApp({}, { database });
  await enableControl(first.app, DEVICE_A);
  const { runID, body: run } = await createRun(first.app, DEVICE_A);
  first.stub.enqueue(JSON.stringify(candidateEnvelope(runID)));
  await startAsync(first.app, DEVICE_A, runID, run.runToken);
  const done = await waitForJob(first.app, DEVICE_A, runID, run.runToken);
  assert.equal(done.body.jobStatus, "completed");

  // 密文不含明文（ID/字段名/原文引文都不可见）
  const row = jobRow(database, runID);
  assert.ok(row.result_ciphertext);
  for (const plaintext of ["C01-title", "candidates", "十分钟", SECRET_MARKER]) {
    assert.ok(!row.result_ciphertext.includes(plaintext), `密文不应含明文：${plaintext}`);
  }

  // 重启：内存缓存清空，结果从加密落库恢复
  const restartedProvider = scriptedProvider();
  const second = restartApp(database, restartedProvider);
  const afterRestart = await pollResult(second.app, DEVICE_A, runID, run.runToken);
  assert.equal(afterRestart.body.jobStatus, "completed");
  assert.deepEqual(afterRestart.body.result.envelope, done.body.result.envelope);

  restartedProvider.enqueue(JSON.stringify(verificationEnvelope(runID)));
  const verify = await post(second.app, `/v1/discovery/runs/${runID}/verify`, DEVICE_A, {
    runToken: run.runToken,
    candidates: afterRestart.body.result.envelope.candidates,
    candidatesHash: afterRestart.body.result.candidatesHash,
    data: VERIFY_DATA,
  });
  assert.equal(verify.status, 200, "重启后核验读落库候选包比对 hash，不再 410");
  assert.equal(restartedProvider.calls.length, 1, "只调用了核验，没有重调候选");
  assert.equal(jobRow(database, runID), undefined, "核验成功后作业密文即焚");
});

test("A4 作业运行中进程重启 → 作业转 failed/DISCOVERY_JOB_INTERRUPTED，同日可重试", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const deferred = deferredProvider();
  const first = createTestApp({}, { database, provider: deferred });
  await enableControl(first.app, DEVICE_A);
  const { runID, body: run } = await createRun(first.app, DEVICE_A);
  await startAsync(first.app, DEVICE_A, runID, run.runToken);
  assert.equal(deferred.pendingCount(), 1);

  const second = restartApp(database, scriptedProvider());
  const polled = await pollResult(second.app, DEVICE_A, runID, run.runToken);
  assert.equal(polled.body.jobStatus, "failed");
  assert.deepEqual(polled.body.error, { code: "DISCOVERY_JOB_INTERRUPTED", reason: null });
  assert.equal(polled.body.retryAvailable, true);
  assert.equal(polled.body.result, null);

  const retry = await createRun(second.app, DEVICE_A);
  assert.equal(retry.response.status, 200, "服务端中断不烧当日名额");

  // 旧进程的挂起调用晚到完成：不得把已判中断的作业改回 completed
  deferred.resolveNext(JSON.stringify(candidateEnvelope(runID)));
  await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(jobRow(database, runID).status, "failed");
});

// ===== 名额语义（S6）=====

test("A5 格式三连败 → 作业 failed（带 reason）且可重试；同日最多 3 次尝试，第 3 次失败后不再可重试", async () => {
  const { app, stub } = createTestApp();
  await enableControl(app, DEVICE_A);
  for (let attempt = 1; attempt <= 3; attempt++) {
    const { response, runID, body: run } = await createRun(app, DEVICE_A);
    assert.equal(response.status, 200, `第 ${attempt} 次尝试可建 run`);
    // 队列为空 → 每次模型调用都返回 "{}"（格式不合格），同 run 内 3 次纠错重试后失败
    await startAsync(app, DEVICE_A, runID, run.runToken);
    const failed = await waitForJob(app, DEVICE_A, runID, run.runToken);
    assert.equal(failed.body.jobStatus, "failed");
    assert.equal(failed.body.error.code, "DISCOVERY_MODEL_OUTPUT_INVALID");
    assert.equal(typeof failed.body.error.reason, "string");
    assert.equal(failed.body.retryAvailable, attempt < 3);
  }
  assert.equal(stub.calls.length, 9, "3 次尝试 × 每次 3 次格式重试");
  const exhausted = await createRun(app, DEVICE_A);
  assert.equal(exhausted.response.status, 429);
  assert.equal(exhausted.body.error.code, "DISCOVERY_DAY_LIMIT");
});

test("A6 上游超时同样可重试；旧客户端的同步路径失败也不再烧当日名额", async () => {
  const { app, stub } = createTestApp();
  await enableControl(app, DEVICE_A);
  const first = await createRun(app, DEVICE_A);
  stub.enqueue(new GatewayError("UPSTREAM_TIMEOUT", "Upstream request timed out", 504));
  const sync = await post(app, `/v1/discovery/runs/${first.runID}/candidates`, DEVICE_A, {
    runToken: first.body.runToken, data: stageData(first.runID),
  });
  assert.equal(sync.status, 504);
  const retry = await createRun(app, DEVICE_A);
  assert.equal(retry.response.status, 200, "同步路径的上游失败同日可重试");
});

test("A7 用户主动取消（已 dispatch）仍按已用计，不可同日重试", async () => {
  const { app, stub } = createTestApp();
  await enableControl(app, DEVICE_A);
  const { runID, body: run } = await createRun(app, DEVICE_A);
  stub.enqueue(JSON.stringify(candidateEnvelope(runID)));
  await startAsync(app, DEVICE_A, runID, run.runToken);
  await waitForJob(app, DEVICE_A, runID, run.runToken);
  const cancel = await post(app, `/v1/discovery/runs/${runID}/cancel`, DEVICE_A, {});
  assert.equal(cancel.status, 200);
  const next = await createRun(app, DEVICE_A);
  assert.equal(next.response.status, 429);
});

test("A8 核验阶段服务端失败（格式三连败）同样可重试", async () => {
  const { app, stub } = createTestApp();
  await enableControl(app, DEVICE_A);
  const { runID, body: run } = await createRun(app, DEVICE_A);
  stub.enqueue(JSON.stringify(candidateEnvelope(runID)));
  await startAsync(app, DEVICE_A, runID, run.runToken);
  const done = await waitForJob(app, DEVICE_A, runID, run.runToken);
  const verify = await post(app, `/v1/discovery/runs/${runID}/verify`, DEVICE_A, {
    runToken: run.runToken,
    candidates: done.body.result.envelope.candidates,
    candidatesHash: done.body.result.candidatesHash,
    data: VERIFY_DATA,
  });
  assert.equal(verify.status, 502);
  const retry = await createRun(app, DEVICE_A);
  assert.equal(retry.response.status, 200);
});

test("A9 无发现（空 candidates）是成功终态：作业 completed、当日按已用计", async () => {
  const { app, stub } = createTestApp();
  await enableControl(app, DEVICE_A);
  const { runID, body: run } = await createRun(app, DEVICE_A);
  stub.enqueue(JSON.stringify(noFindingEnvelope(runID)));
  await startAsync(app, DEVICE_A, runID, run.runToken);
  const done = await waitForJob(app, DEVICE_A, runID, run.runToken);
  assert.equal(done.body.jobStatus, "completed");
  assert.deepEqual(done.body.result.envelope.candidates, []);
  const next = await createRun(app, DEVICE_A);
  assert.equal(next.response.status, 429);
});

// ===== 访问控制 =====

test("A10 取件核对归属与 token：他设备 404、错 token 403、无作业 404", async () => {
  const { app, stub } = createTestApp();
  await enableControl(app, DEVICE_A);
  const { runID, body: run } = await createRun(app, DEVICE_A);
  stub.enqueue(JSON.stringify(candidateEnvelope(runID)));
  await startAsync(app, DEVICE_A, runID, run.runToken);

  const otherDevice = await pollResult(app, DEVICE_B, runID, run.runToken);
  assert.equal(otherDevice.response.status, 404);
  assert.equal(otherDevice.body.error.code, "DISCOVERY_JOB_NOT_FOUND");
  const wrongToken = await pollResult(app, DEVICE_A, runID, "not-the-token");
  assert.equal(wrongToken.response.status, 403);
  assert.equal(wrongToken.body.error.code, "DISCOVERY_RUN_TOKEN_INVALID");
  const missing = await pollResult(app, DEVICE_A, `run-${randomUUID()}`, run.runToken);
  assert.equal(missing.response.status, 404);
  assert.equal(missing.body.error.code, "DISCOVERY_JOB_NOT_FOUND");
});

// ===== 能力与降级 =====

test("A11 capabilities 暴露 features.asyncCandidates 与 budget.attemptsPerDay；无密钥时异步端点 503", async () => {
  const withKey = createTestApp();
  const capabilities = await (await withKey.app.request("/v1/discovery/capabilities", {
    headers: { "x-holo-device-id": DEVICE_A },
  })).json();
  assert.deepEqual(capabilities.features, { asyncCandidates: true });
  assert.equal(capabilities.budget.attemptsPerDay, 3);

  const withoutKey = createTestApp({}, { jobKey: "" });
  const noAsync = await (await withoutKey.app.request("/v1/discovery/capabilities", {
    headers: { "x-holo-device-id": DEVICE_A },
  })).json();
  assert.deepEqual(noAsync.features, { asyncCandidates: false });
  await enableControl(withoutKey.app, DEVICE_A);
  const { runID, body: run } = await createRun(withoutKey.app, DEVICE_A);
  const started = await startAsync(withoutKey.app, DEVICE_A, runID, run.runToken);
  assert.equal(started.response.status, 503);
  assert.equal(started.body.error.code, "DISCOVERY_ASYNC_UNAVAILABLE");
});

// ===== 隐私（S7③）=====

test("A12 失败与成功全程：容器日志与 502 响应体不含用户原文", async () => {
  const captured = [];
  const originalWarn = console.warn;
  const originalError = console.error;
  console.warn = (...args) => captured.push(args.join(" "));
  console.error = (...args) => captured.push(args.join(" "));
  try {
    const { app, stub } = createTestApp();
    await enableControl(app, DEVICE_A);
    // 模型把原文整句抄进非法输出（最坏情况）
    const leaky = JSON.stringify({ leaked: `${SECRET_MARKER} 停了一阵，今天先出去走了十分钟。` });
    stub.enqueue(leaky); stub.enqueue(leaky); stub.enqueue(leaky);
    const first = await createRun(app, DEVICE_A);
    const sync = await post(app, `/v1/discovery/runs/${first.runID}/candidates`, DEVICE_A, {
      runToken: first.body.runToken, data: stageData(first.runID),
    });
    assert.equal(sync.status, 502);
    const errorBody = await sync.text();
    assert.ok(!errorBody.includes(SECRET_MARKER), "502 响应体不含原文");
    assert.ok(!errorBody.includes("rawTail"));

    const second = await createRun(app, DEVICE_A);
    stub.enqueue(JSON.stringify(candidateEnvelope(second.runID)));
    await startAsync(app, DEVICE_A, second.runID, second.body.runToken);
    await waitForJob(app, DEVICE_A, second.runID, second.body.runToken);
  } finally {
    console.warn = originalWarn;
    console.error = originalError;
  }
  for (const line of captured) {
    assert.ok(!line.includes(SECRET_MARKER), `日志不含原文：${line.slice(0, 120)}`);
    assert.ok(!line.includes("十分钟"), `日志不含引文：${line.slice(0, 120)}`);
  }
});
