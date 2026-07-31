import { getQuotaRule, quotaPeriodForDate } from "./quotaPolicy.js";

export function createQuotaActionLedgerStore(
  db,
  { now = () => new Date(), reservationTtlMs = 15 * 60 * 1000 } = {},
) {
  const getAction = db.prepare(`
    SELECT status FROM quota_action_ledger
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
      return db.transaction(() => {
        purgeStale.run(now().getTime() - reservationTtlMs);
        const existing = getAction.get(
          value.subjectId,
          value.quotaType,
          value.periodKey,
          value.actionId,
        );
        if (existing) {
          return { ...snapshot(value), allowed: true, duplicate: true, status: existing.status };
        }

        const before = snapshot(value);
        if (before.available <= 0) {
          return { ...before, allowed: false, reason: "quota_exceeded" };
        }

        const timestamp = now().getTime();
        insertReserved.run(
          value.subjectId,
          value.quotaType,
          value.periodKey,
          value.actionId,
          value.tier,
          timestamp,
          timestamp,
        );
        return { ...snapshot(value), allowed: true, duplicate: false, status: "reserved" };
      })();
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
