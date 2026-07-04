import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

function createTestDatabase() {
  return createDatabase({ dbPath: ":memory:" });
}

function createTestApp(overrides = {}) {
  return createApp({
    database: createTestDatabase(),
    auth: { enforceAppAttest: false },
    dbPath: "/data/holo-backend.db",
    providers: {
      deepseek: {
        type: "openai-compatible",
        baseURL: "https://api.deepseek.com",
        apiKey: "secret-api-key",
      },
    },
    admin: {
      token: "secret-admin-token",
      username: "admin",
      password: "secret-password",
      sessionSecret: "secret-session",
    },
    routes: {
      intent: {
        provider: "deepseek",
        model: "deepseek-chat",
        temperature: 0,
        maxTokens: 4096,
      },
    },
    ...overrides,
  });
}

test("GET /v1/release/status returns safe runtime summary", async () => {
  const app = createTestApp();

  const response = await app.request("/v1/release/status");

  assert.equal(response.status, 200);
  const json = await response.json();
  assert.equal(json.ok, true);
  assert.equal(json.service, "holo-ai-gateway");
  assert.ok(json.generatedAt);
  assert.ok(Array.isArray(json.prompts));
  assert.ok(json.prompts.some((prompt) => prompt.type === "intent_recognition"));
  assert.equal(json.routes.intent.provider, "deepseek");
  assert.equal(json.routes.intent.model, "deepseek-chat");
  assert.equal(json.routes.intent.maxTokens, 4096);
  assert.equal(json.database.configured, true);
  assert.equal(json.database.path, undefined);

  const serialized = JSON.stringify(json);
  assert.equal(serialized.includes("secret-api-key"), false);
  assert.equal(serialized.includes("secret-admin-token"), false);
  assert.equal(serialized.includes("secret-password"), false);
  assert.equal(serialized.includes("secret-session"), false);
  assert.equal(serialized.includes("/data/holo-backend.db"), false);
});
