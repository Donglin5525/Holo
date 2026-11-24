//
//  HoloPaperPalette.swift
//  Holo
//
//  纸色调色板（2026-11-23 审美七项）。P6「纸色随一天的时间走」与 P7「旧记忆泛黄」
//  共用，只放纯函数和色值，方便单测。
//
//  - P6 只换浅色模式下首页与「我的积累」的页面底色；深色模式完全不变。
//  - P7 只换记忆长廊的纸面与文字墨色；徽章、强调色、图片都不动。
//

import SwiftUI

/// 纸张相关设置项的开关 key。
nonisolated enum HoloPaperSettings {
    /// 随时间变换纸色（默认开）
    static let daylightKey = "holo.paper.daylightEnabled"
    /// 旧记忆慢慢泛黄（默认开）
    static let agingKey = "holo.paper.agingEnabled"
}

/// 一天里的四个纸色时段。
///
/// 注意：不要用 `DayPeriod`（问候语用的 0–6 / 6–12 / 12–18 / 18–24 分段）决定纸色——
/// 分段口径不同，混用会把「夜里 23 点」当成傍晚。
nonisolated enum HoloDaylightPeriod: String, CaseIterable {
    case morning, noon, evening, night

    /// 5:00–10:59 早；11:00–16:59 午；17:00–21:59 傍晚；22:00–4:59 夜
    static func period(forHour hour: Int) -> HoloDaylightPeriod {
        switch hour {
        case 5...10: .morning
        case 11...16: .noon
        case 17...21: .evening
        default: .night
        }
    }
}

nonisolated enum HoloPaperPalette {

    /// sRGB 分量，取值 0…1
    nonisolated struct RGB: Equatable {
        let red: Double
        let green: Double
        let blue: Double

        init(hex: String) {
            let value = UInt64(hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted), radix: 16) ?? 0
            red = Double((value >> 16) & 0xFF) / 255
            green = Double((value >> 8) & 0xFF) / 255
            blue = Double(value & 0xFF) / 255
        }

        fileprivate init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }
    }

    /// 记忆泛黄的时长上限（天）：5 年及以上为最旧
    static let agingFullDays = 1825

    /// 一组随进度插值的端点色：progress = 0 为现状，progress = 1 为最旧
    private nonisolated struct AgingEndpoints {
        let paper: RGB
        let agedPaper: RGB
        let ink: RGB
        let agedInk: RGB
        let quiet: RGB
        let agedQuiet: RGB
    }

    /// 浅色：纸 FDFCF8→F1E6CD，墨 333333→5E5240，次要 6E6E6E→6E604A
    /// （与记忆长廊现有 galleryPaper / galleryInk / galleryQuiet 同值，今天与现在完全一样）
    private static let lightEndpoints = AgingEndpoints(
        paper: RGB(hex: "FDFCF8"), agedPaper: RGB(hex: "F1E6CD"),
        ink: RGB(hex: "333333"), agedInk: RGB(hex: "5E5240"),
        quiet: RGB(hex: "6E6E6E"), agedQuiet: RGB(hex: "6E604A")
    )

    /// 深色：纸 0E0E10→1C1812，墨 F5F5F5→E6DAC4，次要 A8A8A8→A99C84
    private static let darkEndpoints = AgingEndpoints(
        paper: RGB(hex: "0E0E10"), agedPaper: RGB(hex: "1C1812"),
        ink: RGB(hex: "F5F5F5"), agedInk: RGB(hex: "E6DAC4"),
        quiet: RGB(hex: "A8A8A8"), agedQuiet: RGB(hex: "A99C84")
    )

    // MARK: - P6 随时间变换纸色

    /// 浅色模式下各时段纸色（深色模式不变，调用方直接用 holoToolBackground）。
    /// 正午等于 ToolBackground 现值，所以白天和现在一模一样。
    static func daylightPaperHex(_ period: HoloDaylightPeriod) -> String {
        switch period {
        case .morning: "FDFBF4"
        case .noon: "FDFCF8"
        case .evening: "FAF3E6"
        case .night: "F8F1E3"
        }
    }

    // MARK: - P7 旧记忆泛黄

    /// 记忆泛黄进度：0（今天）… 1（≥5 年前），缓动 0.6t² + 0.4t。
    /// 一年前约 0.10（几乎看不出），三年前约 0.46。
    static func agingProgress(daysAgo: Int) -> Double {
        let t = min(max(Double(daysAgo) / Double(agingFullDays), 0), 1)
        return 0.6 * t * t + 0.4 * t
    }

    /// 泛黄后的纸色与墨色（light / dark 两套端点插值）。
    /// progress = 0 的端点与记忆长廊现有的 galleryPaper / galleryInk / galleryQuiet 同值，
    /// 所以今天和本月与现在完全一样。
    static func agedColors(progress: Double, scheme: ColorScheme) -> (paper: Color, ink: Color, quiet: Color) {
        let rgb = agedRGB(progress: progress, scheme: scheme)
        return (color(rgb.paper), color(rgb.ink), color(rgb.quiet))
    }

    /// 供测试与调色：泛黄后的 sRGB 分量
    static func agedRGB(progress: Double, scheme: ColorScheme) -> (paper: RGB, ink: RGB, quiet: RGB) {
        let endpoints = scheme == .dark ? darkEndpoints : lightEndpoints
        let t = min(max(progress, 0), 1)
        return (mix(endpoints.paper, endpoints.agedPaper, t),
                mix(endpoints.ink, endpoints.agedInk, t),
                mix(endpoints.quiet, endpoints.agedQuiet, t))
    }

    // MARK: - 计算工具

    private static func color(_ rgb: RGB) -> Color {
        Color(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    private static func mix(_ from: RGB, _ to: RGB, _ t: Double) -> RGB {
        RGB(red: from.red + (to.red - from.red) * t,
            green: from.green + (to.green - from.green) * t,
            blue: from.blue + (to.blue - from.blue) * t)
    }

    /// WCAG 相对亮度
    private static func luminance(_ rgb: RGB) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// 两个 hex 的 WCAG 对比度
    static func contrastRatio(_ a: String, _ b: String) -> Double {
        contrastRatio(RGB(hex: a), RGB(hex: b))
    }

    /// 两个颜色的 WCAG 对比度
    static func contrastRatio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
