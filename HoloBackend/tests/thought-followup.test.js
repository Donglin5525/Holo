import test from "node:test";
import assert from "node:assert/strict";
import { mkdirSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { loadConfig } from "../src/config.js";
import {
  validateFollowupRequest,
  validateFollowupModelOutput,
  organizationCapabilities,
  FOLLOWUP_LIMITS,
  THOUGHT_FOLLOWUP_POLICY_VERSION,
} from "../src/thoughts/followupSchema.js";
import { getPrompt } from "../src/prompts/promptRegistry.js";
import { promptTypeForPurpose } from "../src/prompts/serverPromptPolicy.js";
import { backgroundSubject } from "../src/usage/backgroundCostGuard.js";

// 想法脉络核对（2026-11-16 想法主题与脉络方案 §5 B1 / §6 C2 / §2 A13）：
// 能力口 + 核对端点契约、32KiB 实际字节闸（先于 JSON 解析）、试点白名单（可信主体）、
// 输出契约（六关系枚举/双侧逐字证据/thread 约束/协议错整批失败）、metadata-only 日志、
// 真实路由响应 fixture 导出（驱动 iOS 契约测试）。

const PILOT_SUBJECT = backgroundSubject("debug-device", null);

// fixture 输出目录（真实路由响应体，非手写；供 iOS 契约测试消费）
const FIXTURES_DIR = fileURLToPath(
  new URL("../../docs/thoughts/plans/2026-11-16-想法主题与脉络/fixtures/", import.meta.url),
);

// ─────────────────────────── 测试基建 ───────────────────────────

const noModeration = { isEnabled: () => false };

function makeApp(overrides = {}) {
  const { thoughtFollowup: followupOverrides, ...rest } = overrides;
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database,
    auth: { enforceAppAttest: false },
    contentModeration: rest.contentModeration ?? noModeration,
    ...rest,
    thoughtFollowup: {
      enabled: true,
      privacyVerified: true,
      pilotSubjects: [PILOT_SUBJECT],
      ...(followupOverrides ?? {}),
    },
  });
  return { app, db: database.db };
}

/** 规格示例场景：锚点 N2 × 候选 N0/N1（同主题三段思考）。 */
function followupBody(extra = {}) {
  return {
    schemaVersion: 1,
    operationId: "9f2bb45b-5dd4-457d-88cc-d619aad2eba7",
    policyVersion: THOUGHT_FOLLOWUP_POLICY_VERSION,
    scopeTitle: "产品思考",
    anchorRef: "N2",
    notes: [
      { ref: "N0", createdAtMs: 1767225600000, windows: [{ ref: "W0", text: "我原先想让 AI 自动做决定。" }] },
      { ref: "N1", createdAtMs: 1769904000000, windows: [{ ref: "W0", text: "我发现自动决定出了错难以纠正。" }] },
      { ref: "N2", createdAtMs: 1772323200000, windows: [{ ref: "W0", text: "我修改了自动决定的原则。高影响决定要先确认。" }] },
    ],
    ...extra,
  };
}

function establishedDecision(otherRef, otherQuote, otherRange) {
  return {
    otherRef,
    relation: "revises",
    reason: "把自动决策收紧为高影响时先确认",
    anchorEvidence: { windowRef: "W0", quote: "我修改了自动决定的原则。高影响决定要先确认。", rangeUTF16: [0, 22] },
    otherEvidence: { windowRef: "W0", quote: otherQuote, rangeUTF16: otherRange },
  };
}

const THREAD_OUTPUT = {
  decisions: [
    establishedDecision("N0", "我原先想让 AI 自动做决定。", [0, 15]),
    {
      otherRef: "N1",
      relation: "continues",
      reason: "针对自动决定出错后的问题加了一项确认条件",
      anchorEvidence: { windowRef: "W0", quote: "高影响决定要先确认。", rangeUTF16: [12, 22] },
      otherEvidence: { windowRef: "W0", quote: "我发现自动决定出了错难以纠正。", rangeUTF16: [0, 15] },
    },
  ],
  thread: { title: "AI 做决定的边界", question: "哪些决定可以交给 AI 自动执行？", memberRefs: ["N2", "N0", "N1"] },
};

const NONE_OUTPUT = {
  decisions: [
    { otherRef: "N0", relation: "none", reason: null, anchorEvidence: null, otherEvidence: null },
    { otherRef: "N1", relation: "insufficient", reason: null, anchorEvidence: null, otherEvidence: null },
  ],
  thread: null,
};

function stubCompletion(content) {
  return {
    id: "stub-completion",
    choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
    usage: { prompt_tokens: 100, completion_tokens: 30, total_tokens: 130 },
  };
}

