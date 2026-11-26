//
//  SettingsSubPages.swift
//  Holo
//
//  设置页规整（2026-10-25）拆出的轻量二级页与共享行组件：
//  · SettingsNavRow / SettingsToggleRow —— 与 HoloSettingsRow 共用圆形图标、文字与点击区域
//  · SettingsSheetShell —— 设置二级页统一外壳（X 关闭 + 居中标题 + 工具页背景）
//  · SettingsAppearancePage —— 外观三选一（原一级页 3 行平铺收成入口行后的选择页）
//  周期回放统一使用 HoloAIUserSettingsContent 中的完整设置页。
//

import SwiftUI
import CloudKit

// MARK: - 共享行组件（与 HoloSettingsRow 使用同一套规格）

/// 设置页通用入口行：点击进二级页/触发动作，尾随箭头
struct SettingsNavRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String = ""
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HoloSettingsRow(
                icon: icon,
                iconColor: iconColor,
                title: title,
                subtitle: detailText
            ) {
                HStack(spacing: HoloSpacing.sm) {
                    if let value, !dynamicTypeSize.isAccessibilitySize {
                        Text(value)
                            .holoText(.metadata)
                            .foregroundStyle(Color.holoToolTextSecondary)
                            .fixedSize()
                    }
                    HoloSettingsChevron()
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 大字体下将当前值放回正文列，避免挤掉图标或标题。
    private var detailText: String? {
        let parts = [subtitle.isEmpty ? nil : subtitle,
                     dynamicTypeSize.isAccessibilitySize ? value : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 开关保留完整文字标签，系统朗读与大字体布局都使用同一份标题。
struct SettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HoloSettingsRow(icon: icon, iconColor: iconColor, title: title, subtitle: subtitle)
        }
        .tint(.holoPrimary)
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, HoloSpacing.xs)
    }
}

/// 与 HoloSettingsRow 共用 36pt 圆形底座；显式固定尺寸，防止长文案挤掉图标。
struct SettingsIconTile: View {
    let icon: String
    let iconColor: Color

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(iconColor)
            .frame(width: 36, height: 36)
            .background(Circle().fill(iconColor.opacity(0.12)))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// 用在未包裹 HoloSettingsSection 的整张设置卡内，与正文起点对齐。
struct SettingsRowDivider: View {
    var body: some View {
        Divider().padding(.leading, HoloSpacing.md + 36 + HoloSpacing.sm)
    }
}

// MARK: - 二级页外壳

/// 设置二级页统一外壳：NavigationStack + X 关闭 + 居中标题 + 工具页背景。
/// 与 AboutView 的导航栏规格一致（sheet 场景必须自带关闭钮）。
struct SettingsSheetShell<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                content
                    .padding(.horizontal, HoloSpacing.page)
                    .padding(.vertical, HoloSpacing.md)
                    .holoContentColumn(paintsBackground: false)
            }
            .background(Color.holoToolBackground)
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: HoloToolbarPlacement.topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(String(localized: "关闭"))
                }
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .holoText(.sectionTitle)
                        .foregroundColor(.holoToolText)
                }
            }
        }
    }
}

// MARK: - 外观二级页

