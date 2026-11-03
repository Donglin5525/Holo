import { getQuotaRule, quotaPeriodForDate } from "./quotaPolicy.js";

export function createQuotaActionLedgerStore(
  db,
  { now = () => new Date(), reservationTtlMs = 15 * 60 * 1000, replayGraceMs = 10 * 60 * 1000 } = {},
) {
  const getAction = db.prepare(`
    SELECT status, updated_at_ms FROM quota_action_ledger
    WHERE subject_id = ? AND quota_type = ? AND period_key = ? AND action_id = ?
  `);
  const countByStatus = db.prepare(`
    SELECT
      SUM(CASE WHEN status = 'committed' THEN 1 ELSE 0 END) AS committed,
      SUM(CASE WHEN status = 'reserved' THEN 1 ELSE 0 END) AS reserved
    FROM quota_action_ledger
    WHERE subject_id = ? AND quota_type = ? AND period_key = ?
  `);
  const insertReserved = db.prepare(`
    INSERT INTO quota_action_ledger (
      subject_id, quota_type, period_key, action_id, tier, status,
      created_at_ms, updated_at_ms
    ) VALUES (?, ?, ?, ?, ?, 'reserved', ?, ?)
  `);
  const commitReserved = db.prepare(`
    UPDATE quota_action_ledger SET status = 'committed', updated_at_ms = ?
    WHERE subject_id = ? AND quota_type = ? AND period_key = ? AND action_id = ?
  `);
  const releaseReserved = db.prepare(`
    DELETE FROM quota_action_ledger
    WHERE subject_id = ? AND quota_type = ? AND period_key = ?
      AND action_id = ? AND status = 'reserved'
  `);
  const purgeStale = db.prepare(`
    DELETE FROM quota_action_ledger WHERE status = 'reserved' AND updated_at_ms < ?
  `);
  const resetSubject = db.prepare(`DELETE FROM quota_action_ledger WHERE subject_id = ?`);

  function identity(input) {
    const tier = input.tier === "plus" ? "plus" : "free";
    const rule = getQuotaRule(tier, input.quotaType);
    const period = quotaPeriodForDate(now(), rule.period);
    return { ...input, tier, rule, ...period };
  }

  function snapshot(input) {
    const value = identity(input);
    const row = countByStatus.get(value.subjectId, value.quotaType, value.periodKey) ?? {};
    const used = Number(row.committed ?? 0);
    const reserved = Number(row.reserved ?? 0);
    return {
      quotaType: value.quotaType,
      tier: value.tier,
      period: value.rule.period,
      periodKey: value.periodKey,
      limit: value.rule.limit,
      used,
      remaining: Math.max(value.rule.limit - used, 0),
      available: Math.max(value.rule.limit - used - reserved, 0),
      resetAt: value.resetAt,
      maxSeconds: value.rule.maxSeconds ?? null,
    };
  }

  return {
    peek(input) {
      return snapshot(input);
    },

    reserve(input) {
      const value = identity(input);
      const attemptReserve = db.transaction(() => {
        purgeStale.run(now().getTime() - reservationTtlMs);
        // 幂等键防复用（2026-10-31 审计 D1）：actionId 可由客户端任意指定，
        // 已提交的旧键被重放时若是新请求必须重新计数，否则一个键吃掉整个次数池。
        // 合法重试只会重放客户端自己的原始键（在途 reserved / 宽限期内 committed）；
        // #N 后缀键是服务端铸的，命中一律继续走链，不给「隔次免费」留缝。
        let actionId = value.actionId;
        for (let attempt = 1; ; attempt += 1) {
          const existing = getAction.get(
            value.subjectId,
            value.quotaType,
            value.periodKey,
            actionId,
          );
          if (!existing) break;
          const baseId = attempt === 1;
          const freshCommit =
            baseId &&
            existing.status === "committed" &&
            now().getTime() - existing.updated_at_ms <= replayGraceMs;
          if (baseId && (existing.status === "reserved" || freshCommit)) {
            // 凭证字段（subjectId/quotaType/actionId）必须随返回值带回：
            // 调用方（如云端执行器）会把返回值原样回传给 commit/release，
            // 缺了标识字段 WHERE 全空匹配，commit 静默失效（2026-09-19 实锤：
            // 云端深度分析完成后额度永远停留 reserved）。
            return {
              subjectId: value.subjectId,
              actionId,
              ...snapshot(value),
              allowed: true,
              duplicate: true,
              status: existing.status,
            };
          }
          actionId = `${value.actionId}#${attempt}`;
        }

        const before = snapshot(value);
        if (before.available <= 0) {
          return { subjectId: value.subjectId, actionId, ...before, allowed: false, reason: "quota_exceeded" };
        }

        const timestamp = now().getTime();
        insertReserved.run(
          value.subjectId,
          value.quotaType,
          value.periodKey,
          actionId,
          value.tier,
          timestamp,
          timestamp,
        );
        return {
          subjectId: value.subjectId,
          actionId,
          ...snapshot(value),
          allowed: true,
          duplicate: false,
          status: "reserved",
        };
      });
      // 并发重放同键计算撞后缀时事务以 UNIQUE 冲突回滚，重读一遍再落（对齐 discoveryControlStore.recordRequest 的竞态处理）
      for (let retry = 0; ; retry += 1) {
        try {
          return attemptReserve();
        } catch (error) {
          if (retry >= 2 || !/^UNIQUE constraint/i.test(String(error?.message))) throw error;
        }
      }
    },

    commit(input) {
      const value = identity(input);
      commitReserved.run(
        now().getTime(),
        value.subjectId,
        value.quotaType,
        value.periodKey,
        value.actionId,
      );
      return snapshot(value);
    },

    release(input) {
      const value = identity(input);
      releaseReserved.run(
        value.subjectId,
        value.quotaType,
        value.periodKey,
        value.actionId,
      );
      return snapshot(value);
    },

    reset(subjectId) {
      return resetSubject.run(subjectId).changes;
    },
  };
}
