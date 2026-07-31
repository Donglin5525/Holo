export function createAcceptanceStore(db) {
  const getStatement = db.prepare(`
    SELECT tier FROM subscription_acceptance_overrides WHERE device_id = ?
  `);
  const setStatement = db.prepare(`
    INSERT INTO subscription_acceptance_overrides (device_id, tier, updated_at)
    VALUES (?, ?, CURRENT_TIMESTAMP)
    ON CONFLICT(device_id) DO UPDATE SET
      tier = excluded.tier,
      updated_at = CURRENT_TIMESTAMP
  `);
  const clearStatement = db.prepare(`
    DELETE FROM subscription_acceptance_overrides WHERE device_id = ?
  `);

  return {
    get(deviceId) {
      const tier = getStatement.get(deviceId)?.tier;
      return tier === "free" || tier === "plus" ? { tier } : null;
    },
    set(deviceId, tier) {
      if (tier !== "free" && tier !== "plus") {
        throw new Error(`Unsupported acceptance tier: ${tier}`);
      }
      setStatement.run(deviceId, tier);
      return { tier };
    },
    clear(deviceId) {
      clearStatement.run(deviceId);
    },
  };
}