function stubProvider(handler) {
  return new Map([["stub", { async complete(request) { return handler(request); } }]]);
}

function stubRoutes() {
  return {
    thought_followup_v1: { provider: "stub", model: "stub-model", temperature: 0, maxTokens: 1200 },
  };
}

async function postFollowup(app, body, headers = {}) {
  return app.request("/v1/thoughts/verify-followup", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

function saveFixture(name, payload) {
  mkdirSync(FIXTURES_DIR, { recursive: true });
  writeFileSync(FIXTURES_DIR + name, `${JSON.stringify(payload, null, 2)}\n`);
}

// ─────────────────────────── 输入契约 ───────────────────────────

test("请求契约：合法请求解析归一，锚点排首位、字段按协议保留", () => {
  const parsed = validateFollowupRequest(followupBody());
  assert.equal(parsed.schemaVersion, 1);
  assert.equal(parsed.anchorRef, "N2");
  assert.deepEqual(parsed.notes.map((n) => n.ref), ["N2", "N0", "N1"], "锚点排首位");
  assert.equal(parsed.scopeTitle, "产品思考");
  assert.equal(parsed.policyVersion, "thought-followup-1");
});

test("请求契约：operationId 必须 UUID、policyVersion 必须当前版本、错位一律拒绝", () => {
  assert.throws(() => validateFollowupRequest(followupBody({ operationId: "op-1" })), "非 UUID 拒绝");
  assert.throws(() => validateFollowupRequest(followupBody({ policyVersion: "thought-followup-2" })));
  assert.throws(() => validateFollowupRequest(followupBody({ schemaVersion: 2 })));
  assert.throws(() => validateFollowupRequest({}), "空体拒绝");
});

test("请求契约：notes 数量 2-5、ref 唯一、锚点必须存在、createdAtMs 非负整数", () => {
  const notes = followupBody().notes;
  assert.throws(() => validateFollowupRequest(followupBody({ notes: notes.slice(0, 1) })), "仅锚点一条拒绝");
  assert.throws(() => validateFollowupRequest(followupBody({
    notes: [...notes,
      { ref: "N3", createdAtMs: 1, windows: [{ ref: "W0", text: "x" }] },
      { ref: "N4", createdAtMs: 2, windows: [{ ref: "W0", text: "y" }] },
      { ref: "N5", createdAtMs: 3, windows: [{ ref: "W0", text: "z" }] }],
  })), "超过 5 条拒绝");
  assert.throws(() => validateFollowupRequest(followupBody({ anchorRef: "N9" })), "锚点不在 notes 拒绝");
  assert.throws(() => validateFollowupRequest(followupBody({
    notes: [notes[0], { ...notes[1], ref: "N0" }, notes[2]],
  })), "重复 note ref 拒绝");
  assert.throws(() => validateFollowupRequest(followupBody({
    notes: [{ ...notes[0], createdAtMs: -1 }, notes[1], notes[2]],
  })), "负时间戳拒绝");
  assert.throws(() => validateFollowupRequest(followupBody({
    notes: [{ ...notes[0], createdAtMs: 1.5 }, notes[1], notes[2]],
  })), "非整数时间戳拒绝");
});

test("请求契约：窗口每 note 1-2 个、ref note 内唯一、单窗 ≤600、总正文 ≤6000 UTF-16", () => {
  const notes = followupBody().notes;
  assert.throws(() => validateFollowupRequest(followupBody({
    notes: [{ ...notes[0], windows: [{ ref: "W0", text: "a" }, { ref: "W1", text: "b" }, { ref: "W2", text: "c" }] }, notes[1], notes[2]],
  })), "3 个窗口拒绝");
  assert.throws(() => validateFollowupRequest(followupBody({
    notes: [{ ...notes[0], windows: [{ ref: "W0", text: "a" }, { ref: "W0", text: "b" }] }, notes[1], notes[2]],
  })), "窗口 ref 重复拒绝");
  assert.throws(() => validateFollowupRequest(followupBody({
    notes: [{ ...notes[0], windows: [{ ref: "W0", text: "长".repeat(601) }] }, notes[1], notes[2]],
  })), "窗口超 600 拒绝");

  const bigWindow = "长".repeat(1200);
  const bigNotes = ["N0", "N1", "N2", "N3", "N4"].map((ref, i) => ({
    ref, createdAtMs: i, windows: [{ ref: "W0", text: bigWindow }, { ref: "W1", text: bigWindow }],
  }));
  assert.throws(
    () => validateFollowupRequest(followupBody({ notes: bigNotes, anchorRef: "N4" })),
    "5×2×1200=12000 超总预算拒绝",
  );
});

test("配置解析：HOLO_THOUGHT_FOLLOWUP_ENABLED 默认 false，试点白名单默认空", () => {
  const config = loadConfig();
  assert.equal(config.thoughtFollowup.enabled, false);
  assert.deepEqual(config.thoughtFollowup.pilotSubjects, []);
  assert.equal(config.routes.thought_followup_v1.maxTokens, 1200, "§5 B1 默认输出上限 1200");
});

// ─────────────────────────── 输出契约 ───────────────────────────

function outputParsed(extra = {}) {
  return validateFollowupRequest(followupBody(extra));
}

test("输出契约：成立关系双侧证据齐全 + thread 合法时通过并 canonical 化", () => {
  const out = validateFollowupModelOutput(THREAD_OUTPUT, outputParsed());
  assert.equal(out.malformed, undefined);
  assert.equal(out.decisions[0].relation, "revises");
  assert.deepEqual(out.decisions[0].anchorEvidence.rangeUTF16, [0, 22]);
  assert.deepEqual(out.decisions[0].otherEvidence.rangeUTF16, [0, 15]);
  assert.equal(out.thread.title, "AI 做决定的边界");
  assert.deepEqual(out.thread.memberRefs, ["N2", "N0", "N1"]);
});

test("输出契约：每个非锚点 ref 恰好一条，缺失/自造/重复都整批协议失败", () => {
  // 缺一条 → decisions_incomplete（不降级成 no_result）
  const missing = validateFollowupModelOutput({ decisions: [THREAD_OUTPUT.decisions[0]], thread: null }, outputParsed());
  assert.equal(missing.reason, "decisions_incomplete");
  // 模型自造 ref（顶替合法 ref）→ other_ref_not_allowed
  assert.equal(validateFollowupModelOutput({
    decisions: [THREAD_OUTPUT.decisions[0], { ...THREAD_OUTPUT.decisions[1], otherRef: "N9" }],
  }, outputParsed()).reason, "other_ref_not_allowed");
  // 重复 ref
  assert.equal(validateFollowupModelOutput({
    decisions: [THREAD_OUTPUT.decisions[0], THREAD_OUTPUT.decisions[0]],
  }, outputParsed()).reason, "other_ref_duplicated");
  // 锚点自己出现在 decisions 也非法（锚点不判自己）
  assert.equal(validateFollowupModelOutput({
    decisions: [{ ...THREAD_OUTPUT.decisions[0], otherRef: "N2" }, THREAD_OUTPUT.decisions[1]],
  }, outputParsed()).reason, "other_ref_not_allowed");
});

test("输出契约：relation 六枚举 + confidence 禁令 + 负向决定三字段必须全 null", () => {
  const base = { otherRef: "N0", reason: null, anchorEvidence: null, otherEvidence: null };
  assert.equal(validateFollowupModelOutput({
    decisions: [{ ...base, relation: "same_thread" }, { ...base, otherRef: "N1", relation: "none" }],
  }, outputParsed()).reason, "relation_enum");
  assert.equal(validateFollowupModelOutput({
    decisions: [{ ...base, relation: "none", confidence: 0.9 }, { ...base, otherRef: "N1", relation: "none" }],
  }, outputParsed()).reason, "confidence_forbidden");
  // none 带 reason → 协议错误
  assert.equal(validateFollowupModelOutput({
    decisions: [{ ...base, relation: "none", reason: "其实有关" }, { ...base, otherRef: "N1", relation: "none" }],
  }, outputParsed()).reason, "negative_decision_fields_not_null");
  // insufficient 带证据 → 协议错误
  assert.equal(validateFollowupModelOutput({
    decisions: [{ ...base, relation: "insufficient", anchorEvidence: { windowRef: "W0", quote: "我修改了", rangeUTF16: [0, 4] } },
      { ...base, otherRef: "N1", relation: "none" }],
  }, outputParsed()).reason, "negative_decision_fields_not_null");
});

test("输出契约：成立关系缺 reason、缺任一侧证据、证据不可逐字回源都协议失败", () => {
  const valid = THREAD_OUTPUT.decisions[0];
  assert.equal(validateFollowupModelOutput({
    decisions: [{ ...valid, reason: undefined }, THREAD_OUTPUT.decisions[1]],
    thread: null,
  }, outputParsed()).reason, "reason_shape");
  assert.equal(validateFollowupModelOutput({
    decisions: [{ ...valid, anchorEvidence: null }, THREAD_OUTPUT.decisions[1]],
    thread: null,
  }, outputParsed()).reason, "anchor_evidence_invalid");
  assert.equal(validateFollowupModelOutput({
    decisions: [{ ...valid, otherEvidence: null }, THREAD_OUTPUT.decisions[1]],
    thread: null,
  }, outputParsed()).reason, "other_evidence_invalid");
  // 引用窗口里不存在的句子（拼接/改写）→ 不可回源
  assert.equal(validateFollowupModelOutput({
    decisions: [{ ...valid, anchorEvidence: { windowRef: "W0", quote: "我修改了原则。要先确认一切。", rangeUTF16: [0, 12] } }, THREAD_OUTPUT.decisions[1]],
    thread: null,
  }, outputParsed()).reason, "anchor_evidence_invalid");
  // windowRef 指到不存在的窗口
  assert.equal(validateFollowupModelOutput({
    decisions: [{ ...valid, anchorEvidence: { ...valid.anchorEvidence, windowRef: "W9" } }, THREAD_OUTPUT.decisions[1]],
    thread: null,
  }, outputParsed()).reason, "anchor_evidence_invalid");
});

test("输出契约：跨窗拼接拒绝；排版微差对齐放行；超长 canonical quote 规范到 120", () => {
  const notes = [
    { ref: "N2", createdAtMs: 3, windows: [
      { ref: "W0", text: "前半段以句号结束。后半段另起一句讨论确认。还有第三句收尾。" },
      { ref: "W1", text: "第二个窗口完全不同的内容开始。" },
    ] },
    { ref: "N0", createdAtMs: 1, windows: [{ ref: "W0", text: "较早的一条记录。" }] },
  ];
  const parsed = validateFollowupRequest({ ...followupBody({ notes, anchorRef: "N2" }), notes });
  // 跨窗拼接：W0 尾句 + W1 首句拼成一段 → 对不上 → 拒绝（R17）
  const spliced = validateFollowupModelOutput({
    decisions: [{
      otherRef: "N0", relation: "continues", reason: "拼接证据",
      anchorEvidence: { windowRef: "W0", quote: "还有第三句收尾。第二个窗口完全不同的内容开始。", rangeUTF16: [0, 20] },
      otherEvidence: { windowRef: "W0", quote: "较早的一条记录。", rangeUTF16: [0, 8] },
    }],
    thread: null,
  }, parsed);
  assert.equal(spliced.reason, "anchor_evidence_invalid", "跨窗拼接拒绝");

  // 排版微差（引号形态）对齐后取回 canonical 原文片段
  const curlyNotes = [
    { ref: "N2", createdAtMs: 3, windows: [{ ref: "W0", text: '他说"先确认"再执行。' }] },
    { ref: "N0", createdAtMs: 1, windows: [{ ref: "W0", text: "较早的一条记录。" }] },
  ];
  const curlyParsed = validateFollowupRequest({ ...followupBody({ anchorRef: "N2" }), notes: curlyNotes });
  const aligned = validateFollowupModelOutput({
    decisions: [{
      otherRef: "N0", relation: "continues", reason: "引号形态差异",
      anchorEvidence: { windowRef: "W0", quote: "他说“先确认”再执行。", rangeUTF16: [0, 10] },
      otherEvidence: { windowRef: "W0", quote: "较早的一条记录。", rangeUTF16: [0, 8] },
    }],
    thread: null,
  }, curlyParsed);
  assert.equal(aligned.malformed, undefined);
  assert.equal(aligned.decisions[0].anchorEvidence.quote, '他说"先确认"再执行。', "回源为原文逐字 canonical");

  // 模型复制超长：先确认逐字成立，再规范到协议上限（range 随 canonical 重算）
  const longText = "长".repeat(200);
  const longNotes = [
    { ref: "N2", createdAtMs: 3, windows: [{ ref: "W0", text: longText }] },
    { ref: "N0", createdAtMs: 1, windows: [{ ref: "W0", text: "较早的一条记录。" }] },
  ];
  const longParsed = validateFollowupRequest({ ...followupBody({ anchorRef: "N2" }), notes: longNotes });
  const sliced = validateFollowupModelOutput({
    decisions: [{
      otherRef: "N0", relation: "continues", reason: "整段引用",
      anchorEvidence: { windowRef: "W0", quote: longText, rangeUTF16: [0, 200] },
      otherEvidence: { windowRef: "W0", quote: "较早的一条记录。", rangeUTF16: [0, 8] },
    }],
    thread: null,
  }, longParsed);
  assert.equal(sliced.malformed, undefined);
  assert.equal(sliced.decisions[0].anchorEvidence.quote.length, FOLLOWUP_LIMITS.quoteMaxUTF16);
  assert.deepEqual(sliced.decisions[0].anchorEvidence.rangeUTF16, [0, FOLLOWUP_LIMITS.quoteMaxUTF16]);
});

test("输出契约：rangeUTF16 缺失、形状错、越窗都协议失败", () => {
  const valid = THREAD_OUTPUT.decisions[0];
  const cases = [
    { ...valid, anchorEvidence: { windowRef: "W0", quote: "我修改了自动决定的原则。高影响决定要先确认。" } },
    { ...valid, anchorEvidence: { windowRef: "W0", quote: "我修改了自动决定的原则。高影响决定要先确认。", rangeUTF16: [0] } },
    { ...valid, anchorEvidence: { windowRef: "W0", quote: "我修改了自动决定的原则。高影响决定要先确认。", rangeUTF16: [0, 99] } },
  ];
  for (const [i, item] of cases.entries()) {
    const out = validateFollowupModelOutput({ decisions: [item, THREAD_OUTPUT.decisions[1]], thread: null }, outputParsed());
    assert.equal(out.reason, "anchor_evidence_invalid", `case ${i}`);
  }
});

test("输出契约：thread 为 null 或受约束对象，成员必须含锚点且逐条有成立关系", () => {
  // thread 成员缺锚点
  const noAnchor = validateFollowupModelOutput({
    decisions: THREAD_OUTPUT.decisions,
    thread: { title: "AI 做决定的边界", question: "哪些决定可以交给 AI 自动执行？", memberRefs: ["N0", "N1"] },
  }, outputParsed());
  assert.equal(noAnchor.reason, "thread_member_count", "成员 3-5（含锚点），2 个直接不合法");
  // 模型自造成员 ref
  assert.equal(validateFollowupModelOutput({
    decisions: THREAD_OUTPUT.decisions,
    thread: { title: "标题", question: "什么样的问题？", memberRefs: ["N2", "N0", "N9"] },
  }, outputParsed()).reason, "thread_member_ref_not_allowed");
  // 成员重复
  assert.equal(validateFollowupModelOutput({
    decisions: THREAD_OUTPUT.decisions,
    thread: { title: "标题", question: "什么样的问题？", memberRefs: ["N2", "N0", "N0"] },
  }, outputParsed()).reason, "thread_member_duplicated");
  // 成员缺锚点：4 条笔记、3 个成员全部成立但不含 anchor → thread_missing_anchor
  const fourNotes = [
    ...followupBody().notes,
    { ref: "N3", createdAtMs: 1772323200001, windows: [{ ref: "W0", text: "自动化边界还要再想一步。" }] },
  ];
  const fourParsed = validateFollowupRequest({ ...followupBody({ anchorRef: "N2" }), notes: fourNotes });
  const fourEstablished = [
    establishedDecision("N0", "我原先想让 AI 自动做决定。", [0, 15]),
    { ...THREAD_OUTPUT.decisions[1] },
    establishedDecision("N3", "自动化边界还要再想一步。", [0, 12]),
  ];
  assert.equal(validateFollowupModelOutput({
    decisions: fourEstablished,
    thread: { title: "标题", question: "什么样的问题？", memberRefs: ["N0", "N1", "N3"] },
  }, fourParsed).reason, "thread_missing_anchor");
  assert.equal(validateFollowupModelOutput({
    decisions: fourEstablished,
    thread: { title: "标题", question: "什么样的问题？", memberRefs: ["N2", "N0", "N3"] },
  }, fourParsed).thread?.memberRefs.length, 3, "含锚点的合法成员集通过");
  // 成员关系不成立：thread 只能在全部成员逐条成立时输出
  const weakThread = validateFollowupModelOutput({
    decisions: [
      establishedDecision("N0", "我原先想让 AI 自动做决定。", [0, 15]),
      { otherRef: "N1", relation: "insufficient", reason: null, anchorEvidence: null, otherEvidence: null },
    ],
    thread: { title: "AI 做决定的边界", question: "哪些决定可以交给 AI 自动执行？", memberRefs: ["N2", "N0", "N1"] },
  }, outputParsed());
  assert.equal(weakThread.reason, "thread_member_relation_invalid");
  // title/question 长度约束
  assert.equal(validateFollowupModelOutput({
    decisions: THREAD_OUTPUT.decisions,
    thread: { title: "长", question: "什么样的问题？", memberRefs: ["N2", "N0", "N1"] },
  }, outputParsed()).reason, "thread_title_shape");
  assert.equal(validateFollowupModelOutput({
    decisions: THREAD_OUTPUT.decisions,
    thread: { title: "标题", question: "短的", memberRefs: ["N2", "N0", "N1"] },
  }, outputParsed()).reason, "thread_question_shape");
  // 正常 null thread
  const nullThread = validateFollowupModelOutput({ decisions: THREAD_OUTPUT.decisions, thread: null }, outputParsed());
  assert.equal(nullThread.thread, null);
});

// ─────────────────────────── 能力口（真实路由） ───────────────────────────

test("能力口：默认全关返回固定封套（categoryRulesVersion 0、followupVersion 0），no-store", async () => {
  const { app } = makeApp({ thoughtFollowup: { enabled: false } });
  const response = await app.request("/v1/thoughts/organization-capabilities");
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const body = await response.json();
  assert.deepEqual(Object.keys(body).sort(), ["categoryRulesVersion", "followupVersion", "policyVersion", "schemaVersion"], "封套字段固定，不回显配置");
  assert.equal(body.schemaVersion, 1);
  assert.equal(body.categoryRulesVersion, 0);
  assert.equal(body.followupVersion, 0);
  assert.equal(typeof body.policyVersion, "string");
});

test("能力口：scopeRules 开 → categoryRulesVersion 4；followup 开 + 白名单主体 → 1；非试点主体 → 0", async () => {
  const { app } = makeApp({
    thoughtScopeRules: { enabled: true },
  });
  const pilot = await (await app.request("/v1/thoughts/organization-capabilities")).json();
  assert.equal(pilot.categoryRulesVersion, 4);
  assert.equal(pilot.followupVersion, 1, "debug-device 在试点白名单内");

  const other = await (await app.request("/v1/thoughts/organization-capabilities", {
    headers: { "x-holo-device-id": "another-device" },
  })).json();
  assert.equal(other.followupVersion, 0, "非试点主体看不到能力（服务端解析主体，自报不算数）");

  const empty = organizationCapabilities(
    { thoughtScopeRules: { enabled: false }, thoughtFollowup: { enabled: true, pilotSubjects: [] } },
    { pilotSubject: PILOT_SUBJECT },
  );
  assert.equal(empty.followupVersion, 0, "白名单为空 = 无试点主体");
});

// ─────────────────────────── 核对端点（真实路由） ───────────────────────────

test("核对端点：功能默认关闭返回 503 THOUGHT_FOLLOWUP_DISABLED", async () => {
  const { app } = makeApp({ thoughtFollowup: { enabled: false, pilotSubjects: [PILOT_SUBJECT] } });
  const response = await postFollowup(app, followupBody());
  assert.equal(response.status, 503);
  const body = await response.json();
  assert.equal(body.error.code, "THOUGHT_FOLLOWUP_DISABLED");
  saveFixture("verify-followup-disabled.json", body);
});

test("核对端点：试点白名单外的可信主体拿到与关闭态同一稳定错误码", async () => {
  const { app } = makeApp(); // pilotSubjects 只有 debug-device
  const response = await postFollowup(app, followupBody(), { "x-holo-device-id": "not-in-pilot" });
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "THOUGHT_FOLLOWUP_DISABLED");
});

test("核对端点：供应商隐私闸未核实（非 mock）时 503 PRIVACY_ROUTE_UNVERIFIED，不发源文", async () => {
  let calls = 0;
  const { app } = makeApp({
    thoughtFollowup: { privacyVerified: false },
    providerOverrides: stubProvider(() => { calls += 1; return stubCompletion("{}"); }),
    routes: stubRoutes(),
  });
  const response = await postFollowup(app, followupBody());
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "PRIVACY_ROUTE_UNVERIFIED");
  assert.equal(calls, 0, "隐私闸关闭禁止继续源文调用");
});

