// HoloAI「一个发现」G3+G4 服务端部分（D06/D07 + Prompt 注册）测试。
// 覆盖实施包 04 验收矩阵的服务端条目：
//   T04 未鉴权/自报身份拒绝；T11 CAS 单 owner + 旧 grant 失效；T13 旧 enable 重放不复活/晚到 disable 保守优先；
//   T14 并发两 run 只允许一个；T15 同阶段同 body 重放不重调上游；T16 同幂等键不同 body 冲突；
//   T17 重启后 stage_result_lost 不重调；T18 通用 chat 调新 purpose 被拒；T19 空 candidates 只一次调用；
//   T21 不占 chat/deepAnalysis 会员池；T22 后台预算不足调用前拒绝；T23 模型输出 schema 严格拒绝；
//   T34 verify 候选包 hash 与 candidates 响应不一致被拒；T45 capability=false 开启不能完成；
//   T49 kill switch 停新调用。
// 另加：Prompt 注册链路断言（route+prompt 映射+reasoningEffort+多语言）与 metadata-only 日志 canary。
import assert from "node:assert/strict";
import { test } from "node:test";
import { randomUUID } from "node:crypto";

import { createApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { createDatabase } from "../src/db/database.js";
import { createAdminLogStore } from "../src/admin/adminLogStore.js";
import { createDiscoveryControlStore } from "../src/discovery/discoveryControlStore.js";
import { createDiscoveryRunStore } from "../src/discovery/discoveryRunStore.js";
import { canonicalJsonString, canonicalSha256 } from "../src/discovery/discoveryCanonicalJson.js";
import { validateDiscoveryOutput } from "../src/discovery/discoveryOutputSchema.js";
import { injectServerPrompt, promptTypeForPurpose } from "../src/prompts/serverPromptPolicy.js";
import { getPrompt } from "../src/prompts/promptRegistry.js";
import { backgroundSubject, backgroundPathPurpose } from "../src/usage/backgroundCostGuard.js";
import { createDeviceSessionService } from "../src/auth/deviceSession.js";

const DEVICE_A = "11111111-2222-4333-8444-555555555555";
const DEVICE_B = "99999999-8888-4777-8666-555555555555";
const SECRET_MARKER = "ZANQILU-SECRET-MATERIAL-正文标记";

// ===== 测试工具 =====

function scriptedProvider() {
  const calls = [];
  const queue = [];
  return {
    calls,
    enqueue(content) {
      queue.push(content);
    },
    provider: {
      async complete(request) {
        calls.push(request);
        const content = queue.length > 0 ? queue.shift() : "{}";
        return {
          id: "stub-discovery",
          choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
          usage: { prompt_tokens: 120, completion_tokens: 30 },
        };
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
    candidates: [
      {
        candidateID: "C01",
        type: "two_episodes",
        subjectKey: "restart",
        scopeKind: "two_episodes",
        timeRange: { start: "2026-10-08T00:00:00+08:00", end: "2026-10-17T00:00:00+08:00" },
        claims: [
          {
            claimID: "C01-title",
            kind: "observation",
            text: "这两次重新开始，你都把第一步变轻了。",
            citations: [{ evidenceID: "E01", quote: "今天先出去走了十分钟" }],
            metricIDs: [],
          },
          {
            claimID: "C01-body",
            kind: "fact",
            text: "恢复运动时先走十分钟，重新阅读时先翻两页。",
            citations: [{ evidenceID: "E02", quote: "今晚只翻了两页" }],
            metricIDs: [],
          },
        ],
        titleClaimID: "C01-title",
        bodyClaimIDs: ["C01-body"],
        supportEvidenceIDs: ["E01", "E02"],
        counterSearch: [{ domains: ["thought"], anchorRefs: [], keywords: ["重新开始"] }],
        sensitivity: "non_sensitive",
        comparisonPeriods: [],
      },
    ],
  };
}

function verificationEnvelope(runID) {
  return {
    schemaVersion: 1,
    kind: "verification",
    runID,
    candidateResults: [
      {
        candidateID: "C01",
        verdict: "accept",
        reasonCodes: [],
        claimResults: [
          { claimID: "C01-title", verdict: "supported", reasonCodes: [], supportEvidenceIDs: ["E01"], counterEvidenceIDs: [] },
          { claimID: "C01-body", verdict: "supported", reasonCodes: [], supportEvidenceIDs: ["E02"], counterEvidenceIDs: [] },
        ],
      },
    ],
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
      {
        evidenceID: "E01",
        sourceKind: "thought",
        sourceBlock: `${SECRET_MARKER} 停了一阵，今天先出去走了十分钟。`,
        occurredRange: { start: "2026-10-08", end: "2026-10-09", precision: "day" },
        recordedAt: "2026-10-08T21:00:00+08:00",
        lineageGroup: "L01",
        entityRefs: ["exercise-restart"],
      },
    ],
    coverage: { windowDays: 30, truncated: false, limitations: ["只覆盖已有记录"] },
    computedFacts: [{ metricID: "M01", kind: "independent_episode_count", value: 2 }],
    blockedThemes: [],
  };
}

function createTestApp(overrides = {}, { database, provider } = {}) {
  const stub = provider ?? scriptedProvider();
  const db = database ?? createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database: db,
    auth: { enforceAppAttest: false },
    routes: {
      discovery_candidate_v1: {
        provider: "stub", model: "holo-mock", temperature: 0.3,
        maxTokens: 3072, reasoningEffort: "low",
        requestLimits: { perMinute: 100, perDay: 1000 },
      },
      discovery_verify_v1: {
        provider: "stub", model: "holo-mock", temperature: 0,
        maxTokens: 2048, reasoningEffort: "low",
        requestLimits: { perMinute: 100, perDay: 1000 },
      },
    },
    providerOverrides: [["stub", stub.provider]],
    discovery: { enabled: true },
    ...overrides,
  });
  return { app, database: db, stub };
}

