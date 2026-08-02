//
//  CalendarHeatmap.swift
//  Holo
//
//  月历色阶：事件数 → 等级 → Holo 冷静色阶
//  与热力图区别：0 条=空档，1 条起即有色（月历要体现单条记录）
//  色值统一来自 DesignSystem 的热力图 token，本文件只保留「事件数→等级」的分级逻辑
//

import SwiftUI

enum CalendarHeatmap {

    /// 事件数 → 等级 0...4（0=空档，4=最活跃）
    static func level(forCount count: Int) -> Int {
        switch count {
        case 0:      return 0
        case 1...2:  return 1
        case 3...5:  return 2
        case 6...9:  return 3
        default:     return 4
        }
    }

    /// 等级 → 色值；色阶来源统一走 DesignSystem.holoHeatmapColor（冷蓝）
    static func color(forLevel level: Int, colorScheme: ColorScheme = .light) -> Color {
        Color.holoHeatmapColor(level: level, palette: .cool, colorScheme: colorScheme)
    }

    /// 事件数 → 色值（便捷）
    static func color(forCount count: Int, colorScheme: ColorScheme = .light) -> Color {
        color(forLevel: level(forCount: count), colorScheme: colorScheme)
    }
}
