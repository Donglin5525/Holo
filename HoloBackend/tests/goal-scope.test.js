/**
 * 目标闭环契约测试（2026-10-20 最终规格 §6.4 / §6.5 / R15 R16 R26 R27 R32）
 * - goalScope 白名单校验（app.js 上传边界 + executor 防御）
 * - goalReview 体积封顶
 * - 冻结块：范围由代码声明、事实快照注入、修正草案输出契约
 * - 证据池种子：goal.* 指标与 goal-review:* 证据可被 claim 引用并通过交付核验
 * - 修正草案消毒：kind 白名单 / 引用白名单 / 数量封顶 / 身份字段服务端生成
 * - 端到端：目标回顾任务完成 → goalScope 原样回显 + 草案随结果下发 + 快照数字进白名单
 */

import assert from "node:assert/strict";
import { test } from "node:test";
import { randomBytes } from "node:crypto";

import {
  normalizeGoalScope,
  acceptGoalReview,
  buildGoalScopeBlock,
  seedGoalReviewEvidence,
  goalReviewReferenceSets,
  sanitizeGoalAdjustmentDraft,
} from "../src/agent/goalScopeContract.js";
import { createDatabase } from "../src/db/database.js";
import { createCloudAnalysisTaskStore } from "../src/agent/cloudAnalysisTaskStore.js";
import { createCloudAnalysisExecutor } from "../src/agent/cloudAnalysisExecutor.js";

const TEST_KEY = randomBytes(32).toString("base64");

const SCOPE = {
  schemaVersion: 1,
  goalID: "10000000-0000-0000-0000-000000000001",
  planRevisionID: "20000000-0000-0000-0000-000000000001",
  reviewID: "30000000-0000-0000-0000-000000000001",
  windowStart: "2026-10-01T00:00:00+08:00",
  windowEndExclusive: "2026-10-15T00:00:00+08:00",
  snapshotCutoffAt: "2026-10-15T09:00:00+08:00",
  timeZoneID: "Asia/Shanghai",
  sourceDigest: "digest-abc",
};

const GOAL_REVIEW = {
  schemaVersion: 1,
  goalID: SCOPE.goalID,
  goalTitle: "北海道旅行资金",
  planRevisionID: SCOPE.planRevisionID,
  planRevisionNumber: 1,
  windowStart: SCOPE.windowStart,
  windowEndExclusive: SCOPE.windowEndExclusive,
  snapshotCutoffAt: SCOPE.snapshotCutoffAt,
  timeZoneID: "Asia/Shanghai",
  successCriteria: "出发前专款 18000 元",
  result: { status: "observed", sourceKind: "ledger", sourceLabel: "账户「旅行基金」余额", moneyValue: 4800, unit: "元", observedAt: SCOPE.snapshotCutoffAt, targetValue: 18000 },
  execution: [
    { id: "40000000-0000-0000-0000-000000000001", entityType: "task", entityID: "50000000-0000-0000-0000-000000000001", title: "本月存入 3000", role: "action", isUnavailable: false, taskCompleted: false },
    { id: "40000000-0000-0000-0000-000000000002", entityType: "habit", entityID: "50000000-0000-0000-0000-000000000002", title: "奶茶", role: "constraint", isUnavailable: false },
  ],
  constraints: [
    { id: "40000000-0000-0000-0000-000000000002", kind: "habit_limit", title: "奶茶每周不超过 2 杯", limitValue: 2, observedValue: 3, unit: "杯", windowDays: 7, hasRecords: true, isBreached: true, isUnavailable: false },
  ],
  coverage: { known: ["任务完成 0/1"], unknown: ["体重近 14 天无记录"] },
  review: { cadenceDays: 7, isDue: true },
  fundPlan: {
    target: 18000,
    currentFunds: 4800,
    installmentsTotal: 6,
    installmentsPast: 2,
    outcome: { status: "behind", plannedToDate: 6000, shortfallToDate: 1200, remainingAmount: 13200, remainingInstallments: [{ dueDate: "2026-11-25T00:00:00+08:00", amount: 3000 }], suggestedPerInstallment: 3300 },
  },
  sourceDigest: "digest-abc",
};

// —— normalizeGoalScope ——

