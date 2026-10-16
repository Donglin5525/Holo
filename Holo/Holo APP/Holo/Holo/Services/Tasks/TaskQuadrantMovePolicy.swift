//
//  TaskQuadrantMovePolicy.swift
//  Holo
//
//  象限移动的唯一写入规则（多视图方案 §6.2）：目标格 → 两轴写入补丁。
//  移到「非重要」只表明不是 P1，不把已有「一般」硬改「不重要」；
//  紧急方式转手动让用户指定的目标持续生效。不动截止、计划、提醒、重复、
//  清单、Today、完成、延期次数与旧 priority 列；象限本身不落库。
//

import Foundation

nonisolated enum TaskQuadrantMovePolicy {

    /// 一次移动的两轴写入补丁
    struct Patch: Equatable {
        let importance: TaskImportance
        let urgencyMode: TaskUrgencyMode
    }

    /// 生成目标格补丁；目标等于当前实时解析格时返回 nil（no-op：零写入零提示）。
    /// 输入必须是提交前按 UUID 重读的最新快照（§6.3-6）。
    static func patch(
        target: TaskQuadrant,
        importance: TaskImportance,
        urgencyMode: TaskUrgencyMode,
        effectiveDue: Date?,
        now: Date,
        calendar: Calendar
    ) -> Patch? {
        let currentQuadrant = TaskQuadrantResolver.quadrant(
            importance: importance,
            mode: urgencyMode,
            effectiveDue: effectiveDue,
            now: now,
            calendar: calendar
        )
        guard currentQuadrant != target else { return nil }

        let newImportance: TaskImportance
        switch target {
        case .doFirst, .scheduleTime:
            newImportance = .p1
        case .batchHandle, .reviewLater:
            // 非重要侧：已有 P2/P3 保留（不硬改成同一档），P1/unknown 落中性 P2
            newImportance = (importance == .p2 || importance == .p3) ? importance : .p2
        case .unclassified:
            return nil // 待整理不是移动目标
        }

        let newUrgency: TaskUrgencyMode
        switch target {
        case .doFirst, .batchHandle:
            newUrgency = .p1
        case .scheduleTime, .reviewLater:
            // 已有手动 P2/P3 保留，否则（auto 或手动 P1）设手动 P3
            newUrgency = (urgencyMode == .p2 || urgencyMode == .p3) ? urgencyMode : .p3
        case .unclassified:
            return nil
        }
        return Patch(importance: newImportance, urgencyMode: newUrgency)
    }

    /// 撤回用的精确原值（含 auto，§6.3-9）
    static func revertPatch(importance: TaskImportance, urgencyMode: TaskUrgencyMode) -> Patch {
        Patch(importance: importance, urgencyMode: urgencyMode)
    }
}
