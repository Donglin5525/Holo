/**
 * 目标闭环契约（2026-10-20 最终规格 §6.4 / §6.5）
 *
 * - goalScope：目标分析范围，客户端代码冻结随快照上云；本模块做白名单校验
 *   （app.js 上传时拒绝非法值；executor 防御性二次校验）并原样回显进结果。
 * - goalReview：该目标的统一事实快照（GoalEvaluationSnapshot），确定性数字的
 *   唯一来源。注入冻结块 + 数字白名单 + 证据池种子，模型解释、不重算。
 * - goalAdjustmentDraft：模型在 final_claims 里提出的目标修正草案。服务端按
 *   操作白名单消毒（kind 合法、引用必须落在 goalReview 的对象/绑定集合内、
 *   数量/长度封顶），身份字段（draftID/goalID/baseRevisionID/digest/时间戳）
 *   由服务端从 goalScope 生成，模型不得伪造。客户端还有第二道闸。
 */

import { randomUUID } from "node:crypto";

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const ALLOWED_OPERATION_KINDS = new Set([
  "create_task", "reuse_task", "update_task",
  "create_habit", "reuse_habit", "update_habit",
  "create_budget", "update_budget",
  "end_binding", "replace_binding",
  "update_fund_schedule", "update_review", "change_success_criteria",
]);

const MAX_OPERATIONS = 12;
export const MAX_GOAL_REVIEW_BYTES = 64 * 1024;

function str(value, max) {
  return typeof value === "string" && value.length > 0 && value.length <= max ? value : null;
}

function isoDate(value) {
  if (typeof value !== "string") return null;
  const ms = Date.parse(value);
  return Number.isFinite(ms) ? { text: value, ms } : null;
}

/** 白名单校验 + 规范化：非法返回 { ok:false, reason }；合法返回 { ok:true, scope } */
export function normalizeGoalScope(raw) {
  if (raw == null || typeof raw !== "object" || Array.isArray(raw)) {
    return { ok: false, reason: "goalScope 必须是对象" };
  }
  if (raw.schemaVersion !== undefined && raw.schemaVersion !== 1) {
    return { ok: false, reason: "goalScope.schemaVersion 只支持 1" };
  }
  for (const key of ["goalID", "planRevisionID", "reviewID"]) {
    if (!UUID_RE.test(String(raw[key] ?? ""))) {
      return { ok: false, reason: `goalScope.${key} 必须是 UUID` };
    }
  }
  const windowStart = isoDate(raw.windowStart);
  const windowEndExclusive = isoDate(raw.windowEndExclusive);
  const snapshotCutoffAt = isoDate(raw.snapshotCutoffAt);
  if (!windowStart || !windowEndExclusive || !snapshotCutoffAt) {
    return { ok: false, reason: "goalScope 窗口与截止必须是 ISO8601 字符串" };
  }
  if (windowStart.ms >= windowEndExclusive.ms) {
    return { ok: false, reason: "goalScope.windowStart 必须早于 windowEndExclusive" };
  }
  const timeZoneID = str(raw.timeZoneID, 64);
  const sourceDigest = str(raw.sourceDigest, 128);
  if (!timeZoneID || !sourceDigest) {
    return { ok: false, reason: "goalScope.timeZoneID/sourceDigest 缺失或超长" };
  }
  return {
    ok: true,
    scope: {
      schemaVersion: 1,
      goalID: String(raw.goalID).toLowerCase(),
      planRevisionID: String(raw.planRevisionID).toLowerCase(),
      reviewID: String(raw.reviewID).toLowerCase(),
      windowStart: windowStart.text,
      windowEndExclusive: windowEndExclusive.text,
      snapshotCutoffAt: snapshotCutoffAt.text,
      timeZoneID,
      sourceDigest,
    },
  };
}

/** goalReview 只在 goalScope 合法时接受，且体积封顶（防快照炸弹） */
export function acceptGoalReview(raw, scope) {
  if (!scope || raw == null || typeof raw !== "object" || Array.isArray(raw)) return null;
  const size = JSON.stringify(raw).length;
  if (size > MAX_GOAL_REVIEW_BYTES) return null;
  return raw;
}

