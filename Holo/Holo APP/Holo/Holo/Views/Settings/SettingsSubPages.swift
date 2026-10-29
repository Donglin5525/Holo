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

/// 外观三选一：跟随系统 / 浅色 / 深色（原一级页「外观」组的 3 行平铺收进门）
struct SettingsAppearancePage: View {
    @ObservedObject private var darkModeManager = DarkModeManager.shared
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        SettingsSheetShell(String(localized: "外观")) {
            VStack(spacing: 0) {
                ForEach(DarkModeSetting.allCases, id: \.self) { setting in
                    optionRow(setting)
                }
            }
            .background(Color.holoToolSurface)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
        // sheet 有独立的 presentation 场景，preferredColorScheme 需挂 sheet 内容才生效
        .preferredColorScheme(darkModeManager.colorScheme)
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