test("goalScope：合法输入规范化通过（大写 UUID 归一）", () => {
  const check = normalizeGoalScope({ ...SCOPE, goalID: SCOPE.goalID.toUpperCase() });
  assert.equal(check.ok, true);
  assert.equal(check.scope.goalID, SCOPE.goalID);
  assert.equal(check.scope.schemaVersion, 1);
});

test("goalScope：非对象 / 版本 / UUID / 窗口序 / 超长字段分别拒绝", () => {
  assert.equal(normalizeGoalScope(null).ok, false);
  assert.equal(normalizeGoalScope("x").ok, false);
  assert.equal(normalizeGoalScope({ ...SCOPE, schemaVersion: 9 }).ok, false);
  assert.equal(normalizeGoalScope({ ...SCOPE, goalID: "not-uuid" }).ok, false);
  assert.equal(normalizeGoalScope({ ...SCOPE, windowStart: "2026-10-20T00:00:00+08:00" }).ok, false, "起点须早于终点");
  assert.equal(normalizeGoalScope({ ...SCOPE, windowEndExclusive: "不是日期" }).ok, false);
  assert.equal(normalizeGoalScope({ ...SCOPE, sourceDigest: "" }).ok, false);
  assert.equal(normalizeGoalScope({ ...SCOPE, timeZoneID: "x".repeat(65) }).ok, false);
  // 缺 schemaVersion 视为 1（旧客户端兼容）
  const { schemaVersion, ...rest } = SCOPE;
  assert.equal(normalizeGoalScope(rest).ok, true);
  void schemaVersion;
});

test("goalReview：只在 goalScope 合法时接受，且体积封顶", () => {
  assert.equal(acceptGoalReview(GOAL_REVIEW, null), null);
  assert.equal(acceptGoalReview(GOAL_REVIEW, normalizeGoalScope(SCOPE).scope).goalTitle, "北海道旅行资金");
  const huge = { ...GOAL_REVIEW, coverage: { known: ["x".repeat(70_000)] } };
  assert.equal(acceptGoalReview(huge, normalizeGoalScope(SCOPE).scope), null);
});

// —— 冻结块 ——

test("冻结块：范围代码声明 + 事实快照注入 + 草案输出契约", () => {
  const block = buildGoalScopeBlock(normalizeGoalScope(SCOPE).scope, GOAL_REVIEW);
  assert.ok(block.includes("目标回顾任务（代码生成，范围与事实不得改写）"));
  assert.ok(block.includes(SCOPE.goalID));
  assert.ok(block.includes(SCOPE.windowStart) && block.includes(SCOPE.snapshotCutoffAt));
  assert.ok(block.includes("<goal_review_facts>"));
  assert.ok(block.includes("北海道旅行资金"));
  assert.ok(block.includes("结果未知就是未知"));
  assert.ok(block.includes("goalAdjustmentDraft"));
  assert.ok(block.includes("change_success_criteria"));
  const noFacts = buildGoalScopeBlock(normalizeGoalScope(SCOPE).scope, null);
  assert.ok(!noFacts.includes("<goal_review_facts>"));
});

// —— 证据池种子 ——

test("证据池种子：goal.* 指标与 goal-review:* 证据注册，可被引用对账", () => {
  const pools = { metricEvidence: new Map(), validEvidenceIDs: new Set(), evidenceTexts: new Map() };
  seedGoalReviewEvidence(GOAL_REVIEW, pools);
  const keys = [...pools.metricEvidence.keys()];
  assert.ok(keys.includes("goal.result.money|all"));
  assert.ok(keys.includes("goal.fund.current|all"));
  assert.ok(keys.includes("goal.fund.perInstallment|all"));
  assert.ok(keys.includes("goal.execution.tasksTotal|all"));
  assert.ok(keys.includes("goal.constraint.1.observed|all"));
  assert.equal(pools.metricEvidence.get("goal.result.money|all").value, 4800);
  assert.equal(pools.metricEvidence.get("goal.fund.perInstallment|all").value, 3300);
  assert.equal(pools.metricEvidence.get("goal.constraint.1.observed|all").baselineValue, 2);
  for (const id of ["goal-review:result", "goal-review:execution", "goal-review:coverage"]) {
    assert.ok(pools.validEvidenceIDs.has(id));
    assert.ok(pools.evidenceTexts.get(id).length > 0);
  }
  const empty = { metricEvidence: new Map(), validEvidenceIDs: new Set(), evidenceTexts: new Map() };
  seedGoalReviewEvidence(null, empty);
  assert.equal(empty.metricEvidence.size, 0);
});