/**
 * 冻结块（拼进 system prompt）：范围由代码声明，模型不得改写；
 * 统一事实快照作为确定性数字的唯一来源；给出修正草案的输出契约。
 */
export function buildGoalScopeBlock(scope, goalReview) {
  const lines = [
    "【目标回顾任务（代码生成，范围与事实不得改写）】",
    `目标：goalID=${scope.goalID}（结果只围绕这一个目标，不扫其他目标、不把全部生活记录当上下文）`,
    `计划版本：planRevisionID=${scope.planRevisionID}`,
    `观察窗：${scope.windowStart} 至 ${scope.windowEndExclusive}（半开区间；快照截止 ${scope.snapshotCutoffAt}；时区 ${scope.timeZoneID}）`,
    `依据摘要：${scope.sourceDigest}`,
  ];
  if (goalReview) {
    lines.push(
      "",
      "<goal_review_facts>",
      "以下是该目标的统一事实快照（代码计算，含结果/执行/限制/覆盖/资金演算）。数字以它为准：",
      "- 结果未知就是未知（missing/stale/unavailable），不是 0，也不用基线冒充最新观测；",
      "- 执行（任务/习惯完成）与结果（资金/体重/能力）分开说，打卡成功不等于结果改善；",
      "- 只有明细或用户确认后才可提出「外食/宵夜/奶茶变多」这类线索，并标注为线索；",
      "- 资金期次的剩余与每期应存按快照里的 fundPlan 演算引用，不自行除法。",
      JSON.stringify(goalReview),
      "</goal_review_facts>",
    );
    lines.push(
      "",
      "目标修正草案（可选）：当你判断有值得试行的调整时，在 final_claims JSON 里额外输出 goalAdjustmentDraft 字段：",
      '{"goalAdjustmentDraft":{"operations":[{"id":"op-1","kind":"create_task|reuse_task|update_task|create_habit|reuse_habit|update_habit|create_budget|update_budget|end_binding|replace_binding|update_fund_schedule|update_review|change_success_criteria",',
      '"targetEntityID":"快照 execution[].entityID 之一","targetBindingID":"快照 execution[].id 或 constraints[].id 之一","draftRef":"新建对象引用",',
      '"taskSpec":{"title":"..."},"habitSpec":{"name":"...","frequency":"daily|weekly|monthly","type":"checkIn|numeric","targetValue":20},',
      '"review":{"cadenceDays":7},"fundSchedule":[{"dueDate":"ISO","amount":3000}],"criteriaChange":{"newTargetValue":15000},',
      '"currentSummary":"当前安排","proposedSummary":"建议安排","reason":"为什么","affectedObjectTitle":"对象名"}],"expectedObservation":"调整后先看什么"}}',
      "规则：kind 必须在上述白名单内；引用的 ID 只能来自快照 execution/constraints；不虚构未提供的对象；",
      "期次金额给方向即可（客户端会按确认时点的真实资金重算）；默认不得提议降低总目标/延长截止（除非用户明确表达过），",
      "确需改变成果标准时用 change_success_criteria（客户端会要求用户单独确认）；没有值得改的就整个省略该字段。",
    );
  }
  return lines.join("\n");
}

/**
 * 证据池种子（§6.3 单一事实口径）：goalReview 的确定性数字注册为合法 metric/evidence，
 * 模型引用 goal.* 指标或 goal-review:* 证据即可通过交付核验（白名单对账），无须为此再查工具。
 */
