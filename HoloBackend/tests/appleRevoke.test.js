import assert from "node:assert/strict";
import { test } from "node:test";

import { exportPKCS8, generateKeyPair, jwtVerify } from "jose";

import { createAppleRevokeService } from "../src/auth/appleRevokeService.js";

const APPLE_AUDIENCE = "https://appleid.apple.com";
const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
const TEAM_ID = "6WZ5TXGPQY";
const KEY_ID = "ABC123KEYID";
const CLIENT_ID = "com.tangyuxuan.holo-app";

async function makeServiceFixture(overrides = {}) {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const privateKeyPem = await exportPKCS8(privateKey);

  const service = createAppleRevokeService({
    teamId: TEAM_ID,
    keyId: KEY_ID,
    clientId: CLIENT_ID,
    privateKeyPem,
    ...overrides,
  });

  return { service, privateKeyPem, publicKey };
}

test("isConfigured returns true when all credentials are present", async () => {
  const { service } = await makeServiceFixture();
  assert.equal(service.isConfigured(), true);
});

test("isConfigured returns false when any credential is missing", async () => {
  const { privateKeyPem } = await makeServiceFixture();
  assert.equal(
    createAppleRevokeService({ teamId: "", keyId: KEY_ID, clientId: CLIENT_ID, privateKeyPem }).isConfigured(),
    false,
  );
  assert.equal(
    createAppleRevokeService({ teamId: TEAM_ID, keyId: "", clientId: CLIENT_ID, privateKeyPem }).isConfigured(),
    false,
  );
  assert.equal(
    createAppleRevokeService({ teamId: TEAM_ID, keyId: KEY_ID, clientId: "", privateKeyPem }).isConfigured(),
    false,
  );
  assert.equal(
    createAppleRevokeService({ teamId: TEAM_ID, keyId: KEY_ID, clientId: CLIENT_ID, privateKeyPem: "" }).isConfigured(),
    false,
  );
});

test("buildClientSecret produces a valid ES256 JWT signed with the configured key", async () => {
  const { service, publicKey } = await makeServiceFixture();
  const now = new Date("2026-08-13T00:00:00.000Z");
  const secret = await service.buildClientSecret(now);

  const { payload, protectedHeader } = await jwtVerify(secret, publicKey, {
    algorithms: ["ES256"],
    issuer: TEAM_ID,
    audience: APPLE_AUDIENCE,
    subject: CLIENT_ID,
  });

  assert.equal(protectedHeader.alg, "ES256");
  assert.equal(protectedHeader.kid, KEY_ID);
  assert.equal(payload.iss, TEAM_ID);
  assert.equal(payload.sub, CLIENT_ID);
  assert.equal(payload.aud, APPLE_AUDIENCE);
  assert.equal(typeof payload.iat, "number");
  assert.ok(payload.exp > payload.iat);
  assert.equal(payload.exp - payload.iat, 15777000);
});

test("revoke posts the expected form body to Apple and resolves ok on 2xx", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return { ok: true, status: 200 };
  };

  const { service } = await makeServiceFixture({ fetch: fetchImpl });

  // P02（2026-10-04 体检）：撤销只认 refresh token——此前误传 identity token
  // 且 hint 用 id_token，撤销从未真正生效
  const refreshToken = "refresh-token-from-code-exchange";
  const result = await service.revoke(refreshToken);

  assert.deepEqual(result, { ok: true });
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, APPLE_REVOKE_URL);
  assert.equal(calls[0].init.method, "POST");
  assert.equal(calls[0].init.headers["Content-Type"], "application/x-www-form-urlencoded");

  const params = new URLSearchParams(calls[0].init.body);
  assert.equal(params.get("client_id"), CLIENT_ID);
  assert.equal(params.get("token"), refreshToken);
  assert.equal(params.get("token_type_hint"), "refresh_token");
  const clientSecret = params.get("client_secret");
  assert.ok(typeof clientSecret === "string" && clientSecret.length > 0);
});

test("exchangeAuthorizationCode swaps the code for a refresh token", async () => {
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push({ url, init });
    return {
      ok: true,
      status: 200,
      json: async () => ({ access_token: "at", refresh_token: "rt-123", id_token: "idt" }),
    };
  };

  const { service } = await makeServiceFixture({ fetch: fetchImpl });
  const { refreshToken } = await service.exchangeAuthorizationCode("auth-code-abc");

  assert.equal(refreshToken, "rt-123");
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, "https://appleid.apple.com/auth/oauth2/token");
  const params = new URLSearchParams(calls[0].init.body);
  assert.equal(params.get("grant_type"), "authorization_code");
  assert.equal(params.get("code"), "auth-code-abc");
  assert.equal(params.get("client_id"), CLIENT_ID);
  assert.ok(params.get("client_secret"));
});

test("exchangeAuthorizationCode throws when Apple omits the refresh token", async () => {
  const fetchImpl = async () => ({
    ok: true,
    status: 200,
    json: async () => ({ access_token: "at" }),
  });
  const { service } = await makeServiceFixture({ fetch: fetchImpl });
  await assert.rejects(() => service.exchangeAuthorizationCode("code"), /no refresh token/);
});

test("revoke throws when Apple responds with a non-2xx status", async () => {
  const fetchImpl = async () => ({ ok: false, status: 400 });
  const { service } = await makeServiceFixture({ fetch: fetchImpl });
  await assert.rejects(() => service.revoke("refresh-token"), /Apple revoke failed with status 400/);
});

test("revoke rejects an empty token before calling Apple", async () => {
  let called = false;
  const fetchImpl = async () => {
    called = true;
    return { ok: true, status: 200 };
  };
  const { service } = await makeServiceFixture({ fetch: fetchImpl });
  await assert.rejects(() => service.revoke(""), /Apple refresh token is required/);
  assert.equal(called, false);
});

test("revoke throws APPLE_REVOKE_NOT_CONFIGURED when credentials are missing", () => {
  const service = createAppleRevokeService({
    teamId: "",
    keyId: "",
    clientId: "",
    privateKeyPem: "",
  });
  return assert.rejects(() => service.revoke("identity-token"), /APPLE_REVOKE_NOT_CONFIGURED/);
});

test("buildClientSecret tolerates a PEM whose newlines were flattened to literal \\n", async () => {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const privateKeyPem = await exportPKCS8(privateKey);
  // 模拟环境变量里换行被转成字面 \n 的情况
  const flattenedPem = privateKeyPem.replace(/\n/g, "\\n");

  const service = createAppleRevokeService({
    teamId: TEAM_ID,
    keyId: KEY_ID,
    clientId: CLIENT_ID,
    privateKeyPem: flattenedPem,
  });

  const secret = await service.buildClientSecret(new Date("2026-08-13T00:00:00.000Z"));
  // 能用公钥验签成功，说明字面 \n 已被还原成真实换行，私钥正确导入
  await jwtVerify(secret, publicKey, {
    algorithms: ["ES256"],
    issuer: TEAM_ID,
    audience: APPLE_AUDIENCE,
    subject: CLIENT_ID,
  });
});