/// 外观设置：明暗模式 + 首页视觉模板（允许用户自由切换经典光球 / 纸本星象 / 盈亏月相）
struct SettingsAppearancePage: View {
    @ObservedObject private var darkModeManager = DarkModeManager.shared
    @ObservedObject private var homeTemplateManager = HomeTemplateManager.shared
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        SettingsSheetShell(String(localized: "外观")) {
            VStack(alignment: .leading, spacing: HoloSpacing.lg) {
                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text(String(localized: "明暗模式"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(DarkModeSetting.allCases, id: \.self) { setting in
                            optionRow(setting)
                        }
                    }
                    .background(Color.holoToolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                }

                VStack(alignment: .leading, spacing: HoloSpacing.sm) {
                    Text(String(localized: "首页风格"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .padding(.horizontal, 4)

                    VStack(spacing: 0) {
                        ForEach(Array(HomeTemplateStyle.allCases.enumerated()), id: \.element.id) { idx, style in
                            if idx > 0 {
                                SettingsRowDivider()
                            }
                            homeTemplateRow(style)
                        }
                    }
                    .background(Color.holoToolSurface)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
                }
            }
        }
        // sheet 有独立的 presentation 场景，preferredColorScheme 需挂 sheet 内容才生效
        .preferredColorScheme(darkModeManager.colorScheme)
    }

    private func homeTemplateRow(_ style: HomeTemplateStyle) -> some View {
        let isSelected = style == homeTemplateManager.currentStyle
        return Button {
            homeTemplateManager.updateStyle(style)
        } label: {
            HStack(spacing: HoloSpacing.md) {
                homeTemplateThumbnail(style, isSelected: isSelected)

                VStack(alignment: .leading, spacing: 3) {
                    Text(style.displayName)
                        .holoText(.body)
                        .foregroundStyle(Color.holoToolText)
                    Text(style.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(Color.holoPrimary)
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 13)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func homeTemplateThumbnail(_ style: HomeTemplateStyle, isSelected: Bool) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .fill(isSelected ? Color.holoPrimary.opacity(0.09) : Color.holoToolInset)
                .frame(width: 44, height: 44)
                .overlay(
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        .strokeBorder(isSelected ? Color.holoPrimary.opacity(0.45) : Color.clear, lineWidth: 0.8)
                )

            switch style {
            case .classic:
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.holoPrimaryLight, .holoPrimary, .holoPrimaryDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 24, height: 24)
                    .overlay(Circle().stroke(Color.white.opacity(0.55), lineWidth: 1).frame(width: 14, height: 14))
            case .sundial:
                ZStack {
                    Circle()
                        .stroke(Color.holoAlmanacInk.opacity(0.32), style: StrokeStyle(lineWidth: 0.9, dash: [1.5, 2.5]))
                        .frame(width: 26, height: 26)
                    Circle()
                        .fill(Color.holoPaper)
                        .frame(width: 17, height: 17)
                        .overlay(Circle().stroke(Color.holoAlmanacInk.opacity(0.25), lineWidth: 0.6))
                    Capsule()
                        .fill(Color.holoAlmanacInk)
                        .frame(width: 1.2, height: 8)
                        .offset(y: -2.5)
                        .rotationEffect(.degrees(32))
                    Circle()
                        .fill(Color.holoPrimary)
                        .frame(width: 3, height: 3)
                }
            case .moonPhase:
                ZStack {
                    Circle()
                        .stroke(Color.holoAlmanacInk.opacity(0.24), lineWidth: 0.8)
                        .frame(width: 26, height: 26)
                    Circle()
                        .fill(Color.holoAlmanacInk.opacity(0.85))
                        .frame(width: 16, height: 16)
                        .mask(
                            ZStack {
                                Circle().frame(width: 16, height: 16)
                                Circle().frame(width: 15, height: 15).offset(x: -6).blendMode(.destinationOut)
                            }
                            .compositingGroup()
                        )
                    Circle()
                        .fill(Color.holoPrimary)
                        .frame(width: 2.8, height: 2.8)
                        .offset(y: -11)
                }
            }
        }
    }

    private func optionRow(_ setting: DarkModeSetting) -> some View {
        Button {
            darkModeManager.updateSetting(setting)
        } label: {
            HStack(spacing: HoloSpacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: HoloRadius.sm)
                        // 未选中砖改嵌套底：深色下纯黑砖压深灰卡，浅色下观感不变
                        .fill(setting == darkModeManager.currentSetting
                              ? Color.holoPrimary.opacity(0.1)
                              : Color.holoToolInset)
                        .frame(width: 40, height: 40)

                    Image(systemName: setting.iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(setting == darkModeManager.currentSetting
                                         ? .holoPrimary
                                         : .holoToolTextSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(setting.displayName)
                        .holoText(.body)
                        .foregroundColor(.holoToolText)

                    // 跟随系统时显示当前系统状态
                    if setting == .system {
                        Text(systemColorScheme == .dark ? String(localized: "当前：深色") : String(localized: "当前：浅色"))
                            .font(.system(size: 12))
                            .foregroundColor(.holoToolTextSecondary)
                    }
                }

                Spacer()

                if setting == darkModeManager.currentSetting {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(.holoPrimary)
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// 账号可用不等于同步成功；入口与详情统一优先提示失败、进行中与首次等待。
@MainActor
enum SettingsSyncCopy {
    static func summary(for status: ICloudSyncStatusService) -> String {
        guard CloudKitRuntimeAvailability.isAvailable else {
            return String(localized: "当前构建未启用 iCloud 同步")
        }
        if status.lastErrorMessage != nil { return String(localized: "同步遇到问题 · 查看详情") }
        if status.isSyncing { return String(localized: "正在同步") }
        if status.isInitialSyncPending { return String(localized: "正在等待首次同步") }
        if status.accountStatus == .available { return String(localized: "iCloud 可用") }
        return status.accountStatusText
    }
}
