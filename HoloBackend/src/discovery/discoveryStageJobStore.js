import { createCipheriv, createDecipheriv, createHash, hkdfSync, randomBytes } from "node:crypto";

/**
 * 「一个发现」候选异步作业存储（1.1.5 S3/S4/S5，2026-11-02）。
 *
 * 为什么要落库：候选生成是长调用（旧链路 60–71s 同步长连接）。客户端锁屏、切走、断连，
 * 或者服务端发版重启，都会让「已计费的结果」随连接一起丢失。作业化之后，客户端随时取件；
 * 结果以密文落库，扛得住重启。
 *
 * 隐私边界（与云端分析任务同纪律）：
 * - 只存元数据（归属、token 摘要、阶段 hash、状态、错误码/拒因枚举）+ 结果密文，不存明文；
 * - 密钥：部署密钥经 HKDF-SHA256（info=holo-discovery-stage-job-v1）派生，与云端分析
 *   域隔离，不新增生产 env；AES-256-GCM，AAD=runID（密文不可跨 run 挪用）；
 * - 即焚：核验成功后删行；租约到期（默认 24h）由 sweepExpired 删行。
 *
 * 状态：running → completed | failed。只允许从 running 迁出（晚到的旧进程结果不得覆盖已判中断的作业）。
 */

const HKDF_INFO = "holo-discovery-stage-job-v1";

export function createDiscoveryStageJobStore(db, { encryptionKey, now = () => Date.now() } = {}) {
  const raw = typeof encryptionKey === "string" && encryptionKey.length > 0
    ? Buffer.from(encryptionKey, "base64")
    : null;
  if (!raw || raw.length !== 32) {
    throw new Error("DISCOVERY_JOB_ENCRYPTION_KEY_INVALID");
  }
  const key = Buffer.from(hkdfSync("sha256", raw, Buffer.alloc(0), Buffer.from(HKDF_INFO, "utf8"), 32));

  const getJob = db.prepare("SELECT * FROM discovery_stage_jobs WHERE run_id = ?");
  const insertJob = db.prepare(`
    INSERT OR IGNORE INTO discovery_stage_jobs
      (run_id, subject, device_id, token_hash, stage, request_hash, status, created_at, updated_at, expires_at)
    VALUES (?, ?, ?, ?, ?, ?, 'running', ?, ?, ?)
  `);
  const completeJob = db.prepare(`
    UPDATE discovery_stage_jobs SET status = 'completed', result_ciphertext = ?, updated_at = ?
    WHERE run_id = ? AND status = 'running'
  `);
  const failJob = db.prepare(`
    UPDATE discovery_stage_jobs SET status = 'failed', error_code = ?, error_reason = ?, updated_at = ?
    WHERE run_id = ? AND status = 'running'
  `);
  const deleteJob = db.prepare("DELETE FROM discovery_stage_jobs WHERE run_id = ?");
  const listRunning = db.prepare("SELECT run_id FROM discovery_stage_jobs WHERE status = 'running'");
  const deleteExpired = db.prepare("DELETE FROM discovery_stage_jobs WHERE expires_at <= ?");

  function encrypt(plaintext, runId) {
    const iv = randomBytes(12);
    const cipher = createCipheriv("aes-256-gcm", key, iv);
    cipher.setAAD(Buffer.from(runId, "utf8"));
    const ct = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
    return JSON.stringify({
      v: 1,
      iv: iv.toString("base64"),
      tag: cipher.getAuthTag().toString("base64"),
      ct: ct.toString("base64"),
    });
  }

  function decrypt(boxedText, runId) {
    const boxed = JSON.parse(boxedText);
    const decipher = createDecipheriv("aes-256-gcm", key, Buffer.from(boxed.iv, "base64"));
    decipher.setAAD(Buffer.from(runId, "utf8"));
    decipher.setAuthTag(Buffer.from(boxed.tag, "base64"));
    return Buffer.concat([decipher.update(Buffer.from(boxed.ct, "base64")), decipher.final()]).toString("utf8");
  }

  return {
    available: true,

    /** 登记 running 作业；同 run 已有作业时不覆盖，返回 { inserted:false }。 */
    start({ runId, subject, deviceId, tokenHash, stage, requestHash, expiresAt }) {
      const ts = now();
      const result = insertJob.run(runId, subject, deviceId, tokenHash, stage, requestHash, ts, ts, expiresAt);
      return { inserted: result.changes === 1 };
    },

    get(runId) {
      return getJob.get(runId) ?? null;
    },

    /** 成功落密文；只能从 running 迁出。返回是否生效。 */
    complete({ runId, payload }) {
      const ciphertext = encrypt(JSON.stringify(payload), runId);
      return completeJob.run(ciphertext, now(), runId).changes === 1;
    },

    /** 失败只记错误码与拒因枚举（无用户内容）；只能从 running 迁出。 */
    fail({ runId, code, reason = null }) {
      const safeReason = typeof reason === "string" ? reason.slice(0, 80) : null;
      return failJob.run(String(code ?? "UPSTREAM_ERROR").slice(0, 64), safeReason, now(), runId).changes === 1;
    },

    /** 解密完成作业的载荷；非 completed 返回 null。 */
    readResult(runId) {
      const job = getJob.get(runId);
      if (!job || job.status !== "completed" || !job.result_ciphertext) return null;
      return JSON.parse(decrypt(job.result_ciphertext, runId));
    },

    purge(runId) {
      deleteJob.run(runId);
    },

    /** 进程启动：上一进程遗留的 running 作业已无执行者，统一判中断。返回受影响 runId 列表。 */
    recoverInterrupted() {
      const interrupted = [];
      for (const { run_id: runId } of listRunning.all()) {
        if (failJob.run("DISCOVERY_JOB_INTERRUPTED", null, now(), runId).changes === 1) interrupted.push(runId);
      }
      return interrupted;
    },

    sweepExpired() {
      return deleteExpired.run(now()).changes;
    },
  };
}

/** run token 摘要（与 discoveryRunStore 同口径：sha256 hex）。 */
export function hashRunToken(token) {
  return createHash("sha256").update(String(token)).digest("hex");
}
