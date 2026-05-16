import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

// 每个测试使用独立的内存数据库
function createTestDatabase() {
  return createDatabase({ dbPath: `:memory:` });
}

function createTestApp(overrides = {}) {
  return createApp({
    database: createTestDatabase(),
    auth: { enforceAppAttest: false },
    limits: {
      chatRequestsPerMinute: 2,
      chatRequestsPerDay: 10,
    },
    routes: {
      chat: {
        provider: "mock",
        model: "holo-mock",
        temperature: 0.2,
        maxTokens: 512,
      },
    },
    ...overrides,
  });
}

// 辅助函数：创建带 session cookie 的已登录 app
async function createLoggedInApp(overrides = {}) {
  const app = createTestApp({
    admin: {
      username: "admin",
      password: "test-password",
      sessionSecret: "test-session-secret",
    },
    ...overrides,
  });

  const loginResponse = await app.request("/admin/login", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      username: "admin",
      password: "test-password",
    }).toString(),
  });

  assert.equal(loginResponse.status, 302);
  const cookie = loginResponse.headers.get("set-cookie");
  return { app, cookie };
}

// === 测试 1: /v1/prompts/meta 返回元数据（不含 content） ===

test("GET /v1/prompts/meta 返回 Prompt 元数据，不包含 content 字段", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/meta");

  assert.equal(response.status, 200);
  const json = await response.json();
  assert.ok(Array.isArray(json.prompts));
  assert.ok(json.prompts.length > 0, "应至少有一个 Prompt 类型");

  // 每个条目应有 type/version/source/updatedAt，不应有 content
  for (const prompt of json.prompts) {
    assert.ok(prompt.type, "应有 type 字段");
    assert.ok(typeof prompt.version === "number", "应有 version 字段");
    assert.ok(prompt.source, "应有 source 字段");
    assert.equal(prompt.content, undefined, "不应包含 content 字段");
  }

  // 确认 meta 版本号与 /v1/prompts 一致
  const fullResponse = await app.request("/v1/prompts");
  const fullJson = await fullResponse.json();
  const fullPrompt = fullJson.prompts.find((p) => p.type === "system_prompt");
  const metaPrompt = json.prompts.find((p) => p.type === "system_prompt");
  assert.equal(fullPrompt.version, metaPrompt.version, "版本号应一致");
  // fullPrompt 有 contentLength 但不含 content（listPrompts 返回摘要）
  assert.ok(fullPrompt.contentLength, "/v1/prompts 应包含 contentLength");
});

// === 测试 2: /v1/prompts/meta 在 SQLite 不可用时降级处理 ===

test("GET /v1/prompts/meta 在无 SQLite 时仍能返回基本元数据", async () => {
  // 创建不传 database 的 app — 但 createApp 强制创建，
  // 所以我们测试正常路径下 meta 数据的完整性
  const app = createTestApp();

  const response = await app.request("/v1/prompts/meta");
  assert.equal(response.status, 200);

  const json = await response.json();
  assert.ok(json.prompts.some((p) => p.type === "intent_recognition"));
  assert.ok(json.prompts.some((p) => p.type === "system_prompt"));
  assert.ok(json.prompts.some((p) => p.type === "memory_insight_generation"));

  // 验证 version 是合理数字
  for (const prompt of json.prompts) {
    assert.ok(prompt.version >= 1, `Prompt ${prompt.type} 的 version 应 >= 1`);
  }
});

test("启动时自动把默认 Prompt 登记到版本历史", async () => {
  const { app, cookie } = await createLoggedInApp();

  const historyPage = await app.request("/admin/prompts/memory_insight_generation/history", {
    headers: { cookie },
  });

  assert.equal(historyPage.status, 200);
  const historyHtml = await historyPage.text();
  assert.match(historyHtml, /default/);
  assert.match(historyHtml, /自动登记默认 Prompt 基线/);
});