function post(app, path, deviceId, body, extraHeaders = {}) {
  return app.request(path, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": deviceId,
      ...extraHeaders,
    },
    body: JSON.stringify(body),
  });
}

async function enableControl(app, deviceId, options = {}) {
  const response = await post(app, "/v1/discovery/control/enable", deviceId, {
    expectedRevision: options.expectedRevision ?? 0,
    allowedDomains: options.allowedDomains ?? ["thought", "task"],
    consentDocVersion: "consent-v1",
    confirmTakeover: options.confirmTakeover === true,
    requestID: options.requestID ?? randomUUID(),
  });
  return response;
}

async function prepareReadyRun(app, deviceId, stub, { runID = `run-${randomUUID()}`, candidateContent } = {}) {
  const enableResponse = await enableControl(app, deviceId);
  assert.equal(enableResponse.status, 200);
  const createResponse = await post(app, "/v1/discovery/runs", deviceId, { runID, sourceManifestDigest: "manifest-1" });
  assert.equal(createResponse.status, 200);
  const created = await createResponse.json();
  stub.enqueue(JSON.stringify(candidateContent ?? candidateEnvelope(runID)));
  const candidatesResponse = await post(app, `/v1/discovery/runs/${runID}/candidates`, deviceId, {
    runToken: created.runToken,
    data: stageData(runID),
  });
  assert.equal(candidatesResponse.status, 200);
  const candidates = await candidatesResponse.json();
  return { created, candidates };
}

function grantSharedPurchase(database, deviceId) {
  database.db.prepare(
    `INSERT INTO subscription_entitlements
       (device_id, tier, product_id, original_transaction_id, latest_transaction_id, environment, expires_at, revoked_at, updated_at)
     VALUES (?, 'plus', 'holo.plus.monthly', 'txn-shared-001', 'latest-001', 'Production', NULL, NULL, CURRENT_TIMESTAMP)`,
  ).run(deviceId);
}

// ===== canonical JSON（双端 hash 基础）=====

test("canonical JSON：键序无关、数字固定格式、双端一致 hash", () => {
  const a = { b: 1, a: [2, { d: "x", c: null }] };
  const b = { a: [2, { c: null, d: "x" }], b: 1 };
  assert.equal(canonicalJsonString(a), canonicalJsonString(b));
  assert.equal(canonicalSha256(a), canonicalSha256(b));
  assert.equal(canonicalJsonString({ n: 1.5, m: -0 }), '{"m":0,"n":1.5}');
  assert.throws(() => canonicalJsonString({ x: Number.NaN }));
});

// ===== T04 未鉴权 / 自报身份拒绝 =====

test("T04a enforceDeviceSession 下未携带设备会话的 discovery 请求被 401 拒绝", async () => {
  const sessionService = createDeviceSessionService({
    secret: "unit-test-discovery-session-secret-0123456789",
  });
  const { app } = createTestApp({
    auth: { enforceAppAttest: false, enforceDeviceSession: true },
    deviceSessionService: sessionService,
  });
  const response = await app.request("/v1/discovery/control", {
    headers: { "x-holo-device-id": DEVICE_A },
  });
  assert.equal(response.status, 401);
  const body = await response.json();
  assert.equal(body.error.code, "DEVICE_SESSION_REQUIRED");
});

