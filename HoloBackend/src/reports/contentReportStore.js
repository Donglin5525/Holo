import { randomUUID } from 'node:crypto';

/**
 * AI 内容举报持久化存储（App Store Guideline 1.2）
 * - 由 POST /v1/reports 写入
 * - 由管理后台 GET /v1/admin/reports 查看
 * status 流转：pending →（人工处理）reviewing/resolved/dismissed
 */
export function createContentReportStore(db) {
  const insertStmt = db.prepare(`
    INSERT INTO content_reports (id, device_id, message_id, reason, detail, content_snapshot, status)
    VALUES (?, ?, ?, ?, ?, ?, 'pending')
  `);

  const listStmt = db.prepare(`
    SELECT id, device_id, message_id, reason, detail, content_snapshot, status, created_at
    FROM content_reports
    ORDER BY created_at DESC
    LIMIT ?
  `);

  return {
    create({ deviceId, messageId, reason, detail = null, contentSnapshot = null }) {
      const id = randomUUID();
      insertStmt.run(id, deviceId, messageId, reason, detail, contentSnapshot);
      return { id };
    },

    list(limit = 200) {
      return listStmt.all(limit);
    },
  };
}
