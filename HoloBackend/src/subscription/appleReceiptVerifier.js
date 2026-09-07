/**
 * Apple 内购交易验证器（/v1/subscription/sync）。
 *
 * - disabled（默认）：验单未配置，一切交易 503，绝不「装作成功」。
 * - test：调试/内部验收模式，只认字面量 "test-valid" 的合成交易。
 * - production：真实链路，两段验证：
 *     1) 离线验签：客户端上传的 StoreKit 2 交易 JWS（signedTransactionInfo），
 *        用苹果根证书链验签 + bundleId/appAppleId 绑定（SignedDataVerifier）；
 *     2) 在线对账：App Store Server API getTransactionInfo 取权威最新状态
 *        （续订/撤销/退款以苹果为准；Production 查不到回落 Sandbox，覆盖
 *        TestFlight 与 App Store 审核的沙盒购买）。对账通道故障时以离线验签
 *        结果放行（签名可信 + 过期由 entitlementStore 统一判定），不因苹果
 *        接口抖动拒绝刚完成的真实购买。
 *
 * 权益判定口径：productId 必须是 Plus 商品；expiresAt/revokedAt 原样落
 * subscription_entitlements，过期与撤销的生效判断统一在 entitlementStore.get。
 */

import { readFileSync } from "node:fs";
import { GatewayError } from "../errors.js";
import { tierForProductId } from "./productIds.js";
import {
  AppStoreServerAPIClient,
  SignedDataVerifier,
} from "@apple/app-store-server-library";

const ROOT_CERT_PATH = new URL("./certs/AppleRootCA-G3.cer", import.meta.url);

export function createAppleReceiptVerifier(config = {}, deps = {}) {
  const mode = config.appleVerificationMode ?? "disabled";

  if (mode === "test") {
    return {
      async verify(input) {
        return verifyTestTransaction(input);
      },
    };
  }

  if (mode === "production") {
    return createProductionVerifier(config.apple ?? {}, deps);
  }

  return {
    async verify() {
      throw new GatewayError(
        "SUBSCRIPTION_VERIFICATION_UNAVAILABLE",
        "Subscription verification is not configured",
        503,
      );
    },
  };
}

function verifyTestTransaction(input) {
  if (tierForProductId(input.productId) !== "plus") {
    throw new GatewayError("INVALID_PRODUCT_ID", "Product is not supported", 400);
  }
  if (input.signedTransactionInfo !== "test-valid") {
    throw new GatewayError("INVALID_TRANSACTION", "Transaction verification failed", 401);
  }
  if (!input.expiresAt || Number.isNaN(new Date(input.expiresAt).getTime())) {
    throw new GatewayError("INVALID_TRANSACTION", "expiresAt is required", 400);
  }
  return {
    tier: "plus",
    productId: input.productId,
    originalTransactionId: input.originalTransactionId,
    latestTransactionId: input.transactionId,
    environment: input.environment ?? "Sandbox",
    expiresAt: input.expiresAt,
    revokedAt: input.revokedAt ?? null,
  };
}

