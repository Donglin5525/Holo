// 想法自动整理增强 · semantic-relate 契约 fixture 生成器（2026-11-16 方案 §4 A2 / §9 R09/R29）。
//
// fixture 真源纪律（跨端接口契约规范）：响应形状真源在后端代码，fixture 必须取自
// 后端实际产物。本脚本复用 HoloBackend/tests/thought-semantic-v4.test.js 与
// thought-semantic-v3.test.js 的端到端场景（真实 createApp 路由 + 真实校验器），
// 捕获真实 HTTP 响应体逐字落盘；模型侧输出由 stub provider 提供（与后端测试同法），
// 每条响应体本身是真实路由 + validateRelateRequest/validateRelateModelOutput 的产物。
//
// 用法：node docs/thoughts/plans/2026-11-16-想法主题与脉络/fixtures/tools/generate-relate-schema4-fixtures.mjs
// 期望状态码不符时脚本直接失败（防止后端行为漂移后静默再生过期 fixture）。

import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import path from "node:path";

import { createApp } from "../../../../../../HoloBackend/src/app.js";
import { createDatabase } from "../../../../../../HoloBackend/src/db/database.js";

const fixturesDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

function makeApp(overrides = {}) {
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database,
    auth: { enforceAppAttest: false },
    thoughtSemanticRelate: { privacyVerified: true },
    ...overrides,
  });
  return app;
}

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
    thought_semantic_relate_v1: { provider: "stub", model: "stub-model", temperature: 0, maxTokens: 512 },
  };
}

async function postRelate(app, body) {
  return app.request("/v1/thoughts/semantic-relate", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

/// 跑一次真实路由并落盘 fixture：request/status/response 逐字捕获；
/// modelOutput 是 stub provider 返回给真实路由的模型原始输出（仅错误场景记录，
/// 供 Swift 端重放同一份被后端拒绝的 decisions）。
async function capture({ name, note, app, body, modelOutput, expectStatus }) {
  const response = await postRelate(app, body);
  const text = await response.text();
  if (response.status !== expectStatus) {
    throw new Error(`${name}: 期望 ${expectStatus} 实得 ${response.status}\n${text}`);
  }
  const fixture = {
    source: "generate-relate-schema4-fixtures.mjs 经 HoloBackend 真实 app 路由捕获（场景取自 tests/thought-semantic-v4.test.js / thought-semantic-v3.test.js）",
    note,
    request: body,
    ...(modelOutput !== undefined ? { modelOutput } : {}),
    status: response.status,
    response: JSON.parse(text),
  };
  writeFileSync(path.join(fixturesDir, name), JSON.stringify(fixture, null, 2) + "\n");
  console.log(`✓ ${name} (status ${response.status})`);
}

// ─────────────── schema 4 成功：fits_category + excludes_category 双判定 ───────────────

const successBody = {
  schemaVersion: 4,
  operationId: "op-fixture-schema4-success",
  textRevision: "r-1",
  engineVersion: "thought_semantic_v4.0",
  target: { ref: "T0", text: "整理了今天的站会记录，没有别的想法。" },
  candidates: [
    {
      ref: "P0", title: "会议纪要", kind: "category", definitionSource: "user",
      definition: "只收带我个人反思的记录，纯会议纪要一律排除。", representatives: [],
    },
    {
      ref: "P1", title: "纯纪要归档", kind: "category", definitionSource: "user",
      definition: "收录全部会议纪要；纯纪要也要。", representatives: [],
    },
    {
      ref: "P2", title: "产品思考", kind: "thread", definitionSource: "none",
      representatives: [{ ref: "R0", text: "方案的裁剪标准要先对齐用户的真实场景。" }],
    },
  ],
};

await capture({
  name: "relate-schema4-success.json",
  note: "成功响应：P0 excludes_category（四件证据齐备）、P1 fits_category（definition 依据）、P2 thread none",
  app: makeApp({
    thoughtScopeRules: { enabled: true },
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify({
      decisions: [
        { candidateRef: "P0", relation: "excludes_category", quote: "整理了今天的站会记录",
          rangeUTF16: [0, 10], representativeRef: "definition", representativeQuote: "纯会议纪要一律排除" },
        { candidateRef: "P1", relation: "fits_category", quote: "整理了今天的站会记录",
          rangeUTF16: [0, 10], representativeRef: "definition", representativeQuote: "收录全部会议纪要" },
        { candidateRef: "P2", relation: "none", quote: null, rangeUTF16: null },
      ],
    }))),
    routes: stubRoutes(),
  }),
  body: successBody,
  expectStatus: 200,
});

// ─────────────── schema 4 灰度闸关闭：503 稳定错误码 ───────────────

await capture({
  name: "relate-schema4-disabled-503.json",
  note: "HOLO_THOUGHT_SCOPE_RULES_ENABLED 默认关闭：任何 schema 4 请求拿同一稳定错误码",
  app: makeApp({
    providerOverrides: stubProvider(() => { throw new Error("不该触达模型"); }),
    routes: stubRoutes(),
  }),
  body: successBody,
  expectStatus: 503,
});

