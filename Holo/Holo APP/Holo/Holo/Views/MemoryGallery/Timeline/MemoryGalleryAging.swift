//
//  MemoryGalleryAging.swift
//  Holo
//
//  「旧记忆慢慢泛黄」基建（2026-11-23 审美七项 P7）：
//  - 墨色走环境键 memoryAgingInk：每个日行注入该日墨色，行内文字经 memoryAgedInk(_:) 读取，
//    未注入（今天 / 近期低于可见阈值 / 开关关闭）时回退 galleryInk / galleryQuiet 原色
//  - 纸面缓存条目 MemoryAgedDay：纯函数 HoloPaperPalette.agedColors 的按天结果，
//    由时间线在 rebuildSections() 里与 chaptersCache 一起重建，body 内零重算
//  - 徽章、强调色（galleryAccent / galleryOrange）、缩略图、头图不在此机制内，保持原色
//

import SwiftUI

/// 泛黄进度的「可见阈值」：低于该值视作「现在」，不注入墨色、不铺纸面背景。
/// 一个月内任何一天的进度上限约 0.0068，取 0.01 保证整月与现状完全一致。
nonisolated enum MemoryAgingMetrics {
    static let visibleThreshold: Double = 0.01
    /// 时间线尽头由旧纸色渐变回纸底的高度
    static let tailFadeHeight: CGFloat = 320
}

/// 注入日行的墨色对（环境值；元组不进 Environment，收敛为小的 Equatable 结构）。
struct MemoryAgingInk: Equatable {
    let ink: Color
    let quiet: Color
}

private struct MemoryAgingInkKey: EnvironmentKey {
    static let defaultValue: MemoryAgingInk? = nil
}

extension EnvironmentValues {
    /// 该日的泛黄墨色；nil = 用原色（今天 / 近期 / 开关关闭）。
    var memoryAgingInk: MemoryAgingInk? {
        get { self[MemoryAgingInkKey.self] }
        set { self[MemoryAgingInkKey.self] = newValue }
    }
}

/// 某一天的泛黄结果（纸面 + 墨色 + 进度），按天缓存的条目。
struct MemoryAgedDay: Equatable {
    let paper: Color
    let ink: Color
    let quiet: Color
    let progress: Double

    /// 是否达到可见阈值：达到才注入墨色 / 铺纸面背景
    var isVisible: Bool { progress >= MemoryAgingMetrics.visibleThreshold }
}

/// 文字墨色的泛黄读取器：替换行内写死的 galleryInk / galleryQuiet。
struct MemoryAgedInkStyle: ViewModifier {
    enum Role {
        /// 主墨色（原 galleryInk）
        case ink
        /// 次级墨色（原 galleryQuiet）
        case quiet
    }

    @Environment(\.memoryAgingInk) private var agingInk
    let role: Role
    /// 今天 / 定位日等强调态：走 galleryAccent，不参与泛黄
    var accentOverride = false

    func body(content: Content) -> some View {
        content.foregroundStyle(color)
    }

    private var color: Color {
        if accentOverride { return .galleryAccent }
        guard let agingInk else { return role == .ink ? .galleryInk : .galleryQuiet }
        return role == .ink ? agingInk.ink : agingInk.quiet
    }
}

extension View {
    /// P7 泛黄墨色：读环境值替换 galleryInk / galleryQuiet，未注入时回退原色。
    func memoryAgedInk(_ role: MemoryAgedInkStyle.Role, accentOverride: Bool = false) -> some View {
        modifier(MemoryAgedInkStyle(role: role, accentOverride: accentOverride))
    }
}