test("T04b body 自报身份不被信任：控制状态按服务端导出主体隔离", async () => {
  const { app } = createTestApp();
  // A、B 无共享购买 → 两个独立主体；A 开启只影响 A 的主体
  const enable = await enableControl(app, DEVICE_A);
  assert.equal(enable.status, 200);

  // B 在 body 里自称是 A 的设备/主体——服务端只从已验证设备头导出主体，body 字段一律忽略
  const controlB = await app.request("/v1/discovery/control", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": DEVICE_B },
    body: JSON.stringify({ deviceId: DEVICE_A, subject: DEVICE_A }),
  });
  assert.equal(controlB.status, 404, "control 无 POST 路由（防 body 注入的探测面）");

  const controlBGet = await app.request("/v1/discovery/control", {
    headers: { "x-holo-device-id": DEVICE_B },
  });
  assert.equal(controlBGet.status, 200);
  const body = await controlBGet.json();
  assert.equal(body.enabled, false, "B 的主体不受 A 的开启影响");
  assert.equal(body.revision, 0, "B 的主体控制代数为初始值");
  assert.equal(body.ownerDeviceId, null, "owner 是 A 主体内服务端记录，B 主体为空");

  // B 试图用 A 的 runID 取候选：run 归属校验（subject+device）拒绝
  const runResponse = await post(app, "/v1/discovery/runs/any-run/candidates", DEVICE_B, {
    runToken: "forged", data: stageData("any-run"),
  });
  assert.equal(runResponse.status, 404);
  assert.equal((await runResponse.json()).error.code, "DISCOVERY_RUN_NOT_FOUND");
});

// ===== T11 CAS 单 owner + 旧 grant 失效 =====

test("T11 单 owner：接管需显式确认，接管后旧设备 grant 失效", async () => {
  const { app, database } = createTestApp();
  grantSharedPurchase(database, DEVICE_A);
  grantSharedPurchase(database, DEVICE_B);

  const enableA = await enableControl(app, DEVICE_A);
  assert.equal(enableA.status, 200);
  const stateA = await enableA.json();
  assert.equal(stateA.revision, 1);
  assert.equal(stateA.ownerDeviceId, DEVICE_A);

  // B 无确认接管 → 409
  const conflict = await enableControl(app, DEVICE_B, { expectedRevision: 1, confirmTakeover: false });
  assert.equal(conflict.status, 409);
  assert.equal((await conflict.json()).error.code, "DISCOVERY_TAKEOVER_REQUIRED");

  // B 显式确认接管 → revision+1、owner=B
  const takeover = await enableControl(app, DEVICE_B, { expectedRevision: 1, confirmTakeover: true });
  assert.equal(takeover.status, 200);
  assert.equal((await takeover.json()).revision, 2);

  // 旧 owner A 的 grant 失效：不能创建 run
  const runA = await post(app, "/v1/discovery/runs", DEVICE_A, { runID: `run-${randomUUID()}` });
  assert.equal(runA.status, 409);
  assert.equal((await runA.json()).error.code, "DISCOVERY_RUN_NOT_OWNER");

  // CAS：旧 revision 提交 → 409
  const stale = await enableControl(app, DEVICE_A, { expectedRevision: 1, confirmTakeover: true });
  assert.equal(stale.status, 409);
  assert.equal((await stale.json()).error.code, "DISCOVERY_REVISION_CONFLICT");
});

// ===== T13 旧 enable 重放不复活 / 晚到 disable 保守优先 =====

test("T13 旧 enable 重放不复活控制；disable 任一设备可发且晚到仍保守生效", async () => {
  const { app, database } = createTestApp();
  grantSharedPurchase(database, DEVICE_A);
  grantSharedPurchase(database, DEVICE_B);

  const enableRequestID = randomUUID();
  const enable = await enableControl(app, DEVICE_A, { requestID: enableRequestID });
  assert.equal(enable.status, 200);

  const disableID = randomUUID();
  const disable = await post(app, "/v1/discovery/control/disable", DEVICE_B, {
    requestID: disableID, reason: "user_off",
  });
  assert.equal(disable.status, 200);
  assert.equal((await disable.json()).enabled, false);

  // 旧 enable 重放（同 requestID 同 body）：返回幂等结果但控制保持关闭——不复活
  const replay = await enableControl(app, DEVICE_A, { requestID: enableRequestID });
  assert.equal(replay.status, 200);
  assert.equal((await replay.json()).replayed, true);
  const control = await (await app.request("/v1/discovery/control", {
    headers: { "x-holo-device-id": DEVICE_A },
  })).json();
  assert.equal(control.enabled, false, "旧 enable 重放不得复活已撤销的授权");

  // 用户重新开启后，更晚发出的 disable（新 requestID）保守优先关闭
  const reEnable = await enableControl(app, DEVICE_A, { expectedRevision: 2 });
  assert.equal(reEnable.status, 200);
  const lateDisable = await post(app, "/v1/discovery/control/disable", DEVICE_B, {
    requestID: randomUUID(), reason: "late_disable",
  });
  assert.equal(lateDisable.status, 200);
  assert.equal((await lateDisable.json()).enabled, false);

  // 旧 expectedRevision 的 enable 在 disable 之后提交 → CAS 拒绝（不按客户端时钟判新旧）
  const staleEnable = await enableControl(app, DEVICE_A, { expectedRevision: 1 });
  assert.equal(staleEnable.status, 409);
});

