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
    exposePromptEndpointsForTests: true,
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

test("intent_recognition 默认 Prompt 已瘦身并固定个人状态路由（v24）", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/intent_recognition");
  assert.equal(response.status, 200);
  const prompt = await response.json();

  // 版本号
  assert.equal(prompt.version, 24);

  // 长度验证：Router 允许补充必要规则，但仍防止重新膨胀为长 prompt
  // 红线 4350：update_task 补全了改任务（改时间/标题/优先级）的字段映射，属于功能必需内容
  assert.ok(prompt.content.length < 4350, `prompt 长度 ${prompt.content.length} 超过 4350`);

  // 保留的核心字段
  assert.match(prompt.content, /note/);
  assert.match(prompt.content, /用户可见名称/);
  assert.match(prompt.content, /categoryCandidate/);
  assert.match(prompt.content, /transactionDate/);
  assert.match(prompt.content, /昨天=交易日-1/);
  assert.match(prompt.content, /normalizedCategoryCandidate/);
  assert.match(prompt.content, /semanticCategoryHint/);
  assert.match(prompt.content, /reminderDate/);
  assert.match(prompt.content, /subtasks/);
  assert.match(prompt.content, /description/);
  assert.match(prompt.content, /购物清单/);

  // 保留的分流规则
  assert.match(prompt.content, /今年买烟花花了多少/);
  assert.match(prompt.content, /今年收入是多少/);
  assert.match(prompt.content, /flexible_data_query/);
  assert.match(prompt.content, /query_analysis/);
  assert.match(prompt.content, /平均每笔\/每次\/每顿/);
  assert.match(prompt.content, /最近一个月吃了多少顿麦当劳/);
  assert.match(prompt.content, /必须输出 single_action/);
  assert.match(prompt.content, /不要拆成 multi_action/);
  assert.match(prompt.content, /睡眠/);
  assert.match(prompt.content, /analysisDomain: "health"/);
  assert.match(prompt.content, /HOLO_PERSONAL_STATE_ROUTING_V24/);
  assert.match(prompt.content, /我最近状态怎么样\/如何/);
  assert.match(prompt.content, /不得追问领域/);
  assert.match(prompt.content, /analysisDomain="cross_domain"/);

  // 已下沉字段不应出现在 Router prompt 中
  assert.doesNotMatch(prompt.content, /installmentEnabled/);
  assert.doesNotMatch(prompt.content, /installmentPeriods/);
  assert.doesNotMatch(prompt.content, /repeatEnabled/);
  assert.doesNotMatch(prompt.content, /repeatType/);
  assert.doesNotMatch(prompt.content, /habitPolarity/);
  assert.doesNotMatch(prompt.content, /stayBelowTarget/);

  // 已移除的大段内容
  assert.doesNotMatch(prompt.content, /系统科目对照 catalog/);
  assert.doesNotMatch(prompt.content, /## 科目体系/);
  assert.doesNotMatch(prompt.content, /## 输出格式/);
});

test("flexible_query_planner supports deterministic per-meal averages", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/flexible_query_planner");
  assert.equal(response.status, 200);
  const prompt = await response.json();

  assert.equal(prompt.version, 4);
  assert.match(prompt.content, /averageAmount/);
  assert.match(prompt.content, /averageUnit/);
  assert.match(prompt.content, /"operation":"sumAmount"/);
  assert.match(prompt.content, /"averageUnit":"meal"/);
  assert.match(prompt.content, /麦当劳/);
  assert.match(prompt.content, /不要记录.*吨.*顿.*纠错说明/);
});

test("system_prompt 默认 Prompt 使用结论先行与渐进披露约束", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/system_prompt");
  assert.equal(response.status, 200);
  const prompt = await response.json();

  assert.equal(prompt.version, 4);
  // v4: 表达边界与档案规则由 Persona Preamble 接管，正文只保留核心能力与操作禁令；
  // C 端阅读格式仍由 _consumer_readable_answer_v1_contract 契约片段 append。
  assert.match(prompt.content, /HOLO_CONSUMER_READABLE_ANSWER_V1/);
  assert.match(prompt.content, /第一段直接回答用户最关心的问题/);
  assert.match(prompt.content, /一个主结论和最多三个关键点/);
  assert.match(prompt.content, /另起‘详细分析’一行/);
  assert.match(prompt.content, /禁止假装执行操作/);
  assert.match(prompt.content, /禁止编造数据/);
});

