import assert from "node:assert/strict";
import { test } from "node:test";

import { SignJWT, exportJWK, generateKeyPair } from "jose";

import { createAppleIdentityVerifier } from "../src/auth/appleIdentityVerifier.js";
import { createHoloSessionService } from "../src/auth/holoSession.js";
import { loadConfig } from "../src/config.js";

const NOW = new Date("2026-07-13T00:00:00.000Z");
const APPLE_ISSUER = "https://appleid.apple.com";
const CLIENT_ID = "com.tangyuxuan.holo-app";

test("Default Apple audience includes the physical-device bundle ID", () => {
  assert.ok(loadConfig().auth.appleClientIds.includes(CLIENT_ID));
});

async function makeAppleFixture() {
  const { privateKey, publicKey } = await generateKeyPair("RS256");
  const publicJwk = await exportJWK(publicKey);
  publicJwk.kid = "apple-test-key";
  publicJwk.alg = "RS256";

  const verifier = createAppleIdentityVerifier({
    clientIds: [CLIENT_ID],
    jwks: { keys: [publicJwk] },
    now: () => NOW,
  });

  async function sign(overrides = {}) {
    const claims = {
      sub: "apple-owner-sub",
      ...overrides,
    };
    return new SignJWT(claims)
      .setProtectedHeader({ alg: "RS256", kid: "apple-test-key" })
      .setIssuer(APPLE_ISSUER)
      .setAudience(overrides.aud ?? CLIENT_ID)
      .setIssuedAt(Math.floor(NOW.getTime() / 1000) - 10)
      .setExpirationTime(overrides.exp ?? Math.floor(NOW.getTime() / 1000) + 300)
      .sign(privateKey);
  }

  return { verifier, sign };
}

test("Apple identity verifier accepts a valid Apple identity token", async () => {
  const { verifier, sign } = await makeAppleFixture();
  const identity = await verifier.verify(await sign());
  assert.equal(identity.sub, "apple-owner-sub");
  assert.equal(identity.audience, CLIENT_ID);
});

test("Apple identity verifier rejects a wrong audience", async () => {
  const { verifier, sign } = await makeAppleFixture();
  const token = await sign({ aud: "com.example.other" });
  await assert.rejects(() => verifier.verify(token));
});

test("Apple identity verifier rejects an expired token", async () => {
  const { verifier, sign } = await makeAppleFixture();
  const token = await sign({ exp: Math.floor(NOW.getTime() / 1000) - 1 });
  await assert.rejects(() => verifier.verify(token));
});

test("Holo session marks only allowlisted Apple subjects as internal", async () => {
  const service = createHoloSessionService({
    secret: "test-session-secret-that-is-at-least-32-bytes-long",
    internalSubjects: ["apple-owner-sub"],
    now: () => NOW,
  });

  const owner = await service.verify(await service.issue("apple-owner-sub"));
  const regular = await service.verify(await service.issue("regular-user-sub"));

  assert.equal(owner.internalDiagnostics, true);
  assert.equal(regular.internalDiagnostics, false);
});

test("Holo session rejects expired and tampered tokens", async () => {
  const service = createHoloSessionService({
    secret: "test-session-secret-that-is-at-least-32-bytes-long",
    internalSubjects: [],
    ttlSeconds: -1,
    now: () => NOW,
  });
  const expired = await service.issue("regular-user-sub");
  await assert.rejects(() => service.verify(expired));

  const validService = createHoloSessionService({
    secret: "test-session-secret-that-is-at-least-32-bytes-long",
    internalSubjects: [],
    now: () => NOW,
  });
  const valid = await validService.issue("regular-user-sub");
  await assert.rejects(() => validService.verify(`${valid.slice(0, -1)}x`));
});

test("Holo session fails closed when the signing secret is unavailable", () => {
  assert.throws(() => createHoloSessionService({ secret: "", internalSubjects: [] }));
});
