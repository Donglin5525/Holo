//
//  HoloDaylightPaperBackground.swift
//  Holo
//
//  随时间变换纸色（2026-11-23 审美七项 P6）：只换页面底色，不改文字色与卡片色。
//  - 只在浅色模式生效；深色模式完全不变。
//  - 只用于首页与「我的积累」两个页面（接入处调用 .holoDaylightPaper()）。
//  - 时段与色值见 HoloPaperPalette；正午等于 ToolBackground 现值，白天和现在一模一样。
//

import SwiftUI

struct HoloDaylightPaperBackground: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(HoloPaperSettings.daylightKey) private var enabled = true

    /// 决定纸色的三个量，任一变化都做一次淡入淡出
    private struct PaperKey: Equatable {
        let period: HoloDaylightPeriod
        let isDark: Bool
        let isEnabled: Bool
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            let key = paperKey(at: context.date)
            Self.paper(for: key)
                .animation(reduceMotion ? HoloAnimation.reducedFade : HoloAnimation.paperCrossfade, value: key)
        }
    }

    private func paperKey(at date: Date) -> PaperKey {
        PaperKey(period: Self.period(at: date), isDark: scheme == .dark, isEnabled: enabled)
    }

    /// 当前时刻的纸色（不做时段切换的淡入淡出）：给 toolbarBackground 这类只收颜色的场合用，
    /// 让导航栏与页面是同一张纸。
    static func currentPaper(isDark: Bool, isEnabled: Bool, date: Date = Date()) -> Color {
        paper(for: PaperKey(period: period(at: date), isDark: isDark, isEnabled: isEnabled))
    }

    private static func period(at date: Date) -> HoloDaylightPeriod {
        // App Store 截图模式固定正午，避免截图偏色
        if HoloAppStoreScreenshotSeeder.isRequested { return .noon }
        #if DEBUG
        if let forced = HoloDaylightPaperDebug.forcedPeriod { return forced }
        #endif
        return HoloDaylightPeriod.period(forHour: Calendar.current.component(.hour, from: date))
    }

    private static func paper(for key: PaperKey) -> Color {
        key.isDark || !key.isEnabled
            ? Color.holoToolBackground
            : Color(hex: HoloPaperPalette.daylightPaperHex(key.period))
    }
}

extension View {
    /// 页面底色随时段变化（仅首页与「我的积累」使用）。
    func holoDaylightPaper() -> some View {
        background(HoloDaylightPaperBackground().ignoresSafeArea())
    }
}

#if DEBUG
/// 验收用启动参数：-HoloDaylightPeriod=morning|noon|evening|night 强制时段。
nonisolated enum HoloDaylightPaperDebug {
    static let forcedPeriod: HoloDaylightPeriod? = {
        let prefix = "-HoloDaylightPeriod="
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return HoloDaylightPeriod(rawValue: String(argument.dropFirst(prefix.count)))
    }()
}
#endif
