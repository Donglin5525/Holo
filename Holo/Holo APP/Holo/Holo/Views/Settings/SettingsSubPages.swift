//
//  SettingsSubPages.swift
//  Holo
//
//  设置页规整（2026-10-25）拆出的轻量二级页与共享行组件：
//  · SettingsNavRow / SettingsToggleRow —— 原 SettingsView 私有行视图提为共享组件，
//    视觉规格（40pt 圆角方砖 + 图标 + 标题副标题 + 尾随元素）与原设置页逐像素一致
//  · SettingsSheetShell —— 设置二级页统一外壳（X 关闭 + 居中标题 + 工具页背景）
//  · SettingsAppearancePage —— 外观三选一（原一级页 3 行平铺收成入口行后的选择页）
//  · SettingsAIPlaybackPage —— AI 回放三开关（原独立分组收进门）
//

import SwiftUI

// MARK: - 共享行组件（从 SettingsView 提取，规格不变）

/// 设置页通用入口行：点击进二级页/触发动作，尾随箭头
struct SettingsNavRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    /// 尾随值文本（如外观当前值），显示在箭头左侧
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                iconTile(icon: icon, iconColor: iconColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .holoText(.body)
                        .foregroundColor(.holoToolText)
                        .lineLimit(1)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.holoToolTextSecondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if let value {
                    Text(value)
                        .font(.system(size: 13))
                        .foregroundColor(.holoToolTextSecondary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoToolTextSecondary.opacity(0.5))
            }
            .padding(HoloSpacing.md)
            .background(Color.holoToolSurface)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
    }
}

/// 设置页通用开关行
struct SettingsToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: HoloSpacing.md) {
            iconTile(icon: icon, iconColor: iconColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(.holoToolTextSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(.holoPrimary)
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 12)
    }
}

/// 40pt 圆角方砖图标底座（原 SettingsView 行内嵌套规格）
struct SettingsIconTile: View {
    let icon: String
    let iconColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .fill(iconColor.opacity(0.1))
                .frame(width: 40, height: 40)

            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(iconColor)
        }
    }
}

private extension SettingsNavRow {
    func iconTile(icon: String, iconColor: Color) -> some View {
        SettingsIconTile(icon: icon, iconColor: iconColor)
    }
}

private extension SettingsToggleRow {
    func iconTile(icon: String, iconColor: Color) -> some View {
        SettingsIconTile(icon: icon, iconColor: iconColor)
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
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoToolBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoToolTextSecondary)
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

// MARK: - AI 回放二级页

/// AI 回放三开关（原一级页「AI 回放」独立组收进门）
struct SettingsAIPlaybackPage: View {
    @ObservedObject private var insightSettings = MemoryInsightScheduleSettings.shared

    var body: some View {
        SettingsSheetShell(String(localized: "AI 回放")) {
            VStack(spacing: 0) {
                SettingsToggleRow(
                    icon: "calendar.badge.clock",
                    iconColor: .holoPrimary,
                    title: String(localized: "每周提醒我生成周回放"),
                    subtitle: weeklyReminderSubtitle,
                    isOn: $insightSettings.weeklyReminderEnabled
                )

                Divider().padding(.leading, 56)

                SettingsToggleRow(
                    icon: "calendar.circle",
                    iconColor: .holoSuccess,
                    title: String(localized: "每月提醒我生成月回放"),
                    subtitle: monthlyReminderSubtitle,
                    isOn: $insightSettings.monthlyReminderEnabled
                )

                Divider().padding(.leading, 56)

                SettingsToggleRow(
                    icon: "arrow.triangle.2.circlepath",
                    iconColor: .holoInfo,
                    title: String(localized: "允许后台自动尝试生成"),
                    subtitle: String(localized: "iOS 不保证准时执行，下次打开 App 时会补生成"),
                    isOn: $insightSettings.backgroundAutoGenerationEnabled
                )
            }
            .background(Color.holoToolSurface)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    private var weeklyReminderSubtitle: String {
        if insightSettings.weeklyReminderEnabled {
            return String(localized: "每\(insightSettings.weeklyReminderWeekdayName) \(String(format: "%02d", insightSettings.weeklyReminderHour)):00")
        }
        return String(localized: "默认关闭")
    }

    private var monthlyReminderSubtitle: String {
        if insightSettings.monthlyReminderEnabled {
            return String(localized: "每月\(insightSettings.monthlyReminderDay)日 \(String(format: "%02d", insightSettings.monthlyReminderHour)):00")
        }
        return String(localized: "默认关闭")
    }
}
