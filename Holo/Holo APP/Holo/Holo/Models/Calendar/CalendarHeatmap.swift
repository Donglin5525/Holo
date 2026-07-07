//
//  CalendarHeatmap.swift
//  Holo
//
//  月历色阶：事件数 → 等级 → Holo 冷静品牌色阶
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
        Color(hex: hex(forLevel: level))
    }

    static func hex(forLevel level: Int) -> String {
        switch level {
        case 0:  return "#F6F8FB"
        case 1:  return "#EAF2FF"
        case 2:  return "#D9ECFF"
        case 3:  return "#CFE7F7"
        default: return "#C8DDF8"
        }
    }

    /// 事件数 → 色值（便捷）
    static func color(forCount count: Int) -> Color {
        color(forLevel: level(forCount: count))
    }
}