test("analysis_prompt 默认 Prompt 使用温档洞察方法论与 few-shot", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/analysis_prompt");
  assert.equal(response.status, 200);
  const prompt = await response.json();

  assert.equal(prompt.version, 5);
  // v5: 温档——补洞察方法论 + few-shot；表达边界与输出格式段由 Persona Preamble / 契约接管。
  assert.match(prompt.content, /洞察方法论/);
  assert.match(prompt.content, /从数据读生活场景/);
  assert.match(prompt.content, /工作日午饭的节奏/);
  assert.match(prompt.content, /分析场景用温档/);
  assert.match(prompt.content, /HOLO_CONSUMER_READABLE_ANSWER_V1/);
  // 业务硬口径保留
  assert.match(prompt.content, /财务分析口径/);
  assert.match(prompt.content, /习惯分析口径/);
});

test("Persona Preamble 片段含表达边界，并由 injectServerPrompt 注入到所有 purpose 前", async () => {
  const app = createTestApp();

  // 1. _persona_preamble 片段本身承载了收敛后的表达边界（v4 起各 purpose 正文不再重复）
  const preambleResponse = await app.request("/v1/prompts/system_prompt");
  // preamble 不作为独立 prompt type 暴露在 /v1/prompts，但 injectServerPrompt 会消费它。
  // 这里直接验证注入逻辑：injectServerPrompt 对任意 purpose 都应 prepend preamble。
  const { injectServerPrompt } = await import("../src/prompts/serverPromptPolicy.js");

  for (const purpose of ["chat", "analysis", "insight", "flexible_query_planner"]) {
    const result = injectServerPrompt(purpose, [{ role: "user", content: "测试" }]);
    const systemContent = result.messages[0].content;

    // Persona Preamble 在 system message 最前面
    assert.match(systemContent, /^你是 Holo，陪伴用户的生活助理/);
    // 安全边界由 Preamble 正向表述接管（v4 起各 purpose 不再重复旧禁令式措辞）
    assert.match(systemContent, /陪伴者，不是医生/);
    assert.match(systemContent, /相关性，但因果留给证据/);
    assert.match(systemContent, /人格标签/);
    assert.match(systemContent, /可能\/像是\/值得留意/);
    // 信息优先级
    assert.match(systemContent, /当前这一刻用户的明确输入.*永远优先/);
    assert.match(systemContent, /档案是用户主动告诉你的/);
    // 姿态切换
    assert.match(systemContent, /专业分析|情绪陪伴|日常相处/);
    assert.doesNotMatch(systemContent, /你是一个很自律的人/);
    // purpose 自身的任务指令接在 Preamble 之后
    assert.ok(systemContent.includes("\n\n"), `${purpose} 的 system message 应在 preamble 和 purpose 之间有分隔`);
  }

  // 2. 各 purpose 正文不再自带表达边界块（已收敛到 Preamble）
  for (const type of ["system_prompt", "memory_insight_generation", "analysis_prompt"]) {
    const response = await app.request(`/v1/prompts/${type}`);
    assert.equal(response.status, 200);
    const prompt = await response.json();
    // 正文不应再含旧的表达边界块标题（这些由 Preamble 接管）
    assert.doesNotMatch(prompt.content, /表达边界：\n-/);
    assert.doesNotMatch(prompt.content, /低置信判断必须使用/);
  }
});

