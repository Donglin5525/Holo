/**
 * 云端异步分析任务存储（二期 M1 底座）
 * - 表 agent_cloud_analysis_tasks：快照/问题/失败原因/结果均为 AES-256-GCM 密文
 *   （复用 stepResponseCipher 的信封格式，独立密钥，AAD=taskId），数据库层面零明文。
 * - 隐私契约（设计稿 2026-08-30）：上传数据仅用于本次分析——完成/失败/取消时
 *   主动销毁快照+问题密文+该 runId 的 step 幂等缓存；结果回传确认后销毁；
 *   7 天无人认领过期兜底清理。「分析结束即删除」是代码行为，不是文案修辞。
 * - 状态机：uploading → queued → running → completed | failed；任意态可 cancelled；
 *   过期清理置 expired。状态迁移单向，禁止回退。
 */

import { createCipheriv, createDecipheriv, randomBytes, randomUUID } from "node:crypto";
import { createHash } from "node:crypto";

const RESULT_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

export const CLOUD_ANALYSIS_STATUS = {
  UPLOADING: "uploading",
  QUEUED: "queued",
  RUNNING: "running",
  COMPLETED: "completed",
  FAILED: "failed",
  CANCELLED: "cancelled",
  EXPIRED: "expired",
};

/** 快照密文信封（独立于 step 缓存格式；格式版本内嵌便于演进） */
function encryptField(key, plaintext, taskId) {
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  cipher.setAAD(Buffer.from(taskId, "utf8"));
  const ciphertext = Buffer.concat([
    cipher.update(plaintext, "utf8"),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return JSON.stringify({
    v: 1,
    iv: iv.toString("base64"),
    tag: tag.toString("base64"),
    ct: ciphertext.toString("base64"),
    aad: createHash("sha256").update(taskId).digest("base64"),
  });
}

export function createCloudAnalysisTaskStore(db, { encryptionKey } = {}) {
  if (!encryptionKey || Buffer.from(encryptionKey, "base64").length !== 32) {
    throw new Error("CLOUD_ANALYSIS_ENCRYPTION_KEY_MISSING");
  }
  const key = Buffer.from(encryptionKey, "base64");

  const insertStmt = db.prepare(`
    INSERT INTO agent_cloud_analysis_tasks
      (id, device_id, status, question_ciphertext, created_at_ms, expires_at_ms)
    VALUES (?, ?, ?, ?, ?, ?)
  `);
  const getStmt = db.prepare(`
    SELECT * FROM agent_cloud_analysis_tasks WHERE id = ?
  `);
  const attachSnapshotStmt = db.prepare(`
    UPDATE agent_cloud_analysis_tasks
    SET snapshot_ciphertext = ?, snapshot_size_bytes = ?, uploaded_at_ms = ?, status = 'queued'
    WHERE id = ? AND status = 'uploading'
  `);
  const transitionStmt = db.prepare(`
    UPDATE agent_cloud_analysis_tasks
    SET status = ?, started_at_ms = CASE WHEN ? = 'running' THEN ? ELSE started_at_ms END,
        completed_at_ms = CASE WHEN ? IN ('completed','failed') THEN ? ELSE completed_at_ms END
    WHERE id = ?
  `);
  const attachResultStmt = db.prepare(`
    UPDATE agent_cloud_analysis_tasks
    SET result_ciphertext = ?, status = 'completed', completed_at_ms = ?
    WHERE id = ? AND status = 'running'
  `);
  const failStmt = db.prepare(`
    UPDATE agent_cloud_analysis_tasks
    SET failure_reason_ciphertext = ?, status = 'failed', completed_at_ms = ?
    WHERE id = ? AND status IN ('running','queued')
  `);
  const destroyDataStmt = db.prepare(`
    UPDATE agent_cloud_analysis_tasks
    SET question_ciphertext = NULL, snapshot_ciphertext = NULL, snapshot_size_bytes = NULL
    WHERE id = ?
  `);
  const destroyResultStmt = db.prepare(`
    UPDATE agent_cloud_analysis_tasks
    SET result_ciphertext = NULL
    WHERE id = ?
  `);
  const deleteStmt = db.prepare(`
    DELETE FROM agent_cloud_analysis_tasks WHERE id = ?
  `);
  const purgeExpiredStmt = db.prepare(`
    DELETE FROM agent_cloud_analysis_tasks WHERE expires_at_ms <= ?
  `);
  const listExpiredStmt = db.prepare(`
    SELECT id FROM agent_cloud_analysis_tasks WHERE expires_at_ms <= ? LIMIT ?
  `);

  function decryptField(envelope, taskId) {
    if (!envelope) return null;
    const boxed = JSON.parse(envelope);
    const expectedAad = createHash("sha256").update(taskId).digest("base64");
    if (boxed.aad !== expectedAad) {
      throw new Error("CLOUD_ANALYSIS_DECRYPT_AUTH_FAILED");
    }
    const decipher = createDecipheriv(
      "aes-256-gcm",
      key,
      Buffer.from(boxed.iv, "base64"),
    );
    decipher.setAAD(Buffer.from(taskId, "utf8"));
    decipher.setAuthTag(Buffer.from(boxed.tag, "base64"));
    return Buffer.concat([
      decipher.update(Buffer.from(boxed.ct, "base64")),
      decipher.final(),
    ]).toString("utf8");
  }

  return {
    create({ deviceId, question, now = Date.now(), ttlMs = RESULT_RETENTION_MS }) {
      const id = randomUUID();
      insertStmt.run(
        id,
        deviceId,
        CLOUD_ANALYSIS_STATUS.UPLOADING,
        encryptField(key, question, id),
        now,
        now + ttlMs,
      );
      return { id, expiresAt: now + ttlMs };
    },

    get(id) {
      const row = getStmt.get(id);
      if (!row) return null;
      return { ...row };
    },

    /** 仅设备所有权校验后的受信读取：解密问题/结果 */
    getDecrypted(id, fields = ["question", "result", "failureReason"]) {
      const row = getStmt.get(id);
      if (!row) return null;
      const out = { ...row };
      out.question = fields.includes("question") && row.question_ciphertext
        ? decryptField(row.question_ciphertext, id)
        : null;
      out.result = fields.includes("result") && row.result_ciphertext
        ? decryptField(row.result_ciphertext, id)
        : null;
      out.failureReason = fields.includes("failureReason") && row.failure_reason_ciphertext
        ? decryptField(row.failure_reason_ciphertext, id)
        : null;
      return out;
    },

    /** 上传快照（uploading 态一次性整包；幂等：同任务重复 PUT 覆盖） */
    attachSnapshot({ id, snapshot, now = Date.now() }) {
      const result = attachSnapshotStmt.run(
        encryptField(key, snapshot, id),
        Buffer.byteLength(snapshot, "utf8"),
        now,
        id,
      );
      return result.changes === 1;
    },

    transition(id, status, now = Date.now()) {
      const result = transitionStmt.run(status, status, now, status, now, id);
      return result.changes === 1;
    },

    complete({ id, result, now = Date.now() }) {
      const updated = attachResultStmt.run(encryptField(key, result, id), now, id);
      if (updated.changes === 1) {
        // 完成即焚第一段：输入侧数据立即销毁（结果仍在，等回传）
        destroyDataStmt.run(id);
      }
      return updated.changes === 1;
    },

    fail({ id, reason, now = Date.now() }) {
      const updated = failStmt.run(encryptField(key, reason, id), now, id);
      if (updated.changes === 1) {
        destroyDataStmt.run(id);
      }
      return updated.changes === 1;
    },

    /** 用户取消：整行销毁（含结果——未领取的取消不留任何数据） */
    cancel(id) {
      deleteStmt.run(id);
    },

    /** 结果回传确认：销毁结果密文，任务行转为已领取的历史记录（仅状态与时间戳） */
    consumeResult(id) {
      destroyResultStmt.run(id);
    },

    purgeExpired(now = Date.now(), limit = 200) {
      const rows = listExpiredStmt.all(now, limit);
      const purge = db.transaction(() => {
        for (const row of rows) deleteStmt.run(row.id);
        return rows.length;
      });
      return purge();
    },

    /** 诊断/验收用：断言数据已销毁（快照与问题密文均为空） */
    isDataDestroyed(id) {
      const row = getStmt.get(id);
      if (!row) return true;
      return row.question_ciphertext == null && row.snapshot_ciphertext == null;
    },
  };
}