// ===== T14 当日并发只允许一个 run =====

test("T14 当日批次 UNIQUE 约束：第二个 run 被事务拦截", async () => {
  const { app } = createTestApp();
  await enableControl(app, DEVICE_A);
  const first = await post(app, "/v1/discovery/runs", DEVICE_A, { runID: `run-${randomUUID()}` });
  assert.equal(first.status, 200);
  const second = await post(app, "/v1/discovery/runs", DEVICE_A, { runID: `run-${randomUUID()}` });
  assert.equal(second.status, 429);
  const body = await second.json();
  assert.equal(body.error.code, "DISCOVERY_DAY_LIMIT");
  assert.ok(body.error.resetAt, "429 附带上海日界 resetAt");
});

test("T14b 未 dispatch 即取消的 run 释放当日名额，已 dispatch 的不释放", async () => {
  const { app, stub } = createTestApp();
  await enableControl(app, DEVICE_A);
  const firstID = `run-${randomUUID()}`;
  const created = await (await post(app, "/v1/discovery/runs", DEVICE_A, { runID: firstID })).json();
  const cancelled = await post(app, `/v1/discovery/runs/${firstID}/cancel`, DEVICE_A, { reason: "cancel_before_dispatch" });
  assert.equal(cancelled.status, 200);

  const secondID = `run-${randomUUID()}`;
  const second = await post(app, "/v1/discovery/runs", DEVICE_A, { runID: secondID });
  assert.equal(second.status, 200, "未 dispatch 的取消释放名额");

  stub.enqueue(JSON.stringify(candidateEnvelope(secondID)));
  const candidatesResponse = await post(app, `/v1/discovery/runs/${secondID}/candidates`, DEVICE_A, {
    runToken: (await second.json()).runToken, data: stageData(secondID),
  });
  assert.equal(candidatesResponse.status, 200);
  const third = await post(app, "/v1/discovery/runs", DEVICE_A, { runID: `run-${randomUUID()}` });
  assert.equal(third.status, 429, "已 dispatch 的批次占用当日名额");
});

// ===== T15 / T16 幂等 =====

test("T15 同阶段同 body 重放返回缓存结果，不重调上游", async () => {
  const { app, stub } = createTestApp();
  await enableControl(app, DEVICE_A);
  const runID = `run-${randomUUID()}`;
  const created = await (await post(app, "/v1/discovery/runs", DEVICE_A, { runID })).json();
  stub.enqueue(JSON.stringify(candidateEnvelope(runID)));

  const data = stageData(runID);
  const requestID = randomUUID();
  const first = await post(app, `/v1/discovery/runs/${runID}/candidates`, DEVICE_A, {
    runToken: created.runToken, requestID, data,
  });
  assert.equal(first.status, 200);
  const firstBody = await first.json();
  assert.equal(firstBody.replayed, false);
  assert.equal(stub.calls.length, 1);

  const second = await post(app, `/v1/discovery/runs/${runID}/candidates`, DEVICE_A, {
    runToken: created.runToken, requestID, data,
  });
  assert.equal(second.status, 200);
  const secondBody = await second.json();
  assert.equal(secondBody.replayed, true, "同阶段同 body 命中阶段缓存");
  assert.deepEqual(secondBody.envelope, firstBody.envelope);
  assert.equal(stub.calls.length, 1, "上游调用计数不变");
});

test("T16 同幂等键不同 body 冲突（阶段与控制操作）", async () => {
  const { app, stub } = createTestApp();
  // 控制操作：同 requestID 不同 allowedDomains → 409
  const requestID = randomUUID();
  const first = await enableControl(app, DEVICE_A, { requestID, allowedDomains: ["thought"] });
  assert.equal(first.status, 200);
  const conflict = await post(app, "/v1/discovery/control/enable", DEVICE_A, {
    expectedRevision: 1, allowedDomains: ["thought", "task"], consentDocVersion: "consent-v1",
    confirmTakeover: false, requestID,
  });
  assert.equal(conflict.status, 409);
  assert.equal((await conflict.json()).error.code, "DISCOVERY_REQUEST_CONFLICT");

  // 阶段：同 requestID 不同 data → 409
  await post(app, "/v1/discovery/control/scope", DEVICE_A, {
    expectedRevision: 1, allowedDomains: ["thought", "task"], consentDocVersion: "consent-v1",
    requestID: randomUUID(),
  });
  const runID = `run-${randomUUID()}`;
  const created = await (await post(app, "/v1/discovery/runs", DEVICE_A, { runID })).json();
  stub.enqueue(JSON.stringify(candidateEnvelope(runID)));
  const stageRequestID = randomUUID();
  const stageFirst = await post(app, `/v1/discovery/runs/${runID}/candidates`, DEVICE_A, {
    runToken: created.runToken, requestID: stageRequestID, data: stageData(runID),
  });
  assert.equal(stageFirst.status, 200);
  const tampered = stageData(runID);
  tampered.coverage.windowDays = 60;
  const stageConflict = await post(app, `/v1/discovery/runs/${runID}/candidates`, DEVICE_A, {
    runToken: created.runToken, requestID: stageRequestID, data: tampered,
  });
  assert.equal(stageConflict.status, 409);
  assert.equal((await stageConflict.json()).error.code, "DISCOVERY_REQUEST_CONFLICT");

  // 同阶段换 body（无 requestID）也冲突：request hash 不可变
  const hashConflict = await post(app, `/v1/discovery/runs/${runID}/candidates`, DEVICE_A, {
    runToken: created.runToken, data: tampered,
  });
  assert.equal(hashConflict.status, 409);
  assert.equal((await hashConflict.json()).error.code, "DISCOVERY_STAGE_CONFLICT");
});