test("核对端点：请求超 32KiB 按实际字节数拒绝（413 INPUT_TOO_LARGE），先于 JSON 解析", async () => {
  const { app, db } = makeApp({ providerOverrides: stubProvider(() => stubCompletion("{}")), routes: stubRoutes() });
  // 超限且非法 JSON：字节闸先行 → INPUT_TOO_LARGE 而非 INVALID_JSON
  const oversized = "x".repeat(FOLLOWUP_LIMITS.requestBodyMaxBytes + 100);
  const response = await postFollowup(app, oversized);
  assert.equal(response.status, 413);
  assert.equal((await response.json()).error.code, "INPUT_TOO_LARGE");
  // 合法 JSON 超限同样拒绝
  const bigBody = JSON.stringify(followupBody({
    notes: followupBody().notes.map((note) => ({ ...note, windows: [{ ref: "W0", text: "长".repeat(600) }] })),
  })) + " ".repeat(FOLLOWUP_LIMITS.requestBodyMaxBytes);
  const response2 = await postFollowup(app, bigBody);
  assert.equal(response2.status, 413);
  const logs = db.prepare("SELECT COUNT(*) AS n FROM ai_call_logs").get();
  assert.equal(logs.n, 0, "字节闸在供应商调用之前，无 AI 调用产生");
});

