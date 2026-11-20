/**
 * 「一个发现」v4 送达台账（2026-11-21 预算墙，东林拍板）。
 *
 * 计数口径：只记「实际送达的卡」（闸门放行的 selected）——
 * none_worthwhile / gate_rejected / disabled / quota_exhausted 的响应不计数，
 * 否则免费用户某天模型没产出会白烧当周唯一名额（体验红线，评估时定谳）。
 *
 * 窗口：7 天滚动（对外沟通为「每周」），按设备计数（与 ai_call_logs 同口径）。
 * 台账只存 device_id + 时间戳，无任何内容。
 */
const WEEK_MS = 7 * 24 * 3600 * 1000;

const MIGRATION_SQL = `
  CREATE TABLE IF NOT EXISTS insight_deliveries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    device_id TEXT NOT NULL,
    delivered_at INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS idx_insight_deliveries_device_time
    ON insight_deliveries(device_id, delivered_at);
`;

export function createInsightDeliveryStore(db, options = {}) {
  if (db) db.exec(MIGRATION_SQL);
  const nowMs = options.now ?? (() => Date.now());

  const countSince = db.prepare(
    "SELECT COUNT(*) AS c FROM insight_deliveries WHERE device_id = ? AND delivered_at > ?"
  );
  const insert = db.prepare(
    "INSERT INTO insight_deliveries (device_id, delivered_at) VALUES (?, ?)"
  );
  const cleanupBefore = db.prepare(
    "DELETE FROM insight_deliveries WHERE delivered_at < ?"
  );

  return {
    /** 近 7 天滚动窗口内的送达条数。 */
    countLastWeek(deviceId, now = nowMs()) {
      return countSince.get(deviceId, now - WEEK_MS).c;
    },
    /** 记一次送达（闸门放行后调用；顺带清理 14 天前的旧账，表恒小）。 */
    record(deviceId, at = nowMs()) {
      insert.run(deviceId, at);
      cleanupBefore.run(at - 2 * WEEK_MS);
    },
  };
}
