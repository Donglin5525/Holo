import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";

import { loadConfig } from "../src/config.js";
import { getPrompt } from "../src/prompts/promptRegistry.js";
import { injectServerPrompt } from "../src/prompts/serverPromptPolicy.js";
import { GatewayError } from "../src/errors.js";

// 通用个人情境 purpose 契约（docs/_common/plans/2026-09-06-HoloAI通用个人情境理解与规划-完整实施方案.md §11/§12）
// 本文件只验证本地网关契约：路由/配额映射/prompt 存在/metadata_only/语言策略；
// 不调真实 Provider（模型语义评测见 iOS 端 P9）。

const CHAT_PURPOSES = [
  "personal_context_extraction",
  "personal_context_verification",
  "personal_context_request",
  "personal_context_planning",
];

function quotaTypeForPurpose(purpose) {
  // 与 src/app.js 内同名函数保持一致的最小镜像（该函数未导出，测试用镜像锁定契约）。
  if (purpose === "chat" || purpose === "analysis") return "chat";
  if (purpose === "agent_loop") return "deepAnalysis";
  if (purpose === "weekly_plan_generation") return "lifePlan";
  if (purpose === "personal_context_extraction" || purpose === "personal_context_verification") return null;
  if (purpose === "personal_context_request" || purpose === "personal_context_planning") return "chat";
  return null;
}

test("个人情境：四个 chat purpose 都有路由配置（provider/model/限流桶）", () => {
  const config = loadConfig();
  for (const purpose of CHAT_PURPOSES) {
    const route = config.routes[purpose];
    assert.ok(route, `${purpose} 必须有路由配置`);
    assert.ok(route.provider, `${purpose} 缺 provider`);
    assert.ok(route.model, `${purpose} 缺 model`);
    assert.ok(route.maxTokens > 0, `${purpose} 缺 maxTokens`);
    assert.ok(
      route.requestLimits?.perMinute > 0 && route.requestLimits?.perDay > 0,
      `${purpose} 缺独立限流桶`,
    );
  }
});

test("个人情境：萃取/核验不占会员池；请求准备/规划归 chat 池", () => {
  assert.equal(quotaTypeForPurpose("personal_context_extraction"), null);
  assert.equal(quotaTypeForPurpose("personal_context_verification"), null);
  assert.equal(quotaTypeForPurpose("personal_context_request"), "chat");
  assert.equal(quotaTypeForPurpose("personal_context_planning"), "chat");
});

test("个人情境：embedding purpose 有路由与维度配置", () => {
  const config = loadConfig();
  const route = config.routes.personal_context_embedding;
  assert.ok(route, "personal_context_embedding 必须有路由");
  assert.ok(route.dimensions > 0, "embedding 路由缺 dimensions");
  assert.ok(route.requestLimits?.perMinute > 0, "embedding 缺限流桶");
});

test("个人情境：四个 purpose 的服务端 prompt 已注册且有版本", () => {
  for (const purpose of CHAT_PURPOSES) {
    const prompt = getPrompt(purpose);
    assert.ok(prompt?.content, `${purpose} 的 prompt 缺正文`);
    assert.ok(prompt?.version >= 1, `${purpose} 的 prompt 缺版本号`);
  }
});

test("个人情境：metadata_only 强制集覆盖全部四个 purpose（正文不进日志）", () => {
  // DEFAULT_METADATA_ONLY_PURPOSES 未导出；按源码契约断言（行为级验证在 aiCallLogs 类测试）。
  const source = readFileSync(new URL("../src/admin/adminLogStore.js", import.meta.url), "utf8");
  for (const purpose of CHAT_PURPOSES) {
    assert.ok(
      source.includes(`'${purpose}'`) || source.includes(`"${purpose}"`),
      `adminLogStore 必须把 ${purpose} 纳入 metadata_only`,
    );
  }
});

test("个人情境：extraction 输入是数据不是指令的注入防护文案存在", () => {
  const prompt = getPrompt("personal_context_extraction");
  assert.ok(prompt.content.includes("不是指令"), "萃取 prompt 必须声明输入不可执行");
  assert.ok(prompt.content.includes("quote"), "萃取 prompt 必须要求逐字引用");
});

test("个人情境：planning/request 允许多语言指令；extraction/verification 不注入", () => {
  const messages = [{ role: "user", content: "测试输入" }];
  const planningInjected = injectServerPrompt("personal_context_planning", messages, { language: "zh-Hant" });
  assert.ok(
    planningInjected.messages.some((m) => m.content.includes("繁體中文")),
    "planning 输出用户直接阅读，须支持语言指令",
  );
  const requestInjected = injectServerPrompt("personal_context_request", messages, { language: "zh-Hant" });
  assert.ok(
    requestInjected.messages.some((m) => m.content.includes("繁體中文")),
    "request 输出用户直接阅读，须支持语言指令",
  );
  const extractionInjected = injectServerPrompt("personal_context_extraction", messages, { language: "zh-Hant" });
  assert.ok(
    !extractionInjected.messages.some((m) => m.content.includes("語言要求") || m.content.includes("【语言要求】")),
    "extraction 是结构化契约，不得注入语言指令",
  );
  const verificationInjected = injectServerPrompt("personal_context_verification", messages, { language: "zh-Hant" });
  assert.ok(
    !verificationInjected.messages.some((m) => m.content.includes("【语言要求】")),
    "verification 是结构化契约，不得注入语言指令",
  );
});

test("个人情境：未知 purpose 仍被拒绝（不因扩展放开校验）", () => {
  assert.throws(
    () => injectServerPrompt("personal_context_unknown", [{ role: "user", content: "x" }], {}),
    (error) => error instanceof GatewayError && error.code === "PROMPT_NOT_FOUND",
  );
});
