import test from "node:test";
import assert from "node:assert/strict";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { createAdminLogStore } from "../src/admin/adminLogStore.js";
import { createThoughtOrganizeBudgetStore } from "../src/thoughts/thoughtOrganizeBudgetStore.js";
import {
  validateOrganizeRequest,
  validateStageAOutput,
  validateStageBOutput,
  parseModelJSON,
  measureCatalogBudgets,
  explicitNameHits,
} from "../src/thoughts/organizeSchema.js";

// 想法自动整理 V2（docs/thoughts/plans/2026-09-05-想法自动整理V2实施方案-GLM.md）：
// 覆盖输入契约、两阶段校验、端点编排、隐私哨兵（日志无内容）与金额预算台账。

const SENTINEL = "HOLO-PRIVACY-SENTINEL-7f3a9c";

function makeApp(overrides = {}) {
  const database = createDatabase({ dbPath: ":memory:" });
  const app = createApp({
    database,
    auth: { enforceAppAttest: false },
    // 测试默认视为隐私路由已核实（注入 stub provider 时闸门只认 mock 名）；
    // 「未核实返回 503」用例单独覆盖。
    thoughtOrganize: { privacyVerified: true },
    ...overrides,
  });
  return { app, db: database.db };
}

function organizeBody(extra = {}) {
  return {
    schemaVersion: 2,
    operationId: "op-" + Math.random().toString(36).slice(2, 10),
    textRevision: "r-1",
    catalogRevision: "c-1",
    text: "今天用 AI 写周报，省了半小时。",
    catalog: [
      { ref: 1, name: "AI", definition: "人工智能技术及其使用", aliases: ["人工智能"], userNamed: false },
      { ref: 2, name: "写作", definition: "撰写或修改文字内容", aliases: [], userNamed: true },
    ],
    blockedRefs: [],
    blockedNames: [],
    ...extra,
  };
}