export function seedGoalReviewEvidence(goalReview, pools) {
  if (!goalReview) return;
  const addMetric = (metricKey, value, unit, baselineValue, group) => {
    if (value == null || !Number.isFinite(Number(value))) return;
    pools.metricEvidence.set(`${metricKey}|all`, {
      kind: "metric",
      metricKey,
      dataset: "goal.review",
      group: group ?? null,
      value: Number(value),
      unit: unit ?? null,
      baselineValue: baselineValue != null && Number.isFinite(Number(baselineValue)) ? Number(baselineValue) : null,
      formula: null,
      sourceCount: 1,
    });
    pools.validEvidenceIDs.add(metricKey);
    pools.validEvidenceIDs.add(`dynamic-${metricKey}`);
  };
  const addEvent = (id, excerpt) => {
    pools.validEvidenceIDs.add(id);
    pools.evidenceTexts.set(id, excerpt);
  };

  const result = goalReview.result ?? {};
  if (result.value != null) addMetric("goal.result.value", result.value, result.unit, result.baselineValue, result.sourceLabel);
  if (result.moneyValue != null) addMetric("goal.result.money", result.moneyValue, result.unit ?? "元", result.baselineValue, result.sourceLabel);
  const fund = goalReview.fundPlan;
  if (fund) {
    if (fund.currentFunds != null) addMetric("goal.fund.current", fund.currentFunds, "元");
    if (fund.outcome) {
      addMetric("goal.fund.plannedToDate", fund.outcome.plannedToDate, "元");
      addMetric("goal.fund.shortfallToDate", fund.outcome.shortfallToDate, "元");
      addMetric("goal.fund.remainingAmount", fund.outcome.remainingAmount, "元");
      if (fund.outcome.suggestedPerInstallment != null) {
        addMetric("goal.fund.perInstallment", fund.outcome.suggestedPerInstallment, "元");
      }
    }
  }
  const execution = Array.isArray(goalReview.execution) ? goalReview.execution : [];
  const tasks = execution.filter((item) => item.entityType === "task" && !item.isUnavailable);
  if (tasks.length > 0) {
    addMetric("goal.execution.tasksCompleted", tasks.filter((item) => item.taskCompleted === true).length, "个");
    addMetric("goal.execution.tasksTotal", tasks.length, "个");
  }
  const constraints = Array.isArray(goalReview.constraints) ? goalReview.constraints : [];
  constraints.forEach((constraint, index) => {
    if (constraint.observedValue != null) {
      addMetric(`goal.constraint.${index + 1}.observed`, constraint.observedValue, constraint.unit, constraint.limitValue, constraint.title);
    }
  });

  // 每个目标条件保留自己的单位与状态，不把混合来源压成一个进度数字。
  const requirements = Array.isArray(goalReview.requirements) ? goalReview.requirements : [];
  requirements.forEach((item, index) => {
    const key = `goal.requirement.${index + 1}`;
    if (item.state !== "unavailable" && item.state !== "missing") {
      addMetric(`${key}.observed`, item.value, item.unit, null, item.title);
    }
    addMetric(`${key}.target`, item.requirement?.target, item.unit, null, item.title);
    addEvent(`goal-review:requirement:${index + 1}`,
      `${item.title ?? "目标条件"}：${item.state ?? "missing"}；${item.role ?? "action"}；已确认 ${item.confirmedDays ?? 0}/${item.expectedDays ?? 0} 天`);
  });

  addEvent("goal-review:result", `目标「${goalReview.goalTitle ?? ""}」结果：${result.status ?? "unknown"}${
    result.moneyValue != null ? `，金额 ${result.moneyValue}${result.unit ?? "元"}` : ""
  }${result.value != null ? `，数值 ${result.value}${result.unit ?? ""}` : ""}（来源：${result.sourceLabel ?? "未知"}）`);
  addEvent("goal-review:execution", `执行概况：${execution.map((item) => `${item.title ?? item.entityType}${item.taskCompleted === true ? "已完成" : ""}`).join("、") || "无绑定"}`);
  const coverage = goalReview.coverage ?? {};
  addEvent("goal-review:coverage", `已知：${(coverage.known ?? []).join("；") || "无"}。未知：${(coverage.unknown ?? []).join("；") || "无"}`);
}

