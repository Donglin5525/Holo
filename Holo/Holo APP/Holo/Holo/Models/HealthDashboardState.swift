//
//  HealthDashboardState.swift
//  Holo
//
//  健康模块展示状态模型
//

import Foundation
import SwiftUI

enum HealthMetricAvailability: Equatable {
    case available
    case unauthorized
    case noData
    case unsupported

    var isReliableForScore: Bool {
        self == .available
    }
}

enum HealthDataSourceState: Equatable {
    case notRequested
    case connected
    case partiallyConnected
    case denied
    case unavailable

    var title: String {
        switch self {
        case .notRequested:
            return String(localized: "Apple Health 未连接")
        case .connected:
            return String(localized: "Apple Health 已连接")
        case .partiallyConnected:
            return String(localized: "Apple Health 部分连接")
        case .denied:
            return String(localized: "无法访问健康数据")
        case .unavailable:
            return String(localized: "健康功能暂不支持 iPad 和 Mac")
        }
    }

    var subtitle: String {
        switch self {
        case .notRequested:
            return String(localized: "授权后只读同步健康数据")
        case .connected:
            return String(localized: "只读同步 · 步数 / 睡眠 / 站立")
        case .partiallyConnected:
            return String(localized: "部分指标可用 · 点按前往设置补全权限")
        case .denied:
            return String(localized: "请在系统设置中允许 HOLO 读取健康数据")
        case .unavailable:
            return String(localized: "健康数据保存在 iPhone 的「健康」App 里，请在 iPhone 上查看和记录。")
        }
    }

    var badgeText: String {
        switch self {
        case .notRequested:
            return String(localized: "待授权")
        case .connected:
            return String(localized: "在线")
        case .partiallyConnected:
            return String(localized: "部分")
        case .denied:
            return String(localized: "关闭")
        case .unavailable:
            return String(localized: "不可用")
        }
    }

    var badgeColor: Color {
        switch self {
        case .connected:
            return .holoSuccess
        case .partiallyConnected, .notRequested:
            return .holoPrimary
        case .denied, .unavailable:
            return .holoError
        }
    }
}

struct HealthMetricSnapshot: Identifiable, Equatable {
    let type: HealthMetricType
    let value: Double
    let availability: HealthMetricAvailability

    var id: String { type.id }

    var title: String {
        type.displayName
    }

    var goal: Double {
        type.dailyGoal
    }

    var progress: Double {
        guard availability == .available, goal > 0 else { return 0 }
        return min(value / goal, 1)
    }

    var progressPercent: Int {
        Int((progress * 100).rounded())
    }

    var valueText: String {
        switch availability {
        case .available:
            return type.formatValue(value)
        case .unauthorized:
            return "--"
        case .noData:
            return "--"
        case .unsupported:
            return "--"
        }
    }

    var targetText: String {
        switch type {
        case .steps:
            return String(localized: "目标 \(Int(goal).formatted())")
        case .sleep, .standHours:
            return String(localized: "目标 \(type.formatValue(goal))h")
        case .activeMinutes, .workout:
            return String(localized: "目标 \(Int(goal)) 分钟")
        }
    }

    var statusText: String {
        switch availability {
        case .available:
            return "\(progressPercent)%"
        case .unauthorized:
            return String(localized: "未授权")
        case .noData:
            return String(localized: "暂无数据")
        case .unsupported:
            return String(localized: "不可用")
        }
    }

    var isGoalMet: Bool {
        availability == .available && progress >= 1
    }

    /// 距目标的差值（带单位）；已达标或无可用数据时为 nil
    var gapText: String? {
        guard availability == .available, value < goal else { return nil }
        let gap = goal - value
        let number: String
        switch type {
        case .steps, .activeMinutes, .workout:
            number = Int(gap.rounded(.up)).formatted()
        case .sleep, .standHours:
            // 整数小时不带小数（差 1 小时），其余保留一位；不足 0.1 也按 0.1 说，不出现「差 0 小时」
            let rounded = max((gap * 10).rounded() / 10, 0.1)
            number = rounded == rounded.rounded() ? Int(rounded).formatted() : String(format: "%.1f", rounded)
        }
        return "\(number) \(type.unit)"
    }
}

struct HealthDashboardSnapshot: Equatable {
    let steps: HealthMetricSnapshot
    let sleep: HealthMetricSnapshot
    /// 运动会话指标（指标卡行展示；不计入身体分数与三环）
    let workout: HealthMetricSnapshot
    let standOrActivity: HealthMetricSnapshot
    let dataSourceState: HealthDataSourceState