test("引用集合：execution 的 entityID/id 与 constraints 的 id 进入白名单", () => {
  const { entityIDs, bindingIDs } = goalReviewReferenceSets(GOAL_REVIEW);
  assert.equal(entityIDs.size, 2);
  assert.ok(entityIDs.has("50000000-0000-0000-0000-000000000001"));
  assert.equal(bindingIDs.size, 2);
  assert.ok(bindingIDs.has("40000000-0000-0000-0000-000000000002"));
});

// —— 修正草案消毒 ——

test("草案消毒：合法保留 / 越权引用丢弃 / 未知 kind 丢弃 / 身份字段服务端生成", () => {
  const scope = normalizeGoalScope(SCOPE).scope;
  const raw = {
    operations: [
      {
        id: "op-1", kind: "update_fund_schedule",
        fundSchedule: [{ dueDate: "2026-11-25T00:00:00+08:00", amount: 3300 }],
        currentSummary: "每期 3000", proposedSummary: "剩 4 期每期 3300", reason: "落后 1200",
      },
      {
        id: "op-2", kind: "end_binding",
        targetBindingID: "40000000-0000-0000-0000-000000000002",
        reason: "奶茶超限，换成每周上限",
      },
      { id: "op-3", kind: "update_habit", targetEntityID: "60000000-0000-0000-0000-000000000009", habitSpec: { name: "x", frequency: "daily" } },
      { id: "op-4", kind: "delete_everything", targetEntityID: "50000000-0000-0000-0000-000000000001" },
      { id: "op-5", kind: "change_success_criteria", criteriaChange: { newTargetValue: 15000 }, proposedSummary: "总目标降到 15000" },
    ],
    expectedObservation: "先看四周后资金",
  };
  const { draft, warnings } = sanitizeGoalAdjustmentDraft(raw, scope, GOAL_REVIEW);
  assert.ok(draft, "应产出草案");
  assert.equal(draft.operations.length, 3, "越权引用与未知 kind 各丢一条");
  assert.deepEqual(draft.operations.map((op) => op.id), ["op-1", "op-2", "op-5"]);
  assert.ok(warnings.includes("GOAL_ADJUSTMENT_REF_DROPPED:op-3"));
  assert.ok(warnings.includes("GOAL_ADJUSTMENT_OP_DROPPED:op-4"));
  // 身份字段服务端生成：模型给的 goalID/digest 一概不信
  assert.equal(draft.goalID, scope.goalID);
  assert.equal(draft.baseRevisionID, scope.planRevisionID);
  assert.equal(draft.sourceDigest, scope.sourceDigest);
  assert.match(draft.draftID, /^[0-9a-f-]{36}$/);
  assert.ok(draft.expiresAt > draft.createdAt);
  assert.equal(draft.expectedObservation, "先看四周后资金");

  const none = sanitizeGoalAdjustmentDraft({ operations: [{ id: "x", kind: "hack" }] }, scope, GOAL_REVIEW);
  assert.equal(none.draft, null);
  assert.ok(none.warnings.includes("GOAL_ADJUSTMENT_DROPPED"));
});

test("草案消毒：操作数量封顶 12", () => {
  const scope = normalizeGoalScope(SCOPE).scope;
  const raw = {
    operations: Array.from({ length: 20 }, (_, i) => ({
      id: `op-${i + 1}`, kind: "update_review", review: { cadenceDays: 7 },
    })),
  };
  const { draft, warnings } = sanitizeGoalAdjustmentDraft(raw, scope, GOAL_REVIEW);
  assert.equal(draft.operations.length, 12);
  assert.ok(warnings.includes("GOAL_ADJUSTMENT_OPS_CAPPED"));
});

// —— 端到端：executor 深度分析（目标回顾任务）——

function agentJson(status, extra = {}) {
  return JSON.stringify({ status, reasoning: "r", toolRequests: [], claims: [], warnings: [], ...extra });
}

