import { shanghaiDateString } from "../usage/quotaPolicy.js";

/**
 * 想法自动整理 V2 费用台账（方案 §6.3）。
 *
 * 全后端第一个按人民币金额计量的预算组件：会员配额体系按「次数」计数，
 * 本模块按「金额」控制（单任务上限 + 计费主体日预算），单位为 micro-CNY
 * 整数（1 CNY = 1_000_000 micro），全程无浮点累加误差。
 *
 * 台账只存元数据：计费主体、随机操作 ID、尝试次数、预留/消耗金额与状态。
 * 不含正文、标签或模型结果（方案 §2.2）。
 *
 * 预留/结算协议：
 * - 每次上游调用前按保守估算预留（est），调用结束按实际 usage 结算（actual）；
 * - usage 丢失（上游结果未返回）按已预留上界计入，不当作免费重试；
 * - 进程崩溃留下的悬挂预留由 recoverStale 按上界转入已消耗。
 */

const STALE_OPERATION_MS = 10 * 60 * 1000;
const IN_PROGRESS_GUARD_MS = 90 * 1000;

const MIGRATION_SQL = `
  CREATE TABLE IF NOT EXISTS thought_organize_budget (
    subject_id TEXT NOT NULL,
    day_key TEXT NOT NULL,
    committed_micro INTEGER NOT NULL DEFAULT 0,
    reserved_micro INTEGER NOT NULL DEFAULT 0,
    updated_at TEXT NOT NULL DEFAULT (datetime('now')),
    PRIMARY KEY (subject_id, day_key)
  );
  CREATE TABLE IF NOT EXISTS thought_organize_operations (
    operation_id TEXT PRIMARY KEY,
    subject_id TEXT NOT NULL,
    day_key TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'running',
    attempts INTEGER NOT NULL DEFAULT 1,
    reserved_micro INTEGER NOT NULL DEFAULT 0,
    committed_micro INTEGER NOT NULL DEFAULT 0,
    created_at TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
  );
`;

