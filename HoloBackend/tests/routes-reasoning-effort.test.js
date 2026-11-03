// §reasoning-budget（2026-10-09 全量补档）防回归：config.routes 里每个 AI purpose
// 必须显式配置 reasoningEffort。漏配的用途会吃模型默认满档思考（输出价计费），
// 2026-10 前 analysis / health_insight_generation 等 8 个用途裸奔是实锤教训。
// 新增 purpose 时若确实不该传 effort（如纯 embedding 通道），把键加进豁免清单并注明理由。
import assert from "node:assert/strict";
import { test } from "node:test";

import { loadConfig } from "../src/config.js";

// 非 LLM 生成通道（无思考概念）：embedding 向量通道。
const NON_LLM_EXEMPT = new Set(["thought_embedding", "personal_context_embedding"]);

const VALID_EFFORTS = new Set(["none", "low", "medium", "high"]);

test("config.routes 每个 LLM purpose 都显式配置 reasoningEffort", () => {
  const config = loadConfig();
  const missing = [];
  const invalid = [];
  for (const [purpose, route] of Object.entries(config.routes)) {
    if (NON_LLM_EXEMPT.has(purpose)) continue;
    if (route.reasoningEffort === undefined || route.reasoningEffort === null || route.reasoningEffort === "") {
      missing.push(purpose);
    } else if (!VALID_EFFORTS.has(route.reasoningEffort)) {
      invalid.push(`${purpose}=${route.reasoningEffort}`);
    }
  }
  assert.deepEqual(missing, [], `以下 purpose 未配 reasoningEffort（将吃默认满档思考）: ${missing.join(", ")}`);
  assert.deepEqual(invalid, [], `以下 purpose 的 reasoningEffort 取值非法: ${invalid.join(", ")}`);
});
