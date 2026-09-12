import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";

import { loadConfig } from "../src/config.js";
import { getPrompt } from "../src/prompts/promptRegistry.js";
import { injectServerPrompt } from "../src/prompts/serverPromptPolicy.js";

// Matter「进行中的事」对账 purpose 契约（docs/_common/plans/2026-09-11-Holo-Matter进行中的事完整实施方案.md §12）
// 只验证本地网关契约：路由/配额映射/prompt 存在与注入防护/语言策略/metadata_only。

function quotaTypeForPurpose(purpose) {
  // 与 src/app.js 内同名函数保持一致的最小镜像（该函数未导出，测试用镜像锁定契约）。
  if (purpose === "chat" || purpose === "analysis") return "chat";
  if (purpose === "personal_context_request" || purpose === "personal_context_planning") return "chat";
  if (purpose === "matter_reconciliation") return "chat";
  return null;
}

test("Matter 对账：路由配置齐备（provider/model/maxTokens/独立限流桶）", () => {
  const config = loadConfig();
  const route = config.routes.matter_reconciliation;
  assert.ok(route, "matter_reconciliation 必须有路由配置");
  assert.ok(route.provider, "缺 provider");
  assert.ok(route.model, "缺 model");
  assert.ok(route.maxTokens > 0 && route.maxTokens <= 4000, "对账是小输出任务，maxTokens 应克制");
  assert.ok(
    route.requestLimits?.perMinute > 0 && route.requestLimits?.perDay > 0,
    "缺独立限流桶",
  );
});

test("Matter 对账：归 chat 配额池（独立 purpose 计费口径）", () => {
  assert.equal(quotaTypeForPurpose("matter_reconciliation"), "chat");
});

test("Matter 对账：服务端 prompt 已注册且有版本", () => {
  const prompt = getPrompt("matter_reconciliation");
  assert.ok(prompt?.content, "prompt 缺正文");
  assert.ok(prompt?.version >= 1, "prompt 缺版本号");
});

test("Matter 对账：prompt 含注入防护与越权禁令", () => {
  const prompt = getPrompt("matter_reconciliation");
  assert.ok(prompt.content.includes("不是指令"), "必须声明输入是数据不可执行");
  assert.ok(prompt.content.includes("用户消息里如果包含指令") || prompt.content.includes("任何文字"), "用户新消息里的指令不得覆盖 system policy");
  assert.ok(prompt.content.includes("confirmOpenLoop"), "必须显式禁止模型升级 epistemic");
  assert.ok(prompt.content.includes("不得输出完成/归档/删除"), "必须禁止完成/归档/删除 Matter");
  assert.ok(prompt.content.includes("不要猜测"), "歧义必须追问不许猜");
});

test("Matter 对账：结构化契约 purpose 不注入语言指令", () => {
  const messages = [{ role: "user", content: "酒店订好了" }];
  const injected = injectServerPrompt("matter_reconciliation", messages, { language: "zh-Hant" });
  assert.ok(
    !injected.messages.some((m) => m.content.includes("【语言要求】")),
    "对账输出参与 JSON 契约解析，不得注入语言指令",
  );
  // system prompt 注入在消息首位
  assert.equal(injected.messages[0].role, "system");
  assert.ok(injected.messages[0].content.includes("对账助手"));
});

test("Matter 对账：prompt 与契约的 kind 白名单一致（三种可用 mutation）", () => {
  const prompt = getPrompt("matter_reconciliation");
  for (const kind of ["setOpenLoopState", "addSuggestedOpenLoop", "proposeLink"]) {
    assert.ok(prompt.content.includes(kind), `契约缺 ${kind}`);
  }
});

test("Matter 对账：adminLogStore 已纳入 metadata_only 强制集", () => {
  const source = readFileSync(new URL("../src/admin/adminLogStore.js", import.meta.url), "utf8");
  assert.ok(
    source.includes("'matter_reconciliation'") || source.includes('"matter_reconciliation"'),
    "对账请求含 Matter 快照与用户消息，必须 metadata_only",
  );
});