export function createThoughtOrganizeBudgetStore(db, options = {}) {
  if (db) {
    db.exec(MIGRATION_SQL);
  }

  const nowMs = options.now ?? (() => Date.now());

  function statements(db) {
    return {
      getOperation: db.prepare("SELECT * FROM thought_organize_operations WHERE operation_id = ?"),
      insertOperation: db.prepare(`
        INSERT INTO thought_organize_operations
          (operation_id, subject_id, day_key, status, attempts, reserved_micro, committed_micro)
        VALUES (?, ?, ?, 'running', ?, ?, 0)
        ON CONFLICT(operation_id) DO UPDATE SET
          status = 'running',
          attempts = excluded.attempts,
          reserved_micro = excluded.reserved_micro,
          updated_at = datetime('now')
      `),
      updateOperationSettle: db.prepare(`
        UPDATE thought_organize_operations SET
          status = ?,
          reserved_micro = ?,
          committed_micro = committed_micro + ?,
          updated_at = datetime('now')
        WHERE operation_id = ?
      `),
      getBudget: db.prepare(
        "SELECT committed_micro, reserved_micro FROM thought_organize_budget WHERE subject_id = ? AND day_key = ?",
      ),
      upsertBudgetReserve: db.prepare(`
        INSERT INTO thought_organize_budget (subject_id, day_key, reserved_micro, committed_micro)
        VALUES (?, ?, ?, 0)
        ON CONFLICT(subject_id, day_key) DO UPDATE SET
          reserved_micro = reserved_micro + excluded.reserved_micro,
          updated_at = datetime('now')
      `),
      settleBudget: db.prepare(`
        UPDATE thought_organize_budget SET
          reserved_micro = MAX(0, reserved_micro - ?),
          committed_micro = committed_micro + ?,
          updated_at = datetime('now')
        WHERE subject_id = ? AND day_key = ?
      `),
      listStaleOperations: db.prepare(`
        SELECT operation_id, subject_id, day_key, reserved_micro FROM thought_organize_operations
        WHERE status = 'running' AND updated_at < datetime('now', ?)
      `),
      failStaleOperation: db.prepare(`
        UPDATE thought_organize_operations SET status = 'failed', updated_at = datetime('now')
        WHERE operation_id = ?
      `),
    };
  }

  const stmts = db ? statements(db) : null;

  /** 上海时区日窗口的 resetAt（次日 00:00 +08:00）。 */
  function resetAtForDayKey(dayKey) {
    const [year, month, day] = dayKey.split("-").map(Number);
    const next = new Date(Date.UTC(year, month - 1, day + 1));
    return `${next.toISOString().slice(0, 10)}T00:00:00+08:00`;
  }

  /**
   * 开启（或重开）一个逻辑整理任务并完成首笔预留。
   * 返回：
   *   { allowed: true, dayKey, attempts }
   *   { allowed: false, reason: "in_progress" }
   *   { allowed: false, reason: "budget_exceeded", resetAt, dailyBudgetMicro }
   */
  function beginOperation({ subjectId, operationId, estimateMicro, dailyBudgetMicro, now = nowMs() }) {
    if (!stmts) return { allowed: true, dayKey: null, attempts: 1 }; // 无持久层（纯测试）时放行
    const dayKey = shanghaiDateString(new Date(now));
    const existing = stmts.getOperation.get(operationId);

    if (existing) {
      const isLive = existing.status === "running"
        && now - Date.parse(`${existing.updated_at.replace(" ", "T")}Z`) < IN_PROGRESS_GUARD_MS;
      if (isLive) {
        return { allowed: false, reason: "in_progress" };
      }
      if (existing.status === "running") {
        // 崩溃残留：悬挂预留按上界计入已消耗，再允许重开
        carryStaleIntoCommitted(existing);
      }
    }

    const budget = stmts.getBudget.get(subjectId, dayKey)
      ?? { committed_micro: 0, reserved_micro: 0 };
    const totalAfterReserve = budget.committed_micro + budget.reserved_micro + estimateMicro;
    if (totalAfterReserve > dailyBudgetMicro) {
      return {
        allowed: false,
        reason: "budget_exceeded",
        resetAt: resetAtForDayKey(dayKey),
        dailyBudgetMicro,
      };
    }

    const attempts = existing ? existing.attempts + 1 : 1;
    db.transaction(() => {
      stmts.upsertBudgetReserve.run(subjectId, dayKey, estimateMicro);
      stmts.insertOperation.run(operationId, subjectId, dayKey, attempts, estimateMicro);
    })();
    return { allowed: true, dayKey, attempts };
  }

  /** 崩溃残留的运行中任务：reserved 转入 committed（按上界计费），状态落 failed。 */
  function carryStaleIntoCommitted(existing) {
    if (existing.reserved_micro <= 0) {
      stmts.failStaleOperation.run(existing.operation_id);
      return;
    }
    db.transaction(() => {
      stmts.settleBudget.run(
        existing.reserved_micro,
        existing.reserved_micro,
        existing.subject_id,
        existing.day_key,
      );
      stmts.updateOperationSettle.run("failed", 0, existing.reserved_micro, existing.operation_id);
    })();
  }

  /**
   * 结算一次任务：撤销预留 est、计入 actual（actual 为 null 时按 est 上界计入）。
   * status: completed | failed。
   */
  function settleOperation({ operationId, estimateMicro, actualMicro, status, now = nowMs() }) {
    if (!stmts) return;
    const existing = stmts.getOperation.get(operationId);
    if (!existing || existing.status !== "running") return;
    const settleMicro = actualMicro == null ? Math.max(estimateMicro, 0) : actualMicro;
    db.transaction(() => {
      stmts.settleBudget.run(estimateMicro, settleMicro, existing.subject_id, existing.day_key);
      stmts.updateOperationSettle.run(status, 0, settleMicro, operationId);
    })();
  }

  /** 追加预留（同一任务的 R/B 阶段调用前）；预算不足返回 false。 */
  function reserveMore({ operationId, estimateMicro, dailyBudgetMicro, now = nowMs() }) {
    if (!stmts) return true;
    const existing = stmts.getOperation.get(operationId);
    if (!existing || existing.status !== "running") return false;
    const dayKey = shanghaiDateString(new Date(now));
    const budget = stmts.getBudget.get(existing.subject_id, existing.day_key)
      ?? { committed_micro: 0, reserved_micro: 0 };
    if (budget.committed_micro + budget.reserved_micro + estimateMicro > dailyBudgetMicro) {
      return false;
    }
    db.transaction(() => {
      stmts.upsertBudgetReserve.run(existing.subject_id, existing.day_key, estimateMicro);
      db.prepare(
        "UPDATE thought_organize_operations SET reserved_micro = reserved_micro + ?, updated_at = datetime('now') WHERE operation_id = ?",
      ).run(estimateMicro, operationId);
    })();
    return true;
  }

  /** 进程启动恢复：把超时运行中的悬挂预留按上界计入，避免预算泄漏成无限可用。 */
  function recoverStale() {
    if (!stmts) return 0;
    const staleMinutes = `-${Math.ceil(STALE_OPERATION_MS / 60000)} minutes`;
    const rows = stmts.listStaleOperations.all(staleMinutes);
    for (const row of rows) {
      carryStaleIntoCommitted(row);
    }
    return rows.length;
  }

  function dailySnapshot(subjectId, now = nowMs()) {
    if (!stmts) return { committedMicro: 0, reservedMicro: 0 };
    const dayKey = shanghaiDateString(new Date(now));
    const budget = stmts.getBudget.get(subjectId, dayKey)
      ?? { committed_micro: 0, reserved_micro: 0 };
    return {
      dayKey,
      committedMicro: budget.committed_micro,
      reservedMicro: budget.reserved_micro,
      resetAt: resetAtForDayKey(dayKey),
    };
  }

  return {
    beginOperation,
    reserveMore,
    settleOperation,
    recoverStale,
    dailySnapshot,
  };
}
