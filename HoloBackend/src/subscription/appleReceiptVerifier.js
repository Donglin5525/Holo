import { GatewayError } from "../errors.js";
import { tierForProductId } from "./productIds.js";

export function createAppleReceiptVerifier(config = {}) {
  const mode = config.appleVerificationMode ?? "disabled";

  return {
    async verify(input) {
      if (mode === "test") return verifyTestTransaction(input);
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
