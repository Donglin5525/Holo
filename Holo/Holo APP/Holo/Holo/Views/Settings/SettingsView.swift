//
//  SettingsView.swift
//  Holo
//
//  设置页面 - 包含深色模式等设置项
//  从首页右上角人头像按钮进入
//

import SwiftUI
import OSLog

// MARK: - SettingsView

/// 设置页面
struct SettingsView: View {

    // MARK: - Environment

    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var systemColorScheme

    // MARK: - Observed Objects

    @ObservedObject private var darkModeManager = DarkModeManager.shared
    @State private var showAISettings = false

    // MARK: - Body

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: HoloSpacing.lg) {
                    // 用户信息卡片
                    userInfoCard

                    // 深色模式设置
                    darkModeSection

                    // 其他设置（占位）
                    otherSettingsSection
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.vertical, HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                ToolbarItem(placement: .principal) {
                    Text("设置")
                        .font(.holoHeading)
                        .foregroundColor(.holoTextPrimary)
                }
            }
        }
        .preferredColorScheme(darkModeManager.colorScheme)
        .id(darkModeManager.currentSetting)
        .swipeBackToDismiss { dismiss() }
    }

    // MARK: - 用户信息卡片

    private var userInfoCard: some View {
        HStack(spacing: HoloSpacing.md) {
            // 头像
            ZStack {
                Circle()
                    .fill(Color.holoPrimary.opacity(0.1))
                    .frame(width: 56, height: 56)

                Image(systemName: "person.fill")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.holoPrimary)
            }

            // 用户信息
            VStack(alignment: .leading, spacing: 4) {
                Text("东林")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text("holo@example.com")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            // 箭头
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    // MARK: - 深色模式设置

    private var darkModeSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "moon.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoPrimary)

                Text("外观")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            // 深色模式选项
            VStack(spacing: 0) {
                ForEach(DarkModeSetting.allCases, id: \.self) { setting in
                    darkModeOptionRow(setting)
                }
            }
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
        }
    }

    /// 深色模式选项行
    private func darkModeOptionRow(_ setting: DarkModeSetting) -> some View {
        Button {
            darkModeManager.updateSetting(setting)
        } label: {
            HStack(spacing: HoloSpacing.md) {
                // 图标
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(setting == darkModeManager.currentSetting
                              ? Color.holoPrimary.opacity(0.1)
                              : Color.holoBackground)
                        .frame(width: 40, height: 40)

                    Image(systemName: setting.iconName)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(setting == darkModeManager.currentSetting
                                         ? .holoPrimary
                                         : .holoTextSecondary)
                }

                // 文字
                VStack(alignment: .leading, spacing: 2) {
                    Text(setting.displayName)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    // 跟随系统时显示当前系统状态
                    if setting == .system {
                        Text(systemColorScheme == .dark ? "当前：深色" : "当前：浅色")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }
                }

                Spacer()

                // 选中指示器
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

    // MARK: - 其他设置（占位）

    private var otherSettingsSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            // 标题
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "gearshape.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoTextSecondary)

                Text("通用")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            // AI 设置
            settingsRow(
                icon: "sparkles",
                iconColor: .purple,
                title: "AI 助手",
                subtitle: "配置 AI 对话服务"
            ) {
                showAISettings = true
            }
            .sheet(isPresented: $showAISettings) {
                NavigationStack {
                    AISettingsView()
                }
            }

            // 关于
            settingsRow(
                icon: "info.circle",
                iconColor: .holoInfo,
                title: "关于 Holo",
                subtitle: "版本 1.0.0"
            ) {
                // TODO: 显示关于页面
            }

            // 调试：清除观点数据
            debugSection
        }
    }

    // MARK: - 调试

    @State private var showClearThoughtDataAlert: Bool = false

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "ladybug.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.orange)

                Text("调试")
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
            }

            Button {
                showClearThoughtDataAlert = true
            } label: {
                HStack(spacing: HoloSpacing.md) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.red.opacity(0.1))
                            .frame(width: 40, height: 40)

                        Image(systemName: "trash.circle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.red)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("清除观点数据")
                            .font(.holoBody)
                            .foregroundColor(.red)

                        Text("删除所有观点、标签和引用")
                            .font(.system(size: 12))
                            .foregroundColor(.holoTextSecondary)
                    }

                    Spacer()
                }
                .padding(HoloSpacing.md)
                .background(Color.holoCardBackground)
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .buttonStyle(PlainButtonStyle())
            .alert("确认清除观点数据？", isPresented: $showClearThoughtDataAlert) {
                Button("取消", role: .cancel) {}
                Button("清除", role: .destructive) {
                    clearThoughtData()
                }
            } message: {
                Text("此操作将删除所有观点、标签和引用数据，不可恢复。")
            }
        }
    }

    private func clearThoughtData() {
        do {
            let repo = ThoughtRepository()
            try repo.deleteAllThoughtData()
            NotificationCenter.default.post(name: .thoughtDataDidChange, object: nil)
        } catch {
            Logger(subsystem: "com.holo.app", category: "Settings").error("清除观点数据失败: \(error.localizedDescription)")
        }
    }

    /// 通用设置行
    private func settingsRow(
        icon: String,
        iconColor: Color,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: HoloSpacing.md) {
                // 图标
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(iconColor.opacity(0.1))
                        .frame(width: 40, height: 40)

                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(iconColor)
                }

                // 文字
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                // 箭头
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextSecondary.opacity(0.5))
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
