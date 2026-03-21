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
    case overview = "总览"
    case detail = "明细"
    case category = "类别"

    var id: String { rawValue }

    /// 对应的 SF Symbol 图标名
    var icon: String {
        switch self {
        case .overview: return "chart.bar.fill"
        case .detail: return "chart.line.uptrend.xyaxis"
        case .category: return "chart.pie.fill"
        }
    }
}