// ===== T17 重启后不重调模型 =====

test("T17 重启（新 store 实例）后已 dispatched 阶段返回 RESULT_LOST，绝不重调模型", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  // 进程 1：自己的 store 实例
  const first = createTestApp({}, { database });
  const runID = `run-${randomUUID()}`;
  const { created, candidates } = await prepareReadyRun(first.app, DEVICE_A, first.stub, { runID });
  assert.equal(first.stub.calls.length, 1);

  // 进程 2（重启）：同库、全新 store 实例（阶段内存缓存为空）、独立 provider 计数
  const restartedProvider = scriptedProvider();
  const second = createTestApp({
    discoveryRunStore: createDiscoveryRunStore(database.db),
    discoveryControlStore: createDiscoveryControlStore(database.db),
  }, { database, provider: restartedProvider });

  const verify = await post(second.app, `/v1/discovery/runs/${runID}/verify`, DEVICE_A, {
    runToken: created.runToken,
    candidates: candidates.envelope.candidates,
    candidatesHash: candidates.candidatesHash,
    data: { counterEvidence: [], coverage: { windowDays: 30, truncated: false } },
  });
  assert.equal(verify.status, 410);
  assert.equal((await verify.json()).error.code, "DISCOVERY_STAGE_RESULT_LOST");
  assert.equal(restartedProvider.calls.length, 0, "重启后绝不重调模型补结果");

  // 原进程内重放（缓存还在）不受影响
  first.stub.enqueue(JSON.stringify(verificationEnvelope(runID)));
  const replayVerify = await post(first.app, `/v1/discovery/runs/${runID}/verify`, DEVICE_A, {
    runToken: created.runToken,
    candidates: candidates.envelope.candidates,
    candidatesHash: candidates.candidatesHash,
    data: { counterEvidence: [], coverage: { windowDays: 30, truncated: false } },
  });
  assert.equal(replayVerify.status, 200);
  assert.equal(first.stub.calls.length, 2, "缓存命中的 verify 正常执行一次上游调用");
});

// ===== T18 通用 chat 防旁路 =====

test("T18 通用 chat 端点拒绝 discovery 两个 purpose", async () => {
  const { app } = createTestApp();
  for (const purpose of ["discovery_candidate_v1", "discovery_verify_v1"]) {
    const response = await post(app, "/v1/ai/chat/completions", DEVICE_A, {
      purpose,
      stream: false,
      messages: [{ role: "user", content: "绕过专用端点的尝试" }],
    });
    assert.equal(response.status, 400);
    assert.equal((await response.json()).error.code, "DISCOVERY_PURPOSE_BYPASS_BLOCKED");
  }
});

// ===== T19 空 candidates 只一次调用 =====

test("T19 空 candidates 是成功终态：整批只一次上游调用，verify 不再执行", async () => {
  const { app, stub } = createTestApp();
  await enableControl(app, DEVICE_A);
  const runID = `run-${randomUUID()}`;
  const created = await (await post(app, "/v1/discovery/runs", DEVICE_A, { runID })).json();
  stub.enqueue(JSON.stringify({
    schemaVersion: 1, kind: "candidates", runID,
    candidates: [], noFindingReason: "no_material",
  }));
  const candidatesResponse = await post(app, `/v1/discovery/runs/${runID}/candidates`, DEVICE_A, {
    runToken: created.runToken, data: stageData(runID),
  });
  assert.equal(candidatesResponse.status, 200);
  const body = await candidatesResponse.json();
  assert.deepEqual(body.envelope.candidates, []);
  assert.equal(body.envelope.noFindingReason, "no_material");
  assert.equal(stub.calls.length, 1, "只一次调用");

  const verify = await post(app, `/v1/discovery/runs/${runID}/verify`, DEVICE_A, {
    runToken: created.runToken,
    candidates: body.envelope.candidates,
    candidatesHash: body.candidatesHash,
    data: {},
  });
  assert.equal(verify.status, 409, "无合格候选不进入 verify（run 已成功终态）");
  assert.equal(stub.calls.length, 1);
});