test("核对端点：成功含 thread → 200 封套回显 schemaVersion/operationId/policyVersion", async () => {
  const { app } = makeApp({
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify(THREAD_OUTPUT))),
    routes: stubRoutes(),
  });
  const response = await postFollowup(app, followupBody());
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("cache-control"), "no-store");
  const body = await response.json();
  assert.equal(body.schemaVersion, 1);
  assert.equal(body.operationId, "9f2bb45b-5dd4-457d-88cc-d619aad2eba7");
  assert.equal(body.policyVersion, "thought-followup-1");
  assert.equal(body.decisions.length, 2);
  assert.equal(body.decisions[0].relation, "revises");
  assert.equal(body.thread.title, "AI 做决定的边界");
  saveFixture("verify-followup-success-thread.json", body);
});

test("核对端点：全部无关 + thread null → 200 空结果（终态）", async () => {
  const { app } = makeApp({
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify(NONE_OUTPUT))),
    routes: stubRoutes(),
  });
  const response = await postFollowup(app, followupBody());
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.decisions[0].relation, "none");
  assert.equal(body.decisions[0].anchorEvidence, null);
  assert.equal(body.thread, null);
  saveFixture("verify-followup-success-empty.json", body);
});

test("核对端点：仅一条成立 → 相关区可用、脉络为空（thread null）", async () => {
  const singlePairOutput = {
    decisions: [
      THREAD_OUTPUT.decisions[0],
      { otherRef: "N1", relation: "insufficient", reason: null, anchorEvidence: null, otherEvidence: null },
    ],
    thread: null,
  };
  const { app } = makeApp({
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify(singlePairOutput))),
    routes: stubRoutes(),
  });
  const response = await postFollowup(app, followupBody());
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.decisions[0].relation, "revises");
  assert.equal(body.decisions[1].relation, "insufficient");
  assert.equal(body.thread, null);
  saveFixture("verify-followup-success-single-pair.json", body);
});