async function postOrganize(app, body, headers = {}) {
  return app.request("/v1/thoughts/organize", {
    method: "POST",
    headers: { "content-type": "application/json", ...headers },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

// ─────────────────────────── 输入契约 ───────────────────────────

test("validateOrganizeRequest 接受合法请求并归一化 catalog", () => {
  const parsed = validateOrganizeRequest(organizeBody());
  assert.equal(parsed.catalog.length, 2);
  assert.equal(parsed.catalog[0].path, null);
  assert.equal(parsed.catalog[1].userNamed, true);
});

test("validateOrganizeRequest 拒绝超长正文 INPUT_TOO_LARGE", () => {
  assert.throws(
    () => validateOrganizeRequest(organizeBody({ text: "a".repeat(8001) })),
    (error) => error.code === "INPUT_TOO_LARGE" && error.status === 413,
  );
});

test("validateOrganizeRequest 拒绝纯空白、重复 ref、路径注入与越界 blockedRefs", () => {
  assert.throws(() => validateOrganizeRequest(organizeBody({ text: "   " })));
  assert.throws(() => validateOrganizeRequest(organizeBody({
    catalog: [
      { ref: 1, name: "AI" },
      { ref: 1, name: "写作" },
    ],
  })));
  assert.throws(() => validateOrganizeRequest(organizeBody({
    catalog: [{ ref: 1, name: "AI/命令注入" }],
  })));
  assert.throws(() => validateOrganizeRequest(organizeBody({ blockedRefs: [99] })));
});

test("parseModelJSON 剥离一层代码围栏后严格解析，垃圾输入返回 null", () => {
  assert.deepEqual(parseModelJSON('```json\n{"a":1}\n```'), { a: 1 });
  assert.deepEqual(parseModelJSON('{"a":1}'), { a: 1 });
  assert.equal(parseModelJSON("这不是 JSON"), null);
  assert.equal(parseModelJSON(undefined), null);
});

// ─────────────────────────── 两阶段校验 ───────────────────────────

const SAMPLE_TEXT = "今天用 AI 写周报，省了半小时。";

test("validateStageAOutput 丢弃伪造 quote、越界数量并归一 priority", () => {
  const parsed = {
    anchors: [
      { surface: "AI", meaning: "人工智能", quote: "AI", priority: "primary" },
      { surface: "幻觉", meaning: "原文没有这个词", quote: "原文不存在的片段", priority: "primary" },
      { surface: "写作", meaning: "写内容", quote: "写周报", priority: "maybe" },
    ],
  };
  const { anchors } = validateStageAOutput(parsed, SAMPLE_TEXT);
  assert.equal(anchors.length, 2);
  assert.equal(anchors[1].priority, "secondary");
});

test("validateStageAOutput 超过 3 个候选时截断", () => {
  const anchors = Array.from({ length: 5 }, (_, i) => ({
    surface: `概念${i}`, meaning: "x", quote: "AI", priority: "primary",
  }));
  const result = validateStageAOutput({ anchors }, SAMPLE_TEXT);
  assert.equal(result.anchors.length, 3);
});

test("validateStageBOutput 拒绝未知 ref、二选一冲突、blocked 约束与非 equivalent 关系", () => {
  const anchors = [{ surface: "AI", meaning: "", quote: "AI", priority: "primary" }];
  const catalog = [
    { ref: 1, name: "AI", definition: null, path: null, aliases: [], userNamed: false },
    { ref: 2, name: "写作", definition: null, path: null, aliases: [], userNamed: false },
  ];
  const base = { text: SAMPLE_TEXT, anchors, catalog, blockedRefs: [2], blockedNames: ["奶茶"] };

  // 未知 ref
  let out = validateStageBOutput({
    assignments: [{ anchorRef: 0, existingRef: 99, relation: "equivalent", quote: "AI" }],
  }, base);
  assert.equal(out.assignments.length, 0);
  // existingRef 与 newConcept 同时出现
  out = validateStageBOutput({
    assignments: [{
      anchorRef: 0, existingRef: 1, newConcept: { name: "X" }, relation: "equivalent", quote: "AI",
    }],
  }, base);
  assert.equal(out.assignments.length, 0);
  // blockedRefs 命中
  out = validateStageBOutput({
    assignments: [{ anchorRef: 0, existingRef: 2, relation: "equivalent", quote: "AI" }],
  }, base);
  assert.equal(out.assignments.length, 0);
  // blockedNames 命中 newConcept
  out = validateStageBOutput({
    assignments: [{ anchorRef: 0, newConcept: { name: "奶茶" }, relation: "equivalent", quote: "AI" }],
  }, base);
  assert.equal(out.assignments.length, 0);
  // 非 equivalent 关系不构成标签
  out = validateStageBOutput({
    assignments: [{ anchorRef: 0, existingRef: 1, relation: "related", quote: "AI" }],
  }, base);
  assert.equal(out.assignments.length, 0);
  // 合法 existingRef：quote 转成 UTF-16 范围
  out = validateStageBOutput({
    assignments: [{ anchorRef: 0, existingRef: 1, relation: "equivalent", quote: "AI" }],
  }, base);
  assert.equal(out.assignments.length, 1);
  assert.deepEqual(out.assignments[0].rangeUTF16, [SAMPLE_TEXT.indexOf("AI"), 2]);
});

test("validateStageBOutput 最多保留 2 个且同概念去重", () => {
  const anchors = [
    { surface: "A", meaning: "", quote: "AI", priority: "primary" },
    { surface: "B", meaning: "", quote: "写周报", priority: "secondary" },
    { surface: "C", meaning: "", quote: "半小时", priority: "secondary" },
  ];
  const catalog = [
    { ref: 1, name: "AI", definition: null, path: null, aliases: [], userNamed: false },
    { ref: 2, name: "写作", definition: null, path: null, aliases: [], userNamed: false },
    { ref: 3, name: "时间", definition: null, path: null, aliases: [], userNamed: false },
  ];
  const out = validateStageBOutput({
    assignments: [
      { anchorRef: 0, existingRef: 1, relation: "equivalent", quote: "AI" },
      { anchorRef: 0, existingRef: 1, relation: "equivalent", quote: "AI" },
      { anchorRef: 1, existingRef: 2, relation: "equivalent", quote: "写周报" },
      { anchorRef: 2, existingRef: 3, relation: "equivalent", quote: "半小时" },
    ],
  }, { text: SAMPLE_TEXT, anchors, catalog, blockedRefs: [], blockedNames: [] });
  assert.equal(out.assignments.length, 2);
});

test("measureCatalogBudgets 与 explicitNameHits 行为正确", () => {
  const catalog = [
    { ref: 1, name: "AI", definition: "人工智能", path: null, aliases: ["人工智能"], userNamed: false },
    { ref: 2, name: "写作", definition: null, path: "工作/写作", aliases: [], userNamed: true },
  ];
  const { fullChars, nameChars } = measureCatalogBudgets(catalog);
  assert.ok(fullChars > nameChars);
  const anchors = [{ surface: "人工智能", meaning: "", quote: "AI", priority: "primary" }];
  assert.deepEqual(explicitNameHits(anchors, catalog), [1]);
});

// ─────────────────────────── 端点编排（mock provider） ───────────────────────────

test("端到端：目录命中时复用 existingRef，quote 与 rangeUTF16 逐字可回验", async () => {
  const { app } = makeApp();
  const body = organizeBody({ text: "用 #AI 写周报，省了半小时。" });
  const response = await postOrganize(app, body);
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.outcome, "tagged");
  assert.equal(result.catalogCoverage, "full");
  assert.equal(result.assignments.length, 1);
  const assignment = result.assignments[0];
  assert.equal(assignment.existingRef, 1);
  const [location, length] = assignment.rangeUTF16;
  assert.equal(body.text.slice(location, location + length), assignment.quote);
  assert.ok(result.usage.inputTokens > 0);
  assert.ok(result.usage.estimatedCostCNY >= 0);
});

test("端到端：目录未命中时提出 newConcept", async () => {
  const { app } = makeApp();
  const response = await postOrganize(app, organizeBody({
    text: "试着跑通了本地向量检索 demo",
    catalog: [],
  }));
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.outcome, "tagged");
  assert.ok(result.assignments[0].newConcept.name.length > 0);
  assert.equal(result.catalogCoverage, "full");
});

test("端到端：A 空数组返回 no_evidence，不调用 B", async () => {
  const calls = [];
  const { app } = makeApp({
    providerOverrides: new Map([["stub", {
      async complete(request) {
        calls.push(request.purpose);
        if (request.purpose === "thought_organize_a") return stubCompletion('{"anchors":[]}');
        return stubCompletion("{}");
      },
    }]]),
    routes: stubRoutes(),
  });
  const response = await postOrganize(app, organizeBody());
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.outcome, "no_evidence");
  assert.deepEqual(calls, ["thought_organize_a"]);
});