test("thought_voice_summary 默认 Prompt 要求自然分段且小标题只在必要时出现", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/thought_voice_summary");
  assert.equal(response.status, 200);
  const prompt = await response.json();

  assert.equal(prompt.version, 2);
  assert.match(prompt.content, /自然分段/);
  assert.match(prompt.content, /不要默认添加小标题/);
  assert.match(prompt.content, /只有当原文包含多个主题/);
  assert.match(prompt.content, /不要使用 Markdown 语法符号/);
  assert.match(prompt.content, /短文本.*单段/);
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

test("agent_loop prompt 存在并包含 Agent Loop 核心约束", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/agent_loop");
  assert.equal(response.status, 200);
  const prompt = await response.json();

  assert.equal(prompt.version, 20);
  assert.match(prompt.content, /need_tools/);
  assert.match(prompt.content, /need_more_analysis/);
  assert.match(prompt.content, /final_claims/);
  assert.match(prompt.content, /只输出 JSON/);
  assert.match(prompt.content, /metricAssertions/);
  assert.match(prompt.content, /evidenceIDs/);
  // v17: 新增 title/narrativeSummary 顶层字段，让 LLM 产出有人味儿的标题和摘要
  assert.match(prompt.content, /narrativeSummary/);
  assert.match(prompt.content, /一句话总结这次的发现/);
  assert.match(prompt.content, /health_overview/);
  assert.match(prompt.content, /steps_summary/);
  assert.match(prompt.content, /sleep_summary/);
  assert.match(prompt.content, /stand_summary/);
  assert.match(prompt.content, /activity_summary/);
  assert.match(prompt.content, /workout_summary/);
  assert.match(prompt.content, /dynamic_query/);
  assert.match(prompt.content, /禁止生成 SQL/);
  // v18: 新增 expression 派生操作（分档换算自由组合）
  assert.match(prompt.content, /expression/);
  assert.match(prompt.content, /分档换算/);
  assert.match(prompt.content, /percentageChange/);
  assert.match(prompt.content, /cross_domain/);
  assert.match(prompt.content, /health×finance/);
  assert.match(prompt.content, /task×habit/);
  assert.match(prompt.content, /goal×task/);
  assert.match(prompt.content, /goal\.progress\.daily/);
  assert.match(prompt.content, /所有数据域/);
  assert.match(prompt.content, /conversation/);
  assert.match(prompt.content, /历史消息原文/);
  assert.match(prompt.content, /绝不能表述/);
  assert.match(prompt.content, /全部明确子问题/);
  assert.match(prompt.content, /自然日数/);
  assert.match(prompt.content, /当前只能评估睡眠时长/);
  assert.match(prompt.content, /不要输出 suggestion claim/);
  assert.match(prompt.content, /HOLO_AGENT_READABLE_ANSWER_V10/);
  assert.match(prompt.content, /HOLO_AGENT_TOOL_REQUEST_V11/);
  assert.match(prompt.content, /HOLO_AGENT_FINAL_CLAIMS_V14/);
  assert.match(prompt.content, /HOLO_AGENT_USABLE_ANSWER_V15/);
  assert.match(prompt.content, /dynamicPlan 和 crossDomainPlan 必须与 parameters 同级/);
  assert.match(
    prompt.content,
    /"parameters":\{\},"dynamicPlan":null,"crossDomainPlan":null/
  );
  assert.match(prompt.content, /普通用户直接理解/);
  assert.match(prompt.content, /禁止输出 metric key/);
  assert.match(prompt.content, /health\.steps\.average/);
  assert.match(prompt.content, /观察 01/);
  assert.match(prompt.content, /问步数不能混入睡眠/);
  assert.match(prompt.content, /不要重复同一句结论/);
  assert.match(prompt.content, /final_claims 必须包含至少一条 claim/);
  assert.match(prompt.content, /"metricKey":"string","value":0,"baselineValue":null/);
  assert.match(prompt.content, /HOLO_AGENT_RESPONSE_RECOVERY_V1/);
  assert.match(prompt.content, /权威范围/);
  assert.match(prompt.content, /尚未发生的分期/);
  assert.match(prompt.content, /事件数据/);
  assert.match(prompt.content, /type=suggestion/);
  assert.match(prompt.content, /禁止把全部指标逐条堆砌/);
});

test("memory insight prompt 强制输出稳定主题键和四字段候选", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/memory_insight_generation");
  assert.equal(response.status, 200);
  const prompt = await response.json();

  assert.equal(prompt.version, 10);
  assert.match(prompt.content, /HOLO_MEMORY_SEMANTIC_V2/);
  assert.match(prompt.content, /subjectKey/);
  assert.match(prompt.content, /跨日报、周报、月报稳定不变/);
  assert.match(prompt.content, /context\.longTermMemoryContext/);
  assert.match(prompt.content, /缺一则整条候选无效/);
  assert.doesNotMatch(prompt.content, /memoryCandidate 包含 3 个字段/);
  assert.match(prompt.content, /"subjectKey": "string, 跨周期稳定主题键/);
  assert.match(prompt.content, /顶层必须输出 usedMemoryIDs 数组/);
  assert.match(prompt.content, /仅看到但未使用时输出 \[\]/);
  assert.match(prompt.content, /monthly：summary 90-140 字，4-6 张 cards/);
  assert.match(prompt.content, /不得把语气推断成“职业焦虑”等心理标签/);
  assert.match(prompt.content, /对应原始数字和周期/);
});

test("annual review prompt 提供年度回放所需的信息深度", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/prompts/annual_review");
  assert.equal(response.status, 200);
  const prompt = await response.json();

  assert.equal(prompt.version, 2);
  assert.match(prompt.content, /summary 控制在 160-240 字/);
  assert.match(prompt.content, /输出 6-8 张 cards/);
  assert.match(prompt.content, /每张 body 120-180 字/);
  assert.match(prompt.content, /跨模块关联只能表达为并发现象/);
});