test("核对端点：模型输出协议错 → 整批 502 MODEL_OUTPUT_INVALID，不降级空结果、不二次调用", async () => {
  let calls = 0;
  const { app, db } = makeApp({
    providerOverrides: stubProvider(() => {
      calls += 1;
      return stubCompletion(JSON.stringify({
        decisions: [
          { otherRef: "N0", relation: "same_thread", reason: "枚举外关系", anchorEvidence: null, otherEvidence: null },
          { otherRef: "N1", relation: "none", reason: null, anchorEvidence: null, otherEvidence: null },
        ],
        thread: null,
      }));
    }),
    routes: stubRoutes(),
  });
  const response = await postFollowup(app, followupBody());
  assert.equal(response.status, 502);
  assert.equal(calls, 1, "不二次调用模型修补");
  const body = await response.json();
  assert.equal(body.error.code, "MODEL_OUTPUT_INVALID");
  const log = db.prepare("SELECT error_message FROM ai_call_logs ORDER BY rowid DESC LIMIT 1").get();
  assert.equal(JSON.parse(log.error_message).code, "MODEL_OUTPUT_INVALID/relation_enum");
  saveFixture("verify-followup-model-output-invalid.json", body);
});

test("核对端点：超限请求返回 413 错误封套供 fixture 导出（真实响应体）", async () => {
  const { app } = makeApp({ routes: stubRoutes() });
  const oversized = JSON.stringify(followupBody({
    notes: followupBody().notes.map((note) => ({ ...note, windows: [{ ref: "W0", text: "长".repeat(600) }] })),
  })) + " ".repeat(FOLLOWUP_LIMITS.requestBodyMaxBytes);
  const response = await postFollowup(app, oversized);
  assert.equal(response.status, 413);
  saveFixture("verify-followup-input-too-large.json", await response.json());
});

