/**
 * 产品埋点事件存储（SQLite）
 * - iOS 端 HoloProductAnalytics 的服务端落地：匿名产品使用事件（模块曝光/记账/
 *   打卡/建任务/付费墙漏斗）在前台化/进后台时批量上报。方案与埋点字典见
 *   docs/_common/plans/2026-10-19-产品埋点自建方案/README.md。
 * - 主键 id = 客户端事件 UUID：上报失败重试 INSERT OR IGNORE 幂等去重。
 * - 隐私契约：仅白名单事件名 + 扁平短字符串参数（枚举值），不收任何用户内容；
 *   入库前由端点 normalizeProductEvent 做白名单与长度截断。
 * - 180 天滚动保留（产品行为数据比 Agent 技术诊断的 14 天回看周期长），写入时
 *   顺手清理过期行。
 */

const RETENTION_MS = 180 * 24 * 60 * 60 * 1000;

export function createProductEventStore(db) {
  const insertStmt = db.prepare(`
    INSERT OR IGNORE INTO product_events (
      id, device_id, name, timestamp_ms, params, app_version, build_channel, session_id, received_at_ms
    ) VALUES (
      @id, @device_id, @name, @timestamp_ms, @params, @app_version, @build_channel, @session_id, @received_at_ms
    )
  `);
  const purgeStmt = db.prepare(`
    DELETE FROM product_events WHERE received_at_ms <= ?
  `);
  const countStmt = db.prepare(`
    SELECT COUNT(*) AS total FROM product_events
  `);
  const listByDeviceStmt = db.prepare(`
    SELECT * FROM product_events
    WHERE device_id = ?
    ORDER BY timestamp_ms ASC
    LIMIT ?
  `);

  return {
    /** 批量写入；返回实际新增条数（重复 id 不计） */
    insertBatch(deviceId, events, now = Date.now()) {
      const rows = events.map((event) => ({
        id: event.id,
        device_id: deviceId,
        name: event.name,
        timestamp_ms: event.timestampMs,
        params: event.params ? JSON.stringify(event.params) : null,
        app_version: event.appVersion ?? null,
        build_channel: event.buildChannel ?? null,
        session_id: event.sessionId ?? null,
        received_at_ms: now,
      }));
      const write = db.transaction(() => {
        let inserted = 0;
        for (const row of rows) {
          inserted += insertStmt.run(row).changes;
        }
        return inserted;
      });
      const inserted = write();
      purgeStmt.run(now - RETENTION_MS);
      return inserted;
    },

    count() {
      return countStmt.get().total;
    },

    listByDevice(deviceId, limit = 200) {
      return listByDeviceStmt.all(deviceId, limit);
    },
  };
}
