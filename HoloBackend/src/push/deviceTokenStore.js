/**
 * 设备推送令牌存储（SQLite）
 * device_id 主键一行：token 上报 upsert；environment 由 APNs 首次成功发送后回写
 * （后续直发免回退试探）；410 Unregistered 时删除。
 */

export function createDeviceTokenStore(db) {
  const upsertStmt = db.prepare(`
    INSERT INTO agent_device_tokens (device_id, token, environment, updated_at_ms)
    VALUES (?, ?, NULL, ?)
    ON CONFLICT(device_id) DO UPDATE SET
      token = excluded.token,
      environment = NULL,
      updated_at_ms = excluded.updated_at_ms
  `);

  const getStmt = db.prepare(`
    SELECT device_id, token, environment, updated_at_ms
    FROM agent_device_tokens WHERE device_id = ?
  `);

  const setEnvironmentStmt = db.prepare(`
    UPDATE agent_device_tokens SET environment = ? WHERE device_id = ?
  `);

  const deleteStmt = db.prepare(`
    DELETE FROM agent_device_tokens WHERE device_id = ?
  `);

  return {
    /** 上报/更新 token；token 变化时清空已验证环境（新 token 环境未知，重新探测） */
    upsert(deviceId, token) {
      const existing = getStmt.get(deviceId);
      if (existing && existing.token === token) return;
      upsertStmt.run(deviceId, token, Date.now());
    },

    get(deviceId) {
      const row = getStmt.get(deviceId);
      return row
        ? { deviceId: row.device_id, token: row.token, environment: row.environment, updatedAt: row.updated_at_ms }
        : null;
    },

    markEnvironment(deviceId, environment) {
      setEnvironmentStmt.run(environment, deviceId);
    },

    remove(deviceId) {
      deleteStmt.run(deviceId);
    },
  };
}