test("核对端点：设备限流命中 → 429 RATE_LIMITED（独立限流桶）", async () => {
  const { app } = makeApp({
    thoughtFollowup: { requestLimits: { perMinute: 1, perDay: 12 } },
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify(NONE_OUTPUT))),
    routes: stubRoutes(),
  });
  const first = await postFollowup(app, followupBody());
  assert.equal(first.status, 200);
  const second = await postFollowup(app, followupBody({ operationId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee" }));
  assert.equal(second.status, 429);
  const body = await second.json();
  assert.equal(body.error.code, "RATE_LIMITED");
  saveFixture("verify-followup-rate-limited.json", body);
});

test("核对端点：主体预算打满 → 429 BUDGET_EXCEEDED；同 operationId 在途 → 409 OPERATION_IN_PROGRESS", async () => {
  const blockedStore = (reason) => ({
    recoverStale() {},
    beginOperation: () => ({ allowed: false, reason, resetAt: "2026-11-17T00:00:00.000Z", dailyBudgetMicro: 0 }),
    settleOperation() {},
  });
  const budget = makeApp({
    thoughtOrganizeBudgetStore: blockedStore("budget_exceeded"),
    routes: stubRoutes(),
  });
  const budgetResponse = await postFollowup(budget.app, followupBody());
  assert.equal(budgetResponse.status, 429);
  assert.equal((await budgetResponse.json()).error.code, "BUDGET_EXCEEDED");

  const inProgress = makeApp({
    thoughtOrganizeBudgetStore: blockedStore("in_progress"),
    routes: stubRoutes(),
  });
  const inProgressResponse = await postFollowup(inProgress.app, followupBody());
  assert.equal(inProgressResponse.status, 409);
  assert.equal((await inProgressResponse.json()).error.code, "OPERATION_IN_PROGRESS");
});

test("核对端点：送审正文未过审核 → 400 MODERATION_BLOCKED（200 恒为终态，不以 deferred 污染缓存）", async () => {
  const { app } = makeApp({
    contentModeration: { isEnabled: () => true, moderate: async () => ({ passed: false, labels: ["abuse"], riskLevel: "high" }) },
    providerOverrides: stubProvider(() => stubCompletion("{}")),
    routes: stubRoutes(),
  });
  const response = await postFollowup(app, followupBody());
  assert.equal(response.status, 400);
  assert.equal((await response.json()).error.code, "MODERATION_BLOCKED");
});

test("核对端点：metadata-only 日志——开启内容抓取仍不落正文/证据/模型输出", async () => {
  const { app, db } = makeApp({
    contentCaptureEnabled: true,
    aiCallLogs: { enabled: true },
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify(THREAD_OUTPUT))),
    routes: stubRoutes(),
  });
  const response = await postFollowup(app, followupBody());
  assert.equal(response.status, 200);
  const log = db.prepare(
    "SELECT purpose, prompt_type, prompt_version, request_summary, response_summary, content_capture_enabled FROM ai_call_logs ORDER BY rowid DESC LIMIT 1",
  ).get();
  assert.equal(log.purpose, "thought_followup_v1");
  assert.equal(log.prompt_type, "thought_followup_v1");
  const registryVersion = db.prepare(
    "SELECT version FROM prompt_versions WHERE prompt_type = 'thought_followup_v1' ORDER BY version DESC LIMIT 1",
  ).get()?.version;
  assert.equal(log.prompt_version, registryVersion, "Prompt 版本从实际 registry 读取");
  const serialized = JSON.stringify([log.request_summary, log.response_summary]);
  assert.ok(!serialized.includes("我修改了自动决定的原则"), "锚点正文不落日志");
  assert.ok(!serialized.includes("我原先想让"), "候选正文不落日志");
  assert.ok(!serialized.includes("AI 做决定的边界"), "模型输出（thread 标题）不落日志");
});