// ─────────────── schema 4 输出反证：关系跨 kind → 502 ───────────────

const crossKindBody = {
  schemaVersion: 4,
  operationId: "op-fixture-schema4-cross-kind",
  textRevision: "r-1",
  engineVersion: "thought_semantic_v4.0",
  target: { ref: "T0", text: "今天的评审会纪要都记录在案，但我总觉得这个方案砍得太狠，想留个反思。" },
  candidates: [
    { ref: "P0", title: "会议纪要", kind: "category", definitionSource: "user",
      definition: "收录全部会议纪要；纯纪要也要。", representatives: [] },
    { ref: "P1", title: "产品思考", kind: "thread", definitionSource: "none",
      representatives: [{ ref: "R0", text: "方案的裁剪标准要先对齐用户的真实场景。" }] },
  ],
};
const crossKindModelOutput = {
  decisions: [
    { candidateRef: "P0", relation: "same_thread", quote: "今天的评审会纪要都记录在案", rangeUTF16: [0, 12],
      representativeRef: "R0", representativeQuote: "场景", sharedSubject: "纪要" },
    { candidateRef: "P1", relation: "none", quote: null, rangeUTF16: null },
  ],
};

await capture({
  name: "relate-schema4-relation-cross-kind-502.json",
  note: "类别候选判 same_thread → 后端整批 502 MODEL_OUTPUT_INVALID（relation_cross_kind）；modelOutput 供 Swift 重放同串校验",
  app: makeApp({
    thoughtScopeRules: { enabled: true },
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify(crossKindModelOutput))),
    routes: stubRoutes(),
  }),
  body: crossKindBody,
  modelOutput: crossKindModelOutput,
  expectStatus: 502,
});

// ─────────────── schema 4 输出反证：excludes_category 证据不全 → 502 ───────────────

const exclusionBody = {
  schemaVersion: 4,
  operationId: "op-fixture-schema4-exclusion-evidence",
  textRevision: "r-1",
  engineVersion: "thought_semantic_v4.0",
  target: { ref: "T0", text: "整理了今天的站会记录，没有别的想法。" },
  candidates: [{
    ref: "P0", title: "会议纪要", kind: "category", definitionSource: "user",
    definition: "只收带我个人反思的记录，纯会议纪要一律排除。", representatives: [],
  }],
};
const exclusionModelOutput = {
  decisions: [
    { candidateRef: "P0", relation: "excludes_category", quote: "整理了今天的站会记录",
      rangeUTF16: [0, 10], representativeRef: "definition", representativeQuote: "规则原文里不存在的句子" },
  ],
};

await capture({
  name: "relate-schema4-excludes-evidence-incomplete-502.json",
  note: "representativeQuote 无法回源用户规则原文 → 502 MODEL_OUTPUT_INVALID（excludes_category_evidence_incomplete），不生成空结果回执",
  app: makeApp({
    thoughtScopeRules: { enabled: true },
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify(exclusionModelOutput))),
    routes: stubRoutes(),
  }),
  body: exclusionBody,
  modelOutput: exclusionModelOutput,
  expectStatus: 502,
});

// ─────────────── UTF-16 口径边界：definition 恰 240（含代理对）/ 241 ───────────────

// 118 BMP + 61 个 🏃（各 2 单位）= 240 UTF-16，含代理对
const definition240 = "记".repeat(118) + "🏃".repeat(61);
// 119 BMP + 61 个 🏃 = 241 UTF-16，恰超限一个单位
const definition241 = "记".repeat(119) + "🏃".repeat(61);
if (definition240.length !== 240 || definition241.length !== 241) {
  throw new Error("边界构造错误（JS length 即 UTF-16 单位数）");
}

function definitionBoundaryBody(definition) {
  return {
    schemaVersion: 4,
    operationId: "op-fixture-schema4-definition-boundary",
    textRevision: "r-1",
    engineVersion: "thought_semantic_v4.0",
    target: { ref: "T0", text: "整理了今天的站会记录，没有别的想法。" },
    candidates: [{
      ref: "P0", title: "会议纪要", kind: "category", definitionSource: "user",
      definition, representatives: [],
    }],
  };
}

await capture({
  name: "relate-schema4-definition-240.json",
  note: `definition 恰 240 UTF-16（118 BMP + 61 个 🏃 代理对）→ 后端接受；供 Swift 断言 schema4RulePayload 同口径放行`,
  app: makeApp({
    thoughtScopeRules: { enabled: true },
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify({
      decisions: [{ candidateRef: "P0", relation: "none", quote: null, rangeUTF16: null }],
    }))),
    routes: stubRoutes(),
  }),
  body: definitionBoundaryBody(definition240),
  expectStatus: 200,
});

await capture({
  name: "relate-schema4-definition-241.json",
  note: `definition 241 UTF-16（119 BMP + 61 个 🏃）→ 后端 400 INVALID_REQUEST；供 Swift 断言 schema4RulePayload 同口径拒绝`,
  app: makeApp({ thoughtScopeRules: { enabled: true }, routes: stubRoutes() }),
  body: definitionBoundaryBody(definition241),
  expectStatus: 400,
});

