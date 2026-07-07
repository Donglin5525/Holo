//
//  ScheduleRankingModels.swift
//  Holo
//
//  首页胶囊排序纯逻辑：业务优先级 + 稳定 tiebreaker
//  见本周观察方案 §4.4。从 HomeScheduleService 提取 ReminderUrgency/ReminderModule，
//  保证 ScheduleRanker 可被 standalone test 覆盖（不依赖 SwiftUI/UIKit/Core Data）。
//

import Foundation

// MARK: - Module

/// 推送来源模块
enum ReminderModule: String, Codable {
    case task
    case insight
    /// 本周观察（方案 §2.4 独立胶囊通道，P0 业务优先级）
    case weeklyObservation
}

// MARK: - Urgency / Business Priority

/// 紧急程度 / 业务优先级（决定信号灯颜色和展示优先级）
/// 优先级从高到低：newInsight > overdue > today > upcoming > pending
enum ReminderUrgency: Int, Comparable {
    case pending    = 1  // 仅有未完成 / 普通观察提醒（最低）
    case upcoming   = 2  // 近 3 天到期
    case today      = 3  // 今天到期
    case overdue    = 4  // 已过期（任务主线）
    case newInsight = 5  // 新观察未读（24h 保护期内，P0，方案 §2.4）

    static func < (lhs: ReminderUrgency, rhs: ReminderUrgency) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Candidate

/// 排序候选（纯排序字段，不含跳转目标，保证可独立测试）
/// 跳转目标由 Service 层将 topCandidate 映射为 ScheduleReminderState 时补回（方案 §4.4）。
struct ScheduleCandidate: Equatable {
    /// 稳定标识（tiebreaker + 曝光记录用，方案 §4.4）
    let id: String
    let urgency: ReminderUrgency
    let module: ReminderModule
    let message: String
    /// 24h 保护期截止时间（新观察生成后 24h 内优先展示；nil 表示无保护期）
    let protectionUntil: Date?
}

// MARK: - Ranker（纯逻辑）

enum ScheduleRanker {

    /// 排序：urgency 降序 → module 升序（字典序）→ id 字典序（稳定 tiebreaker，方案 §4.4）
    static func rank(_ candidates: [ScheduleCandidate]) -> [ScheduleCandidate] {
        candidates.sorted { lhs, rhs in
            if lhs.urgency != rhs.urgency { return lhs.urgency > rhs.urgency }
            if lhs.module != rhs.module { return lhs.module.rawValue < rhs.module.rawValue }
            return lhs.id < rhs.id
        }
    }

    /// 取最高优先级候选（空数组返回 nil）
    static func topCandidate(_ candidates: [ScheduleCandidate]) -> ScheduleCandidate? {
        rank(candidates).first
    }

    /// 是否处于保护期内
    static func isProtected(_ candidate: ScheduleCandidate, now: Date) -> Bool {
        guard let until = candidate.protectionUntil else { return false }
        return now < until
    }
}
