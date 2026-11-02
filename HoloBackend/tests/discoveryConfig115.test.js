// 「一个发现」1.1.5 S2：两阶段路由默认钉 deepseek-chat，不再回落聊天模型。
// 根因（2026-11-02 真机日志 + 生产 ai_call_logs）：生产 HOLO_CHAT_PROVIDER=qwen/qwen3.7-flash
// 开思考，候选阶段未配专属 env → 回落聊天模型，每次 60–71s，超客户端 60s 超时。
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { test } from "node:test";

import { discoveryRouteTarget, loadConfig } from "../src/config.js";

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

// 1.1.5 S7：候选输出上限须给思考草稿留余量。
// 根因（2026-11-02 21:08 真机 run DDA00A25 + 生产 ai_call_logs）：deepseek-chat 在
// reasoning_effort=low 下草稿与正文共用 max_tokens——20:32 成功那次 2817 token 中 1913 是草稿，
// 21:08 那次顶到 3072 → TRUNCATED_MODEL_RESPONSE；r17 试评亦有一次恰好 3072。
test("S7 候选默认输出上限 ≥ 8192（草稿+正文），核验保持 4096 不开思考", () => {
  const saved = {
    c: process.env.HOLO_DISCOVERY_CANDIDATE_MAX_TOKENS,
    v: process.env.HOLO_DISCOVERY_VERIFY_MAX_TOKENS,
  };
  delete process.env.HOLO_DISCOVERY_CANDIDATE_MAX_TOKENS;
  delete process.env.HOLO_DISCOVERY_VERIFY_MAX_TOKENS;
  try {
    const { routes } = loadConfig();
    assert.ok(routes.discovery_candidate_v1.maxTokens >= 8192, `candidate maxTokens=${routes.discovery_candidate_v1.maxTokens}`);
    assert.equal(routes.discovery_candidate_v1.reasoningEffort, "low");
    assert.equal(routes.discovery_verify_v1.maxTokens, 4096);
    assert.equal(routes.discovery_verify_v1.reasoningEffort, "none");
    // env 覆盖通道仍有效（回滚用）。DEFAULT_CONFIG 在模块加载时求值，须新起进程验证。
    const overridden = execFileSync(process.execPath, [
      "--input-type=module", "-e",
      "import { loadConfig } from './src/config.js'; process.stdout.write(String(loadConfig().routes.discovery_candidate_v1.maxTokens));",
    ], { cwd: new URL("..", import.meta.url), env: { ...process.env, HOLO_DISCOVERY_CANDIDATE_MAX_TOKENS: "3072" } }).toString();
    assert.equal(overridden, "3072");
  } finally {
    if (saved.c === undefined) delete process.env.HOLO_DISCOVERY_CANDIDATE_MAX_TOKENS; else process.env.HOLO_DISCOVERY_CANDIDATE_MAX_TOKENS = saved.c;
    if (saved.v === undefined) delete process.env.HOLO_DISCOVERY_VERIFY_MAX_TOKENS; else process.env.HOLO_DISCOVERY_VERIFY_MAX_TOKENS = saved.v;
  }
});