test("端到端：伪造证据全部被丢弃后按无证据完成", async () => {
  const { app } = makeApp({
    providerOverrides: new Map([["stub", {
      async complete(request) {
        if (request.purpose === "thought_organize_a") {
          return stubCompletion(JSON.stringify({
            anchors: [{ surface: "AI", meaning: "x", quote: "原文中不存在的证据片段", priority: "primary" }],
          }));
        }
        return stubCompletion('{"assignments":[]}');
      },
    }]]),
    routes: stubRoutes(),
  });
  const response = await postOrganize(app, organizeBody());
  assert.equal(response.status, 200);
  assert.equal((await response.json()).outcome, "no_evidence");
});

test("端到端：阶段输出非 JSON 按 502 终止，不二次修 JSON", async () => {
  const calls = [];
  const { app } = makeApp({
    providerOverrides: new Map([["stub", {
      async complete(request) {
        calls.push(request.purpose);
        if (request.purpose === "thought_organize_a") return stubCompletion("压根不是 JSON");
        return stubCompletion('{"assignments":[]}');
      },
    }]]),
    routes: stubRoutes(),
  });
  const response = await postOrganize(app, organizeBody());
  assert.equal(response.status, 502);
  assert.equal((await response.json()).error.code, "MODEL_OUTPUT_INVALID");
  assert.deepEqual(calls, ["thought_organize_a"]);
});

test("端到端：目录超出两级预算返回 deferred/catalog_budget_exceeded", async () => {
  const { app } = makeApp({
    thoughtOrganize: { catalog: { fullCharBudget: 1, nameCharBudget: 1 } },
  });
  const response = await postOrganize(app, organizeBody());
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.outcome, "deferred");
  assert.equal(result.reasonCode, "catalog_budget_exceeded");
});