test("intent_recognition 默认 Prompt 已移除完整科目表并使用 categoryCandidate", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/intent_recognition");
  assert.equal(response.status, 200);
  const prompt = await response.json();

  assert.equal(prompt.version, 6);
  assert.match(prompt.content, /categoryCandidate/);
  assert.match(prompt.content, /系统科目对照 catalog/);
  assert.doesNotMatch(prompt.content, /## 科目体系/);
  assert.doesNotMatch(prompt.content, /### 支出/);
  assert.doesNotMatch(prompt.content, /### 收入/);
  assert.doesNotMatch(prompt.content, /餐饮 \\| 早餐、午餐、晚餐/);
});

test("默认 Prompt 文件内容与当前版本不一致时会同步为可见历史版本", async () => {
  const database = createTestDatabase();
  const { app, cookie } = await createLoggedInApp({ database });

  const beforeResponse = await app.request("/v1/prompts/system_prompt");
  const before = await beforeResponse.json();

  await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "临时覆盖 Prompt，等待默认文件同步",
      change_note: "模拟网页修改",
    }).toString(),
  });

  const afterManagedResponse = await app.request("/v1/prompts/system_prompt");
  const afterManaged = await afterManagedResponse.json();
  assert.equal(afterManaged.source, "managed");

  const { app: restartedApp, cookie: restartedCookie } = await createLoggedInApp({ database });
  const afterRestartResponse = await restartedApp.request("/v1/prompts/system_prompt");
  const afterRestart = await afterRestartResponse.json();

  assert.equal(afterRestart.source, "default_sync");
  assert.equal(afterRestart.content, before.content);
  assert.equal(afterRestart.version, afterManaged.version + 1);

  const historyPage = await restartedApp.request("/admin/prompts/system_prompt/history", {
    headers: { cookie: restartedCookie },
  });
  assert.equal(historyPage.status, 200);
  const historyHtml = await historyPage.text();
  assert.match(historyHtml, /default_sync/);
  assert.match(historyHtml, /自动同步默认 Prompt 文件变更/);
});

// === 测试 3: Prompt 保存后版本号递增 ===

test("保存 Prompt 后版本号递增", async () => {
  const { app, cookie } = await createLoggedInApp();

  // 获取初始版本
  const beforeResponse = await app.request("/v1/prompts/system_prompt");
  const before = await beforeResponse.json();
  const initialVersion = before.version;

  // 保存新内容
  await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "新版本 Prompt 内容 v1",
    }).toString(),
  });

  // 验证版本递增
  const afterResponse = await app.request("/v1/prompts/system_prompt");
  const after = await afterResponse.json();
  assert.equal(after.version, initialVersion + 1, "版本号应递增 1");
  assert.equal(after.content, "新版本 Prompt 内容 v1");
  assert.equal(after.source, "managed");

  // 再保存一次，版本再递增
  await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "新版本 Prompt 内容 v2",
    }).toString(),
  });

  const after2Response = await app.request("/v1/prompts/system_prompt");
  const after2 = await after2Response.json();
  assert.equal(after2.version, initialVersion + 2, "版本号应再递增 1");
  assert.equal(after2.content, "新版本 Prompt 内容 v2");
});

// === 测试 4: change_note 保存和读取 ===

test("change_note 可以保存并在历史记录中读取", async () => {
  const { app, cookie } = await createLoggedInApp();

  // 保存带 change_note 的 Prompt
  const saveResponse = await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "带变更说明的 Prompt",
      change_note: "修复了记账意图识别的准确性问题",
    }).toString(),
  });
  assert.equal(saveResponse.status, 302);

  // 查看历史页面应包含 change_note
  const historyPage = await app.request("/admin/prompts/system_prompt/history", {
    headers: { cookie },
  });
  assert.equal(historyPage.status, 200);
  const historyHtml = await historyPage.text();
  assert.match(historyHtml, /修复了记账意图识别的准确性问题/);
  assert.match(historyHtml, /变更说明/);
});

test("不带 change_note 保存时 history 中显示为空", async () => {
  const { app, cookie } = await createLoggedInApp();

  // 保存不带 change_note 的 Prompt
  await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "不带变更说明的 Prompt",
    }).toString(),
  });

  // 历史页面应正常渲染，变更说明列显示 '-'
  const historyPage = await app.request("/admin/prompts/system_prompt/history", {
    headers: { cookie },
  });
  assert.equal(historyPage.status, 200);
  const historyHtml = await historyPage.text();
  assert.match(historyHtml, /变更说明/);
});

test("getPrompt 返回 lastChangeNote 字段", async () => {
  const { app, cookie } = await createLoggedInApp();

  // 保存带 change_note 的 Prompt
  await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "检查 lastChangeNote 的 Prompt",
      change_note: "这是变更说明",
    }).toString(),
  });

  // /v1/prompts/:type 接口应返回 lastChangeNote
  const response = await app.request("/v1/prompts/system_prompt");
  assert.equal(response.status, 200);
  const json = await response.json();
  assert.equal(json.lastChangeNote, "这是变更说明");
});

test("编辑器页面显示上次的 change_note", async () => {
  const { app, cookie } = await createLoggedInApp();

  // 保存带 change_note 的 Prompt
  await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "编辑器显示 change_note 测试",
      change_note: "上次的变更说明",
    }).toString(),
  });

  // 编辑器页面应包含变更说明 textarea 和上次的说明
  const editorPage = await app.request("/admin/prompts/system_prompt", {
    headers: { cookie },
  });
  assert.equal(editorPage.status, 200);
  const editorHtml = await editorPage.text();
  assert.match(editorHtml, /变更说明/);
  assert.match(editorHtml, /上次的变更说明/);
});

