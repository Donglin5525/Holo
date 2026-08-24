//
//  ReportScenarioTag.swift
//  Holo
//
//  报告档案的场景归类（P0 方案）：按问句关键词本地匹配，词表与
//  AnalysisScenario 的预填问句同源；历史报告（含旧默认问句）可回溯打标。
//  后续若意图识别返回场景字段，替换 classify 的实现即可，档案零迁移。
//

import SwiftUI
import UIKit

enum ReportScenarioTag: String, CaseIterable, Sendable {
    case crossDomain
    case finance
    case habit
    case health
    case task
    case thought
    case goal
    case longTermPattern
    case replay
    case general

    /// 筛选行与徽标共用短名
    var label: String {
        switch self {
        case .crossDomain: return "跨域"
        case .finance: return "财务"
        case .habit: return "习惯"
        case .health: return "健康"
        case .task: return "任务"
        case .thought: return "想法"
        case .goal: return "目标"
        case .longTermPattern: return "长期"
        case .replay: return "回放"
        case .general: return "其他"
        }
    }

    /// 徽标配色：前景色按亮暗模式切换，背景由同色低透明生成；
    /// replay 复用类型徽标，不另显场景徽标。
    var badgeColors: (background: Color, foreground: Color) {
        let tint = badgeTint
        return (tint.opacity(0.12), tint)
    }

    private var badgeTint: Color {
        switch self {
        case .crossDomain:
            return .holoLineageTint
        case .finance:
            return .holoStarTint
        case .habit:
            return Color.holoDynamic(
                light: UIColor(red: 0.08, green: 0.50, blue: 0.24, alpha: 1),
                dark: UIColor(red: 0.45, green: 0.88, blue: 0.60, alpha: 1)
            )
        case .health:
            return .holoFollowUpTint
        case .task:
            return Color.holoDynamic(
                light: UIColor(red: 0.26, green: 0.23, blue: 0.79, alpha: 1),
                dark: UIColor(red: 0.68, green: 0.67, blue: 1.00, alpha: 1)
            )
        case .thought:
            return Color.holoDynamic(
                light: UIColor(red: 0.75, green: 0.09, blue: 0.36, alpha: 1),
                dark: UIColor(red: 1.00, green: 0.55, blue: 0.72, alpha: 1)
            )
        case .goal:
            return Color.holoDynamic(
                light: UIColor(red: 0.76, green: 0.26, blue: 0.05, alpha: 1),
                dark: UIColor(red: 1.00, green: 0.65, blue: 0.42, alpha: 1)
            )
        case .longTermPattern:
            return Color.holoDynamic(
                light: UIColor(red: 0.06, green: 0.46, blue: 0.43, alpha: 1),
                dark: UIColor(red: 0.45, green: 0.85, blue: 0.80, alpha: 1)
            )
        case .replay, .general:
            return .secondary
        }
    }

    /// 问句 → 场景。跨域判定优先（旧跨域问句含多个单域词，先判单域会误归）；
    /// 「数据趋势」是旧默认跨域问句（分析一下我最近的数据趋势）的特征词。
    static func classify(question: String?) -> ReportScenarioTag {
        guard let q = question, !q.isEmpty else { return .general }
        if q.contains("放在一起") || q.contains("各类生活数据")
            || q.contains("跨领域") || q.contains("数据趋势") {
            return .crossDomain
        }
        if q.contains("财务") || q.contains("支出") || q.contains("花销")
            || q.contains("消费") || q.contains("预算") {
            return .finance
        }
        if q.contains("睡眠") || q.contains("健康") || q.contains("运动") || q.contains("步数") {
            return .health
        }
        if q.contains("习惯") || q.contains("打卡") {
            return .habit
        }
        if q.contains("任务") || q.contains("待办") {
            return .task
        }
        if q.contains("想法") || q.contains("主题") || q.contains("念头") {
            return .thought
        }
        if q.contains("目标") {
            return .goal
        }
        if q.contains("长期偏好") || q.contains("长期模式") {
            return .longTermPattern
        }
        return .general
    }
}
