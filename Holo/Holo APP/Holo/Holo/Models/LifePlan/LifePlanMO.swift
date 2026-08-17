//
//  LifePlanMO.swift
//  Holo
//
//  LifePlan 计划台账 Core Data 实体（六个对象）
//  记录「我们合作做过什么」：计划主体 / 优先结果 / 行动卡 / 信号 / 反馈 / 运行记录。
//  与长期记忆的分工：这里是精确的交互台账（用户显式确认产生），不是萃取的印象。
//

import Foundation
import CoreData

/// 计划主体（本周计划；scope 预留 month）
@objc(LifePlanMO)
public final class LifePlanMO: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var scope: String
    @NSManaged public var periodStart: Date
    @NSManaged public var periodEnd: Date
    /// draft / active / completed / superseded
    @NSManaged public var status: String
    @NSManaged public var constraintSummary: String?
    /// 数据快照截止（对齐 Agent Job 冻结口径）
    @NSManaged public var snapshotCutoffAt: Date
    @NSManaged public var version: Int16
    /// weeklyPlanning / userQuestion / …
    @NSManaged public var trigger: String
    @NSManaged public var dataSufficient: Bool
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
}

/// 优先结果（每计划最多 3 条）
@objc(PlanPriorityMO)
public final class PlanPriorityMO: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var planID: UUID
    /// 结果导向标题（「降体脂到 22%」而非「跑步」）
    @NSManaged public var outcome: String
    /// 为什么是现在
    @NSManaged public var whyNow: String
    /// Evidence Ledger 证据 ID（JSON array string）
    @NSManaged public var evidenceIDsJSON: String
    @NSManaged public var priorityRank: Int16
    /// pending / accepted / edited / rejected
    @NSManaged public var userDecision: String?
    /// 确认后创建的 Goal 回链
    @NSManaged public var goalID: UUID?
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
}

/// 行动卡（每计划 3–7 张；type 仅 task/habit 可写回，其余预留）
@objc(PlanActionMO)
public final class PlanActionMO: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var planID: UUID
    /// task / habit / budgetGuardrail(预留) / reminder(预留) / defer(预留)
    @NSManaged public var type: String
    /// PlanActionDraftPayload JSON（内嵌 GoalTaskDraft / GoalHabitDraft）
    @NSManaged public var draftPayloadJSON: String
    @NSManaged public var expectedBenefit: String?
    @NSManaged public var tradeoff: String?
    @NSManaged public var evidenceIDsJSON: String
    @NSManaged public var requiresConfirmation: Bool
    /// proposed / accepted / rejected / completed / expired
    @NSManaged public var status: String
    /// PlanUndoToken JSON（goalID/taskIDs/habitIDs），撤销=删除这些实体
    @NSManaged public var undoTokenJSON: String?
    @NSManaged public var sortOrder: Int16
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
}

/// 标准化信号（原始数据变化 → 是否值得处理的评分；第三刀偏离检测启用）
@objc(PlanSignalMO)
public final class PlanSignalMO: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var planID: UUID?
    /// finance / task / habit / health / goal / thought
    @NSManaged public var domain: String
    @NSManaged public var severity: Double
    @NSManaged public var novelty: Double
    @NSManaged public var confidence: Double
    @NSManaged public var actionability: Double
    @NSManaged public var urgency: Double
    @NSManaged public var evidenceIDsJSON: String
    /// surfaced / dismissed
    @NSManaged public var outcome: String
    @NSManaged public var dismissedAt: Date?
    @NSManaged public var createdAt: Date
}

/// 用户反馈（拒绝原因等；「教得会」的数据基础）
@objc(PlanFeedbackMO)
public final class PlanFeedbackMO: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var actionID: UUID
    @NSManaged public var planID: UUID
    /// accepted / edited / rejected
    @NSManaged public var decision: String
    /// 不需要 / 时间不够 / 不喜欢方式 / 证据不信服 …
    @NSManaged public var reasonTag: String?
    @NSManaged public var freeText: String?
    @NSManaged public var createdAt: Date
}

/// 运行记录（Job ↔ 计划 ↔ 成本；自包含，不回查 Job）
@objc(PlanRunMO)
public final class PlanRunMO: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var planID: UUID
    @NSManaged public var jobID: String
    @NSManaged public var trigger: String
    @NSManaged public var inputSnapshotVersion: Int16
    /// HoloAgentBudget consumed 摘要 JSON（成本指标数据源）
    @NSManaged public var consumedBudgetJSON: String?
    /// completed / failedDegraded / failed
    @NSManaged public var resultStatus: String
    @NSManaged public var createdAt: Date
}
