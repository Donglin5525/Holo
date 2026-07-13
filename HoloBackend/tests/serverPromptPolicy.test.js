import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";
import { injectServerPrompt, promptTypeForPurpose, renderPromptVariables } from "../src/prompts/serverPromptPolicy.js";

test("every public AI purpose resolves to a server-owned Prompt", () => {
  const purposes = [
    "chat", "analysis", "intent", "flexible_query_planner", "insight", "health_insight_generation",
    "thought_voice_summary", "memory_observer", "finance_action_parser", "task_action_parser",
    "thought_organization", "thought_tag_convergence", "category_pattern_induction", "agent_loop",
  ];
  for (const purpose of purposes) assert.ok(promptTypeForPurpose(purpose), purpose);
});

test("server Prompt is always the first upstream system message", () => {
  createApp({ database: createDatabase({ dbPath: ":memory:" }) });
  const result = injectServerPrompt("chat", [{ role: "user", content: "你好" }]);
  assert.equal(result.promptType, "system_prompt");
  assert.ok(result.promptVersion >= 1);
  assert.equal(result.messages[0].role, "system");
  assert.match(result.messages[0].content, /Holo|数据|助手/i);
  assert.deepEqual(result.messages[1], { role: "user", content: "你好" });
});

test("server renders time variables without exposing raw placeholders upstream", () => {
  const rendered = renderPromptVariables(
    "{{todayISODate}}|{{thirtyDaysAgoDate}}|{{currentYear}}|{{currentTime}}",
    new Date("2026-07-13T04:34:00.000Z"),
  );
  assert.equal(rendered, "2026-07-13|2026-06-14|2026|12:34");
});

test("production app does not register public Prompt endpoints", async () => {
  const app = createApp({ database: createDatabase({ dbPath: ":memory:" }) });
  for (const path of ["/v1/prompts", "/v1/prompts/meta", "/v1/prompts/system_prompt"]) {
    const response = await app.request(path);
    assert.equal(response.status, 404, path);
  }
});