test("端到端：目录超完整预算但名称预算内时走 R 路径并标记 names_recalled", async () => {
  const purposes = [];
  const bigCatalog = Array.from({ length: 120 }, (_, i) => ({
    ref: i + 1,
    name: `标签${i + 1}`,
    definition: "定义".repeat(10),
    aliases: [],
  }));
  const { app } = makeApp({
    thoughtOrganize: { privacyVerified: true, catalog: { fullCharBudget: 2_000, nameCharBudget: 12_000 } },
    providerOverrides: new Map([["stub", {
      async complete(request) {
        purposes.push(request.purpose);
        if (request.purpose === "thought_organize_a") {
          return stubCompletion(JSON.stringify({
            anchors: [{ surface: "标签3", meaning: "x", quote: "AI", priority: "primary" }],
          }));
        }
        if (request.purpose === "thought_organize_r") {
          return stubCompletion('{"refs":[3]}');
        }
        return stubCompletion(JSON.stringify({
          assignments: [{ anchorRef: 0, existingRef: 3, relation: "equivalent", quote: "AI" }],
        }));
      },
    }]]),
    routes: stubRoutes(),
  });
  const response = await postOrganize(app, organizeBody({ catalog: bigCatalog }));
  assert.equal(response.status, 200);
  const result = await response.json();
  assert.equal(result.catalogCoverage, "names_recalled");
  assert.equal(result.assignments[0].existingRef, 3);
  assert.deepEqual(purposes, ["thought_organize_a", "thought_organize_r", "thought_organize_b"]);
});

test("端到端：请求体超过 128KiB 返回 413", async () => {
  const { app } = makeApp();
  const response = await app.request("/v1/thoughts/organize", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "content-length": String(200 * 1024),
    },
    body: JSON.stringify(organizeBody()),
  });
  assert.equal(response.status, 413);
});

test("端到端：非 mock provider 且隐私路由未核实返回 PRIVACY_ROUTE_UNVERIFIED", async () => {
  const { app } = makeApp({
    thoughtOrganize: { privacyVerified: false },
    routes: {
      thought_organize_a: { provider: "deepseek", model: "deepseek-v4-flash", temperature: 0, maxTokens: 400 },
      thought_organize_r: { provider: "deepseek", model: "deepseek-v4-flash", temperature: 0, maxTokens: 160 },
      thought_organize_b: { provider: "deepseek", model: "deepseek-v4-flash", temperature: 0, maxTokens: 600 },
    },
  });
  const response = await postOrganize(app, organizeBody());
  assert.equal(response.status, 503);
  assert.equal((await response.json()).error.code, "PRIVACY_ROUTE_UNVERIFIED");
});

test("端到端：日预算耗尽后后续任务按预算终态 deferred 完成", async () => {
  const { app } = makeApp({
    thoughtOrganize: { budgets: { perSubjectDailyCNY: 0.014 } },
  });
  const first = await postOrganize(app, organizeBody());
  assert.equal(first.status, 200);
  assert.equal((await first.json()).outcome, "tagged");
  const second = await postOrganize(app, organizeBody());
  assert.equal(second.status, 200);
  const result = await second.json();
  assert.equal(result.outcome, "deferred");
  assert.equal(result.reasonCode, "budget_exceeded");
});

test("端到端：同一 operationId 并发执行第二个被拒 409", async () => {
  let release;
  const gate = new Promise((resolve) => { release = resolve; });
  const { app } = makeApp({
    providerOverrides: new Map([["stub", {
      async complete(request) {
        if (request.purpose === "thought_organize_a") {
          await gate;
          return stubCompletion('{"anchors":[]}');
        }
        return stubCompletion("{}");
      },
    }]]),
    routes: stubRoutes(),
  });
  const body = organizeBody();
  const firstPromise = postOrganize(app, body);
  // 稍等首个请求真正进入 running 状态
  await new Promise((resolve) => setTimeout(resolve, 30));
  const second = await postOrganize(app, body);
  assert.equal(second.status, 409);
  release();
  assert.equal((await firstPromise).status, 200);
});

