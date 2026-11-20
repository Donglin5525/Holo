import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { loadConfig } from "../src/config.js";
import { BACKGROUND_PURPOSES } from "../src/usage/backgroundCostGuard.js";
import { promptTypeForPurpose } from "../src/prompts/serverPromptPolicy.js";

// 2026-11-20 记忆萃取重构 Phase 2：portrait_synthesis purpose 契约测试
// 1) routes.portrait_synthesis 已注册且参数受控（maxTokens<=2500, none 思考档, 日限流有限）
// 2) 归属 BACKGROUND_PURPOSES 后台成本桶
// 3) serverPromptPolicy 与 defaultPrompts.json 双侧注册且包含五维度与三态契约

test("portrait_synthesis 路由已注册且参数受控", () => {
  const config = loadConfig();
  const route = config.routes?.portrait_synthesis;
  assert.ok(route, "routes.portrait_synthesis 必须注册");
  assert.ok(route.maxTokens > 0 && route.maxTokens <= 2500, "portrait_synthesis maxTokens 应受控（≤2500）");
  assert.equal(route.reasoningEffort, "none", "portrait_synthesis 应使用 none 思考档控成本");
  assert.ok(route.requestLimits?.perDay && route.requestLimits.perDay <= 20, "日限流必须存在且有限（≤20）");
  assert.notEqual(route, config.routes.chat, "portrait_synthesis 独立于前台 chat 路由");
});

test("portrait_synthesis 归属后台成本桶", () => {
  assert.ok(BACKGROUND_PURPOSES.has("portrait_synthesis"),
    "portrait_synthesis 必须在 BACKGROUND_PURPOSES 中受后台总预算约束");
});

test("portrait_synthesis 服务端 prompt 已注册且包含五维度契约", () => {
  assert.equal(promptTypeForPurpose("portrait_synthesis"), "portrait_synthesis");
  const promptsPath = path.resolve(process.cwd(), "src/prompts/defaultPrompts.json");
  const prompts = JSON.parse(fs.readFileSync(promptsPath, "utf8"));
  const prompt = prompts.portrait_synthesis;
  assert.equal(typeof prompt, "string");
  assert.ok(prompt.includes("crossDomainInsight"), "prompt 必须包含 crossDomainInsight 维度");
  assert.ok(prompt.includes("rejectedBlacklist"), "prompt 必须要求遵守 rejectedBlacklist");
  assert.ok(prompt.includes("needsClarification"), "prompt 必须包含 needsClarification 置信态");
});
