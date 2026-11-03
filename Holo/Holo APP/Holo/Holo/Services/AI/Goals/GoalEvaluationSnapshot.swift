//
//  GoalEvaluationSnapshot.swift
//  Holo
//
//  目标闭环·同一份事实快照（最终规格 §6.3）
//
//  纯值类型。由 GoalEvaluationSnapshotBuilder 从生效计划与授权来源读取，
//  供目标详情、分析上下文、风险提醒、HoloGoalTool 共用一个口径：
//  - result：结果观测（observed / missing / stale / unavailable / pendingSource / notApplicable），
//    不用 baseline 冒充最新观测，没有结果量时不输出虚假成果百分比
//  - execution：行动执行情况（明确标为「执行」，不做成果判断）
//  - constraints：限制（数字习惯上限 / 预算）从原始数值另算
//  - coverage：已知 / 未知
//  - review：回顾到期状态
//  - fundPlan：资金期次演算（仅 ledger 结果 + 期次计划时启用）
//  - sourceDigest：依据摘要，用于报告去重与修正草案过期校验
//

import Foundation

enum GoalResultObservationStatus: String, Codable, Equatable, Sendable {
    case observed
    case missing
    case stale
    case unavailable
    case pendingSource = "pending_source"
    case notApplicable = "not_applicable"
}

struct GoalResultObservation: Codable, Equatable, Sendable {
    var status: GoalResultObservationStatus
    var sourceKind: GoalResultSourceKind?
    /// 来源的用户可读名称：全账本净结余增加 / 账户「旅行」余额 / 体重 / 手动记录
    var sourceLabel: String
    /// 数值型观测（习惯 / 手动）
    var value: Double?
    /// 金额型观测（ledger）
    var moneyValue: Decimal?
    var unit: String?
    var observedAt: Date?
    var targetValue: Double?
    var baselineValue: Double?
    var baselineObservedAt: Date?
    /// 仅在结果量与目标值都有意义时给出（0...1）；过程型/缺测恒 nil
    var progressFraction: Double?
    var unavailableReason: String?
    var note: String?
}

struct GoalExecutionItem: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var entityType: GoalPlanBindingEntityType
    var entityID: UUID?
    var title: String
    var role: GoalPlanBindingRole
    var isOwnedByGoal: Bool
    var isUnavailable: Bool
    var unavailableReason: String?

    // 任务
    var taskCompleted: Bool?
    var taskCompletedAt: Date?
    var taskDueDate: Date?
    var taskPlannedStart: Date?
    var taskIsOverdue: Bool?
    var taskCompletedInWindow: Bool?

    // 习惯
    var habitAggregation: String?
    var habitFrequency: String?
    var habitRecordedDays: Int?
    var habitExpectedDays: Int?
    var habitCompletionRate: Double?
    var habitWindowSum: Double?
    var habitLatestValue: Double?
    var habitLatestValueAt: Date?
    var habitIsPaused: Bool?
    var habitUnit: String?
}

enum GoalConstraintKind: String, Codable, Equatable, Sendable {
    case habitLimit = "habit_limit"
    case budget
}

struct GoalConstraintStatus: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: GoalConstraintKind
    var title: String
    var limitValue: Decimal
    var observedValue: Decimal?
    var unit: String?
    var windowLabel: String
    var windowStart: Date?
    var windowEndExclusive: Date?
    /// nil = 无记录无法判断（缺记录 ≠ 0）
    var isBreached: Bool?
    var hasRecords: Bool
    var isUnavailable: Bool
    var note: String?
    var confirmedDays: Int?
    var expectedDays: Int?
    var confirmationDigest: String?
}

struct GoalCoverageFacts: Codable, Equatable, Sendable {
    var known: [String]
    var unknown: [String]
}

struct GoalReviewStatus: Codable, Equatable, Sendable {
    var cadenceDays: Int?
    var nextReviewAt: Date?
    var isDue: Bool
    var lastCompletedReviewAt: Date?
    var lastReportMessageID: UUID?
}

struct GoalFundPlanStatus: Codable, Equatable, Sendable {
    var target: Decimal
    var currentFunds: Decimal?
    var installmentsTotal: Int
    var installmentsPast: Int
    var outcome: GoalFundScheduleMath.Outcome?
}

struct GoalEvaluationSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = GoalEvaluationSnapshot.currentSchemaVersion
    var goalID: UUID
    var goalTitle: String
    var planRevisionID: UUID
    var planRevisionNumber: Int
    var generatedAt: Date
    var windowStart: Date
    var windowEndExclusive: Date
    var snapshotCutoffAt: Date
    var timeZoneID: String
    var successCriteria: String?
    var deadline: Date?
    var result: GoalResultObservation
    var execution: [GoalExecutionItem]
    var constraints: [GoalConstraintStatus]
    var coverage: GoalCoverageFacts
    var review: GoalReviewStatus
    var fundPlan: GoalFundPlanStatus?
    var sourceDigest: String
    /// 多条件分别展示，不生成跨单位综合百分比；旧报告缺字段仍可读取。
    var requirements: [GoalRequirementObservation]?

    var observationWindow: GoalObservationWindow {
        GoalObservationWindow(start: windowStart,
                              endExclusive: windowEndExclusive,
                              cutoff: snapshotCutoffAt,
                              timeZone: TimeZone(identifier: timeZoneID) ?? .current)
    }

    /// 执行侧汇总（仅用于展示「执行」，不代表成果）
    var executionSummary: (tasksTotal: Int, tasksCompleted: Int, habitsTotal: Int, habitAverageRate: Double?) {
        let tasks = execution.filter { $0.entityType == .task && !$0.isUnavailable }
        let habits = execution.filter { $0.entityType == .habit && !$0.isUnavailable }
        let rates = habits.compactMap(\.habitCompletionRate)
        let average = rates.isEmpty ? nil : rates.reduce(0, +) / Double(rates.count)
        return (tasks.count, tasks.filter { $0.taskCompleted == true }.count, habits.count, average)
    }
}