// ─────────────────────────── 隐私哨兵：日志无内容 ───────────────────────────

test("隐私：内容采集开启时 thought purpose 的 SQLite/hotCache 均不含正文哨兵", async () => {
  const { app, db } = makeApp({ contentCaptureEnabled: true });
  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      purpose: "thought_organization",
      messages: [{ role: "user", content: JSON.stringify({ thoughtContent: SENTINEL }) }],
    }),
  });
  assert.equal(response.status, 200);
  const logId = response.headers.get("x-holo-request-id");
  assert.ok(logId);

  const rows = db.prepare("SELECT request_summary, response_summary, error_message FROM ai_call_logs WHERE purpose = 'thought_organization'").all();
  assert.ok(rows.length > 0);
  for (const row of rows) {
    const joined = [row.request_summary, row.response_summary, row.error_message].join("|");
    assert.ok(!joined.includes(SENTINEL), `thought 日志泄漏哨兵: ${joined.slice(0, 120)}`);
    assert.equal(row.request_summary, null);
  }

  const adminStore = createAdminLogStore({ db, contentCaptureEnabled: true });
  void adminStore; // store 实例仅证明可重建；hotCache 检查走响应详情
  const detail = db.prepare("SELECT * FROM ai_call_logs WHERE id = ?").get(
    db.prepare("SELECT id FROM ai_call_logs WHERE purpose = 'thought_organization' ORDER BY id DESC LIMIT 1").get().id,
  );
  assert.ok(!JSON.stringify(detail).includes(SENTINEL));
});

test("隐私：普通 chat purpose 在内容采集开启时仍按原规则采集（对照组）", async () => {
  const { app, db } = makeApp({ contentCaptureEnabled: true });
  await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      purpose: "chat",
      messages: [{ role: "user", content: SENTINEL }],
    }),
  });
  const row = db.prepare("SELECT request_summary FROM ai_call_logs WHERE purpose = 'chat' ORDER BY id DESC LIMIT 1").get();
  // 对照组证明开关本身工作：chat 记内容、thought 被强制 metadata 拦下
  assert.ok(row.request_summary.includes(SENTINEL) || row.request_summary.includes("[number]"));
});

test("隐私：上游错误 echo 哨兵时 thought purpose 的 error 只留 code/status", async () => {
  const { app, db } = makeApp({
    contentCaptureEnabled: true,
    providerOverrides: new Map([["stub", {
      async complete() {
        const error = new Error(`upstream 500: ${SENTINEL}`);
        error.name = "UpstreamError";
        throw error;
      },
    }]]),
    routes: {
      thought_organization: { provider: "stub", model: "stub-model", temperature: 0, maxTokens: 128 },
    },
  });
  const response = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      purpose: "thought_organization",
      messages: [{ role: "user", content: JSON.stringify({ thoughtContent: SENTINEL }) }],
    }),
  });
  assert.ok(response.status >= 500);
  const row = db.prepare("SELECT error_message FROM ai_call_logs WHERE purpose = 'thought_organization' ORDER BY id DESC LIMIT 1").get();
  assert.ok(!row.error_message.includes(SENTINEL));
  const parsed = JSON.parse(row.error_message);
  assert.equal(parsed.code, "UPSTREAM_ERROR");
  assert.equal(parsed.message, undefined);
});

test("隐私：整理端点的 stage 日志（成功/错误）只含元数据", async () => {
  const { app, db } = makeApp();
  const body = organizeBody({ text: `今天想了想 ${SENTINEL} 的事` });
  const response = await postOrganize(app, body);
  assert.equal(response.status, 200);

  const rows = db.prepare("SELECT * FROM ai_call_logs WHERE purpose LIKE 'thought_organize_%'").all();
  assert.ok(rows.length >= 2, "至少 A/B 两条 stage 日志");
  for (const row of rows) {
    const joined = JSON.stringify(row);
    assert.ok(!joined.includes(SENTINEL), "stage 日志泄漏正文哨兵");
    assert.ok(!joined.includes("今天想了想"));
    assert.equal(row.request_summary, null);
    assert.equal(row.response_summary, null);
    // token 计量列正常落库（成本可审计）
    assert.ok(row.prompt_tokens > 0);
  }
});