    /// 指标卡行顺序（阅读动线：睡眠→步数→运动→站立/活动）。
    /// 睡眠居首与身体分数权重（0.45）、今日看板顺序一致。
    var metrics: [HealthMetricSnapshot] {
        [sleep, steps, workout, standOrActivity]
    }

    /// 三环/身体分数口径只含这三项（运动不参与打分）
    var ringMetrics: [HealthMetricSnapshot] {
        [steps, sleep, standOrActivity]
    }

    /// 三环里有可用数据、参与打分的项数
    var scoringRingCount: Int {
        ringMetrics.filter { $0.availability.isReliableForScore }.count
    }

    /// 身体分：按可用项重新折算权重，但至少两项有数据才出分——
    /// 只有一项时折算后等于「单项完成度」，走满一万步就 100 分，不代表身体状态。
    var bodyScore: Int? {
        let weightedInputs: [(HealthMetricSnapshot, Double)] = [
            (steps, 0.30),
            (sleep, 0.45),
            (standOrActivity, 0.25)
        ]

        let reliableInputs = weightedInputs.filter { $0.0.availability.isReliableForScore }
        guard reliableInputs.count >= 2 else { return nil }

        let weightedScore = reliableInputs.reduce(0.0) { partial, item in
            partial + item.0.progress * item.1 * 100
        }
        let availableWeight = reliableInputs.reduce(0.0) { $0 + $1.1 }
        guard availableWeight > 0 else { return nil }

        return min(Int((weightedScore / availableWeight).rounded()), 100)
    }

    var bodyScoreText: String {
        bodyScore.map(String.init) ?? "--"
    }

    var statusTitle: String {
        guard let score = bodyScore else {
            return scoringRingCount == 0 ? String(localized: "等待健康数据") : String(localized: "数据不全")
        }
        if score >= 85 { return String(localized: "状态很好") }
        if score >= 70 { return String(localized: "状态不错") }
        if score >= 45 { return String(localized: "身体需要一点照顾") }
        return String(localized: "离目标还远")
    }

    /// 今天卡判词（分行版，显示用）：达标一句、差距一句各占一行；
    /// 整段自动换行会把「睡眠」这类词拆到两行。页面可切历史日期，文案不写「今天」。
    var verdictClauses: [String] {
        let available = ringMetrics.filter { $0.availability.isReliableForScore }
        let separator = String(localized: "、")

        guard bodyScore != nil else {
            if available.isEmpty {
                return [String(localized: "Apple Health 里还没有这一天的记录。")]
            }
            let names = available.map(\.title).joined(separator: separator)
            return [String(localized: "只有\(names)有记录，暂不计算身体分。")]
        }

        let metNames = available.filter(\.isGoalMet).map(\.title).joined(separator: separator)
        guard let worst = available.filter({ !$0.isGoalMet }).min(by: { $0.progress < $1.progress }),
              let gap = worst.gapText else {
            return [available.count == ringMetrics.count
                ? String(localized: "三环全部达标。")
                : String(localized: "\(metNames)已达标。")]
        }
        var clauses: [String] = []
        if !metNames.isEmpty {
            clauses.append(String(localized: "\(metNames)已达标，"))
        }
        clauses.append(String(localized: "\(worst.title)还差 \(gap)。"))
        return clauses
    }

    /// 判词整句（无障碍朗读 / 测试用）
    var verdictText: String {
        verdictClauses.joined()
    }

    /// 打分口径说明（出分时才有）：缺项时分数是按剩余项折算的，必须说明
    var scoringBadgeText: String? {
        guard bodyScore != nil else { return nil }
        return String(localized: "按 \(scoringRingCount) 项算")
    }

    static func standOrActivitySnapshot(
        standHours: Double,
        activeMinutes: Double,
        standAvailability: HealthMetricAvailability
    ) -> HealthMetricSnapshot {
        if standAvailability == .unsupported || (standAvailability == .noData && standHours == 0 && activeMinutes > 0) {
            return HealthMetricSnapshot(
                type: .activeMinutes,
                value: activeMinutes,
                availability: activeMinutes > 0 ? .available : .noData
            )
        }

        return HealthMetricSnapshot(
            type: .standHours,
            value: standHours,
            availability: standAvailability
        )
    }
}