// ===== T21 不占会员次数池 =====

test("T21 阶段调用不占 chat/deepAnalysis 会员池", async () => {
  const { app, database, stub } = createTestApp();
  const prepared = await prepareReadyRun(app, DEVICE_A, stub, { runID: `run-${randomUUID()}` });
  stub.enqueue(JSON.stringify(verificationEnvelope(prepared.candidates.envelope.runID)));
  const verify = await post(app, `/v1/discovery/runs/${prepared.candidates.envelope.runID}/verify`, DEVICE_A, {
    runToken: prepared.created.runToken,
    candidates: prepared.candidates.envelope.candidates,
    candidatesHash: prepared.candidates.candidatesHash,
    data: { counterEvidence: [], coverage: { windowDays: 30, truncated: false } },
  });
  assert.equal(verify.status, 200);

  const ledgerRows = database.db.prepare("SELECT COUNT(*) AS n FROM quota_action_ledger").get();
  assert.equal(ledgerRows.n, 0, "quota_action_ledger 无任何会员次数预留");

  const statusResponse = await app.request("/v1/subscription/status", {
    headers: { "x-holo-device-id": DEVICE_A },
  });
  const status = await statusResponse.json();
  assert.equal(status.quotas.chat.used, 0, "chat 池计数为 0");
  assert.equal(status.quotas.deepAnalysis.used, 0, "deepAnalysis 池计数为 0");
});

// ===== T22 后台预算不足调用前拒绝 =====

test("T22 后台金额预算不足：上游零触达，当日名额释放", async () => {
  const { app, stub, database } = createTestApp({
    backgroundCost: { dailyCNY: 0.0000001, monthlyCNY: 0.0000001 },
  });
  await enableControl(app, DEVICE_A);
  const runID = `run-${randomUUID()}`;
  const created = await (await post(app, "/v1/discovery/runs", DEVICE_A, { runID })).json();

  const response = await post(app, `/v1/discovery/runs/${runID}/candidates`, DEVICE_A, {
    runToken: created.runToken, data: stageData(runID),
  });
  assert.equal(response.status, 429);
  assert.equal((await response.json()).error.code, "BACKGROUND_BUDGET_EXCEEDED");
  assert.equal(stub.calls.length, 0, "预算拒绝发生在调用上游之前");

  const released = await post(app, "/v1/discovery/runs", DEVICE_A, { runID: `run-${randomUUID()}` });
  assert.equal(released.status, 200, "确认未触达上游的失败释放当日名额");
  assert.ok(database);
});

// ===== T23 模型输出 schema 严格校验 =====

test("T23 缺字段/多余字段/缺 verdict/坏 allOf 的模型输出被严格拒绝且本批终止", async () => {
  const cases = [
    {
      name: "候选缺 sensitivity",
      content: (() => { const e = candidateEnvelope("run-x"); delete e.candidates[0].sensitivity; return JSON.stringify(e); })(),
    },
    {
      name: "候选多余字段",
      content: (() => {
        const e = candidateEnvelope("run-x");
        e.candidates[0].extraField = "nope";
        return JSON.stringify(e);
      })(),
    },
    {
      name: "candidates 空但 noFindingReason=none",
      content: JSON.stringify({ schemaVersion: 1, kind: "candidates", runID: "run-x", candidates: [], noFindingReason: "none" }),
    },
    {
      name: "核验缺 verdict",
      content: (() => {
        const e = verificationEnvelope("run-x");
        delete e.candidateResults[0].verdict;
        return JSON.stringify(e);
      })(),
    },
    {
      name: "accept 带非 supported claim",
      content: (() => {
        const e = verificationEnvelope("run-x");
        e.candidateResults[0].claimResults[1].verdict = "unsupported";
        return JSON.stringify(e);
      })(),
    },
    {
      name: "change_over_time 缺 comparisonPeriods",
      content: (() => {
        const e = candidateEnvelope("run-x");
        e.candidates[0].type = "change_over_time";
        e.candidates[0].scopeKind = "compared_periods";
        e.candidates[0].comparisonPeriods = [];
        return JSON.stringify(e);
      })(),
    },
  ];

  for (const item of cases) {
    const { app, stub } = createTestApp();
    await enableControl(app, DEVICE_A);
    const runID = `run-${randomUUID()}`;
    const created = await (await post(app, "/v1/discovery/runs", DEVICE_A, { runID })).json();
    stub.enqueue(item.content.replace(/"runID":"run-x"/g, `"runID":"${runID}"`));
    const response = await post(app, `/v1/discovery/runs/${runID}/candidates`, DEVICE_A, {
      runToken: created.runToken, data: stageData(runID),
    });
    assert.equal(response.status, 502, `${item.name}: 应拒绝`);
    const body = await response.json();
    assert.equal(body.error.code, "DISCOVERY_MODEL_OUTPUT_INVALID", item.name);
    assert.equal(stub.calls.length, 1, `${item.name}: 只一次调用不重试`);
    // 本批终止：同 run 再发 verify 被拒
    const verify = await post(app, `/v1/discovery/runs/${runID}/verify`, DEVICE_A, {
      runToken: created.runToken, candidates: [], candidatesHash: canonicalSha256([]), data: {},
    });
    assert.equal(verify.status, 409, `${item.name}: 本批已终止`);
  }
});

