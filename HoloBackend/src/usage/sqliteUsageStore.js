/**
 * SQLite 持久化限流存储
 * - 替代 inMemoryUsageStore
 * - INSERT ... ON CONFLICT 保证原子性
 * - 成本接口 fail-closed
 */

export function createSqliteUsageStore(db, { failClosed = true } = {}) {
  const upsertStmt = db.prepare(`
    INSERT INTO rate_limits (key, count, expires_at)
    VALUES (?, 1, ?)
    ON CONFLICT(key) DO UPDATE SET count = count + 1
  `);

  const getCountStmt = db.prepare(`
    SELECT count FROM rate_limits WHERE key = ?
  `);

  const cleanupStmt = db.prepare(`
    DELETE FROM rate_limits WHERE expires_at IS NOT NULL AND expires_at < datetime('now')
  `);

  /** 定期清理过期记录 */
  function cleanup() {
    try {
      cleanupStmt.run();
    } catch (err) {
      console.error('[SqliteUsageStore] 清理失败:', err.message);
    }
  }

  // 每次启动清理一次
  cleanup();

  return {
    consume({ deviceId, purpose, minuteLimit, dailyLimit }) {
      try {
        const now = new Date();
        const minuteKey = `${deviceId}:${purpose}:${toISOStringMinute(now)}`;
        const dayKey = `${deviceId}:${purpose}:${toISOStringDay(now)}`;

        const minuteExpires = new Date(now.getTime() + 60_000).toISOString();
        const dayExpires = new Date(now.getTime() + 86_400_000).toISOString();

        // 检查分钟限制
        const minuteRow = getCountStmt.get(minuteKey);
        if (minuteRow && minuteRow.count >= minuteLimit) {
          return { allowed: false, reason: 'minute_limit' };
        }

        // 检查日限制
        const dayRow = getCountStmt.get(dayKey);
        if (dayRow && dayRow.count >= dailyLimit) {
          return { allowed: false, reason: 'daily_limit' };
        }

        // 原子计数 +1
        const transaction = db.transaction(() => {
          upsertStmt.run(minuteKey, minuteExpires);
          upsertStmt.run(dayKey, dayExpires);
        });
        transaction();

        // 偶尔清理
        if (Math.random() < 0.01) cleanup();

        return { allowed: true };
      } catch (err) {
        console.error('[SqliteUsageStore] consume 失败:', err.message);

        // 成本接口 fail-closed：写入失败时拒绝请求
        if (failClosed) {
          return { allowed: false, reason: 'storage_error' };
        }

        // 非成本接口 fail-open
        return { allowed: true };
      }
    },

    cleanup,
  };
}

function toISOStringMinute(date) {
  return date.toISOString().slice(0, 16);
}

function toISOStringDay(date) {
  return date.toISOString().slice(0, 10);
}
