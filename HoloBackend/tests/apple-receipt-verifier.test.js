import assert from "node:assert/strict";
import { test } from "node:test";

import { createAppleReceiptVerifier } from "../src/subscription/appleReceiptVerifier.js";

const PLUS_MONTHLY = "com.tangyuxuan.holo.plus.monthly";
const EXPIRES_MS = 1758000000000;
const REVOKED_MS = 1757000000000;

function decodedTransaction(overrides = {}) {
  return {
    transactionId: "10000001",
    originalTransactionId: "10000000",
    bundleId: "com.tangyuxuan.holo-app",
    productId: PLUS_MONTHLY,
    environment: "Production",
    expiresDate: EXPIRES_MS,
    revocationDate: null,
    ...overrides,
  };
}

/** 离线验签注入：按 JWS 字符串返回预置解码结果；未命中视为验签失败（模拟真实验签拒绝）。 */
function makeVerifierFactory(byEnvironment) {
  return (environment) => ({
    async verifyAndDecodeTransaction(jws) {
      const decoded = byEnvironment[environment]?.[jws];
      if (!decoded) throw new Error("VERIFICATION_FAILURE");
      return decoded;
    },
  });
}

/** 在线对账注入：environment → client；getTransactionInfo 返回苹果签名串或抛 httpStatusCode 错误。 */
function makeClientFactory(byEnvironment) {
  return () => (environment) => byEnvironment[environment];
}

async function assertGatewayError(promise, code, status) {
  await assert.rejects(promise, (error) => {
    assert.equal(error.code, code);
    assert.equal(error.status, status);
    return true;
  });
}

// —— disabled / test 模式 ——

test("disabled：一切交易 503，绝不装作成功", async () => {
  const verifier = createAppleReceiptVerifier({ appleVerificationMode: "disabled" });
  await assertGatewayError(verifier.verify({}), "SUBSCRIPTION_VERIFICATION_UNAVAILABLE", 503);
});

test("未配置模式默认 disabled", async () => {
  const verifier = createAppleReceiptVerifier({});
  await assertGatewayError(verifier.verify({}), "SUBSCRIPTION_VERIFICATION_UNAVAILABLE", 503);
});

test("test 模式：合成交易通过并映射权益", async () => {
  const verifier = createAppleReceiptVerifier({ appleVerificationMode: "test" });
  const verified = await verifier.verify({
    productId: PLUS_MONTHLY,
    signedTransactionInfo: "test-valid",
    transactionId: "t1",
    originalTransactionId: "t0",
    expiresAt: "2026-10-01T00:00:00.000Z",
  });
  assert.equal(verified.tier, "plus");
  assert.equal(verified.productId, PLUS_MONTHLY);
  assert.equal(verified.revokedAt, null);
});

test("test 模式：非 Plus 商品 400、字面量不符 401、缺过期时间 400", async () => {
  const verifier = createAppleReceiptVerifier({ appleVerificationMode: "test" });
  await assertGatewayError(
    verifier.verify({ productId: "com.other.app", signedTransactionInfo: "test-valid", expiresAt: "2026-10-01T00:00:00.000Z" }),
    "INVALID_PRODUCT_ID",
    400,
  );
  await assertGatewayError(
    verifier.verify({ productId: PLUS_MONTHLY, signedTransactionInfo: "forged", expiresAt: "2026-10-01T00:00:00.000Z" }),
    "INVALID_TRANSACTION",
    401,
  );
  await assertGatewayError(
    verifier.verify({ productId: PLUS_MONTHLY, signedTransactionInfo: "test-valid" }),
    "INVALID_TRANSACTION",
    400,
  );
});

// —— production 模式（注入假验签器/假 API client）——

const DEVICE_JWS = "device-jws";
const AUTHORITATIVE_JWS = "authoritative-jws";

function productionConfig(overrides = {}) {
  return {
    appleVerificationMode: "production",
    apple: { bundleId: "com.tangyuxuan.holo-app", appAppleId: 6770199832, ...overrides },
  };
}

test("production：离线验签+在线对账成功，映射过期时间与撤销字段", async () => {
  const authoritative = decodedTransaction();
  const verifier = createAppleReceiptVerifier(productionConfig(), {
    makeVerifier: makeVerifierFactory({
      Production: { [DEVICE_JWS]: decodedTransaction(), [AUTHORITATIVE_JWS]: authoritative },
    }),
    makeClient: makeClientFactory({
      Production: { async getTransactionInfo(id) { return { signedTransactionInfo: AUTHORITATIVE_JWS }; } },
    }),
  });

  const verified = await verifier.verify({ signedTransactionInfo: DEVICE_JWS });
  assert.equal(verified.tier, "plus");
  assert.equal(verified.productId, PLUS_MONTHLY);
  assert.equal(verified.originalTransactionId, "10000000");
  assert.equal(verified.latestTransactionId, "10000001");
  assert.equal(verified.environment, "Production");
  assert.equal(verified.expiresAt, new Date(EXPIRES_MS).toISOString());
  assert.equal(verified.revokedAt, null);
});

