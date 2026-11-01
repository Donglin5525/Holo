// 「一个发现」1.1.5 S2：两阶段路由默认钉 deepseek-chat，不再回落聊天模型。
// 根因（2026-11-02 真机日志 + 生产 ai_call_logs）：生产 HOLO_CHAT_PROVIDER=qwen/qwen3.7-flash
// 开思考，候选阶段未配专属 env → 回落聊天模型，每次 60–71s，超客户端 60s 超时。
import assert from "node:assert/strict";
import { test } from "node:test";

import { discoveryRouteTarget } from "../src/config.js";

const PROD_LIKE = {
  HOLO_CHAT_PROVIDER: "qwen",
  HOLO_CHAT_MODEL: "qwen3.7-flash",
  DEEPSEEK_API_KEY: "sk-test",
};

test("S2 生产形态（聊天=qwen、有 DeepSeek 钥匙、候选未配专属 env）→ 候选钉 deepseek-chat", () => {
  assert.deepEqual(discoveryRouteTarget(PROD_LIKE, "CANDIDATE"), { provider: "deepseek", model: "deepseek-chat" });
});

test("S2 核验同口径；生产已显式配置的核验 env 保持不变", () => {
  assert.deepEqual(discoveryRouteTarget(PROD_LIKE, "VERIFY"), { provider: "deepseek", model: "deepseek-chat" });
  assert.deepEqual(
    discoveryRouteTarget({ ...PROD_LIKE, HOLO_DISCOVERY_VERIFY_PROVIDER: "deepseek", HOLO_DISCOVERY_VERIFY_MODEL: "deepseek-chat" }, "VERIFY"),
    { provider: "deepseek", model: "deepseek-chat" },
  );
});

test("S2 显式 env 仍可覆盖（回滚/试验通道）", () => {
  assert.deepEqual(
    discoveryRouteTarget({ ...PROD_LIKE, HOLO_DISCOVERY_CANDIDATE_PROVIDER: "qwen", HOLO_DISCOVERY_CANDIDATE_MODEL: "qwen-plus" }, "CANDIDATE"),
    { provider: "qwen", model: "qwen-plus" },
  );
  // 只配 provider 不配 model：沿用旧口径回落聊天模型名
  assert.deepEqual(
    discoveryRouteTarget({ ...PROD_LIKE, HOLO_DISCOVERY_CANDIDATE_PROVIDER: "qwen" }, "CANDIDATE"),
    { provider: "qwen", model: "qwen3.7-flash" },
  );
  // 只配 model：provider 仍取 deepseek（有钥匙）
  assert.deepEqual(
    discoveryRouteTarget({ ...PROD_LIKE, HOLO_DISCOVERY_CANDIDATE_MODEL: "deepseek-reasoner" }, "CANDIDATE"),
    { provider: "deepseek", model: "deepseek-reasoner" },
  );
});

test("S2 无 DeepSeek 钥匙的开发/测试环境保持旧回落（聊天路由 / mock），不引入不可用的 provider", () => {
  assert.deepEqual(discoveryRouteTarget({}, "CANDIDATE"), { provider: "mock", model: "holo-mock" });
  assert.deepEqual(
    discoveryRouteTarget({ HOLO_CHAT_PROVIDER: "qwen", HOLO_CHAT_MODEL: "qwen3.7-flash" }, "CANDIDATE"),
    { provider: "qwen", model: "qwen3.7-flash" },
  );
});