/** production 模式：在线验证组件懒加载（首次 verify 才构建），配置缺失表现为 503 而不是启动崩溃。 */
function createProductionVerifier(apple, deps = {}) {
  const makeVerifier =
    deps.makeVerifier ??
    ((environment) =>
      new SignedDataVerifier(
        [readFileSync(ROOT_CERT_PATH)],
        true,
        environment,
        apple.bundleId,
        apple.appAppleId > 0 ? apple.appAppleId : undefined,
      ));

  let verifiers = null;
  let clients = null;
  let clientFactory = null;

  function verifierFor(environment) {
    verifiers ??= {};
    verifiers[environment] ??= makeVerifier(environment);
    return verifiers[environment];
  }

  function clientFor(environment) {
    if (!clientFactory) {
      clientFactory = deps.makeClient
        ? deps.makeClient()
        : buildConfiguredClientFactory(apple);
    }
    clients ??= {};
    clients[environment] ??= clientFactory(environment);
    return clients[environment];
  }

  return {
    async verify(input) {
      const jws = input?.signedTransactionInfo;
      if (!jws || typeof jws !== "string") {
        throw new GatewayError("INVALID_TRANSACTION", "signedTransactionInfo is required", 400);
      }

      let decoded = await decodeTransaction(jws);
      if (tierForProductId(decoded.productId ?? "") !== "plus") {
        throw new GatewayError("INVALID_PRODUCT_ID", "Product is not supported", 400);
      }

      const environment = decoded.environment === "Sandbox" ? "Sandbox" : "Production";
      // client 构建即校验凭据：缺失/配置错误在这里抛 503，
      // 不落入下方「对账通道抖动」的容错兜底
      const primaryClient = clientFor(environment);
      const sandboxFallbackClient = environment === "Sandbox" ? null : clientFor("Sandbox");
      let authoritative = decoded;
      try {
        let signedInfo;
        try {
          signedInfo = await primaryClient.getTransactionInfo(String(decoded.transactionId));
        } catch (error) {
          if (!isNotFound(error) || environment === "Sandbox") {
            throw error;
          }
          // Production 查不到 → 回落 Sandbox（TestFlight / App Store 审核的沙盒购买）
          signedInfo = await sandboxFallbackClient.getTransactionInfo(String(decoded.transactionId));
        }
        authoritative = await decodeTransaction(signedInfo.signedTransactionInfo);
      } catch (error) {
        if (isNotFound(error)) {
          // 苹果签名过的交易在两个环境都查不到：无法确认归属，拒绝
          throw new GatewayError("INVALID_TRANSACTION", "Transaction not found on App Store", 401);
        }
        // 对账通道抖动：以离线验签结果放行（过期/撤销的常规判定不受影响）
        console.log("[apple-verify] getTransactionInfo 不可用，按离线验签结果放行:", error?.message ?? error);
      }

      if (!authoritative.expiresDate) {
        throw new GatewayError("INVALID_TRANSACTION", "expiresAt is required", 400);
      }
      return {
        tier: "plus",
        productId: authoritative.productId,
        originalTransactionId: String(authoritative.originalTransactionId ?? decoded.originalTransactionId ?? ""),
        latestTransactionId: String(authoritative.transactionId ?? decoded.transactionId),
        environment: authoritative.environment ?? environment,
        expiresAt: new Date(authoritative.expiresDate).toISOString(),
        revokedAt: authoritative.revocationDate ? new Date(authoritative.revocationDate).toISOString() : null,
      };
    },
  };

  async function decodeTransaction(jws) {
    try {
      return await verifierFor("Production").verifyAndDecodeTransaction(jws);
    } catch {
      try {
        return await verifierFor("Sandbox").verifyAndDecodeTransaction(jws);
      } catch {
        throw new GatewayError("INVALID_TRANSACTION", "Transaction verification failed", 401);
      }
    }
  }
}

function loadPrivateKey(apple) {
  if (apple.privateKeyPem) {
    return normalizeP8(apple.privateKeyPem);
  }
  if (apple.privateKeyPath) {
    return normalizeP8(readFileSync(apple.privateKeyPath, "utf8"));
  }
  return "";
}

/** 凭据齐备时返回 environment → AppStoreServerAPIClient 的工厂；缺失时抛 503。 */
function buildConfiguredClientFactory(apple) {
  const privateKey = loadPrivateKey(apple);
  if (!privateKey || !apple.keyId || !apple.issuerId || !apple.bundleId) {
    throw new GatewayError(
      "SUBSCRIPTION_VERIFICATION_UNAVAILABLE",
      "Apple verification credentials are not configured",
      503,
    );
  }
  return (environment) =>
    new AppStoreServerAPIClient(privateKey, apple.keyId, apple.issuerId, apple.bundleId, environment);
}

/** .p8 直接放入环境变量时换行常被转义成字面 \n */
function normalizeP8(pem) {
  return pem.includes("\\n") ? pem.replaceAll("\\n", "\n") : pem;
}

function isNotFound(error) {
  return (
    error?.httpStatusCode === 404 ||
    error?.status === 404 ||
    error?.response?.status === 404 ||
    /404|NOT_FOUND/i.test(error?.message ?? "")
  );
}
