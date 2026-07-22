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

test("App Attest issues an instance session, rejects replay, and protects AI routes", async () => {
  const keyId = "A".repeat(43);
  const app = createApp({
    database: createDatabase({ dbPath: ':memory:' }),
    auth: {
      enforceAppAttest: true,
      sessionSecret: "test-app-attest-session-secret-at-least-32-characters",
      appAttestTeamId: "TEAMID1234",
      appAttestBundleId: "com.example.holo",
    },
    appAttestVerifier: {
      verifyAttestation(input) {
        assert.equal(input.keyId, keyId);
        assert.equal(input.attestationObject, "fake-attestation");
        return {
          publicKeyPem: "fake-public-key",
          receipt: "fake-receipt",
          signCount: 0,
          environment: "development",
        };
      },
      verifyAssertion(input) {
        assert.equal(input.publicKeyPem, "fake-public-key");
        assert.equal(input.assertionObject, "fake-assertion");
        return { signCount: 1 };
      },
    },
  });

  const challengeResponse = await app.request("/v1/app-attest/challenge", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ keyId }),
  });
  const challenge = await challengeResponse.json();
  assert.equal(challengeResponse.status, 200);

  const attestationBody = {
    keyId,
    challengeId: challenge.challengeId,
    challenge: challenge.challenge,
    attestationObject: "fake-attestation",
  };
  const attestationResponse = await app.request("/v1/app-attest/attest", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(attestationBody),
  });
  assert.equal(attestationResponse.status, 200);
  const session = await attestationResponse.json();
  assert.equal(session.mode, "app_attest");
  assert.equal(typeof session.token, "string");

  const replayResponse = await app.request("/v1/app-attest/attest", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(attestationBody),
  });
  assert.equal(replayResponse.status, 409);
  assert.equal((await replayResponse.json()).error.code, "INVALID_APP_ATTEST_CHALLENGE");

  const denied = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-holo-device-id": "spoofed-device",
    },
    body: JSON.stringify({ messages: [{ role: "user", content: "hello" }] }),
  });
  assert.equal(denied.status, 401);
  assert.equal((await denied.json()).error.code, "APP_ATTEST_REQUIRED");

  const allowed = await app.request("/v1/ai/chat/completions", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: "Bearer " + session.token,
    },
    body: JSON.stringify({ messages: [{ role: "user", content: "hello" }] }),
  });
  assert.equal(allowed.status, 200);

  const assertionChallengeResponse = await app.request("/v1/app-attest/challenge", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ keyId }),
  });
  const assertionChallenge = await assertionChallengeResponse.json();
  const assertionResponse = await app.request("/v1/app-attest/assert", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      keyId,
      challengeId: assertionChallenge.challengeId,
      challenge: assertionChallenge.challenge,
      assertionObject: "fake-assertion",
    }),
  });
  assert.equal(assertionResponse.status, 200);
  assert.equal((await assertionResponse.json()).mode, "app_attest");
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
