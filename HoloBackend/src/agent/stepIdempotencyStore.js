/**
 * Agent step 级幂等存储（SQLite）
 * - 主键 (run_id, step_id)：同一 Agent 步骤最多一条记录
 * - 状态机：processing → completed / failed_retryable / failed_final
 *   failed_retryable 允许受控重试（reacquireProcessing 转回 processing）
 * - response 列为 TTL 敏感数据：AES-256-GCM 应用层加密，仅暂存结构化模型响应 JSON，
 *   不存完整 messages，不进管理后台详情；runId/stepId/requestHash 作为 AAD 防调包。
 * - 时间戳为 epoch 毫秒；过期记录 get 时视为不存在并顺手删除，purgeExpired 兜底清理
 */

import { createStepResponseCipher } from "./stepResponseCipher.js";

export const STEP_STATUS = {
  PROCESSING: "processing",
  COMPLETED: "completed",
  FAILED_RETRYABLE: "failed_retryable",
  FAILED_FINAL: "failed_final",
};

export function createStepIdempotencyStore(db, { responseCipher } = {}) {
  const cipher = responseCipher ?? createStepResponseCipher({
    primaryKey: process.env.HOLO_AGENT_STEP_IDEMPOTENCY_ENCRYPTION_KEY,
    previousKeys: process.env.HOLO_AGENT_STEP_IDEMPOTENCY_PREVIOUS_ENCRYPTION_KEYS,
    allowEphemeral: process.env.NODE_ENV !== "production",
  });
  const getStmt = db.prepare(`
    SELECT run_id, step_id, request_hash, status, response, usage,
           error_code, error_status, created_at, updated_at, expires_at
    FROM agent_step_idempotency
    WHERE run_id = ? AND step_id = ?
  `);

  const insertStmt = db.prepare(`
    INSERT INTO agent_step_idempotency
      (run_id, step_id, request_hash, status, created_at, updated_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
  `);

  const deleteStmt = db.prepare(`
    DELETE FROM agent_step_idempotency WHERE run_id = ? AND step_id = ?
  `);

  const completeStmt = db.prepare(`
    UPDATE agent_step_idempotency
    SET status = ?, response = ?, usage = ?, error_code = NULL, error_status = NULL, updated_at = ?
    WHERE run_id = ? AND step_id = ? AND request_hash = ?
  `);

  const completedResponsesStmt = db.prepare(`
    SELECT run_id, step_id, request_hash, response
    FROM agent_step_idempotency
    WHERE status = ? AND response IS NOT NULL AND expires_at > ?
  `);

  const updateResponseStmt = db.prepare(`
    UPDATE agent_step_idempotency
    SET response = ?, updated_at = ?
    WHERE run_id = ? AND step_id = ? AND request_hash = ?
  `);

  const failStmt = db.prepare(`
    UPDATE agent_step_idempotency
    SET status = ?, error_code = ?, error_status = ?, updated_at = ?
    WHERE run_id = ? AND step_id = ?
  `);

  const reacquireStmt = db.prepare(`
    UPDATE agent_step_idempotency
    SET status = ?, updated_at = ?, expires_at = ?
    WHERE run_id = ? AND step_id = ? AND request_hash = ? AND status = ?
  `);

  const purgeStmt = db.prepare(`
    DELETE FROM agent_step_idempotency WHERE expires_at <= ?
  `);

  function identityFor(row) {
    return {
      runId: row.run_id,
      stepId: row.step_id,
      requestHash: row.request_hash,
    };
  }

  function decryptResponse(row) {
    if (!row.response) return null;
    if (!cipher.isEncrypted(row.response)) {
      // 兼容首次上线前的短期明文记录：读取前原地加密，不把缓存当 miss 重调 provider。
      const encrypted = cipher.encrypt(row.response, identityFor(row));
      updateResponseStmt.run(
        encrypted,
        Date.now(),
        row.run_id,
        row.step_id,
        row.request_hash,
      );
      return row.response;
    }
    return cipher.decrypt(row.response, identityFor(row));
  }

  function mapRow(row) {
    return {
      runId: row.run_id,
      stepId: row.step_id,
      requestHash: row.request_hash,
      status: row.status,
      response: decryptResponse(row),
      usage: row.usage ? JSON.parse(row.usage) : null,
      errorCode: row.error_code,
      errorStatus: row.error_status,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      expiresAt: row.expires_at,
    };
  }

  const storeAPI = {
    /** 读取记录；过期记录视为不存在并顺手删除 */
    get(runId, stepId) {
      const row = getStmt.get(runId, stepId);
      if (!row) return null;
      if (row.expires_at <= Date.now()) {
        deleteStmt.run(runId, stepId);
        return null;
      }
      return mapRow(row);
    },

    /**
     * 创建 processing 记录。
     * @returns {boolean} true 表示抢到该 step；false 表示 (runId, stepId) 已存在（并发冲突）
     */
    createProcessing(runId, stepId, requestHash, ttlSeconds) {
      const now = Date.now();
      try {
        insertStmt.run(
          runId,
          stepId,
          requestHash,
          STEP_STATUS.PROCESSING,
          now,
          now,
          now + ttlSeconds * 1000,
        );
        return true;
      } catch (error) {
        if (isUniqueConstraintError(error)) return false;
        throw error;
      }
    },

    /**
     * failed_retryable 受控重试：仅当记录仍处于 failed_retryable 且 hash 一致时转回 processing。
     * @returns {boolean} true 表示成功转为 processing
     */
    reacquireProcessing(runId, stepId, requestHash, ttlSeconds) {
      const now = Date.now();
      const result = reacquireStmt.run(
        STEP_STATUS.PROCESSING,
        now,
        now + ttlSeconds * 1000,
        runId,
        stepId,
        requestHash,
        STEP_STATUS.FAILED_RETRYABLE,
      );
      return result.changes > 0;
    },

    /** 标记完成，加密暂存结构化响应 JSON 与 token usage */
    markCompleted(runId, stepId, response, usage) {
      const row = getStmt.get(runId, stepId);
      if (!row) {
        throw new Error(`Agent step 不存在，无法标记完成: ${runId}/${stepId}`);
      }
      const encryptedResponse = cipher.encrypt(JSON.stringify(response), identityFor(row));
      const result = completeStmt.run(
        STEP_STATUS.COMPLETED,
        encryptedResponse,
        usage ? JSON.stringify(usage) : null,
        Date.now(),
        runId,
        stepId,
        row.request_hash,
      );
      if (result.changes !== 1) {
        throw new Error(`Agent step 身份变化，拒绝写入完成响应: ${runId}/${stepId}`);
      }
    },

    /** 标记失败；retryable=false 为终态失败，重放时返回相同错误 */
    markFailed(runId, stepId, { retryable, errorCode = null, errorStatus = null } = {}) {
      failStmt.run(
        retryable ? STEP_STATUS.FAILED_RETRYABLE : STEP_STATUS.FAILED_FINAL,
        errorCode,
        errorStatus,
        Date.now(),
        runId,
        stepId,
      );
    },

    /** 删除所有过期记录，返回删除条数 */
    purgeExpired(now = Date.now()) {
      return purgeStmt.run(now).changes;
    },

    /** 仅暴露非敏感算法标识，供部署验收；不返回 key id。 */
    encryptionMetadata() {
      return { algorithm: cipher.algorithm };
    },
  };

  function migrateStoredResponses() {
    purgeStmt.run(Date.now());
    const rows = completedResponsesStmt.all(STEP_STATUS.COMPLETED, Date.now());
    const migrate = db.transaction(() => {
      let migrated = 0;
      let rotated = 0;
      for (const row of rows) {
        const identity = identityFor(row);
        if (!cipher.isEncrypted(row.response)) {
          updateResponseStmt.run(
            cipher.encrypt(row.response, identity),
            Date.now(),
            row.run_id,
            row.step_id,
            row.request_hash,
          );
          migrated += 1;
          continue;
        }
        const plaintext = cipher.decrypt(row.response, identity);
        if (cipher.needsRotation(row.response)) {
          updateResponseStmt.run(
            cipher.encrypt(plaintext, identity),
            Date.now(),
            row.run_id,
            row.step_id,
            row.request_hash,
          );
          rotated += 1;
        }
      }
      return { migrated, rotated };
    });
    return migrate();
  }

  storeAPI.migrationSummary = migrateStoredResponses();
  return storeAPI;
}

function isUniqueConstraintError(error) {
  return typeof error?.code === "string" && error.code.startsWith("SQLITE_CONSTRAINT");
}