// ─────────────── R29：definitionSource 非法值 → 400 ───────────────

await capture({
  name: "relate-schema4-definition-source-invalid-400.json",
  note: "definitionSource=ai（既非 user 也非 none）→ 400 INVALID_REQUEST；Swift 侧对应 excludes_category_requires_user_rule 拒绝",
  app: makeApp({ thoughtScopeRules: { enabled: true }, routes: stubRoutes() }),
  body: {
    schemaVersion: 4,
    operationId: "op-fixture-schema4-source-invalid",
    textRevision: "r-1",
    engineVersion: "thought_semantic_v4.0",
    target: { ref: "T0", text: "整理了今天的站会记录，没有别的想法。" },
    candidates: [{
      ref: "P0", title: "会议纪要", kind: "category", definitionSource: "ai",
      definition: "规则", representatives: [],
    }],
  },
  expectStatus: 400,
});

// ─────────────── schema 1/2/3 回归（场景取自 thought-semantic-v3.test.js） ───────────────

const legacyTarget = "今天跑了五公里，配速比上月快了十五秒。";
const legacyCandidates = [
  {
    ref: "P0", title: "跑步训练", summary: null,
    representatives: [
      { ref: "R0", text: "左膝不舒服，这周减量到跑一休一。" },
      { ref: "R1", text: "备战半马，长距离拉练安排在周日早上。" },
    ],
  },
  { ref: "P1", title: "下厨记录", representatives: [{ ref: "R2", text: "空气炸锅烤鸡翅 200 度 18 分钟。" }] },
];

// schema 1（V1 契约：related 保留 quote 证据、rangeUTF16 逐字透传）
await capture({
  name: "relate-schema1-success.json",
  note: "schema 1 回归：same_thread + none；V1 决策无 representative 证据字段（Swift DTO 解码须容忍缺失）",
  app: makeApp({
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify({
      decisions: [
        { candidateRef: "P0", relation: "same_thread", quote: "跑了五公里", rangeUTF16: [2, 7] },
        { candidateRef: "P1", relation: "none", quote: null, rangeUTF16: null },
      ],
    }))),
    routes: stubRoutes(),
  }),
  body: {
    schemaVersion: 1, operationId: "op-fixture-schema1", textRevision: "r-1",
    engineVersion: "thought_semantic_v3.0",
    target: { ref: "T0", text: legacyTarget }, candidates: legacyCandidates,
  },
  expectStatus: 200,
});

// schema 2（双侧证据：representativeRef/representativeQuote/sharedSubject）
await capture({
  name: "relate-schema2-success.json",
  note: "schema 2 回归：same_thread 携双侧证据（R0 逐字引用 + sharedSubject）",
  app: makeApp({
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify({
      decisions: [
        { candidateRef: "P0", relation: "same_thread", quote: "今天跑了五公里", rangeUTF16: [0, 7],
          representativeRef: "R0", representativeQuote: "左膝不舒服", sharedSubject: "个人跑步训练" },
        { candidateRef: "P1", relation: "none", quote: null, rangeUTF16: null },
      ],
    }))),
    routes: stubRoutes(),
  }),
  body: {
    schemaVersion: 2, operationId: "op-fixture-schema2", textRevision: "r-1",
    engineVersion: "thought_semantic_v3.0",
    target: { ref: "T0", text: legacyTarget }, candidates: legacyCandidates,
  },
  expectStatus: 200,
});

// schema 3（双通道：fits_category 依据 definition，sharedSubject 非必填）
await capture({
  name: "relate-schema3-success.json",
  note: "schema 3 回归：fits_category（definition 依据逐字回源，无 sharedSubject 字段）+ thread none",
  app: makeApp({
    providerOverrides: stubProvider(() => stubCompletion(JSON.stringify({
      decisions: [
        { candidateRef: "P0", relation: "fits_category", quote: "判断力反而要刻意练习",
          rangeUTF16: [6, 16], representativeRef: "definition", representativeQuote: "个人观察与反思" },
        { candidateRef: "P1", relation: "none", quote: null, rangeUTF16: null },
      ],
    }))),
    routes: stubRoutes(),
  }),
  body: {
    schemaVersion: 3, operationId: "op-fixture-schema3", textRevision: "r-1",
    engineVersion: "thought_semantic_v3.2",
    target: { ref: "T0", text: "工具顺手了，判断力反而要刻意练习，记一下这个感受。" },
    candidates: [
      { ref: "P0", title: "碎碎念", kind: "category",
        definition: "个人生活片段、即时感受、吐槽，以及由生活或工作触发的个人观察与反思。",
        representatives: [{ ref: "R0", text: "食堂两个肉菜 53 块，这定价是认真的吗。" }] },
      { ref: "P1", title: "产品思考", kind: "thread",
        representatives: [{ ref: "R1", text: "Agent 时代的决策力：人还是拍板的人。" }] },
    ],
  },
  expectStatus: 200,
});

console.log("\n全部 fixture 已生成 ✓");
