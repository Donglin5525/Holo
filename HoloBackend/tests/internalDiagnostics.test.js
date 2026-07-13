import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createHoloSessionService } from "../src/auth/holoSession.js";
import { createDatabase } from "../src/db/database.js";

const SESSION_SECRET = "holo-internal-diagnostics-test-secret-123456789";

function createTestApp() {
  const holoSessionService = createHoloSessionService({
    secret: SESSION_SECRET,
    internalSubjects: ["owner-sub"],
  });
  const app = createApp({
    database: createDatabase({ dbPath: ":memory:" }),
    auth: { enforceAppAttest: false },
    appleIdentityVerifier: {
      async verify(token) {
        if (token === "owner-apple-token") return { sub: "owner-sub" };
        if (token === "user-apple-token") return { sub: "user-sub" };
        throw new Error("invalid Apple token");
      },
    },
    holoSessionService,
  });
  return { app, holoSessionService };
}

async function createSession(app, identityToken) {
  const response = await app.request("/v1/auth/apple/session", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ identityToken }),
  });
  return { response, json: await response.json() };
}

test("Apple session only grants internal diagnostics to the configured owner", async () => {
  const { app } = createTestApp();
  const owner = await createSession(app, "owner-apple-token");
  const user = await createSession(app, "user-apple-token");

  assert.equal(owner.response.status, 200);
  assert.equal(owner.json.internalDiagnostics, true);
  assert.equal(user.response.status, 200);
  assert.equal(user.json.internalDiagnostics, false);
  assert.equal(owner.response.headers.get("cache-control"), "no-store");
});

test("invalid Apple identity fails closed", async () => {
  const { app } = createTestApp();
  const result = await createSession(app, "invalid-token");
  assert.equal(result.response.status, 401);
  assert.equal(result.json.error.code, "INVALID_APPLE_IDENTITY");
});

test("AI response exposes request ID and only owner session can fetch the full hot log", async () => {
  const { app } = createTestApp();
  const owner = await createSession(app, "owner-apple-token");
  const user = await createSession(app, "user-apple-token");
  const chat = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "diagnostic-device" },
    body: JSON.stringify({
      purpose: "chat",
      messages: [{ role: "user", content: "仅用于诊断的原始内容" }],
    }),
  });
  const requestId = chat.headers.get("x-holo-request-id");
  assert.ok(requestId);

  const forbidden = await app.request(`/v1/internal/ai-logs/${requestId}`, {
    headers: { authorization: `Bearer ${user.json.token}` },
  });
  assert.equal(forbidden.status, 403);

  const allowed = await app.request(`/v1/internal/ai-logs/${requestId}`, {
    headers: { authorization: `Bearer ${owner.json.token}` },
  });
  assert.equal(allowed.status, 200);
  assert.equal(allowed.headers.get("cache-control"), "no-store");
  const body = await allowed.json();
  assert.equal(body.log.id, requestId);
  assert.equal(body.log.request.messages[0].content, "仅用于诊断的原始内容");
});

test("streaming AI response also exposes the same request ID contract", async () => {
  const { app } = createTestApp();
  const chat = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: { "content-type": "application/json", "x-holo-device-id": "diagnostic-device" },
    body: JSON.stringify({
      purpose: "chat",
      stream: true,
      messages: [{ role: "user", content: "stream diagnostic" }],
    }),
  });
  assert.equal(chat.status, 200);
  assert.ok(chat.headers.get("x-holo-request-id"));
  await chat.text();
});