function makeProvider(responses) {
  const calls = [];
  return {
    calls,
    async complete(request) {
      calls.push(request);
      const next = responses.shift();
      if (!next) throw new Error("PROVIDER_EXHAUSTED");
      return { choices: [{ index: 0, message: { role: "assistant", content: next }, finish_reason: "stop" }], usage: { prompt_tokens: 10, completion_tokens: 5 } };
    },
  };
}

test("端到端：goalScope 原样回显 + 快照数字过核验 + 草案随结果下发 + 证据池种子", async () => {
  const finalClaims = agentJson("final_claims", {
    title: "北海道资金落后 1200",
    claims: [
      { displayText: "旅行资金 4800 元，比计划少 1200 元，剩余 4 期每期应存 3300 元", metricAssertions: [{ metricKey: "goal.result.money", value: 4800, unit: "元" }], evidenceIDs: ["goal-review:result"] },
      { displayText: "奶茶本周 3 杯超出上限 2 杯", metricAssertions: [{ metricKey: "goal.constraint.1.observed", value: 3, baselineValue: 2, unit: "杯" }], evidenceIDs: [] },
    ],
    goalAdjustmentDraft: {
      operations: [
        { id: "op-1", kind: "update_fund_schedule", fundSchedule: [{ dueDate: "2026-11-25T00:00:00+08:00", amount: 3300 }], currentSummary: "每期 3000", proposedSummary: "每期 3300" },
        { id: "op-2", kind: "update_habit", targetEntityID: "50000000-0000-0000-0000-000000000099", habitSpec: { name: "x", frequency: "daily" } },
      ],
    },
  });
  const provider = makeProvider([finalClaims]);
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const quota = {
    reserve: () => ({ allowed: true, subjectId: "s", tier: "free", quotaType: "deepAnalysis", actionId: "a", periodKey: "p" }),
    commit() {}, release() {},
  };
  let systemPrompt = "";
  const executor = createCloudAnalysisExecutor({
    taskStore: store,
    providers: new Map([["fake", {
      ...provider,
      async complete(request) {
        if (request.messages?.[0]?.role === "system") systemPrompt = request.messages[0].content;
        return provider.complete(request);
      },
    }]]),
    route: { provider: "fake", model: "m", temperature: 0.2, maxTokens: 1024 },
    providerRetries: 1,
    quotaLedger: quota,
    entitlementResolver: { resolve: () => ({ usageSubjectId: "subj-1", tier: "free" }) },
    log: () => {},
    injectedQuestionTimeResolver: { resolveQuestionTime: async () => null },
  });

  const task = store.create({ deviceId: "device-goal", question: "回顾目标「北海道旅行资金」", taskType: "deep_analysis" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify({
    version: 1,
    datasets: {},
    answerTask: {
      scenarioID: "goal",
      userQuestion: "回顾目标",
      questionKind: "diagnosis",
      primaryTimeRange: { label: "目标回顾窗口", start: 1_759_276_800, end: 1_760_486_400 },
      answerChecklist: ["当初想达到什么"],
    },
    goalScope: SCOPE,
    goalReview: GOAL_REVIEW,
  }) });

  assert.equal(await executor.run(task.id), "completed");
  const result = JSON.parse(store.getDecrypted(task.id, ["result"]).result);

  // 范围回显（客户端据此归类「目标」并双入口同报告）
  assert.equal(result.goalScope.goalID, SCOPE.goalID);
  assert.equal(result.goalScope.planRevisionID, SCOPE.planRevisionID);
  assert.equal(result.goalScope.sourceDigest, SCOPE.sourceDigest);

  // 草案：合法 op 保留，越权引用丢弃并记 warning
  assert.equal(result.goalAdjustmentDraft.operations.length, 1);
  assert.equal(result.goalAdjustmentDraft.operations[0].kind, "update_fund_schedule");
  assert.ok(result.warnings.includes("GOAL_ADJUSTMENT_REF_DROPPED:op-2"));

  // 引用 goal.* 指标的数字结论不被 NUMERIC_CLAIM_UNVERIFIED 撤回（快照数字进白名单）
  assert.equal(result.claims.length, 2, `两条结论都应存活，实际 ${JSON.stringify(result.warnings)}`);
  assert.ok(result.evidence.some((item) => item.metricKey === "goal.result.money"), "证据池应含 goal 指标");

  // system prompt 含冻结块与事实快照
  assert.ok(systemPrompt.includes("目标回顾任务（代码生成，范围与事实不得改写）"));
  assert.ok(systemPrompt.includes(SCOPE.goalID));
  assert.ok(systemPrompt.includes("<goal_review_facts>"));
});

