import assert from "node:assert/strict";
import { test } from "node:test";

import { createApp } from "../src/app.js";
import { createDatabase } from "../src/db/database.js";

test("POST /v1/app-attest/challenge returns short-lived challenge", async () => {
  const app = createApp({
    database: createDatabase({ dbPath: ':memory:' }),
    auth: { enforceAppAttest: false },
  });

  const response = await app.request("/v1/app-attest/challenge", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ deviceId: "device-attest-a" }),
  });

  assert.equal(response.status, 200);
  const json = await response.json();
  assert.equal(json.expiresInSeconds, 300);
  assert.equal(typeof json.challenge, "string");
  assert.ok(json.challenge.length >= 32);
});

test("POST /v1/app-attest/assert allows debug assertion when enforcement is disabled", async () => {
  const app = createApp({
    database: createDatabase({ dbPath: ':memory:' }),
    auth: { enforceAppAttest: false },
  });

  const response = await app.request("/v1/app-attest/assert", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ deviceId: "device-attest-b", debug: true }),
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    mode: "debug",
  });
});

test("POST /v1/asr/transcriptions returns mock transcript for uploaded audio", async () => {
  const app = createApp({
    database: createDatabase({ dbPath: ':memory:' }),
    auth: { enforceAppAttest: false },
    limits: {
      chatRequestsPerMinute: 20,
      chatRequestsPerDay: 50,
      asrRequestsPerMinute: 2,
      asrRequestsPerDay: 10,
      asrMaxBytes: 1024,
    },
  });
  const body = new FormData();
  body.set("audio", new Blob(["fake-audio"], { type: "audio/wav" }), "sample.wav");

  const response = await app.request("/v1/asr/transcriptions", {
    method: "POST",
    headers: {
      "x-holo-device-id": "device-asr-a",
    },
    body,
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    text: "Mock transcript",
    provider: "mock",
    duration: null,
    confidence: null,
  });
});

test("POST /v1/asr/transcriptions passes uploaded audio to configured ASR provider", async () => {
  let captured = null;
  const app = createApp({
    database: createDatabase({ dbPath: ':memory:' }),
    auth: { enforceAppAttest: false },
    limits: {
      chatRequestsPerMinute: 20,
      chatRequestsPerDay: 50,
      asrRequestsPerMinute: 2,
      asrRequestsPerDay: 10,
      asrMaxBytes: 1024,
    },
    asrProvider: {
      async transcribe(input) {
        captured = input;
        return {
          text: "真实转写结果",
          provider: "test-asr",
          duration: null,
          confidence: null,
        };
      },
    },
  });
  const body = new FormData();
  body.set("audio", new Blob(["voice-bytes"], { type: "audio/wav" }), "voice.wav");
  body.set("locale", "zh-CN");

  const response = await app.request("/v1/asr/transcriptions", {
    method: "POST",
    headers: {
      "x-holo-device-id": "device-asr-provider",
    },
    body,
  });

  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    text: "真实转写结果",
    provider: "test-asr",
    duration: null,
    confidence: null,
  });
  assert.equal(captured.fileName, "voice.wav");
  assert.equal(captured.mimeType, "audio/wav");
  assert.equal(captured.locale, "zh-CN");
  assert.deepEqual(new Uint8Array(captured.audio), new Uint8Array(await new Blob(["voice-bytes"]).arrayBuffer()));
});
