//
//  HoloMatterPlanLaunchModels.swift
//  Holo
//
//  Matter V2 计划启动契约（2026-09-21 方案 §5.3/§5.4）。
//
//  「开始推进」= 确认整份计划：请求不携带 selectedItemIDs，actionable items
//  （task / checklistItem）一次创建；adjustment / information 不产生任务。
//  UI 只能以 HoloMatterPlanLaunchReceipt 展示成功——请求发出、本地临时状态
//  都不算成功，回执以仓储单事务 save 结果为准。
//

import Foundation

/// 唯一写入请求。
nonisolated struct HoloMatterPlanLaunchRequest: Sendable {
    /// 方案卡消息 ID：launch 的幂等来源键（同 origin 只落一次）。
    let contextPlanMessageID: UUID
    /// 用户消息 ID（可空；挂 conversation link 供 Matter Chat 回源）。
    let userMessageID: UUID?
    /// 当前计划草案。items 的数组顺序即计划顺序（planOrder 0...N-1）。
    let draft: HoloContextPlanDraft
    /// 用户确认的事项名（已标准化后传入；清单名由它派生）。
    let confirmedTitle: String
    /// 仅用户明确确认的日期；nil 时任务不带日期（禁止默认今天）。
    let targetDate: Date?
    /// 同名歧义时用户选择继续的既有 Matter；nil = 新建。
    let existingMatterID: UUID?

    init(
        contextPlanMessageID: UUID,
        userMessageID: UUID? = nil,
        draft: HoloContextPlanDraft,
        confirmedTitle: String,
        targetDate: Date? = nil,
        existingMatterID: UUID? = nil
    ) {
        self.contextPlanMessageID = contextPlanMessageID
        self.userMessageID = userMessageID
        self.draft = draft
        self.confirmedTitle = confirmedTitle
        self.targetDate = targetDate
        self.existingMatterID = existingMatterID
    }

    /// 可执行条目（task / checklistItem），保持 draft 顺序。
    var actionableItems: [HoloContextPlanItem] {
        draft.items.filter { $0.kind == .task || $0.kind == .checklistItem }
    }
}

/// 唯一成功回执。
nonisolated struct HoloMatterPlanLaunchReceipt: Equatable, Sendable {
    let matterID: UUID
    let listID: UUID
    let taskIDs: [UUID]
    let createdTaskCount: Int
    let reusedTaskCount: Int
    let openLoopIDs: [UUID]
    let nextActionTaskID: UUID?
    let createdMatter: Bool
}

/// 启动失败（可恢复：事务已整体回滚，不存在部分落库）。
nonisolated enum HoloMatterPlanLaunchError: Error, Equatable, Sendable {
    /// actionable items 不在 1–7 区间（0 条不允许启动；UI 侧本就不该出 CTA）。
    case invalidActionableCount(Int)
    /// 标题标准化后为空，无法派生清单名。
    case emptyTitle
    /// 指定的 existingMatterID 不存在（用户选择的 Matter 已被删除）。
    case existingMatterNotFound
    /// 防连点：上一次启动仍在执行中。
    case launchAlreadyInFlight
}