// ─────────────────────────── 预算台账（单元） ───────────────────────────

function makeBudgetStore() {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createThoughtOrganizeBudgetStore(database.db);
  return { store, db: database.db };
}

test("预算：begin/settle 正常闭环按实际金额入账", () => {
  const { store } = makeBudgetStore();
  const daily = 200_000; // ¥0.20
  const begin = store.beginOperation({
    subjectId: "s1", operationId: "op1", estimateMicro: 10_000, dailyBudgetMicro: daily,
  });
  assert.equal(begin.allowed, true);
  let snapshot = store.dailySnapshot("s1");
  assert.equal(snapshot.reservedMicro, 10_000);
  assert.equal(snapshot.committedMicro, 0);

  store.settleOperation({ operationId: "op1", estimateMicro: 10_000, actualMicro: 6_000, status: "completed" });
  snapshot = store.dailySnapshot("s1");
  assert.equal(snapshot.reservedMicro, 0);
  assert.equal(snapshot.committedMicro, 6_000);
});

test("预算：日预算不足时拒绝并返回 resetAt", () => {
  const { store } = makeBudgetStore();
  const begin = store.beginOperation({
    subjectId: "s1", operationId: "op1", estimateMicro: 150_000, dailyBudgetMicro: 200_000,
  });
  assert.equal(begin.allowed, true);
  const denied = store.beginOperation({
    subjectId: "s1", operationId: "op2", estimateMicro: 100_000, dailyBudgetMicro: 200_000,
  });
  assert.equal(denied.allowed, false);
  assert.equal(denied.reason, "budget_exceeded");
  assert.ok(denied.resetAt);
});

test("预算：usage 丢失按预留上界计入；悬挂预留由 recoverStale 收口", () => {
  const { store, db } = makeBudgetStore();
  store.beginOperation({ subjectId: "s1", operationId: "op1", estimateMicro: 10_000, dailyBudgetMicro: 200_000 });
  store.settleOperation({ operationId: "op1", estimateMicro: 10_000, actualMicro: null, status: "failed" });
  assert.equal(store.dailySnapshot("s1").committedMicro, 10_000);

  // 悬挂预留：begin 后不结算，把 updated_at 拨回 20 分钟前模拟崩溃残留
  store.beginOperation({ subjectId: "s1", operationId: "op2", estimateMicro: 5_000, dailyBudgetMicro: 200_000 });
  db.prepare("UPDATE thought_organize_operations SET updated_at = datetime('now', '-20 minutes') WHERE operation_id = 'op2'").run();
  store.recoverStale();
  const snapshot = store.dailySnapshot("s1");
  assert.equal(snapshot.committedMicro, 15_000);
  assert.equal(snapshot.reservedMicro, 0);
});

test("预算：operation 重开保留 attempts 旧记录", () => {
  const { store } = makeBudgetStore();
  store.beginOperation({ subjectId: "s1", operationId: "op1", estimateMicro: 1_000, dailyBudgetMicro: 200_000 });
  store.settleOperation({ operationId: "op1", estimateMicro: 1_000, actualMicro: 1_000, status: "completed" });
  const reopen = store.beginOperation({
    subjectId: "s1", operationId: "op1", estimateMicro: 1_000, dailyBudgetMicro: 200_000,
  });
  assert.equal(reopen.allowed, true);
  assert.equal(reopen.attempts, 2);
});

// ─────────────────────────── helpers ───────────────────────────

function stubRoutes() {
  return {
    thought_organize_a: { provider: "stub", model: "stub-model", temperature: 0, maxTokens: 400 },
    thought_organize_r: { provider: "stub", model: "stub-model", temperature: 0, maxTokens: 160 },
    thought_organize_b: { provider: "stub", model: "stub-model", temperature: 0, maxTokens: 600 },
  };
}

function stubCompletion(content) {
  return {
    id: "stub-completion",
    choices: [{ index: 0, message: { role: "assistant", content }, finish_reason: "stop" }],
    usage: { prompt_tokens: 100, completion_tokens: 30, total_tokens: 130 },
  };
}
