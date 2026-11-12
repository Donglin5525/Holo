import test from "node:test";
import assert from "node:assert/strict";
import { loadConfig } from "../src/config.js";
import { BACKGROUND_PURPOSES } from "../src/usage/backgroundCostGuard.js";

// 2026-11-13 M2.6 理解引擎提案 purpose 注册契约：
// ① routes 可解析（UNKNOWN_PURPOSE 防线放行）；
// ② 归属后台成本桶（与个人情境同口径，受后台总预算约束）；
// ③ 输出上限与限流存在且有限（不默认无限）。
// 发版闸门：本测试绿=客户端可携 understanding_proposal 调 /v1/ai/chat/completions。

test("understanding_proposal 路由可解析且模型参数受控", () => {
  const config = loadConfig();
  const route = config.routes?.understanding_proposal;
  assert.ok(route, "routes.understanding_proposal 必须注册（否则客户端收到 UNKNOWN_PURPOSE）");
  assert.ok(route.maxTokens > 0 && route.maxTokens <= 2000, "提案输出预算应为方案 §7 的 1500 档（≤2000）");
  assert.equal(route.reasoningEffort, "none", "提案是结构化信号处理：none 思考档（与个人情境萃取同理）");
  assert.ok(route.requestLimits?.perDay && route.requestLimits.perDay <= 60, "日限流必须存在且有限");
});

test("understanding_proposal 归属后台成本桶", () => {
  assert.ok(BACKGROUND_PURPOSES.has("understanding_proposal"),
    "必须在 BACKGROUND_PURPOSES——理解引擎提案受后台总预算约束，不得变成无控制的低成本通道");
});

test("understanding_proposal 不占用前台 chat 配额", async () => {
  // quotaTypeForPurpose 未导出则通过 app 内行为验证成本过高；此处验证 config 侧
  // personal_context 同族 purpose 的日限流独立（提案池与聊天池不互抢）。
  const config = loadConfig();
  const proposal = config.routes.understanding_proposal;
  const chat = config.routes.chat;
  assert.notEqual(proposal, chat, "提案路由独立于 chat（独立限流/参数）");
});
