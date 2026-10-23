import { createHash, randomBytes, randomUUID } from "node:crypto";
import { GatewayError } from "../errors.js";
import { shanghaiDateString } from "../usage/quotaPolicy.js";

/**
 * 「一个发现」运行存储（实施包 03 §3.2/§4.2、02 §9 冻结字段）。
 *
 * 日批次：UNIQUE(subject, day_key) + 事务拦截当日第二个 run（T14）；
 * 上海日键（与 quotaPolicy/thoughtOrganizeBudgetStore 同口径，不用 usageStore 的 UTC 桶）。
 * 预留即算已用；仅「未 dispatch 即取消/租约过期」的 run 释放当日名额（03 §4.2）。
 *
 * run token：随机 32B 与 subject/device/controlRevision/runID 绑定，库内只存 sha256；
 * 每个阶段重新核对归属、版本、token 与租约，不只验签名与过期（03 §3.2）。
 *
 * 阶段推进：verify 必须在 candidates 成功后；同阶段 request hash 不可变（换 body 即冲突）。
 *
 * 阶段响应内存缓存（T17）：key = runID+stage+requestHash，TTL 5 分钟、条数与字节上限；
 * 重启或淘汰后，已 dispatched 的阶段返回 DISCOVERY_STAGE_RESULT_LOST——绝不重调模型补结果，
 * 本批终止（可靠性/隐私取舍：接受偶尔无新发现，不接受隐式双扣与持久化原文）。
 */

const DAY_RUN_LIMIT_CODE = "DISCOVERY_DAY_LIMIT";
const RELEASEABLE_STATUSES = new Set(["cancelled_undispatched"]);
const TERMINAL_STATUSES = new Set(["completed", "cancelled", "cancelled_undispatched", "expired"]);

// 阶段结果缓存上限：条数与总字节双限，超限按最旧淘汰（LRU 近似：插入序）
const STAGE_CACHE_MAX_ENTRIES = 64;
const STAGE_CACHE_MAX_TOTAL_BYTES = 2 * 1024 * 1024;
const STAGE_CACHE_TTL_MS = 5 * 60_000;