/** goalReview 里的可引用对象/绑定 ID 集合（修正草案引用白名单） */
export function goalReviewReferenceSets(goalReview) {
  const entityIDs = new Set();
  const bindingIDs = new Set();
  if (!goalReview) return { entityIDs, bindingIDs };
  for (const item of [...(Array.isArray(goalReview.execution) ? goalReview.execution : []),
    ...(Array.isArray(goalReview.requirements) ? goalReview.requirements : [])]) {
    if (typeof item.entityID === "string" && UUID_RE.test(item.entityID)) entityIDs.add(item.entityID.toLowerCase());
    if (typeof item.id === "string" && UUID_RE.test(item.id)) bindingIDs.add(item.id.toLowerCase());
  }
  for (const constraint of Array.isArray(goalReview.constraints) ? goalReview.constraints : []) {
    if (typeof constraint.id === "string" && UUID_RE.test(constraint.id)) bindingIDs.add(constraint.id.toLowerCase());
  }
  return { entityIDs, bindingIDs };
}

function cleanString(value, max) {
  return typeof value === "string" ? value.trim().slice(0, max) : undefined;
}

function cleanNumber(value) {
  const num = Number(value);
  return value != null && Number.isFinite(num) ? num : undefined;
}

function cleanDate(value) {
  const parsed = isoDate(value);
  return parsed ? parsed.text : undefined;
}

/**
 * 修正草案消毒：kind 白名单 + 引用白名单 + 数量/长度封顶；身份字段由服务端生成。
 * 返回 { draft, warnings }；无合法操作时 draft 为 null。
 */
