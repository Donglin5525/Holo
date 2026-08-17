//
//  LifePlanModels.swift
//  Holo
//
//  LifePlan 计划台账值类型：UI 快照、行动卡载荷、撤销令牌、生成 schema。
//

import Foundation

// MARK: - 行动卡载荷（确认时转 GoalDraft 走 saveDraft）

/// 行动卡的可执行载荷：task / habit 二选一（其余 type 仅展示不写回）
struct PlanActionDraftPayload: Codable, Equatable {
    var task: GoalTaskDraft?
    var habit: GoalHabitDraft?

    var displayTitle: String {
        if let task { return task.title }
        if let habit { return habit.name }
        return ""
    }
}

/// 确认写回后的撤销令牌：记录创建的实体 ID，撤销 = 删除这些实体并回滚状态
struct PlanUndoToken: Codable, Equatable {
    var goalID: UUID?
    var taskIDs: [UUID]
    var habitIDs: [UUID]
}

// MARK: - UI 快照（值类型，从 Repository 读出供渲染）

struct LifePlanPrioritySnapshot: Identifiable, Equatable, Sendable {
    var id: UUID
    var outcome: String
    var whyNow: String
    var evidenceIDs: [String]
    var priorityRank: Int
    var userDecision: String?
    var goalID: UUID?
}

struct LifePlanActionSnapshot: Identifiable, Equatable, Sendable {
    var id: UUID
    var type: String
    var payload: PlanActionDraftPayload
    var expectedBenefit: String?
    var tradeoff: String?
    var evidenceIDs: [String]
    var requiresConfirmation: Bool
    var status: String
    var sortOrder: Int
}

struct LifePlanSnapshot: Identifiable, Equatable, Sendable {
    var id: UUID
    var scope: String
    var periodStart: Date
    var periodEnd: Date
    var status: String
    var constraintSummary: String?
    var version: Int
    var trigger: String
    var dataSufficient: Bool
    var createdAt: Date
    var priorities: [LifePlanPrioritySnapshot]
    var actions: [LifePlanActionSnapshot]

    var acceptedActionCount: Int { actions.filter { $0.status == "accepted" || $0.status == "completed" }.count }
    var rejectedActionCount: Int { actions.filter { $0.status == "rejected" }.count }
    var completedActionCount: Int { actions.filter { $0.status == "completed" }.count }
    var proposedActionCount: Int { actions.filter { $0.status == "proposed" }.count }
}

// MARK: - 生成 Schema（LLM 结构化输出）

/// weekly_plan_generation 的 LLM 输出 schema；校验失败重试一次后降级为普通分析文本。
nonisolated struct LifePlanGenerationPayload: Codable, Equatable {
    struct Priority: Codable, Equatable {
        var outcome: String
        var whyNow: String
        var evidenceHints: [String]
        var actionTitles: [String]
    }

    struct Action: Codable, Equatable {
        var type: String
        var title: String
        var note: String?
        var expectedBenefit: String?
        var tradeoff: String?
    }

    var constraintSummary: String
    var priorities: [Priority]
    var actions: [Action]

    /// 结构护栏：≤3 优先结果、3–7 行动卡、每条非空
    var isValid: Bool {
        (1...3).contains(priorities.count)
            && (3...7).contains(actions.count)
            && !priorities.contains { $0.outcome.isEmpty || $0.whyNow.isEmpty }
            && !actions.contains { $0.title.isEmpty }
            && actions.allSatisfy { ["task", "habit"].contains($0.type) }
    }
}

// MARK: - 运行成本摘要（PlanRun 自包含，不回查 Job）

struct PlanConsumedBudget: Codable, Equatable {
    var llmRounds: Int
    var toolBatches: Int
    var inputTokens: Int
    var outputTokens: Int
    var activeRuntimeSeconds: Double
}

// MARK: - 上一份计划的滚动注入上下文

/// 生成新计划时注入的「上周台账」摘要（对账数据源 = goalID/undoToken 自动回读真实完成状态）
struct LifePlanPreviousPlanContext: Codable, Equatable {
    struct PriorityDecision: Codable, Equatable {
        var outcome: String
        var userDecision: String
        var goalID: UUID?
    }

    struct ActionDecision: Codable, Equatable {
        var title: String
        var type: String
        var status: String
        var rejectReason: String?
        var taskCompleted: Bool?
    }

    var periodStart: Date
    var periodEnd: Date
    var priorities: [PriorityDecision]
    var actions: [ActionDecision]
}
