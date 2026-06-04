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
            return "Apple Health 未连接"
        case .connected:
            return "Apple Health 已连接"
        case .partiallyConnected:
            return "Apple Health 部分连接"
        case .denied:
            return "无法访问健康数据"
        case .unavailable:
            return "此设备不支持 HealthKit"
        }
    }

    var subtitle: String {
        switch self {
        case .notRequested:
            return "授权后只读同步健康数据"
        case .connected:
            return "只读同步 · 步数 / 睡眠 / 站立"
        case .partiallyConnected:
            return "部分指标可用 · 可在系统设置中调整"
        case .denied:
            return "请在系统设置中允许 HOLO 读取健康数据"
        case .unavailable:
            return "可继续使用其他 HOLO 模块"
        }
    }

    var badgeText: String {
        switch self {
        case .notRequested:
            return "待授权"
        case .connected:
            return "在线"
        case .partiallyConnected:
            return "部分"
        case .denied:
            return "关闭"
        case .unavailable:
            return "不可用"
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
        type.rawValue
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
            return "目标 \(Int(goal).formatted())"
        case .sleep, .standHours:
            return "目标 \(type.formatValue(goal))h"
        case .activeMinutes:
            return "目标 \(Int(goal)) 分钟"
        }
    }

    var statusText: String {
        switch availability {
        case .available:
            return "\(progressPercent)%"
        case .unauthorized:
            return "未授权"
        case .noData:
            return "暂无数据"
        case .unsupported:
            return "不可用"
        }
    }
}

struct HealthInsight: Identifiable {
    let id = UUID()
    let domain: String
    let title: String
    let detail: String
    let color: Color
}

struct HealthDashboardSnapshot: Equatable {
    let steps: HealthMetricSnapshot
    let sleep: HealthMetricSnapshot
    let standOrActivity: HealthMetricSnapshot
    let dataSourceState: HealthDataSourceState

    var metrics: [HealthMetricSnapshot] {
        [steps, sleep, standOrActivity]
    }

    var bodyScore: Int? {
        let weightedInputs: [(HealthMetricSnapshot, Double)] = [
            (steps, 0.30),
            (sleep, 0.45),
            (standOrActivity, 0.25)
        ]

        let reliableInputs = weightedInputs.filter { $0.0.availability.isReliableForScore }
        guard !reliableInputs.isEmpty else { return nil }

        let weightedScore = reliableInputs.reduce(0.0) { partial, item in
            partial + item.0.progress * item.1 * 100
        }
        let availableWeight = reliableInputs.reduce(0.0) { $0 + $1.1 }
        guard availableWeight > 0 else { return nil }

        return min(Int((weightedScore / availableWeight).rounded()), 100)
    }

    var bodyScoreText: String {
        bodyScore.map(String.init) ?? "数据不足"
    }

    var statusTitle: String {
        guard let score = bodyScore else { return "等待健康数据" }
        if score >= 85 { return "状态很好" }
        if score >= 70 { return "状态不错" }
        if score >= 45 { return "身体需要一点照顾" }
        return "先把节奏放慢一点"
    }

    var statusSubtitle: String {
        if bodyScore == nil {
            return "授权或刷新 Apple Health 后，HOLO 会生成三环状态。"
        }
        if standOrActivity.type == .activeMinutes {
            return "已启用无 Watch 模式，用活动分钟替代站立环。"
        }
        return "睡眠恢复、日间活动和久坐打断共同构成身体状态。"
    }

    var ringBadgeText: String {
        let nearlyMet = metrics.filter { $0.progress >= 0.8 }.count
        return "三环 \(nearlyMet)/3 接近达标"
    }

    var coreInsight: HealthInsight {
        if sleep.availability == .available && sleep.value >= 7.5 {
            return HealthInsight(
                domain: "HOLO 洞察",
                title: "今日核心洞察",
                detail: "你睡眠接近目标时，第二天任务完成率通常更稳定。今晚优先保住睡眠环。",
                color: .holoPrimary
            )
        }

        if sleep.availability == .available && sleep.value < 6.5 {
            return HealthInsight(
                domain: "HOLO 洞察",
                title: "今日核心洞察",
                detail: "昨晚睡眠偏低，今天适合减少高压力安排，并提前准备休息窗口。",
                color: .holoPrimary
            )
        }

        return HealthInsight(
            domain: "HOLO 洞察",
            title: "今日核心洞察",
            detail: "健康数据正在积累。保持连续记录后，HOLO 会把身体状态和任务、习惯、记账串起来。",
            color: .holoPrimary
        )
    }

    var lifestyleInsights: [HealthInsight] {
        [
            HealthInsight(
                domain: "习",
                title: "运动习惯正在拉动步数",
                detail: "连续运动后，步数达标日通常会更稳定。",
                color: .holoSuccess
            ),
            HealthInsight(
                domain: "财",
                title: "低睡眠日咖啡消费偏高",
                detail: "睡眠不足时，咖啡和外食支出更容易上升。",
                color: .holoChart8
            ),
            HealthInsight(
                domain: "想",
                title: "压力记录集中在久坐日",
                detail: "站立不足时，压力类想法更值得回看。",
                color: .holoChart7
            )
        ]
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
