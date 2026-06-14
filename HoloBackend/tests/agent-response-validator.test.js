import assert from "node:assert/strict";
import { test } from "node:test";

import { validateAgentLoopContent } from "../src/agentResponseValidator.js";

test("缺少 status 返回 invalid", () => {
  const result = validateAgentLoopContent(JSON.stringify({ reasoning: "无 status" }));
  assert.equal(result.valid, false);
  assert.match(result.error, /status/i);
});

test("status 不在枚举内返回 invalid", () => {
  const result = validateAgentLoopContent(JSON.stringify({ status: "unknown_status" }));
  assert.equal(result.valid, false);
});

test("need_tools 但 toolRequests 不是数组返回 invalid", () => {
  const result = validateAgentLoopContent(
    JSON.stringify({ status: "need_tools", toolRequests: "not-an-array" })
  );
  assert.equal(result.valid, false);
  assert.match(result.error, /toolRequests/i);
});

test("final_claims 但 claims 不是数组返回 invalid", () => {
  const result = validateAgentLoopContent(
    JSON.stringify({ status: "final_claims", claims: "not-an-array" })
  );
  assert.equal(result.valid, false);
  assert.match(result.error, /claims/i);
});

test("合法 JSON 返回 valid 并带 parsed", () => {
  const result = validateAgentLoopContent(
    JSON.stringify({ status: "final_claims", claims: [], reasoning: "证据充分" })
  );
  assert.equal(result.valid, true);
  assert.equal(result.parsed.status, "final_claims");
});

test("agent_loop 旧 claim.text 会被规范化为 displayText", () => {
  const result = validateAgentLoopContent(
    JSON.stringify({
      status: "final_claims",
      claims: [{ id: "c1", text: "餐饮消费集中在晚餐", metricAssertions: [], evidenceIDs: ["e1"] }],
      reasoning: "证据充分",
    })
  );

  assert.equal(result.valid, true);
  assert.equal(result.parsed.claims[0].displayText, "餐饮消费集中在晚餐");
  assert.equal(result.parsed.claims[0].type, "observation");
  assert.equal(result.parsed.claims[0].confidence, 0.5);
  assert.match(result.content, /displayText/);
});

test("final_claims claim 缺少 displayText 和 text 返回 invalid", () => {
  const result = validateAgentLoopContent(
    JSON.stringify({
      status: "final_claims",
      claims: [{ id: "c1", metricAssertions: [], evidenceIDs: ["e1"] }],
      reasoning: "证据充分",
    })
  );

  assert.equal(result.valid, false);
  assert.match(result.error, /displayText/);
});

test("非法 JSON 文本返回 invalid", () => {
  const result = validateAgentLoopContent("这不是 JSON {");
  assert.equal(result.valid, false);
  assert.match(result.error, /JSON/i);
});

test("markdown code fence 包裹的 agent JSON 可以解析", () => {
  const result = validateAgentLoopContent(
    '```json\n{"status":"final_claims","reasoning":"ok","toolRequests":[],"claims":[],"warnings":[]}\n```'
  );
  assert.equal(result.valid, true);
  assert.equal(result.parsed.status, "final_claims");
});
