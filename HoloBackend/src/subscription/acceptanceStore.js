export function createAcceptanceStore(db) {
  const getStatement = db.prepare(`
    SELECT tier, expires_at FROM subscription_acceptance_overrides WHERE device_id = ?
  `);
  const setStatement = db.prepare(`
    INSERT INTO subscription_acceptance_overrides (device_id, tier, expires_at, updated_at)
    VALUES (?, ?, ?, CURRENT_TIMESTAMP)
    ON CONFLICT(device_id) DO UPDATE SET
      tier = excluded.tier,
      expires_at = excluded.expires_at,
      updated_at = CURRENT_TIMESTAMP
  `);
  const clearStatement = db.prepare(`
    DELETE FROM subscription_acceptance_overrides WHERE device_id = ?
  `);
  const listStatement = db.prepare(`
    SELECT device_id, tier, expires_at, updated_at
    FROM subscription_acceptance_overrides
    ORDER BY updated_at DESC
  `);

  function isExpired(expiresAt) {
    if (!expiresAt) return false;
    const deadline = Date.parse(expiresAt);
    return Number.isNaN(deadline) || deadline <= Date.now();
  }

  return {
    get(deviceId) {
      const row = getStatement.get(deviceId);
      if (!row || isExpired(row.expires_at)) return null;
      return row.tier === "free" || row.tier === "plus" ? { tier: row.tier } : null;
    },
    set(deviceId, tier, expiresAt = null) {
      if (tier !== "free" && tier !== "plus") {
        throw new Error(`Unsupported acceptance tier: ${tier}`);
      }
      if (expiresAt !== null && typeof expiresAt !== "string") {
        throw new Error("expiresAt must be an ISO string or null");
      }
      setStatement.run(deviceId, tier, expiresAt);
      return { tier, expiresAt };
    },
    clear(deviceId) {
      clearStatement.run(deviceId);
    },
    list() {
      return listStatement.all().map((row) => ({
        deviceId: row.device_id,
        tier: row.tier,
        expiresAt: row.expires_at,
        updatedAt: row.updated_at,
        expired: isExpired(row.expires_at),
      }));
    },
  };
}
