import test from "node:test";
import assert from "node:assert/strict";
import { validateBriefRequest, validateBriefModelOutput, BRIEF_LIMITS } from "../src/thoughts/categoryBriefSchema.js";
import { createThoughtCategoryBriefService } from "../src/thoughts/categoryBriefService.js";
import { GatewayError } from "../src/errors.js";

// 归档类别理解器契约（2026-10-12 主题双通道·零打扰）：
// 请求=成员证据（用户确认优先标注）+移出反证；输出=定义+排除边界+逐字证据。

function briefBody(extra = {}) {
  return {
    schemaVersion: 1,
    operationId: "op-" + Math.random().toString(36).slice(2, 10),
    engineVersion: "thought_semantic_v3.2",
    topic: { title: "碎碎念", userDefinition: null, currentBrief: null },
    members: [
      { ref: "R0", text: "食堂两个肉菜 53 块，这定价是认真的吗。", source: "user" },
      { ref: "R1", text: "出门喂猫的时候发现楼下的桂花开了，顺手记一下。", source: "user" },
      { ref: "R2", text: "Agent 越来越能干之后，人反而更不敢拍板了，记下这个感受。", source: "ai" },
      { ref: "R3", text: "地铁上听到一段对话，回家想想还是记下来。", source: "legacy" },
    ],
    removals: [],
    ...extra,
  };
}

// ─────────────────────────── 输入契约 ───────────────────────────

test("validateBriefRequest 接受合法请求并保留证据结构", () => {
  const parsed = validateBriefRequest(briefBody());
  assert.equal(parsed.members.length, 4);
  assert.equal(parsed.members[0].source, "user");
  assert.equal(parsed.topic.userDefinition, null);
});

test("validateBriefRequest 拒绝成员不足/来源非法/重复 ref/越界长度", () => {
  assert.throws(() => validateBriefRequest(briefBody({ schemaVersion: 2 })));
  assert.throws(() => validateBriefRequest(briefBody({ members: [
    { ref: "R0", text: "片段", source: "user" },
    { ref: "R1", text: "片段", source: "user" },
  ] })));
  assert.throws(() => validateBriefRequest(briefBody({ members: [
    { ref: "R0", text: "片段", source: "user" },
    { ref: "R1", text: "片段", source: "weird" },
    { ref: "R2", text: "片段", source: "ai" },
  ] })));
  assert.throws(() => validateBriefRequest(briefBody({ members: [
    { ref: "R0", text: "片段", source: "user" },
    { ref: "R0", text: "片段二", source: "user" },
    { ref: "R1", text: "片段", source: "ai" },
  ] })));
  assert.throws(() => validateBriefRequest(briefBody({ topic: { title: "长".repeat(BRIEF_LIMITS.titleMaxUTF16 + 1) } })));
});

// ─────────────────────────── 输出校验 ───────────────────────────

test("validateBriefModelOutput 接受合法定义并归一化排除项", () => {
  const parsed = validateBriefRequest(briefBody());
  const out = validateBriefModelOutput({
    schemaVersion: 1,
    operationId: parsed.operationId,
    brief: { definition: "个人生活片段、即时感受、吐槽，以及由生活或工作触发的个人观察与反思。", exclusions: ["纯转载", " 纯转载 ", "任务清单"] },
    evidence: [{ ref: "R0", quote: "这定价是认真的吗" }],
  }, parsed);
  assert.equal(out.malformed, undefined);
  assert.deepEqual(out.brief.exclusions, ["纯转载", "任务清单"], "排除项去空格去重");
});

test("validateBriefModelOutput 拒绝伪造证据、空定义与自造 ref", () => {
  const parsed = validateBriefRequest(briefBody());
  assert.equal(validateBriefModelOutput({
    brief: { definition: "定义", exclusions: [] },
    evidence: [{ ref: "R0", quote: "不在原文里的字" }],
  }, parsed).reason, "quote_not_verbatim");
  assert.equal(validateBriefModelOutput({
    brief: { definition: "", exclusions: [] },
    evidence: [{ ref: "R0", quote: "这定价是认真的吗" }],
  }, parsed).reason, "definition_shape");
  assert.equal(validateBriefModelOutput({
    brief: { definition: "定义", exclusions: [] },
    evidence: [{ ref: "NOPE", quote: "片段" }],
  }, parsed).reason, "evidence_ref_not_allowed");
});

// ─────────────────────────── 服务编排（mock provider） ───────────────────────────

function stubCompletion(content) {
  return {
    choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
    usage: { prompt_tokens: 120, completion_tokens: 40 },
  };
}

function stubProvider(handler) {
  return new Map([["stub", { async complete(request) { return handler(request); } }]]);
}

function makeConfig() {
  return {
    aiCallLogs: { enabled: false },
    routes: {
      thought_category_brief_v1: { provider: "stub", model: "stub-model", temperature: 0, maxTokens: 600 },
    },
    thoughtSemanticRelate: {
      enabled: true,
      privacyVerified: true,
      deadlineMs: 5_000,
      budgets: { perSubjectDailyCNY: 1, moderationPerCallCNY: 0 },
      pricing: { inputPerMillionCNY: 2, outputPerMillionCNY: 8 },
    },
  };
}

test("端到端：合法输出回传 definition/exclusions/evidence", async () => {
  const service = createThoughtCategoryBriefService({
    config: makeConfig(),
    providers: stubProvider(() => stubCompletion(JSON.stringify({
      schemaVersion: 1,
      brief: { definition: "个人生活片段、即时感受、吐槽与观察反思。", exclusions: ["纯转载"] },
      evidence: [{ ref: "R0", quote: "这定价是认真的吗" }],
    }))),
    adminLogStore: null,
    budgetStore: makeBudgetStore(),
    contentModeration: null,
  });
  const result = await service.brief({ deviceId: "d1", subjectId: "s1", body: briefBody(), clientSignal: null });
  assert.equal(result.brief.definition, "个人生活片段、即时感受、吐槽与观察反思。");
  assert.deepEqual(result.brief.exclusions, ["纯转载"]);
});

test("端到端：模型输出 malformed 返回 502 且不二次调用", async () => {
  let calls = 0;
  const service = createThoughtCategoryBriefService({
    config: makeConfig(),
    providers: stubProvider(() => { calls += 1; return stubCompletion("{\"brief\":{}}"); }),
    adminLogStore: null,
    budgetStore: makeBudgetStore(),
    contentModeration: null,
  });
  await assert.rejects(
    () => service.brief({ deviceId: "d1", subjectId: "s1", body: briefBody(), clientSignal: null }),
    (error) => error instanceof GatewayError && error.status === 502,
  );
  assert.equal(calls, 1);
});

function makeBudgetStore() {
  const operations = new Map();
  return {
    beginOperation({ operationId }) {
      if (operations.has(operationId)) return { allowed: false, reason: "in_progress" };
      operations.set(operationId, true);
      return { allowed: true };
    },
    settleOperation() {},
  };
}
