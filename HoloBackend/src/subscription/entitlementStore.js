export function createEntitlementStore(db, { now = () => new Date() } = {}) {
  const getStatement = db.prepare(`
    SELECT tier, product_id, original_transaction_id, latest_transaction_id,
           environment, expires_at, revoked_at
    FROM subscription_entitlements
    WHERE device_id = ?
  `);
  const upsertStatement = db.prepare(`
    INSERT INTO subscription_entitlements (
      device_id, tier, product_id, original_transaction_id, latest_transaction_id,
      environment, expires_at, revoked_at, updated_at
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
    ON CONFLICT(device_id) DO UPDATE SET
      tier = excluded.tier,
      product_id = excluded.product_id,
      original_transaction_id = excluded.original_transaction_id,
      latest_transaction_id = excluded.latest_transaction_id,
      environment = excluded.environment,
      expires_at = excluded.expires_at,
      revoked_at = excluded.revoked_at,
      updated_at = CURRENT_TIMESTAMP
  `);

  return {
    get(deviceId) {
      const row = getStatement.get(deviceId);
      if (!row) return freeEntitlement();

      const expiresAt = row.expires_at ?? null;
      const isExpired = !expiresAt || new Date(expiresAt) <= now();
      const isPlusActive = row.tier === "plus" && !row.revoked_at && !isExpired;
      return {
        tier: isPlusActive ? "plus" : "free",
        isPlusActive,
        productId: row.product_id ?? null,
        originalTransactionId: row.original_transaction_id ?? null,
        latestTransactionId: row.latest_transaction_id ?? null,
        environment: row.environment ?? null,
        expiresAt,
        revokedAt: row.revoked_at ?? null,
      };
    },

    upsertVerified(deviceId, entitlement) {
      upsertStatement.run(
        deviceId,
        entitlement.tier,
        entitlement.productId ?? null,
        entitlement.originalTransactionId ?? null,
        entitlement.latestTransactionId ?? null,
        entitlement.environment ?? null,
        entitlement.expiresAt ?? null,
        entitlement.revokedAt ?? null,
      );
      return this.get(deviceId);
    },
  };
}

function freeEntitlement() {
  return {
    tier: "free",
    isPlusActive: false,
    productId: null,
    originalTransactionId: null,
    latestTransactionId: null,
    environment: null,
    expiresAt: null,
    revokedAt: null,
  };
}
