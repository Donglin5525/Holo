//
//  NotificationSettingsView.swift
//  Holo
//
//  通知设置页面
//  管理通知权限、每日提醒等设置
//

import SwiftUI

/// 通知设置页面
struct NotificationSettingsView: View {

    @StateObject private var notificationService = TodoNotificationService.shared
    @Environment(\.dismiss) var dismiss

    @State private var showPermissionAlert = false
    @State private var dailyReminderEnabled = false
    @State private var dailyReminderTime = Date()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: HoloSpacing.lg) {
                        // 通知权限状态
                        permissionSection

                        // 每日提醒
                        dailyReminderSection

                        // 智能提醒（预留）
                        smartReminderSection

                        // 测试通知
                        testNotificationSection
                    }
                    .padding(.horizontal, HoloSpacing.lg)
                    .padding(.top, HoloSpacing.md)
                }
            }
            .navigationTitle("通知设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }
            }
            .alert("通知权限", isPresented: $showPermissionAlert) {
                Button("取消", role: .cancel) { }
                Button("去设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            } message: {
                Text("请在系统设置中开启 Holo 的通知权限")
            }
            .task {
                await loadDailyReminderSettings()
            }
        }
    }

    // MARK: - Permission Section

    private var permissionSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("通知权限")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            HStack(spacing: HoloSpacing.md) {
                Image(systemName: notificationService.isAuthorized ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(notificationService.isAuthorized ? .green : .red)

                VStack(alignment: .leading, spacing: 2) {
                    Text(notificationService.isAuthorized ? "已授权" : (notificationService.isDenied ? "已拒绝" : "未授权"))
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(notificationService.isAuthorized ? "可以接收任务提醒通知" : "需要在设置中开启通知权限")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                if !notificationService.isAuthorized {
                    Button("授权") {
                        Task {
                            do {
                                _ = try await notificationService.requestAuthorization()
                            } catch {
                                showPermissionAlert = true
                            }
                        }
                    }
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.holoPrimary.opacity(0.1))
                    .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
        }
    }

    // MARK: - Daily Reminder Section

    private var dailyReminderSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("每日提醒")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                // 开关
                HStack {
                    Image(systemName: "sunrise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text("每日待办提醒")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Toggle("", isOn: $dailyReminderEnabled)
                        .labelsHidden()
                        .tint(.holoPrimary)
                        .disabled(!notificationService.isAuthorized)
                        .onChange(of: dailyReminderEnabled) { _, newValue in
                            Task {
                                await saveDailyReminderSettings(enabled: newValue)
                            }
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                if dailyReminderEnabled {
                    Divider()
                        .padding(.horizontal, 12)

                    // 时间选择器
                    HStack {
                        Image(systemName: "clock")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)

                        Text("提醒时间")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer()

                        DatePicker(
                            "",
                            selection: $dailyReminderTime,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .onChange(of: dailyReminderTime) { _, _ in
                            Task {
                                await saveDailyReminderSettings(enabled: true)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
        }
        .opacity(notificationService.isAuthorized ? 1 : 0.5)
    }

    // MARK: - Smart Reminder Section (预留)

    private var smartReminderSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("智能提醒")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)

                Text("即将推出")
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.holoPrimary.opacity(0.1))
                    .clipShape(Capsule())
            }

            HStack {
                Image(systemName: "brain")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary.opacity(0.5))

                VStack(alignment: .leading, spacing: 2) {
                    Text("AI 智能提醒")
                        .font(.holoBody)
                        .foregroundColor(.holoTextSecondary)

                    Text("根据任务优先级和习惯智能推荐提醒时间")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary.opacity(0.7))
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(Color.holoCardBackground.opacity(0.5))
            .cornerRadius(HoloRadius.md)
        }
    }

    // MARK: - Test Notification Section

    private var testNotificationSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("测试")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            Button {
                sendTestNotification()
            } label: {
                HStack {
                    Image(systemName: "bell.badge")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(notificationService.isAuthorized ? .holoPrimary : .holoTextSecondary)

                    Text("发送测试通知")
                        .font(.holoBody)
                        .foregroundColor(notificationService.isAuthorized ? .holoPrimary : .holoTextSecondary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .background(notificationService.isAuthorized ? Color.holoPrimary.opacity(0.1) : Color.holoCardBackground.opacity(0.5))
                .cornerRadius(HoloRadius.md)
            }
            .buttonStyle(PlainButtonStyle())
            .disabled(!notificationService.isAuthorized)
        }
    }

    // MARK: - Actions

    private func loadDailyReminderSettings() async {
        dailyReminderEnabled = await notificationService.isDailyReminderEnabled()
        if let time = await notificationService.getDailyReminderTime() {
            let calendar = Calendar.current
            var components = DateComponents()
            components.hour = time.hour
            components.minute = time.minute
            dailyReminderTime = calendar.date(from: components) ?? Date()
        }
    }

    private func saveDailyReminderSettings(enabled: Bool) async {
        guard !isSaving else { return }
        isSaving = true

        do {
            if enabled {
                let calendar = Calendar.current
                let hour = calendar.component(.hour, from: dailyReminderTime)
                let minute = calendar.component(.minute, from: dailyReminderTime)
                try await notificationService.scheduleDailyReminder(at: hour, minute: minute)
            } else {
                notificationService.cancelDailyReminder()
            }
        } catch {
            // 如果保存失败，恢复状态
            dailyReminderEnabled = await notificationService.isDailyReminderEnabled()
        }

        isSaving = false
    }

    private func sendTestNotification() {
        Task {
            do {
                try await notificationService.sendTestNotification()
            } catch {
                // 错误已在服务中处理
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NotificationSettingsView()
}
