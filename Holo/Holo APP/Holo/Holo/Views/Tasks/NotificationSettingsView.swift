//
//  NotificationSettingsView.swift
//  Holo
//
//  统一通知设置页
//  收敛全 App 通知开关：每日早报 / 习惯打卡提醒 / 周一晨报 / 目标提醒说明 / AI 回放
//  （原入口均保留：任务页入口不变，系统设置页 AI 回放区不变）
//

import SwiftUI

/// 通知设置页面
struct NotificationSettingsView: View {

    @StateObject private var notificationService = TodoNotificationService.shared
    @ObservedObject private var insightSettings = MemoryInsightScheduleSettings.shared
    @Environment(\.dismiss) var dismiss

    @State private var showPermissionAlert = false
    @State private var dailyReminderEnabled = false
    @State private var dailyReminderTime = Date()
    @State private var habitReminderEnabled = false
    @State private var habitReminderTime = Date()
    @State private var weeklyBriefEnabled = false
    @State private var weeklyBriefTime = Date()
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: HoloSpacing.lg) {
                        // 通知权限状态
                        permissionSection

                        // 每日早报
                        dailyReminderSection

                        // 习惯打卡提醒
                        habitReminderSection

                        // 周一晨报
                        weeklyBriefSection

                        // 目标提醒（说明卡：开关在各目标详情页）
                        goalRiskSection

                        // AI 回放
                        memoryInsightSection

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
                loadSchedulerSettings()
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
                                // 授权成功后立即把各类滚动通知排起来
                                DailyBriefScheduler.shared.refresh()
                                HabitReminderScheduler.shared.refresh()
                                WeeklyBriefScheduler.shared.refresh()
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

    // MARK: - Daily Brief Section

    private var dailyReminderSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("每日早报")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                // 开关
                HStack {
                    Image(systemName: "sunrise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text("每日早报")
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

                Divider()
                    .padding(.horizontal, 12)

                Text("开启后，每天早上的通知会直接告诉你今天有几件事、最要紧的是哪件；当天没有待办时保持安静，不会打扰。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

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

    // MARK: - Habit Reminder Section

    private var habitReminderSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("习惯打卡提醒")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text("每晚提醒没打卡的习惯")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Toggle("", isOn: $habitReminderEnabled)
                        .labelsHidden()
                        .tint(.holoPrimary)
                        .disabled(!notificationService.isAuthorized)
                        .onChange(of: habitReminderEnabled) { _, newValue in
                            HabitReminderScheduler.shared.isEnabled = newValue
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                Divider()
                    .padding(.horizontal, 12)

                Text("当天全部打卡完成就不会打扰；文案会带上你的连续打卡天数。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                if habitReminderEnabled {
                    Divider()
                        .padding(.horizontal, 12)

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
                            selection: $habitReminderTime,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .onChange(of: habitReminderTime) { _, _ in
                            saveHabitReminderTime()
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

    // MARK: - Weekly Brief Section

    private var weeklyBriefSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("周一晨报")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "flag.checkered")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text("每周一开始时收上周小结")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Toggle("", isOn: $weeklyBriefEnabled)
                        .labelsHidden()
                        .tint(.holoPrimary)
                        .disabled(!notificationService.isAuthorized)
                        .onChange(of: weeklyBriefEnabled) { _, newValue in
                            WeeklyBriefScheduler.shared.isEnabled = newValue
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                Divider()
                    .padding(.horizontal, 12)

                Text("一条通知回顾上周完成了几件事、打卡了几天，点开直达今日看板；上周没有任何记录时保持安静。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                if weeklyBriefEnabled {
                    Divider()
                        .padding(.horizontal, 12)

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
                            selection: $weeklyBriefTime,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .onChange(of: weeklyBriefTime) { _, _ in
                            saveWeeklyBriefTime()
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

    // MARK: - Goal Risk Section（说明卡）

    private var goalRiskSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("目标提醒")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: HoloSpacing.sm) {
                    Image(systemName: "target")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.top, 2)

                    Text("目标快到截止、或停了两周没动静时，HoloAI 会主动提醒你。开关在每个目标的详情页（「允许 HoloAI 主动围绕此目标提醒」），按目标单独控制。")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
        }
    }

    // MARK: - Memory Insight Section（AI 回放收敛）

    private var memoryInsightSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("AI 回放")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "sparkles")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text("每周提醒我生成周回放")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Toggle("", isOn: $insightSettings.weeklyReminderEnabled)
                        .labelsHidden()
                        .tint(.holoPrimary)
                        .disabled(!notificationService.isAuthorized)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                if insightSettings.weeklyReminderEnabled {
                    Divider()
                        .padding(.horizontal, 12)

                    weeklyInsightTimeRow
                }

                Divider()
                    .padding(.horizontal, 12)

                HStack {
                    Image(systemName: "calendar.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text("每月提醒我生成月回放")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Toggle("", isOn: $insightSettings.monthlyReminderEnabled)
                        .labelsHidden()
                        .tint(.holoPrimary)
                        .disabled(!notificationService.isAuthorized)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                if insightSettings.monthlyReminderEnabled {
                    Divider()
                        .padding(.horizontal, 12)

                    monthlyInsightTimeRow
                }
            }
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
        }
        .opacity(notificationService.isAuthorized ? 1 : 0.5)
    }

    /// 周回放时间：周几 + 小时（原设置页只能看不能改，这里补上编辑入口）
    private var weeklyInsightTimeRow: some View {
        HStack {
            Image(systemName: "clock")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            Text("提醒时间")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Picker("", selection: $insightSettings.weeklyReminderWeekday) {
                ForEach(1...7, id: \.self) { weekday in
                    Text(weekdayName(weekday)).tag(weekday)
                }
            }
            .labelsHidden()

            Picker("", selection: $insightSettings.weeklyReminderHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    /// 月回放时间：每月几日 + 小时
    private var monthlyInsightTimeRow: some View {
        HStack {
            Image(systemName: "clock")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoTextSecondary)

            Text("提醒时间")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Picker("", selection: $insightSettings.monthlyReminderDay) {
                ForEach(1...28, id: \.self) { day in
                    Text("每月\(day)日").tag(day)
                }
            }
            .labelsHidden()

            Picker("", selection: $insightSettings.monthlyReminderHour) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(String(format: "%02d:00", hour)).tag(hour)
                }
            }
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "周一" }
        return symbols[weekday - 1]
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

    private func loadSchedulerSettings() {
        let calendar = Calendar.current

        dailyReminderEnabled = DailyBriefScheduler.shared.isEnabled
        dailyReminderTime = timeDate(calendar, DailyBriefScheduler.shared.reminderTime)

        habitReminderEnabled = HabitReminderScheduler.shared.isEnabled
        habitReminderTime = timeDate(calendar, HabitReminderScheduler.shared.reminderTime)

        weeklyBriefEnabled = WeeklyBriefScheduler.shared.isEnabled
        weeklyBriefTime = timeDate(calendar, WeeklyBriefScheduler.shared.reminderTime)
    }

    private func timeDate(_ calendar: Calendar, _ time: (hour: Int, minute: Int)) -> Date {
        var components = DateComponents()
        components.hour = time.hour
        components.minute = time.minute
        return calendar.date(from: components) ?? Date()
    }

    private func saveDailyReminderSettings(enabled: Bool) async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let scheduler = DailyBriefScheduler.shared
        let calendar = Calendar.current
        scheduler.reminderTime = (
            hour: calendar.component(.hour, from: dailyReminderTime),
            minute: calendar.component(.minute, from: dailyReminderTime)
        )
        scheduler.isEnabled = enabled
        // 回读真实状态（权限未授权时排期会被静默跳过）
        dailyReminderEnabled = scheduler.isEnabled
    }

    private func saveHabitReminderTime() {
        let calendar = Calendar.current
        HabitReminderScheduler.shared.reminderTime = (
            hour: calendar.component(.hour, from: habitReminderTime),
            minute: calendar.component(.minute, from: habitReminderTime)
        )
    }

    private func saveWeeklyBriefTime() {
        let calendar = Calendar.current
        WeeklyBriefScheduler.shared.reminderTime = (
            hour: calendar.component(.hour, from: weeklyBriefTime),
            minute: calendar.component(.minute, from: weeklyBriefTime)
        )
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
