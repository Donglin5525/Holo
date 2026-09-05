//
//  AnalysisTab.swift
//  Holo
//
//  财务分析模块的 Tab 枚举
//

import SwiftUI

// MARK: - Analysis Tab 枚举

/// 财务分析模块的 Tab 类型
enum AnalysisTab: String, CaseIterable, Identifiable {
    case overview, detail, category

    var id: String { rawValue }

    /// Tab 显示名（本地化文案）
    var displayName: String {
        switch self {
        case .overview: return String(localized: "总览")
        case .detail: return String(localized: "明细")
        case .category: return String(localized: "类别")
        }
    }

    /// 对应的 SF Symbol 图标名
    var icon: String {
        switch self {
        case .overview: return "chart.bar.fill"
        case .detail: return "chart.line.uptrend.xyaxis"
        case .category: return "chart.pie.fill"
        }
    }
}