export function createDiscoveryRunStore(db, options = {}) {
  const now = options.now ?? (() => Date.now());
  const leaseMs = Number(options.leaseMs ?? 10 * 60_000);

  const getRun = db.prepare("SELECT * FROM discovery_runs WHERE run_id = ?");
  const getRunByDay = db.prepare("SELECT * FROM discovery_runs WHERE subject = ? AND day_key = ?");
  const insertRun = db.prepare(`
    INSERT INTO discovery_runs
      (run_id, subject, device_id, control_revision, scope_revision, source_manifest_digest,
       day_key, status, token_hash, lease_expires_at, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)
  `);
  const deleteRun = db.prepare("DELETE FROM discovery_runs WHERE run_id = ? AND status = ? AND candidate_dispatched = 0");
  const updateRun = db.prepare(`
    UPDATE discovery_runs SET status = ?, candidate_request_hash = COALESCE(?, candidate_request_hash),
      verify_request_hash = COALESCE(?, verify_request_hash),
      candidate_dispatched = MAX(candidate_dispatched, ?), verify_dispatched = MAX(verify_dispatched, ?),
      lease_expires_at = ?, updated_at = ?
    WHERE run_id = ?
  `);
  const listActive = db.prepare("SELECT * FROM discovery_runs WHERE status = 'active'");

  // 阶段响应内存缓存：key = `${runID}:${stage}:${requestHash}`
  const stageCache = new Map();

  function shanghaiDay() {
    return shanghaiDateString(new Date(now()));
  }

  /**
   * 创建 run（当日批次预留）。同 run_id 重试（网络重发）按 request 幂等返回原 token；
   * 当日已有 run：仅可释放名额的终态行（未 dispatch 的取消/过期）让位后重建，否则 429。
   */
  function createRun({ runId, subject, deviceId, control, sourceManifestDigest, requestId, requestHash, idempotency }) {
    const ts = now();
    const dayKey = shanghaiDay();
    const token = randomBytes(32).toString("base64url");
    const tokenHash = sha256(token);
    const leaseExpiresAt = ts + leaseMs;

    // 幂等：同 requestId 重试返回首次签发的 token（result_meta 只含能力令牌与计数器，无用户内容）
    if (idempotency && requestId && requestHash) {
      const replay = idempotency({ requestId, subject, kind: "run_create", requestHash });
      if (replay) return { run: getRun.get(replay.result.runId), runToken: replay.result.runToken, replayed: true };
    }

    const persist = db.transaction(() => {
      try {
        insertRun.run(runId, subject, deviceId, control.revision, control.scopeRevision,
          sourceManifestDigest ?? null, dayKey, tokenHash, leaseExpiresAt, ts, ts);
      } catch (error) {
        if (!/UNIQUE constraint failed/i.test(String(error?.message ?? ""))) throw error;
        // 同 run_id 撞主键（跨日重用等）：正确重试路径是 requestId 幂等或换新 runID
        if (String(error.message).includes("discovery_runs.run_id")) {
          throw new GatewayError("DISCOVERY_RUN_CONFLICT", "Run id already used", 409);
        }
        const existing = getRunByDay.get(subject, dayKey);
        // 当日名额释放规则：仅「未 dispatch 即取消/租约过期」的行可让位（03 §4.2 预留可释放）
        const releaseable = existing
          && existing.candidate_dispatched === 0
          && (RELEASEABLE_STATUSES.has(existing.status)
            || (existing.status === "active" && existing.lease_expires_at <= ts));
        if (releaseable) {
          const removed = deleteRun.run(existing.run_id, existing.status);
          if (removed.changes === 1) {
            insertRun.run(runId, subject, deviceId, control.revision, control.scopeRevision,
              sourceManifestDigest ?? null, dayKey, tokenHash, leaseExpiresAt, ts, ts);
            return;
          }
        }
        throw new GatewayError(DAY_RUN_LIMIT_CODE, "Daily discovery batch already used", 429, {
          resetAt: `${nextDay(dayKey)}T00:00:00+08:00`,
        });
      }
    });
    persist();

    const run = getRun.get(runId);
    if (!run) {
      throw new GatewayError("DISCOVERY_RUN_CONFLICT", "Run id already used", 409);
    }
    if (idempotency && requestId && requestHash) {
      idempotency({
        requestId, subject, kind: "run_create", requestHash,
        record: { status: "committed", resultMeta: { runId, runToken: token } },
      });
    }
    return { run, runToken: token, replayed: false };
  }

  /** 阶段闸门：归属/版本/token/租约/状态全量复核（03 §3.2 每步重核，不只验签名）。 */
  function authorizeStage({ runId, subject, deviceId, runToken, stage }) {
    const run = getRun.get(runId);
    if (!run || run.subject !== subject || run.device_id !== deviceId) {
      throw new GatewayError("DISCOVERY_RUN_NOT_FOUND", "Run not found for this account/device", 404);
    }
    if (TERMINAL_STATUSES.has(run.status)) {
      throw new GatewayError("DISCOVERY_RUN_CLOSED", `Run is ${run.status}`, 409, { status: run.status });
    }
    const ts = now();
    if (run.lease_expires_at <= ts) {
      closeRun(run.run_id, "expired", ts);
      throw new GatewayError("DISCOVERY_LEASE_EXPIRED", "Run lease has expired", 409);
    }
    if (!runToken || run.token_hash !== sha256(String(runToken))) {
      throw new GatewayError("DISCOVERY_RUN_TOKEN_INVALID", "Run token is invalid", 403);
    }
    if (stage === "verify" && run.candidate_dispatched !== 1) {
      throw new GatewayError("DISCOVERY_STAGE_ORDER", "Verify requires a successful candidates stage", 409);
    }
    return run;
  }

  /** 版本复核（控制/范围代数仍匹配）——阶段端点在 authorize 之后单独调用。 */
  function assertControlCurrent(run, control) {
    if (run.control_revision !== control.revision || run.scope_revision !== control.scopeRevision) {
      throw new GatewayError("DISCOVERY_CONTROL_CHANGED", "Control or scope revision changed", 409);
    }
    if (!control.enabled) {
      throw new GatewayError("DISCOVERY_CONTROL_DISABLED", "Discovery has been disabled", 409);
    }
  }

  /** 阶段请求 hash 不可变登记：同阶段换 body → 409；返回该阶段是否已 dispatch（重放判定用）。 */
  function claimStageRequest({ run, stage, requestHash }) {
    const column = stage === "candidates" ? "candidate_request_hash" : "verify_request_hash";
    const existing = run[column];
    if (existing && existing !== requestHash) {
      throw new GatewayError("DISCOVERY_STAGE_CONFLICT", "Stage was already used with a different payload", 409);
    }
    const ts = now();
    updateRun.run(
      run.status, stage === "candidates" ? requestHash : null, stage === "verify" ? requestHash : null,
      0, 0, run.lease_expires_at, ts, run.run_id,
    );
    const fresh = getRun.get(run.run_id);
    return { alreadyDispatched: fresh[stage === "candidates" ? "candidate_dispatched" : "verify_dispatched"] === 1 };
  }

  /** 标记 dispatch 已发生（调用上游前先落库：进程崩溃也不得当作未发生）。 */
  function markDispatched({ run, stage }) {
    const ts = now();
    updateRun.run(
      "active", null, null,
      stage === "candidates" ? 1 : 0, stage === "verify" ? 1 : 0,
      run.lease_expires_at, ts, run.run_id,
    );
  }

  function completeRun({ runId, status }) {
    closeRun(runId, status, now());
  }

  /**
   * 上游调用确认未发生（预算/输入校验在 reserve 阶段拒绝、prompt 缺失等）时
   * 释放当日名额：删行让位下一个 run（03 §4.2「调用上游前校验失败可释放」）。
   * 调用方契约：仅限「candidates 阶段且上游确定未被触达」的失败路径——此时
   * candidate_dispatched=1 是调用前的预留标记而非真实发生；verify 阶段的失败
   * 说明 candidates 已真实发生上游调用，走 completeRun(cancelled) 保留已用名额。
   */
  function releaseUndispatched(runId) {
    const run = getRun.get(runId);
    if (!run) return;
    if (run.verify_dispatched === 1) return;
    db.prepare("DELETE FROM discovery_runs WHERE run_id = ? AND verify_dispatched = 0").run(runId);
  }

  function closeRun(runId, status, ts) {
    const run = getRun.get(runId);
    if (!run || TERMINAL_STATUSES.has(run.status)) return;
    // 未 dispatch 的取消/过期释放当日名额；已 dispatch 的按已用保留行
    const dispatched = run.candidate_dispatched === 1 || run.verify_dispatched === 1;
    const effective = dispatched ? status : (status === "cancelled" ? "cancelled_undispatched" : status);
    updateRun.run(effective, null, null, 0, 0, run.lease_expires_at, ts, runId);
    if (!dispatched) {
      // 未发生任何上游调用：直接删行释放 UNIQUE 名额（保留请求台账于 discovery_requests）
      deleteRun.run(runId, effective);
    }
  }

  function cancel({ runId, subject, deviceId }) {
    const run = getRun.get(runId);
    if (!run || run.subject !== subject || run.device_id !== deviceId) {
      throw new GatewayError("DISCOVERY_RUN_NOT_FOUND", "Run not found for this account/device", 404);
    }
    if (TERMINAL_STATUSES.has(run.status)) return { run: getRun.get(runId) ?? run, alreadyClosed: true };
    closeRun(runId, "cancelled", now());
    const fresh = getRun.get(runId);
    return { run: fresh ?? getRun.get(runId) ?? run, alreadyClosed: false };
  }

  /** 租约过期保守终态（进程内清扫；阶段闸门内也有即时检查兜底）。 */
  function sweepExpired() {
    const ts = now();
    let swept = 0;
    for (const run of listActive.all()) {
      if (run.lease_expires_at <= ts) {
        closeRun(run.run_id, "expired", ts);
        swept += 1;
      }
    }
    return swept;
  }

  // ===== 阶段响应内存缓存（T17）=====

  function cacheStageResult({ runId, stage, requestHash, envelope }) {
    const key = `${runId}:${stage}:${requestHash}`;
    const payload = JSON.stringify(envelope);
    evictIfNeeded(payload.length);
    stageCache.set(key, { payload, size: payload.length, expiresAt: now() + STAGE_CACHE_TTL_MS });
  }

  /**
   * 取阶段缓存：命中 → { hit: true, envelope }；
   * 未命中且该阶段已 dispatched → 抛 DISCOVERY_STAGE_RESULT_LOST（绝不重调模型）；
   * 未命中且未 dispatched → { hit: false }（正常调用路径）。
   */
  function readStageResult({ run, stage, requestHash }) {
    const key = `${run.run_id}:${stage}:${requestHash}`;
    const entry = stageCache.get(key);
    if (entry && entry.expiresAt > now()) {
      stageCache.delete(key);
      stageCache.set(key, entry); // 触碰前移（近似 LRU）
      return { hit: true, envelope: JSON.parse(entry.payload) };
    }
    if (entry) stageCache.delete(key);
    const dispatched = stage === "candidates" ? run.candidate_dispatched === 1 : run.verify_dispatched === 1;
    if (dispatched) {
      throw new GatewayError(
        "DISCOVERY_STAGE_RESULT_LOST",
        "Stage result is no longer available and will not be re-generated",
        410,
      );
    }
    return { hit: false };
  }

  function evictIfNeeded(incomingBytes) {
    let total = [...stageCache.values()].reduce((sum, entry) => sum + entry.size, 0);
    while (stageCache.size + 1 > STAGE_CACHE_MAX_ENTRIES || total + incomingBytes > STAGE_CACHE_MAX_TOTAL_BYTES) {
      const oldest = stageCache.keys().next();
      if (oldest.done) break;
      total -= stageCache.get(oldest.value)?.size ?? 0;
      stageCache.delete(oldest.value);
    }
  }

  /** 进程内诊断视图（不含任何用户内容）。 */
  function stageCacheStats() {
    return {
      entries: stageCache.size,
      bytes: [...stageCache.values()].reduce((sum, entry) => sum + entry.size, 0),
    };
  }

  return {
    createRun,
    authorizeStage,
    assertControlCurrent,
    claimStageRequest,
    markDispatched,
    completeRun,
    releaseUndispatched,
    cancel,
    sweepExpired,
    cacheStageResult,
    readStageResult,
    stageCacheStats,
    get: (runId) => getRun.get(runId) ?? null,
  };
}

/** 服务端签发的一次性请求台账 ID（客户端未传 requestId 时的兜底） */
export function newDiscoveryRequestId() {
  return randomUUID();
}

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function nextDay(dayKey) {
  const [year, month, day] = dayKey.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day + 1)).toISOString().slice(0, 10);
}