test("production：对账查得撤销→revokedAt 落库（entitlementStore 据此判非 Plus）", async () => {
  const verifier = createAppleReceiptVerifier(productionConfig(), {
    makeVerifier: makeVerifierFactory({
      Production: {
        [DEVICE_JWS]: decodedTransaction(),
        [AUTHORITATIVE_JWS]: decodedTransaction({ revocationDate: REVOKED_MS }),
      },
    }),
    makeClient: makeClientFactory({
      Production: { async getTransactionInfo() { return { signedTransactionInfo: AUTHORITATIVE_JWS }; } },
    }),
  });

  const verified = await verifier.verify({ signedTransactionInfo: DEVICE_JWS });
  assert.equal(verified.revokedAt, new Date(REVOKED_MS).toISOString());
});

test("production：Production 查不到回落 Sandbox（TestFlight/审核购买）", async () => {
  const sandboxTx = decodedTransaction({ environment: "Sandbox" });
  const verifier = createAppleReceiptVerifier(productionConfig(), {
    makeVerifier: makeVerifierFactory({
      Production: { [DEVICE_JWS]: decodedTransaction() },
      Sandbox: { [AUTHORITATIVE_JWS]: sandboxTx },
    }),
    makeClient: makeClientFactory({
      Production: { async getTransactionInfo() { throw { httpStatusCode: 404 }; } },
      Sandbox: { async getTransactionInfo() { return { signedTransactionInfo: AUTHORITATIVE_JWS }; } },
    }),
  });

  const verified = await verifier.verify({ signedTransactionInfo: DEVICE_JWS });
  assert.equal(verified.environment, "Sandbox");
});

test("production：两个环境都查不到→401 拒绝", async () => {
  const verifier = createAppleReceiptVerifier(productionConfig(), {
    makeVerifier: makeVerifierFactory({
      Production: { [DEVICE_JWS]: decodedTransaction() },
    }),
    makeClient: makeClientFactory({
      Production: { async getTransactionInfo() { throw { httpStatusCode: 404 }; } },
      Sandbox: { async getTransactionInfo() { throw { httpStatusCode: 404 }; } },
    }),
  });

  await assertGatewayError(verifier.verify({ signedTransactionInfo: DEVICE_JWS }), "INVALID_TRANSACTION", 401);
});

test("production：对账通道故障→按离线验签结果放行（不拒绝刚完成的真实购买）", async () => {
  const verifier = createAppleReceiptVerifier(productionConfig(), {
    makeVerifier: makeVerifierFactory({
      Production: { [DEVICE_JWS]: decodedTransaction() },
    }),
    makeClient: makeClientFactory({
      Production: { async getTransactionInfo() { throw { httpStatusCode: 503 }; } },
    }),
  });

  const verified = await verifier.verify({ signedTransactionInfo: DEVICE_JWS });
  assert.equal(verified.tier, "plus");
  assert.equal(verified.expiresAt, new Date(EXPIRES_MS).toISOString());
});

test("production：沙盒签名的交易走 Sandbox 验签", async () => {
  const sandboxDeviceJws = "sandbox-device-jws";
  const verifier = createAppleReceiptVerifier(productionConfig(), {
    makeVerifier: makeVerifierFactory({
      Production: {},
      Sandbox: { [sandboxDeviceJws]: decodedTransaction({ environment: "Sandbox" }), [AUTHORITATIVE_JWS]: decodedTransaction({ environment: "Sandbox" }) },
    }),
    makeClient: makeClientFactory({
      Sandbox: { async getTransactionInfo() { return { signedTransactionInfo: AUTHORITATIVE_JWS }; } },
    }),
  });

  const verified = await verifier.verify({ signedTransactionInfo: sandboxDeviceJws });
  assert.equal(verified.environment, "Sandbox");
});

test("production：非 Plus 商品 400；验签不过 401；缺 signedTransactionInfo 400", async () => {
  const verifier = createAppleReceiptVerifier(productionConfig(), {
    makeVerifier: makeVerifierFactory({
      Production: { [DEVICE_JWS]: decodedTransaction({ productId: "com.other.product" }) },
    }),
    makeClient: makeClientFactory({ Production: { async getTransactionInfo() { throw new Error("should not be called"); } } }),
  });
  await assertGatewayError(verifier.verify({ signedTransactionInfo: DEVICE_JWS }), "INVALID_PRODUCT_ID", 400);

  const badSignVerifier = createAppleReceiptVerifier(productionConfig(), {
    makeVerifier: makeVerifierFactory({ Production: {} }),
    makeClient: makeClientFactory({ Production: { async getTransactionInfo() { throw new Error("x"); } } }),
  });
  await assertGatewayError(badSignVerifier.verify({ signedTransactionInfo: "forged-jws" }), "INVALID_TRANSACTION", 401);

  await assertGatewayError(verifier.verify({}), "INVALID_TRANSACTION", 400);
});

test("production：苹果凭据缺失→503（部署配置错误不应伪装成交易问题）", async () => {
  // 离线验签可过（注入假验签器），但不注入 makeClient：真实路径走到
  // buildConfiguredClientFactory，凭据缺失必须以 503 暴露配置问题
  const verifier = createAppleReceiptVerifier(productionConfig(), {
    makeVerifier: makeVerifierFactory({
      Production: { [DEVICE_JWS]: decodedTransaction() },
    }),
  });
  await assertGatewayError(verifier.verify({ signedTransactionInfo: DEVICE_JWS }), "SUBSCRIPTION_VERIFICATION_UNAVAILABLE", 503);
});
