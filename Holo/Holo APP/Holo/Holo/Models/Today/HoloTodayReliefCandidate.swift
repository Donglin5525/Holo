//
//  HoloTodayReliefCandidate.swift
//  Holo
//
//  「今天减负」审阅候选与展示事实（2026-10-03 实施方案 §4.3/§10）
//  仅 App target：引用 Today 快照投影类型（Widget 不编译本文件）。
//

import Foundation

// MARK: - 审阅候选与展示事实（§4.3/§10）

/// 审阅弹层的候选：AI 或手动构建的 draft payload + 展示用最小事实。
nonisolated struct HoloTodayReliefCandidate: Equatable, Sendable {
    let scope: HoloTodayDayScope
    let sourceFingerprint: String
    var payload: HoloTodayPlanPayload
    var newTaskTitle: String?
    /// 采用前 heads（乐观并发防线回传服务）。
    let expectedHeads: [UUID]
    /// 审阅行渲染所需的最小事实（不进 payload；UI 名称始终读真实对象）。
    let displayFacts: HoloTodayReliefDisplayFacts
}

nonisolated struct HoloTodayReliefDisplayFacts: Equatable, Sendable {
    nonisolated struct TaskDisplay: Equatable, Sendable {
        let taskID: UUID
        let title: String
        let dueAt: Date?
        let isAllDay: Bool
        let isOverdue: Bool
        let matterTitle: String?
        /// 已有分步计划的当前有效步骤（「今天只推进」出口）。
        let currentStepID: UUID?
        let currentStepAction: String?
        let currentStepFingerprint: String?
        let currentStepRevisionID: UUID?
        let hasSteps: Bool
        let completed: Bool
    }

    let tasks: [UUID: TaskDisplay]
    /// 真实约束（固定日程/执行时段/到期逾期事实）。
    let constraints: [HoloTodayPlanConstraintRow]
    /// 候选读取是否被截断（超 40 上限；UI 明说「根据已读取的安排整理」）。
    let truncated: Bool
    /// 数据可用性（区分不可用与真实 0；§4.5）。
    let tasksAvailable: Bool
    let calendarAuthorized: Bool
}