export function sanitizeGoalAdjustmentDraft(raw, scope, goalReview, now = new Date()) {
  const warnings = [];
  if (raw == null || typeof raw !== "object" || !Array.isArray(raw.operations) || raw.operations.length === 0) {
    return { draft: null, warnings };
  }
  const { entityIDs, bindingIDs } = goalReviewReferenceSets(goalReview);
  const createdAt = now.toISOString();
  const expiresAt = new Date(now.getTime() + 7 * 86_400_000).toISOString();
  const operations = [];
  raw.operations.slice(0, MAX_OPERATIONS * 2).forEach((rawOp, index) => {
    if (!rawOp || typeof rawOp !== "object") return;
    const kind = String(rawOp.kind ?? "");
    if (!ALLOWED_OPERATION_KINDS.has(kind)) {
      warnings.push(`GOAL_ADJUSTMENT_OP_DROPPED:${rawOp.id ?? index}`);
      return;
    }
    const op = { id: cleanString(rawOp.id, 40) || `op-${index + 1}`, kind };
    if (rawOp.targetEntityID != null) {
      const id = String(rawOp.targetEntityID).toLowerCase();
      if (!UUID_RE.test(id) || (entityIDs.size > 0 && !entityIDs.has(id))) {
        warnings.push(`GOAL_ADJUSTMENT_REF_DROPPED:${op.id}`);
        return;
      }
      op.targetEntityID = id;
    }
    if (rawOp.targetBindingID != null) {
      const id = String(rawOp.targetBindingID).toLowerCase();
      if (!UUID_RE.test(id) || (bindingIDs.size > 0 && !bindingIDs.has(id))) {
        warnings.push(`GOAL_ADJUSTMENT_REF_DROPPED:${op.id}`);
        return;
      }
      op.targetBindingID = id;
    }
    if (rawOp.draftRef != null) op.draftRef = cleanString(rawOp.draftRef, 40);
    if (rawOp.currentSummary != null) op.currentSummary = cleanString(rawOp.currentSummary, 200);
    if (rawOp.proposedSummary != null) op.proposedSummary = cleanString(rawOp.proposedSummary, 200);
    if (rawOp.reason != null) op.reason = cleanString(rawOp.reason, 300);
    if (rawOp.affectedObjectTitle != null) op.affectedObjectTitle = cleanString(rawOp.affectedObjectTitle, 80);
    if (rawOp.appliesFrom != null) op.appliesFrom = cleanDate(rawOp.appliesFrom);
    if (rawOp.appliesThrough != null) op.appliesThrough = cleanDate(rawOp.appliesThrough);
    if (typeof rawOp.role === "string" && ["result", "action", "constraint", "context"].includes(rawOp.role)) {
      op.role = rawOp.role;
    }
    if (rawOp.taskSpec && typeof rawOp.taskSpec === "object" && typeof rawOp.taskSpec.title === "string") {
      op.taskSpec = {
        title: rawOp.taskSpec.title.trim().slice(0, 80),
        dueDate: cleanDate(rawOp.taskSpec.dueDate),
        priority: Number.isInteger(rawOp.taskSpec.priority) ? rawOp.taskSpec.priority : undefined,
        note: cleanString(rawOp.taskSpec.note, 200),
      };
    }
    if (rawOp.habitSpec && typeof rawOp.habitSpec === "object" && typeof rawOp.habitSpec.name === "string") {
      op.habitSpec = {
        name: rawOp.habitSpec.name.trim().slice(0, 80),
        frequency: ["daily", "weekly", "monthly"].includes(rawOp.habitSpec.frequency) ? rawOp.habitSpec.frequency : "daily",
        type: rawOp.habitSpec.type === "checkIn" ? "checkIn" : "numeric",
        unit: cleanString(rawOp.habitSpec.unit, 16),
        targetValue: cleanNumber(rawOp.habitSpec.targetValue),
        isBadHabit: typeof rawOp.habitSpec.isBadHabit === "boolean" ? rawOp.habitSpec.isBadHabit : undefined,
      };
    }
    if (rawOp.budgetRule && typeof rawOp.budgetRule === "object" && UUID_RE.test(String(rawOp.budgetRule.accountID ?? ""))) {
      op.budgetRule = {
        accountID: String(rawOp.budgetRule.accountID).toLowerCase(),
        amount: cleanNumber(rawOp.budgetRule.amount),
        period: ["week", "month", "year"].includes(rawOp.budgetRule.period) ? rawOp.budgetRule.period : "month",
      };
    }
    if (Array.isArray(rawOp.fundSchedule) && rawOp.fundSchedule.length > 0) {
      const schedule = rawOp.fundSchedule
        .filter((item) => item && cleanDate(item.dueDate) && cleanNumber(item.amount) > 0)
        .slice(0, 24)
        .map((item) => ({ dueDate: cleanDate(item.dueDate), amount: cleanNumber(item.amount) }));
      if (schedule.length > 0) op.fundSchedule = schedule;
    }
    if (rawOp.review && typeof rawOp.review === "object") {
      op.review = {};
      if (rawOp.review.cadenceDays == null) op.review.cadenceDays = null;
      else if (Number.isInteger(rawOp.review.cadenceDays) && rawOp.review.cadenceDays >= 1 && rawOp.review.cadenceDays <= 90) {
        op.review.cadenceDays = rawOp.review.cadenceDays;
      }
      if (rawOp.review.nextReviewAt != null) op.review.nextReviewAt = cleanDate(rawOp.review.nextReviewAt);
    }
    if (rawOp.criteriaChange && typeof rawOp.criteriaChange === "object") {
      op.criteriaChange = {
        newSuccessCriteria: cleanString(rawOp.criteriaChange.newSuccessCriteria, 200),
        newTargetValue: cleanNumber(rawOp.criteriaChange.newTargetValue),
        newDeadline: cleanDate(rawOp.criteriaChange.newDeadline),
      };
    }
    operations.push(op);
  });

  const limited = operations.slice(0, MAX_OPERATIONS);
  if (operations.length > MAX_OPERATIONS) warnings.push("GOAL_ADJUSTMENT_OPS_CAPPED");
  if (limited.length === 0) {
    warnings.push("GOAL_ADJUSTMENT_DROPPED");
    return { draft: null, warnings };
  }
  return {
    draft: {
      schemaVersion: 1,
      draftID: randomUUID(),
      goalID: scope.goalID,
      baseRevisionID: scope.planRevisionID,
      sourceDigest: scope.sourceDigest,
      createdAt,
      expiresAt,
      expectedObservation: cleanString(raw.expectedObservation, 300),
      operations: limited,
    },
    warnings: [...new Set(warnings)],
  };
}