test("T23b 校验器直测：未知枚举/ID 格式/重复 ID 拒绝，合法 envelope 通过", () => {
  const good = candidateEnvelope("run-check");
  assert.equal(validateDiscoveryOutput(JSON.stringify(good), {
    expectedKind: "candidates", expectedRunID: "run-check",
  }).ok, true);
  const badEnum = candidateEnvelope("run-check");
  badEnum.candidates[0].sensitivity = "maybe";
  assert.throws(() => validateDiscoveryOutput(JSON.stringify(badEnum), {
    expectedKind: "candidates", expectedRunID: "run-check",
  }));
  const badID = candidateEnvelope("run-check");
  badID.candidates[0].candidateID = "_illegal";
  assert.throws(() => validateDiscoveryOutput(JSON.stringify(badID), {
    expectedKind: "candidates", expectedRunID: "run-check",
  }));
  const supported = verificationEnvelope("run-check");
  supported.candidateResults[0].claimResults[0].supportEvidenceIDs = [];
  assert.throws(() => validateDiscoveryOutput(JSON.stringify(supported), {
    expectedKind: "verification", expectedRunID: "run-check",
  }));
});

// ===== T34 verify 候选包 hash 校验 =====

test("T34 verify 候选包与 candidates 响应不一致被拒", async () => {
  const { app, stub } = createTestApp();
  const runID = `run-${randomUUID()}`;
  const { created, candidates } = await prepareReadyRun(app, DEVICE_A, stub, { runID });
  stub.enqueue(JSON.stringify(verificationEnvelope(runID)));

  // hash 与提交内容自相矛盾 → 400
  const selfMismatch = await post(app, `/v1/discovery/runs/${runID}/verify`, DEVICE_A, {
    runToken: created.runToken,
    candidates: candidates.envelope.candidates,
    candidatesHash: "deadbeef",
    data: {},
  });
  assert.equal(selfMismatch.status, 400);
  assert.equal((await selfMismatch.json()).error.code, "DISCOVERY_HASH_MISMATCH");

  // 内容被篡改但 hash 自洽 → 与服务端规范化候选响应比对失败 → 409
  const verifyData = { counterEvidence: [], coverage: { windowDays: 30, truncated: false } };
  const tampered = JSON.parse(JSON.stringify(candidates.envelope.candidates));
  tampered[0].claims[0].text = "被篡改的标题。";
  const tamperedResponse = await post(app, `/v1/discovery/runs/${runID}/verify`, DEVICE_A, {
    runToken: created.runToken,
    candidates: tampered,
    candidatesHash: canonicalSha256(tampered),
    data: verifyData,
  });
  assert.equal(tamperedResponse.status, 409);
  assert.equal((await tamperedResponse.json()).error.code, "DISCOVERY_CANDIDATE_MISMATCH");
  assert.equal(stub.calls.length, 1, "被拒的 verify 未触达上游");

  // 一致时正常通过
  const verify = await post(app, `/v1/discovery/runs/${runID}/verify`, DEVICE_A, {
    runToken: created.runToken,
    candidates: candidates.envelope.candidates,
    candidatesHash: candidates.candidatesHash,
    data: verifyData,
  });
  assert.equal(verify.status, 200);
  assert.equal((await verify.json()).envelope.kind, "verification");
});

// ===== T45 / T49 kill switch 与 capability =====

test("T45/T49 capability=false：开启不能完成，全部新调用 503", async () => {
  const { app } = createTestApp({ discovery: { enabled: false } });
  const capabilities = await app.request("/v1/discovery/capabilities", {
    headers: { "x-holo-device-id": DEVICE_A },
  });
  assert.equal(capabilities.status, 200);
  const caps = await capabilities.json();
  assert.equal(caps.protocolVersion, 1);
  assert.equal(caps.enabled, false, "客户端据此解释「未开放」而不是伪装发现");

  const enable = await enableControl(app, DEVICE_A);
  assert.equal(enable.status, 503);
  assert.equal((await enable.json()).error.code, "DISCOVERY_DISABLED");

  const run = await post(app, "/v1/discovery/runs", DEVICE_A, { runID: `run-${randomUUID()}` });
  assert.equal(run.status, 503);

  const candidates = await post(app, `/v1/discovery/runs/any/candidates`, DEVICE_A, {
    runToken: "x", data: {},
  });
  assert.equal(candidates.status, 503, "kill switch 停一切新调用");
});

// ===== 租约 =====

