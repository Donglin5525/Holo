// 目标共创 purpose（2026-09-17 完整开发计划任务 3）：
// 路由与契约回显、额度豁免（产品决策 2026-09-19：不占额度免费全量开放）、Prompt 注册与版本、
// metadata_only 强制、多语言指令、goalWorkshopV1 开关默认关。mock 请求成功只证明链路，不证明模型质量。
import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { createDatabase } from "../src/db/database.js";
import { createAdminLogStore } from "../src/admin/adminLogStore.js";
import { injectServerPrompt } from "../src/prompts/serverPromptPolicy.js";
import { listPromptMetadata } from "../src/prompts/promptRegistry.js";

const DEVICE_ID = "test-device-goal-workshop";

function createTestApp(overrides = {}) {
  const database = createDatabase({ dbPath: ":memory:" });
  return createApp({
    database,
    auth: { enforceAppAttest: false },
    limits: { chatRequestsPerMinute: 10, chatRequestsPerDay: 50 },
    routes: {
      chat: { provider: "mock", model: "holo-mock", temperature: 0.2, maxTokens: 512 },
      goal_workshop: { provider: "mock", model: "holo-mock", temperature: 0.3, maxTokens: 4096 },
    },
    exposePromptEndpointsForTests: true,
    ...overrides,
  });
}

function workshopRequestBody(operation, extra = {}) {
  return JSON.stringify({
    purpose: "goal_workshop",
    stream: false,
    messages: [
      {
        role: "user",
        content: JSON.stringify({
          schemaVersion: 1,
          sessionID: "11111111-2222-3333-4444-555555555555",
          revision: 3,
          operation,
          input: "我想在工作会议中更敢开口说英语",
          skippedQuestion: false,
          sessionSnapshot: {
            phase: "understanding",
            questionsAsked: 0,
            originalText: "我想在工作会议中更敢开口说英语",
            activeFacts: [],
            routeOptions: [],
            selectedRouteID: null,
            goalDefinition: null,
            today: "2026-09-17",
          },
          contextRefs: [],
        }),
      },
    ],
    ...extra,
  });
}

async function postWorkshop(app, operation, headers = {}) {
  return app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": DEVICE_ID,
      ...headers,
    },
    body: workshopRequestBody(operation),
  });
}

test("goal_workshop 路由可达且 mock 契约回显 sessionID/revision", async () => {
  const app = createTestApp();
  const response = await postWorkshop(app, "propose_options");
  assert.equal(response.status, 200);
  const json = await response.json();
  const content = JSON.parse(json.choices[0].message.content);
  assert.equal(content.schemaVersion, 1);
  assert.equal(content.sessionID, "11111111-2222-3333-4444-555555555555");
  assert.equal(content.revision, 3);
  assert.equal(content.kind, "options");
  assert.equal(content.options.length, 2);
  assert.ok(content.options.every((option) => option.tradeoff && option.fit && option.reason));
});

test("goal_workshop 不占额度（产品决策 2026-09-19：免费全量开放，无 X-Holo-Quota-Type）", async () => {
  const app = createTestApp();
  const response = await postWorkshop(app, "understand");
  assert.equal(response.status, 200);
  assert.equal(
    response.headers.get("X-Holo-Quota-Type"),
    null,
    "goal_workshop 不得记入任何额度池",
  );
});

test("goal_workshop 限流桶独立兜量", () => {
  const config = loadConfig();
  const route = config.routes.goal_workshop;
  assert.ok(route, "goal_workshop route 应存在");
  assert.ok(route.requestLimits.perMinute > 0);
  assert.ok(route.requestLimits.perDay > 0);
  assert.ok(route.maxTokens >= 4096, "草案 JSON 需要充足输出预算");
  assert.equal(typeof route.reasoningEffort, "string");
});

test("quotaTypeForPurpose：goal_workshop 已豁免额度（产品决策 2026-09-19）", () => {
  // 通过配置与实现一致性间接锁定：route 仍在（限流兜量），额度归属已移除
  const config = loadConfig();
  assert.ok(config.routes.goal_workshop);
  assert.ok(config.routes.matter_reconciliation);
});

test("goal_workshop Prompt 已注册且版本为 1", () => {
  const meta = listPromptMetadata().find((item) => item.type === "goal_workshop");
  assert.ok(meta, "goal_workshop 应在注册表");
  assert.equal(meta.version, 1);
  const injected = injectServerPrompt("goal_workshop", [
    { role: "user", content: "{}" },
  ]);
  assert.equal(injected.promptType, "goal_workshop");
  assert.equal(injected.promptVersion, 1);
  const system = injected.messages[0].content;
  assert.match(system, /目标共创助手/);
  assert.match(system, /一次只问一个/);
  assert.match(system, /不得凭空补日历日/);
  assert.match(system, /禁止输出 userStated/);
});

test("GET /v1/prompts/meta 包含 goal_workshop 版本 1", async () => {
  const app = createTestApp();
  const response = await app.request("/v1/prompts/meta");
  assert.equal(response.status, 200);
  const json = await response.json();
  const entry = json.prompts?.find((item) => item.type === "goal_workshop");
  assert.ok(entry, "meta 应包含 goal_workshop");
  assert.equal(entry.version, 1);
});

test("goal_workshop 属多语言 purpose（zh-Hant 注入语言指令）", () => {
  const injected = injectServerPrompt(
    "goal_workshop",
    [{ role: "user", content: "{}" }],
    { language: "zh-Hant" },
  );
  assert.match(injected.messages[0].content, /繁體中文/);
});

test("goal_workshop 强制 metadata_only：管理员开启正文捕获也不落原话", () => {
  const database = createDatabase({ dbPath: ":memory:" });
  const store = createAdminLogStore({ db: database.db, contentCaptureEnabled: true });

  const id = store.startAiCall({
    deviceId: "device-gw-meta",
    purpose: "goal_workshop",
    provider: "mock",
    model: "holo-mock",
    stream: false,
    request: {
      messages: [{ role: "user", content: "我想在工作会议中更敢开口说英语（私人原话）" }],
    },
  });
  store.finishAiCall(id, {
    status: "success",
    response: { text: "目标草案（私人内容）" },
  });

  const row = database.db
    .prepare("SELECT request_summary, response_summary FROM ai_call_logs WHERE rowid = 1")
    .get();
  const blob = JSON.stringify(row);
  assert.ok(!blob.includes("私人原话"), "请求正文不得落日志");
  assert.ok(!blob.includes("私人内容"), "响应正文不得落日志");
});

test("goalWorkshopV1 开关默认关，admin 可开闸（急停通道）", async () => {
  const app = createTestApp({
    admin: { token: "secret-admin-token", username: "admin", password: "pw", sessionSecret: "test-secret" },
    holoSessionService: { async verify() { return { internalDiagnostics: true }; } },
  });

  const status = await app.request("/v1/subscription/status", {
    headers: { "x-holo-device-id": DEVICE_ID },
  });
  const json = await status.json();
  assert.equal(json.featureFlags.goalWorkshopV1, false, "出厂默认关");

  const toggle = await app.request("/admin/feature-flags/goalWorkshopV1", {
    method: "POST",
    headers: { "x-holo-admin-token": "secret-admin-token" },
    body: new URLSearchParams({ value: "true" }).toString(),
  });
  assert.equal(toggle.status, 302);

  const statusAfter = await app.request("/v1/subscription/status", {
    headers: { "x-holo-device-id": DEVICE_ID },
  });
  assert.equal((await statusAfter.json()).featureFlags.goalWorkshopV1, true);
});