test("端到端：非法 goalScope 降级为普通深度分析（不中断）", async () => {
  const provider = makeProvider([
    agentJson("final_claims", { claims: [{ displayText: "支出平稳", metricAssertions: [], evidenceIDs: [] }] }),
  ]);
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createCloudAnalysisTaskStore(database.db, { encryptionKey: TEST_KEY });
  const executor = createCloudAnalysisExecutor({
    taskStore: store,
    providers: new Map([["fake", provider]]),
    route: { provider: "fake", model: "m", temperature: 0.2, maxTokens: 1024 },
    providerRetries: 1,
    quotaLedger: {
      reserve: () => ({ allowed: true, subjectId: "s", tier: "free", quotaType: "deepAnalysis", actionId: "a", periodKey: "p" }),
      commit() {}, release() {},
    },
    entitlementResolver: { resolve: () => ({ usageSubjectId: "subj-1", tier: "free" }) },
    log: () => {},
    injectedQuestionTimeResolver: { resolveQuestionTime: async () => null },
  });
  const task = store.create({ deviceId: "d2", question: "分析我的支出" });
  store.attachSnapshot({ id: task.id, snapshot: JSON.stringify({ version: 1, datasets: {}, goalScope: { goalID: "bad" } }) });

  assert.equal(await executor.run(task.id), "completed");
  const result = JSON.parse(store.getDecrypted(task.id, ["result"]).result);
  assert.equal(result.goalScope, null);
  assert.equal(result.goalAdjustmentDraft, null);
});

// —— 上传边界（app.js 白名单）——

test("上传边界：非法 goalScope 拒 400 / goalReview 超限拒 413 / 合法放行", async () => {
  const { createApp } = await import("../src/app.js");
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database,
    auth: { enforceAppAttest: false },
    limits: { chatRequestsPerMinute: 100, chatRequestsPerDay: 1000, cloudAnalysisStartsPerMinute: 100, cloudAnalysisStartsPerDay: 1000 },
    aiCallLogs: { enabled: false },
    runtimeEnvironment: "test",
    cloudAnalysisEncryptionKey: TEST_KEY,
    cloudAnalysisExecutor: { run: async () => "queued" },
  });
  const headers = { "content-type": "application/json", "x-holo-device-id": "device-goal-scope" };
  const start = await app.request("/v1/ai/agent/cloud/start", { method: "POST", headers, body: JSON.stringify({ question: "回顾目标" }) });
  const { taskId } = await start.json();

  const bad = await app.request(`/v1/ai/agent/cloud/${taskId}/snapshot`, {
    method: "PUT", headers,
    body: JSON.stringify({ version: 1, datasets: {}, goalScope: { goalID: "not-uuid" } }),
  });
  assert.equal(bad.status, 400);
  assert.equal((await bad.json()).error?.code, "INVALID_GOAL_SCOPE");

  // 非法后任务仍处 uploading，可继续上传合法快照
  const oversize = await app.request(`/v1/ai/agent/cloud/${taskId}/snapshot`, {
    method: "PUT", headers,
    body: JSON.stringify({
      version: 1, datasets: {}, goalScope: SCOPE,
      goalReview: { coverage: { known: ["x".repeat(70_000)] } },
    }),
  });
  assert.equal(oversize.status, 413);
  assert.equal((await oversize.json()).error?.code, "GOAL_REVIEW_TOO_LARGE");

  const ok = await app.request(`/v1/ai/agent/cloud/${taskId}/snapshot`, {
    method: "PUT", headers,
    body: JSON.stringify({ version: 1, datasets: {}, goalScope: SCOPE, goalReview: GOAL_REVIEW }),
  });
  assert.equal(ok.status, 200);
});