// ─────────────────────────── Prompt 登记 ───────────────────────────

test("thought_followup_v1 已登记：purpose 映射正确，模板可读", () => {
  const prompt = getPrompt("thought_followup_v1");
  assert.ok(prompt?.content, "模板必须在 defaultPrompts 注册并可读");
  assert.ok(prompt.version >= 1);
  assert.equal(promptTypeForPurpose("thought_followup_v1"), "thought_followup_v1");
});

test("followup 模板覆盖六关系、方向/证据纪律、thread 约束与注入禁令", () => {
  const content = getPrompt("thought_followup_v1").content;
  for (const relation of ["continues", "adds_example", "contrasts", "revises", "none", "insufficient"]) {
    assert.ok(content.includes(relation), `关系枚举 ${relation} 缺失`);
  }
  assert.ok(content.includes("contrasts，不得声称先后变化"), "时间相同只允许对照的纪律缺失");
  assert.ok(content.includes("不能据此推定用户本人改了主意"), "contrasts 误读防线缺失");
  assert.ok(content.includes("不得改写、翻译、拼接两个窗口或两条笔记的片段"), "跨窗拼接禁令缺失");
  assert.ok(content.includes("一律为 null"), "负向决定 null 纪律缺失");
  assert.ok(content.includes("必须包含 anchorRef"), "thread 锚点约束缺失");
  assert.ok(content.includes("都不得执行"), "指令式注入禁令缺失");
  assert.ok(content.includes("不作为共同证据"), "scopeTitle 只是背景的声明缺失");
});