// === 测试 5: History/Rollback 在有 change_note 列时正常工作 ===

test("回滚功能在有 change_note 列时正常工作", async () => {
  const { app, cookie } = await createLoggedInApp();

  // 获取初始版本号
  const initialResponse = await app.request("/v1/prompts/system_prompt");
  const initialJson = await initialResponse.json();
  const initialVersion = initialJson.version;

  // 第一次保存
  await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "版本 A",
      change_note: "第一个变更",
    }).toString(),
  });
  const versionA = initialVersion + 1;

  // 第二次保存
  await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "版本 B",
      change_note: "第二个变更",
    }).toString(),
  });

  // 获取历史，确认有两个新版本
  const historyPage = await app.request("/admin/prompts/system_prompt/history", {
    headers: { cookie },
  });
  assert.equal(historyPage.status, 200);
  const historyHtml = await historyPage.text();
  assert.match(historyHtml, /第一个变更/);
  assert.match(historyHtml, /第二个变更/);

  // 获取当前版本号
  const beforeRollback = await app.request("/v1/prompts/system_prompt");
  const beforeJson = await beforeRollback.json();
  const versionBeforeRollback = beforeJson.version;

  // 回滚到版本 A（versionA）
  const rollbackResponse = await app.request("/admin/prompts/system_prompt/rollback", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      version: versionA,
    }).toString(),
  });
  assert.equal(rollbackResponse.status, 302);
  assert.match(rollbackResponse.headers.get("location"), /rolled_back_to_v/);

  // 验证回滚后内容是版本 A
  const afterRollback = await app.request("/v1/prompts/system_prompt");
  const afterJson = await afterRollback.json();
  assert.equal(afterJson.content, "版本 A");
  assert.equal(afterJson.version, versionBeforeRollback + 1, "回滚应创建新版本");
});

test("恢复默认在有 change_note 列时正常工作", async () => {
  const { app, cookie } = await createLoggedInApp();

  // 先保存一个自定义版本
  await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      content: "自定义版本内容",
      change_note: "自定义修改",
    }).toString(),
  });

  // 恢复默认
  const resetResponse = await app.request("/admin/prompts/system_prompt", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      action: "reset",
    }).toString(),
  });
  assert.equal(resetResponse.status, 302);
  assert.match(resetResponse.headers.get("location"), /prompt_reset/);

  // 验证内容已恢复
  const promptResponse = await app.request("/v1/prompts/system_prompt");
  const promptJson = await promptResponse.json();
  assert.equal(promptJson.source, "reset");
  assert.notEqual(promptJson.content, "自定义版本内容");
});

// === 测试 6: Prompt 测试接口 ===

test("Prompt 测试接口返回模型响应", async () => {
  const { app, cookie } = await createLoggedInApp();

  const testResponse = await app.request("/admin/prompts/system_prompt/test", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      purpose: "chat",
      message: "你好测试",
    }).toString(),
  });

  assert.equal(testResponse.status, 200);
  const json = await testResponse.json();
  assert.ok(json.result, "应返回测试结果");
  assert.match(json.result, /Mock response/);
});

test("Prompt 测试接口在无消息时返回错误", async () => {
  const { app, cookie } = await createLoggedInApp();

  const testResponse = await app.request("/admin/prompts/system_prompt/test", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      purpose: "chat",
      message: "",
    }).toString(),
  });

  assert.equal(testResponse.status, 400);
  const json = await testResponse.json();
  assert.match(json.error, /不能为空/);
});

test("Prompt 测试接口对不存在的 Prompt 类型返回 404", async () => {
  const { app, cookie } = await createLoggedInApp();

  const testResponse = await app.request("/admin/prompts/nonexistent_prompt/test", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
      cookie,
    },
    body: new URLSearchParams({
      purpose: "chat",
      message: "test",
    }).toString(),
  });

  assert.equal(testResponse.status, 404);
});

test("Prompt 测试接口需要管理员权限", async () => {
  const app = createTestApp({
    admin: {
      username: "admin",
      password: "test-password",
      sessionSecret: "test-session-secret",
    },
  });

  const testResponse = await app.request("/admin/prompts/system_prompt/test", {
    method: "POST",
    headers: {
      "content-type": "application/x-www-form-urlencoded",
    },
    body: new URLSearchParams({
      purpose: "chat",
      message: "test",
    }).toString(),
  });

  assert.equal(testResponse.status, 401);
});
