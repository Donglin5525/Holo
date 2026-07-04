//
//  CalendarHeatmap.swift
//  Holo
//
//  月历色阶：事件数 → 等级 → 暖色（复用 MemoryHeatmapView 5 档暖色阶）
//  与热力图区别：0 条=空档，1 条起即有色（月历要体现单条记录）
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

    /// 等级 → 色值
    static func color(forLevel level: Int) -> Color {
        switch level {
        case 0:  return Color(hex: "#F5F2ED")   // 空档米白
        case 1:  return Color(hex: "#FFD6C7")
        case 2:  return Color(hex: "#FFB499")
        case 3:  return Color(hex: "#FF9B7A")
        default: return Color(hex: "#FF8C66")   // 满级
        }
    }

    /// 事件数 → 色值（便捷）
    static func color(forCount count: Int) -> Color {
        color(forLevel: level(forCount: count))
    }
}
