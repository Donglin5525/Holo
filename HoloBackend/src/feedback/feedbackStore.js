import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * 用户反馈持久化存储（设置页「反馈给开发者」通道）
 * - 由 POST /v1/feedback 写入
 * - 由管理后台 GET /admin/feedback 查看、标记处理状态
 * 图片不进数据库（避免 migration 备份与主库膨胀），存 imagesDir 文件系统，
 * 文件名 {feedbackId}-{序号}.jpg，images 列存 JSON 数组。
 */
export function createFeedbackStore(db, { imagesDir }) {
  const insertStmt = db.prepare(`
    INSERT INTO user_feedback (device_id, category, content, contact_type, contact_value, app_version, os_version)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `);
  const setImagesStmt = db.prepare('UPDATE user_feedback SET images = ? WHERE id = ?');
  const setStatusStmt = db.prepare('UPDATE user_feedback SET status = ? WHERE id = ?');
  const listStmt = db.prepare(`
    SELECT id, device_id, category, content, contact_type, contact_value, images,
           app_version, os_version, status, created_at
    FROM user_feedback
    ORDER BY created_at DESC, id DESC
    LIMIT ?
  `);

  function parseImages(row) {
    if (!row.images) return [];
    try {
      const files = JSON.parse(row.images);
      return Array.isArray(files) ? files : [];
    } catch {
      return [];
    }
  }

  return {
    create({ deviceId, category, content, contactType = null, contactValue = null, appVersion = null, osVersion = null, imageBuffers = [] }) {
      const info = insertStmt.run(deviceId, category, content, contactType, contactValue, appVersion, osVersion);
      const id = Number(info.lastInsertRowid);
      if (imageBuffers.length > 0) {
        mkdirSync(imagesDir, { recursive: true });
        const files = imageBuffers.map((buffer, index) => {
          const file = `${id}-${index}.jpg`;
          writeFileSync(join(imagesDir, file), buffer);
          return file;
        });
        setImagesStmt.run(JSON.stringify(files), id);
      }
      return { id };
    },

    markStatus(id, status) {
      setStatusStmt.run(status, id);
    },

    list(limit = 200) {
      return listStmt.all(limit).map((row) => ({ ...row, imageFiles: parseImages(row) }));
    },
  };
}
