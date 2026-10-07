// 设备会话（2026-10-04 体检 S01）测试：
// 服务层——挑战一次性/签名验签/设备号格式；应用层——强制开关下的准入与拒绝负例。
import assert from "node:assert/strict";
import { test } from "node:test";
import { generateKeyPairSync, sign as cryptoSign } from "node:crypto";

import { createApp } from "../src/app.js";
import { loadConfig } from "../src/config.js";
import { createDatabase } from "../src/db/database.js";
import {
  bindingPayload,
  createDeviceSessionService,
  ed25519PublicKeyObject,
} from "../src/auth/deviceSession.js";

const NOW = new Date("2026-10-04T00:00:00.000Z");
const SECRET = "unit-test-device-session-secret-0123456789";
const DEVICE_ID = "319879F7-BC56-465F-B089-8DD56BACC0F0";

function makeKeyPair() {
  const { privateKey, publicKey } = generateKeyPairSync("ed25519");
  const publicKeyRaw = publicKey.export({ type: "spki", format: "der" }).subarray(-32);
  return {
    privateKey,
    publicKeyBase64: publicKeyRaw.toString("base64"),
    publicKeyRaw,
  };
}

function signPayload(privateKey, deviceId, challenge) {
  return cryptoSign(null, Buffer.from(bindingPayload(deviceId, challenge), "utf8"), privateKey)
    .toString("base64");
}

test("设备会话服务：有效绑定签名换取会话并可验证回同一设备", async () => {
  const service = createDeviceSessionService({ secret: SECRET, now: () => NOW });
  const { privateKey, publicKeyBase64 } = makeKeyPair();
  const { challenge } = service.issueChallenge();
  const token = await service.issueSession({
    deviceId: DEVICE_ID,
    publicKey: publicKeyBase64,
    signature: signPayload(privateKey, DEVICE_ID, challenge),
    challenge,
  });
  const session = await service.verifySession(token);
  assert.equal(session.sub, DEVICE_ID);
  assert.equal(service.pendingChallengeCount(), 0);
});

test("设备会话服务：错误签名被拒绝", async () => {
  const service = createDeviceSessionService({ secret: SECRET, now: () => NOW });
  const { privateKey, publicKeyBase64 } = makeKeyPair();
  const other = makeKeyPair();
  const { challenge } = service.issueChallenge();
  await assert.rejects(() =>
    service.issueSession({
      deviceId: DEVICE_ID,
      publicKey: publicKeyBase64,
      signature: signPayload(other.privateKey, DEVICE_ID, challenge),
      challenge,
    }),
  );
});

test("设备会话服务：挑战一次性——重放被拒绝", async () => {
  const service = createDeviceSessionService({ secret: SECRET, now: () => NOW });
  const { privateKey, publicKeyBase64 } = makeKeyPair();
  const { challenge } = service.issueChallenge();
  await service.issueSession({
    deviceId: DEVICE_ID,
    publicKey: publicKeyBase64,
    signature: signPayload(privateKey, DEVICE_ID, challenge),
    challenge,
  });
  await assert.rejects(() =>
    service.issueSession({
      deviceId: DEVICE_ID,
      publicKey: publicKeyBase64,
      signature: signPayload(privateKey, DEVICE_ID, challenge),
      challenge,
    }),
  );
});

test("设备会话服务：非 UUID 设备号被拒绝", async () => {
  const service = createDeviceSessionService({ secret: SECRET, now: () => NOW });
  const { privateKey, publicKeyBase64 } = makeKeyPair();
  const { challenge } = service.issueChallenge();
  await assert.rejects(() =>
    service.issueSession({
      deviceId: "debug-device",
      publicKey: publicKeyBase64,
      signature: signPayload(privateKey, "debug-device", challenge),
      challenge,
    }),
  );
});

test("设备会话服务：SPKI 前缀公钥对象可验原始 32 字节钥匙", () => {
  const { publicKeyRaw } = makeKeyPair();
  const keyObject = ed25519PublicKeyObject(publicKeyRaw.toString("base64"));
  assert.equal(keyObject.asymmetricKeyType, "ed25519");
});

function createEnforcementApp({ enforce }) {
  const service = createDeviceSessionService({ secret: SECRET, now: () => NOW });
  const app = createApp({
    database: createDatabase({ dbPath: ":memory:" }),
    auth: {
      enforceAppAttest: false,
      enforceDeviceSession: enforce,
      sessionSecret: SECRET,
    },
    deviceSessionService: service,
    exposePromptEndpointsForTests: true,
  });
  return { app, service };
}

async function issueTokenFor(service, deviceId = DEVICE_ID) {
  const { privateKey, publicKeyBase64 } = makeKeyPair();
  const { challenge } = service.issueChallenge();
  return service.issueSession({
    deviceId,
    publicKey: publicKeyBase64,
    signature: signPayload(privateKey, deviceId, challenge),
    challenge,
  });
}

test("应用层：开关关闭时维持旧行为——仅凭设备号头放行", async () => {
  const { app } = createEnforcementApp({ enforce: false });
  const response = await app.request("/v1/subscription/status", {
    headers: { "X-Holo-Device-Id": DEVICE_ID },
  });
  assert.equal(response.status, 200);
});

test("应用层：开关开启时无会话被拒（401）", async () => {
  const { app } = createEnforcementApp({ enforce: true });
  const response = await app.request("/v1/subscription/status", {
    headers: { "X-Holo-Device-Id": DEVICE_ID },
  });
  assert.equal(response.status, 401);
  const body = await response.json();
  assert.equal(body.error?.code ?? body.code, "DEVICE_SESSION_REQUIRED");
});

test("应用层：开关开启时有效同主体会话放行", async () => {
  const { app, service } = createEnforcementApp({ enforce: true });
  const token = await issueTokenFor(service);
  const response = await app.request("/v1/subscription/status", {
    headers: {
      "X-Holo-Device-Id": DEVICE_ID,
      Authorization: `Bearer ${token}`,
    },
  });
  assert.equal(response.status, 200);
});

test("应用层：会话主体与设备号不一致被拒（403）", async () => {
  const { app, service } = createEnforcementApp({ enforce: true });
  const token = await issueTokenFor(service, "11111111-2222-3333-4444-555555555555");
  const response = await app.request("/v1/subscription/status", {
    headers: {
      "X-Holo-Device-Id": DEVICE_ID,
      Authorization: `Bearer ${token}`,
    },
  });
  assert.equal(response.status, 403);
});

test("应用层：开关开启时无设备号头且无会话被拒（401），不再落 debug-device", async () => {
  const { app } = createEnforcementApp({ enforce: true });
  const response = await app.request("/v1/subscription/status");
  assert.equal(response.status, 401);
});

test("应用层：设备会话端点全流程——挑战→会话", async () => {
  const { app, service } = createEnforcementApp({ enforce: true });
  const challengeResponse = await app.request("/v1/auth/device/challenge", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({}),
  });
  assert.equal(challengeResponse.status, 200);
  const { challenge, expiresInSeconds } = await challengeResponse.json();
  assert.ok(challenge.length > 0);
  assert.ok(expiresInSeconds > 0);

  const { privateKey, publicKeyBase64 } = makeKeyPair();
  const sessionResponse = await app.request("/v1/auth/device/session", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      deviceId: DEVICE_ID,
      publicKey: publicKeyBase64,
      signature: signPayload(privateKey, DEVICE_ID, challenge),
      challenge,
    }),
  });
  assert.equal(sessionResponse.status, 200);
  const { token } = await sessionResponse.json();
  const session = await service.verifySession(token);
  assert.equal(session.sub, DEVICE_ID);
});