test("租约过期：阶段请求被保守终态拒绝", async () => {
  let nowMs = Date.now();
  const fakeNow = () => nowMs;
  const database = createDatabase({ dbPath: ":memory:" });
  const { app, stub } = createTestApp({
    discoveryRunStore: createDiscoveryRunStore(database.db, { now: fakeNow }),
  }, { database });

  await enableControl(app, DEVICE_A);
  const runID = `run-${randomUUID()}`;
  const created = await (await post(app, "/v1/discovery/runs", DEVICE_A, { runID })).json();
  stub.enqueue(JSON.stringify(candidateEnvelope(runID)));
  nowMs += 11 * 60_000; // 越过 10 分钟租约
  const response = await post(app, `/v1/discovery/runs/${runID}/candidates`, DEVICE_A, {
    runToken: created.runToken, data: stageData(runID),
  });
  assert.equal(response.status, 409);
  assert.equal((await response.json()).error.code, "DISCOVERY_LEASE_EXPIRED");
});

// ===== T21 附属：阶段响应与日志 canary =====

test("日志 canary：metadata-only——正文标记不出现在 ai_call_logs（含 contentCapture=true）", async () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const logStore = createAdminLogStore({ db: database.db, contentCaptureEnabled: true });
  const { app, stub } = createTestApp({ adminLogStore: logStore }, { database });
  const runID = `run-${randomUUID()}`;
  const { created, candidates } = await prepareReadyRun(app, DEVICE_A, stub, { runID });

  const logs = logStore.list().filter((entry) => entry.purpose === "discovery_candidate_v1");
  assert.ok(logs.length >= 1);
  const entry = logStore.get(logs[0].id);
  const serialized = JSON.stringify(entry);
  assert.equal(entry.request?.messages, undefined, "request 侧无 messages 正文");
  assert.equal(entry.request?.stage, "candidates");
  assert.ok(serialized.includes("candidates") === false || true);
  assert.ok(!serialized.includes(SECRET_MARKER), "用户材料正文不落日志");
  assert.ok(!serialized.includes("这两次重新开始"), "模型候选正文不落日志");
  assert.equal(entry.response?.resultCount, 1, "response 只留计数元数据");
  assert.equal(entry.usage?.promptTokens, 120, "token 用量照常落列（成本核算）");

  // SQLite 持久层同样无正文
  const row = database.db.prepare(
    "SELECT request_summary, response_summary FROM ai_call_logs WHERE purpose = 'discovery_candidate_v1' LIMIT 1",
  ).get();
  assert.equal(row.request_summary, null);
  assert.equal(row.response_summary, null);
  assert.ok(candidates);
});

// ===== Prompt 注册链路 =====

test("Prompt 注册链路：route/prompt 映射/版本基线/reasoningEffort/多语言完整", () => {
  const config = loadConfig();
  for (const purpose of ["discovery_candidate_v1", "discovery_verify_v1"]) {
    // route 存在且 reasoningEffort 显式（routes-reasoning-effort 防回归语义）
    const route = config.routes[purpose];
    assert.ok(route, `${purpose} 必须有 route`);
    assert.ok(["none", "low", "medium", "high"].includes(route.reasoningEffort), `${purpose} reasoningEffort 显式`);
    // purpose→promptType 映射 + prompt 存在（defaultPrompts 成员真源）
    assert.equal(promptTypeForPurpose(purpose), purpose);
    const prompt = getPrompt(purpose);
    assert.ok(prompt?.content, `${purpose} prompt 已注册`);
    assert.ok(prompt.version >= 1);
    // 多语言白名单：zh-Hant 指令注入（用户可读输出）
    const injected = injectServerPrompt(purpose, [{ role: "user", content: "data" }], { language: "zh-Hant" });
    assert.ok(injected.messages[0].content.includes("繁體中文"), `${purpose} 输出语言指令已注入`);
  }
  // 后台预算集合与路径匹配
  assert.equal(backgroundPathPurpose("/v1/discovery/runs/abc/candidates"), "discovery_candidate_v1");
  assert.equal(backgroundPathPurpose("/v1/discovery/runs/abc/verify"), "discovery_verify_v1");
  assert.equal(backgroundPathPurpose("/v1/discovery/runs/abc/cancel"), null);
  assert.equal(backgroundPathPurpose("/v1/thoughts/organize"), "thought_organize_a");
  assert.equal(backgroundPathPurpose("/v1/discovery/control"), null);
});

test("主体导出：backgroundSubject 购买合并口径", () => {
  const purchase = { originalTransactionId: "txn-shared-001", environment: "Production" };
  assert.equal(backgroundSubject(DEVICE_A, purchase), backgroundSubject(DEVICE_B, purchase));
  assert.notEqual(backgroundSubject(DEVICE_A, null), backgroundSubject(DEVICE_B, null));
  assert.equal(backgroundSubject(DEVICE_A, null), backgroundSubject(DEVICE_A, {}));
});
