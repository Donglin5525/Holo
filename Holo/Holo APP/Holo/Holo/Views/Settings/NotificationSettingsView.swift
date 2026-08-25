//
//  NotificationSettingsView.swift
//  Holo
//
//  统一通知设置页（推送管理 · 批次3 两级化）
//  首页：四组九行，一行一类总览（状态摘要 + 开关/入口），点行进详情；
//  详情：说明卡 + 时间精调 + 预览通知样式（账单/预算为批次1新增，习惯详情为批次2页面）。
//  （原入口均保留：任务页 bell 入口不变，系统设置页 AI 回放区不变）
//

import SwiftUI
import CoreData
import UserNotifications

// MARK: - 详情页路由

/// 首页行 → 详情页 push 目标
enum NotificationDetailRoute: String, Codable, Hashable, Identifiable {
    case daily
    case habit
    case weekly
    case insight
    case bill
    case budget

    var id: String { rawValue }
}

/// 通知设置首页：一行一类总览，点行进详情
struct NotificationSettingsView: View {

    @StateObject private var notificationService = TodoNotificationService.shared
    @ObservedObject private var insightSettings = MemoryInsightScheduleSettings.shared
    @ObservedObject private var entitlementState = HoloEntitlementState.shared
    @Environment(\.dismiss) var dismiss

    @State private var showPermissionAlert = false
    @State private var path: [NotificationDetailRoute] = []

    // 首页 Toggle 状态（.task 读入；拨动写回调度器即时重排；详情页返回时重读）
    @State private var dailyEnabled = false
    @State private var habitEnabled = false
    @State private var weeklyEnabled = false
    @State private var billEnabled = false
    @State private var budgetEnabled = false

    // 摘要计数（Core Data 查询，加载/回前台/数据变化时刷新，不在 body 中执行）
    @State private var soloHabitCount = 0
    @State private var taskReminderCount = 0
    @State private var anniversaryReminderCount = 0
    @State private var goalNudgeCount = 0

    /// 入口行（任务/纪念日/目标）展开的说明。
    /// 主导航栈耦合在 HomeView 内、无法从设置 sheet 全局切 tab，跳转退化为行内展开说明
    @State private var expandedEntry: EntryNote?

    private enum EntryNote: String, Identifiable {
        case tasks
        case anniversary
        case goal

        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: HoloSpacing.md) {
                        // 通知权限状态（已授权=不显眼的一行小字）
                        permissionSection

                        group("每日 · 每周汇总") {
                            dailyRow
                            habitRow
                            weeklyRow
                            insightRow
                        }

                        group("财务提醒") {
                            billRow
                            budgetRow
                        }

                        group("按条设置的提醒") {
                            taskEntryRow
                            anniversaryEntryRow
                        }

                        group("AI 主动提醒") {
                            goalEntryRow
                        }

                        testSection
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
            .navigationDestination(for: NotificationDetailRoute.self) { route in
                destination(for: route)
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
                loadRowStates()
                loadCounts()
            }
            .onChange(of: path) { _, _ in
                // 从详情页返回：行开关与摘要可能已在详情页改过，重读一遍
                loadRowStates()
                loadCounts()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                loadCounts()
            }
            .onReceive(NotificationCenter.default.publisher(for: .todoDataDidChange)) { _ in
                loadCounts()
            }
            .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
                loadCounts()
                loadRowStates()
            }
            .onReceive(NotificationCenter.default.publisher(for: .anniversaryDataDidChange)) { _ in
                loadCounts()
            }
            .onReceive(NotificationCenter.default.publisher(for: .goalDataDidChange)) { _ in
                loadCounts()
            }
        }
    }

    // MARK: - 详情导航

    @ViewBuilder
    private func destination(for route: NotificationDetailRoute) -> some View {
        switch route {
        case .daily:
            DailyBriefNotificationDetailView()
        case .habit:
            HabitReminderDetailView()
        case .weekly:
            WeeklyBriefNotificationDetailView()
        case .insight:
            InsightNotificationDetailView()
        case .bill:
            BillDueNotificationDetailView()
        case .budget:
            BudgetOverrunNotificationDetailView()
        }
    }

    // MARK: - 权限状态

    @ViewBuilder
    private var permissionSection: some View {
        if notificationService.isAuthorized {
            Text("通知权限已开启")
                .font(.holoCaption)
                .foregroundColor(.holoTextPlaceholder)
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: HoloSpacing.md) {
                Image(systemName: notificationService.isDenied ? "bell.slash.fill" : "bell.badge")
                    .font(.system(size: 22))
                    .foregroundColor(notificationService.isDenied ? .holoError : .holoPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(notificationService.isDenied ? "通知权限已被拒绝" : "通知权限未开启")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text("开启后才能收到各类提醒通知")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                Button("授权") {
                    requestPermission()
                }
                .font(.holoCaption)
                .foregroundColor(.holoPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.holoPrimary.opacity(0.1))
                .clipShape(Capsule())
            }
            .padding(12)
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
        }
    }

    private func requestPermission() {
        Task {
            do {
                _ = try await notificationService.requestAuthorization()
                // 授权成功后立即把各类通知排起来
                DailyBriefScheduler.shared.refresh()
                HabitReminderScheduler.shared.refresh()
                WeeklyBriefScheduler.shared.refresh()
                BillDueReminderScheduler.shared.refresh()
                BudgetOverrunNotificationService.shared.refresh()
            } catch {
                showPermissionAlert = true
            }
        }
    }

    // MARK: - 每日 · 每周汇总

    private var dailyRow: some View {
        settingRow(
            icon: "sunrise.fill",
            title: "每日早报",
            summary: dailyEnabled ? "每天 \(timeText(DailyBriefScheduler.shared.reminderTime))" : "已关闭",
            action: { path.append(.daily) }
        ) {
            toggle(isOn: $dailyEnabled) { newValue in
                DailyBriefScheduler.shared.isEnabled = newValue
            }
        }
    }

    private var habitRow: some View {
        settingRow(
            icon: "checkmark.seal.fill",
            title: "习惯打卡提醒",
            summary: habitSummary,
            action: { path.append(.habit) }
        ) {
            toggle(isOn: $habitEnabled) { newValue in
                HabitReminderScheduler.shared.isEnabled = newValue
            }
        }
    }

    /// 习惯行摘要：总开关关=已关闭；兜底开=兜底时间+单独数；兜底关=只剩单独数
    private var habitSummary: String {
        guard habitEnabled else { return "已关闭" }
        let scheduler = HabitReminderScheduler.shared
        let fallback = timeText(scheduler.reminderTime)
        return scheduler.fallbackEnabled
            ? "兜底 \(fallback) · \(soloHabitCount) 个单独"
            : "\(soloHabitCount) 个单独"
    }

    private var weeklyRow: some View {
        settingRow(
            icon: "flag.checkered",
            title: "周一晨报",
            summary: weeklyEnabled ? "周一 \(timeText(WeeklyBriefScheduler.shared.reminderTime))" : "已关闭",
            action: { path.append(.weekly) }
        ) {
            toggle(isOn: $weeklyEnabled) { newValue in
                WeeklyBriefScheduler.shared.isEnabled = newValue
            }
        }
    }

    private var insightRow: some View {
        settingRow(
            icon: "sparkles",
            iconColor: .holoAI,
            title: "AI 回放",
            summary: insightSummary,
            action: { path.append(.insight) }
        ) {
            // 写回与排期由 MemoryInsightScheduleSettings.didSet 处理
            toggle(isOn: $insightSettings.weeklyReminderEnabled) { _ in }
        }
    }

    /// AI 回放摘要：周开=「周X H时」、月开=「每月d日」，都开用「·」连接，都关=已关闭
    private var insightSummary: String {
        var parts: [String] = []
        if insightSettings.weeklyReminderEnabled {
            parts.append("\(weekdayName(insightSettings.weeklyReminderWeekday)) \(insightSettings.weeklyReminderHour)时")
        }
        if insightSettings.monthlyReminderEnabled {
            parts.append("每月\(insightSettings.monthlyReminderDay)日")
        }
        return parts.isEmpty ? "已关闭" : parts.joined(separator: " · ")
    }

    // MARK: - 财务提醒

    /// 周期账单行：Plus=开关行；非 Plus=只读当前值+锁，整行点击升级
    @ViewBuilder
    private var billRow: some View {
        if entitlementState.isPlusActive {
            settingRow(
                icon: "receipt",
                title: "周期账单到期提醒",
                plusBadge: true,
                summary: billSummary,
                action: { path.append(.bill) }
            ) {
                toggle(isOn: $billEnabled) { newValue in
                    BillDueReminderScheduler.shared.isEnabled = newValue
                }
            }
        } else {
            settingRow(
                icon: "receipt",
                title: "周期账单到期提醒",
                plusBadge: true,
                summary: billSummary,
                action: {
                    HoloPlusActionCoordinator.shared.requirePlus(context: .billingCycle)
                }
            ) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary.opacity(0.6))
            }
        }
    }

    /// 账单行摘要：Plus 关=已关闭；Plus 开/非 Plus=当前提前量+时间（非 Plus 只读展示当前生效值）
    private var billSummary: String {
        let scheduler = BillDueReminderScheduler.shared
        let value = "\(advanceText(scheduler.advance)) \(timeText(scheduler.reminderTime))"
        if entitlementState.isPlusActive {
            return billEnabled ? value : "已关闭"
        }
        return value
    }

    private var budgetRow: some View {
        settingRow(
            icon: "chart.bar.fill",
            title: "预算超支提醒",
            summary: budgetEnabled ? "超支时提醒一次" : "已关闭",
            action: { path.append(.budget) }
        ) {
            toggle(isOn: $budgetEnabled) { newValue in
                BudgetOverrunNotificationService.shared.isEnabled = newValue
            }
        }
    }

    // MARK: - 按条设置的提醒（入口行：就地展开说明）

    private var taskEntryRow: some View {
        entryRow(
            icon: "bell.fill",
            title: "任务提醒",
            summary: "\(taskReminderCount) 条已设置",
            note: .tasks,
            noteText: "各任务的提醒在对应任务的详情页设置：打开任务模块，点开任务后选择「提醒」。"
        )
    }

    private var anniversaryEntryRow: some View {
        entryRow(
            icon: "heart.fill",
            iconColor: .holoError,
            title: "纪念日提醒",
            summary: "\(anniversaryReminderCount) 个已设置",
            note: .anniversary,
            noteText: "纪念日提醒在纪念日编辑页设置：可开关提醒、配置提前提醒的天数。"
        )
    }

    // MARK: - AI 主动提醒（入口行）

    private var goalEntryRow: some View {
        entryRow(
            icon: "target",
            iconColor: .holoAI,
            title: "目标风险提醒",
            summary: "\(goalNudgeCount) 个目标已开启",
            note: .goal,
            noteText: "目标快到截止、或停了两周没动静时，HoloAI 会主动提醒你。开关在每个目标的详情页（「允许 HoloAI 主动围绕此目标提醒」），按目标单独控制。"
        )
    }

    // MARK: - 行组件

    /// 组：灰字组头 + 一组行卡片
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text(title)
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: HoloSpacing.sm) {
                content()
            }
        }
    }

    /// 首页行：图标（30pt 圆角小底块）+ 名称 + 摘要（灰 12pt）+ 右侧控件；
    /// 点行（Toggle 自身响应拨动）触发 action
    private func settingRow<Trailing: View>(
        icon: String,
        iconColor: Color = .holoPrimary,
        title: String,
        plusBadge: Bool = false,
        summary: String,
        action: @escaping () -> Void,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 10) {
            NotificationSettingsIconBlock(systemName: icon, tint: iconColor)

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)
                .lineLimit(1)

            if plusBadge {
                NotificationSettingsPlusBadge()
            }

            Spacer(minLength: HoloSpacing.sm)

            Text(summary)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)

            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
        .opacity(notificationService.isAuthorized ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }

    /// 入口行：右侧 chevron，点击展开/收起底部说明
    private func entryRow(
        icon: String,
        iconColor: Color = .holoPrimary,
        title: String,
        summary: String,
        note: EntryNote,
        noteText: String
    ) -> some View {
        VStack(spacing: HoloSpacing.xs) {
            HStack(spacing: 10) {
                NotificationSettingsIconBlock(systemName: icon, tint: iconColor)

                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)

                Spacer(minLength: HoloSpacing.sm)

                Text(summary)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextPlaceholder)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(HoloAnimation.standard) {
                    expandedEntry = expandedEntry == note ? nil : note
                }
            }

            if expandedEntry == note {
                Text(noteText)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.holoCardBackground)
                    .cornerRadius(HoloRadius.md)
                    .transition(.opacity)
            }
        }
    }

    /// 行内 Toggle（未授权时禁用）
    private func toggle(isOn: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .tint(.holoPrimary)
            .disabled(!notificationService.isAuthorized)
            .onChange(of: isOn.wrappedValue) { _, newValue in
                onChange(newValue)
            }
    }

    // MARK: - 测试

    /// 弱化的测试行（沿用既有发送逻辑）
    private var testSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            Text("测试")
                .font(.holoLabel)
                .foregroundColor(.holoTextPlaceholder)

            Button {
                sendTestNotification()
            } label: {
                Text("发送测试通知")
                    .font(.holoCaption)
                    .foregroundColor(notificationService.isAuthorized ? .holoTextSecondary : .holoTextPlaceholder)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .disabled(!notificationService.isAuthorized)
        }
        .padding(.top, HoloSpacing.sm)
    }

    // MARK: - 数据加载

    private func loadRowStates() {
        dailyEnabled = DailyBriefScheduler.shared.isEnabled
        habitEnabled = HabitReminderScheduler.shared.isEnabled
        weeklyEnabled = WeeklyBriefScheduler.shared.isEnabled
        billEnabled = BillDueReminderScheduler.shared.isEnabled
        budgetEnabled = BudgetOverrunNotificationService.shared.isEnabled
    }

    /// 首页各行摘要计数（直查 Core Data，不依赖各模块是否加载过）
    private func loadCounts() {
        soloHabitCount = HabitRepository.shared.getActiveHabits()
            .filter { $0.isCheckInType && $0.habitReminderMode == .solo }
            .count

        let taskRequest = TodoTask.fetchRequest()
        taskRequest.predicate = NSPredicate(format: "deletedFlag == NO AND archived == NO AND completed == NO")
        taskReminderCount = ((try? CoreDataStack.shared.viewContext.fetch(taskRequest)) ?? [])
            .filter { !$0.remindersSet.isEmpty }
            .count

        anniversaryReminderCount = AnniversaryRepository.shared
            .allAnniversaries()
            .filter { $0.reminderEnabled }
            .count

        let goalRequest = Goal.fetchRequest()
        goalRequest.predicate = NSPredicate(format: "proactiveNudge == YES AND allowAIContext == YES")
        goalNudgeCount = (try? CoreDataStack.shared.viewContext.count(for: goalRequest)) ?? 0
    }

    // MARK: - 动作与文案辅助

    private func sendTestNotification() {
        Task {
            do {
                try await notificationService.sendTestNotification()
            } catch {
                // 错误已在服务中处理
            }
        }
    }

    /// 时:分 文本（如 "20:30"）
    private func timeText(_ time: (hour: Int, minute: Int)) -> String {
        String(format: "%02d:%02d", time.hour, time.minute)
    }

    /// 提前量文本（0=当天早上 / 1=提前 1 天 / 3=提前 3 天）
    private func advanceText(_ days: Int) -> String {
        switch days {
        case 0: return "当天早上"
        case 1: return "提前 1 天"
        default: return "提前 3 天"
        }
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "周一" }
        return symbols[weekday - 1]
    }
}

// MARK: - 每日早报详情页

private struct DailyBriefNotificationDetailView: View {

    @ObservedObject private var notificationService = TodoNotificationService.shared

    @State private var enabled = false
    @State private var time = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                DetailNoteCard(text: "开启后，每天早上的通知会直接告诉你今天有几件事、最要紧的是哪件；当天没有待办时保持安静，不会打扰。")

                VStack(spacing: 0) {
                    DetailToggleRow(icon: "sunrise.fill", title: "每日早报", isOn: $enabled, disabled: !notificationService.isAuthorized)
                        .onChange(of: enabled) { _, newValue in
                            DailyBriefScheduler.shared.isEnabled = newValue
                        }

                    if enabled {
                        Divider().padding(.horizontal, 12)

                        DetailTimeRow(title: "提醒时间", time: $time, disabled: !notificationService.isAuthorized) {
                            saveTime()
                        }
                    }
                }
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.md)
                .opacity(notificationService.isAuthorized ? 1 : 0.5)

                PreviewButtonRow(title: "预览通知样式") {
                    sendPreview()
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
        .background(Color.holoBackground)
        .navigationTitle("每日早报")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            enabled = DailyBriefScheduler.shared.isEnabled
            time = notificationTimeDate(DailyBriefScheduler.shared.reminderTime)
        }
    }

    private func saveTime() {
        let calendar = Calendar.current
        DailyBriefScheduler.shared.reminderTime = (
            hour: calendar.component(.hour, from: time),
            minute: calendar.component(.minute, from: time)
        )
    }

    /// 复用早报文案生成：今天有到期/过期任务用真实数据，否则按同格式给示例
    private func sendPreview() {
        let brief = DailyBriefScheduler.briefContent(for: Date(), tasks: TodoRepository.shared.activeTasks)
        sendPreviewNotification(
            title: brief?.title ?? "早上好，今天 2 件事",
            body: brief?.body ?? "最要紧：准备周会材料（14:00 截止） · 1 件已过期",
            category: TodoNotificationCategory.dailyReminder
        )
    }
}

// MARK: - 周一晨报详情页

private struct WeeklyBriefNotificationDetailView: View {

    @ObservedObject private var notificationService = TodoNotificationService.shared

    @State private var enabled = false
    @State private var time = Date()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                DetailNoteCard(text: "一条通知回顾上周完成了几件事、打卡了几天，点开直达今日看板；上周没有任何记录时保持安静。")

                VStack(spacing: 0) {
                    DetailToggleRow(icon: "flag.checkered", title: "周一晨报", isOn: $enabled, disabled: !notificationService.isAuthorized)
                        .onChange(of: enabled) { _, newValue in
                            WeeklyBriefScheduler.shared.isEnabled = newValue
                        }

                    if enabled {
                        Divider().padding(.horizontal, 12)

                        DetailTimeRow(title: "提醒时间", prefix: "周一", time: $time, disabled: !notificationService.isAuthorized) {
                            saveTime()
                        }
                    }
                }
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.md)
                .opacity(notificationService.isAuthorized ? 1 : 0.5)

                PreviewButtonRow(title: "预览通知样式") {
                    sendPreviewNotification(
                        title: "上周小结 · 新的一周",
                        body: "完成 12 件事 · 打卡 5 天｜本周重点：完成产品评审方案",
                        category: TodoNotificationCategory.weeklyBrief
                    )
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
        .background(Color.holoBackground)
        .navigationTitle("周一晨报")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            enabled = WeeklyBriefScheduler.shared.isEnabled
            time = notificationTimeDate(WeeklyBriefScheduler.shared.reminderTime)
        }
    }

    private func saveTime() {
        let calendar = Calendar.current
        WeeklyBriefScheduler.shared.reminderTime = (
            hour: calendar.component(.hour, from: time),
            minute: calendar.component(.minute, from: time)
        )
    }
}

// MARK: - AI 回放详情页

private struct InsightNotificationDetailView: View {

    @ObservedObject private var notificationService = TodoNotificationService.shared
    @ObservedObject private var insightSettings = MemoryInsightScheduleSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                DetailNoteCard(text: "AI 会把你的上周 / 上月记录整理成回放，生成后通知你查看。周 / 月可以分别开关。")

                VStack(spacing: 0) {
                    DetailToggleRow(
                        icon: "sparkles",
                        iconColor: .holoAI,
                        title: "每周提醒我生成周回放",
                        isOn: $insightSettings.weeklyReminderEnabled,
                        disabled: !notificationService.isAuthorized
                    )

                    if insightSettings.weeklyReminderEnabled {
                        Divider().padding(.horizontal, 12)

                        weeklyInsightTimeRow
                    }

                    Divider().padding(.horizontal, 12)

                    DetailToggleRow(
                        icon: "calendar.circle",
                        iconColor: .holoAI,
                        title: "每月提醒我生成月回放",
                        isOn: $insightSettings.monthlyReminderEnabled,
                        disabled: !notificationService.isAuthorized
                    )

                    if insightSettings.monthlyReminderEnabled {
                        Divider().padding(.horizontal, 12)

                        monthlyInsightTimeRow
                    }
                }
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.md)
                .opacity(notificationService.isAuthorized ? 1 : 0.5)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
        .background(Color.holoBackground)
        .navigationTitle("AI 回放")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// 周回放时间：周几 + 小时
    private var weeklyInsightTimeRow: some View {
        HStack(spacing: 10) {
            NotificationSettingsIconBlock(systemName: "clock", tint: .holoTextSecondary)

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
        .padding(.vertical, 10)
    }

    /// 月回放时间：每月几日 + 小时
    private var monthlyInsightTimeRow: some View {
        HStack(spacing: 10) {
            NotificationSettingsIconBlock(systemName: "clock", tint: .holoTextSecondary)

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
        .padding(.vertical, 10)
    }

    private func weekdayName(_ weekday: Int) -> String {
        let symbols = Calendar.current.weekdaySymbols
        guard symbols.indices.contains(weekday - 1) else { return "周一" }
        return symbols[weekday - 1]
    }
}

// MARK: - 周期账单到期提醒详情页

private struct BillDueNotificationDetailView: View {

    @ObservedObject private var notificationService = TodoNotificationService.shared
    @ObservedObject private var entitlementState = HoloEntitlementState.shared

    @State private var enabled = false
    @State private var time = Date()
    @State private var advance = 1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                DetailNoteCard(text: "房租、订阅等周期账单，到期前提醒一次，点开可快速记一笔。仅 Plus 账户可用（随周期账单功能）。")

                if entitlementState.isPlusActive {
                    plusCard
                        .opacity(notificationService.isAuthorized ? 1 : 0.5)
                } else {
                    lockedCard
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
        .background(Color.holoBackground)
        .navigationTitle("周期账单到期提醒")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let scheduler = BillDueReminderScheduler.shared
            enabled = scheduler.isEnabled
            time = notificationTimeDate(scheduler.reminderTime)
            advance = scheduler.advance
        }
    }

    /// Plus：开关 + 提前量三选一 chips + 时间
    private var plusCard: some View {
        VStack(spacing: 0) {
            DetailToggleRow(icon: "receipt", title: "到期提醒", plusBadge: true, isOn: $enabled, disabled: !notificationService.isAuthorized)
                .onChange(of: enabled) { _, newValue in
                    BillDueReminderScheduler.shared.isEnabled = newValue
                }

            if enabled {
                Divider().padding(.horizontal, 12)

                advanceChips(interactive: true)

                Divider().padding(.horizontal, 12)

                DetailTimeRow(title: "提醒时间", time: $time, disabled: !notificationService.isAuthorized) {
                    saveTime()
                }
            }
        }
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }

    /// 非 Plus：整卡禁用态展示当前生效值 + lock 说明，点击升级
    private var lockedCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                NotificationSettingsIconBlock(systemName: "receipt", tint: .holoPrimary)

                Text("到期提醒")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                NotificationSettingsPlusBadge()

                Spacer()

                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.holoTextSecondary.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 12)

            advanceChips(interactive: false)

            Divider().padding(.horizontal, 12)

            DetailTimeRow(title: "提醒时间", time: $time, disabled: true) {}

            Divider().padding(.horizontal, 12)

            Text("周期账单到期提醒为 Holo Plus 权益，升级后可配置提前量与提醒时间。")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
        .opacity(0.6)
        .contentShape(Rectangle())
        .onTapGesture {
            HoloPlusActionCoordinator.shared.requirePlus(context: .billingCycle)
        }
    }

    /// 提前量三选一 chips（0/1/3 天）；interactive=false 时仅展示当前选中
    private func advanceChips(interactive: Bool) -> some View {
        HStack(spacing: 8) {
            ForEach([0, 1, 3], id: \.self) { days in
                let selected = advance == days
                Button {
                    withAnimation(HoloAnimation.quick) {
                        advance = days
                        BillDueReminderScheduler.shared.advance = days
                    }
                } label: {
                    Text(Self.advanceText(days))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundColor(selected ? .white : .holoTextSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(selected ? Color.holoPrimary : Color.holoNestedCardBackground)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!interactive)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveTime() {
        let calendar = Calendar.current
        BillDueReminderScheduler.shared.reminderTime = (
            hour: calendar.component(.hour, from: time),
            minute: calendar.component(.minute, from: time)
        )
    }

    /// 提前量文本（0=当天早上 / 1=提前 1 天 / 3=提前 3 天）
    private static func advanceText(_ days: Int) -> String {
        switch days {
        case 0: return "当天早上"
        case 1: return "提前 1 天"
        default: return "提前 3 天"
        }
    }
}

// MARK: - 预算超支提醒详情页

private struct BudgetOverrunNotificationDetailView: View {

    @ObservedObject private var notificationService = TodoNotificationService.shared

    @State private var enabled = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                DetailNoteCard(text: "某个预算超支的当天提醒一次，之后不再重复；花销降回预算以内后，再次超支才会再提醒——不会天天念叨。")

                VStack(spacing: 0) {
                    DetailToggleRow(icon: "chart.bar.fill", title: "预算超支提醒", isOn: $enabled, disabled: !notificationService.isAuthorized)
                        .onChange(of: enabled) { _, newValue in
                            BudgetOverrunNotificationService.shared.isEnabled = newValue
                        }
                }
                .background(Color.holoCardBackground)
                .cornerRadius(HoloRadius.md)
                .opacity(notificationService.isAuthorized ? 1 : 0.5)

                PreviewButtonRow(title: "预览通知样式") {
                    sendPreviewNotification(
                        title: "「餐饮」预算超支了",
                        body: "已花 ¥2,340，超了预算 ¥340",
                        category: TodoNotificationCategory.budgetOverrun
                    )
                }
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
        .background(Color.holoBackground)
        .navigationTitle("预算超支提醒")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            enabled = BudgetOverrunNotificationService.shared.isEnabled
        }
    }
}

// MARK: - 详情页共用组件

/// 详情页说明卡
private struct DetailNoteCard: View {

    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 14))
                .foregroundColor(.holoTextSecondary)
                .padding(.top, 2)

            Text(text)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }
}

/// 详情页开关行：图标 + 名称（可带 PLUS 徽章）+ Toggle
private struct DetailToggleRow: View {

    let icon: String
    var iconColor: Color = .holoPrimary
    let title: String
    var plusBadge: Bool = false
    let isOn: Binding<Bool>
    var disabled: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            NotificationSettingsIconBlock(systemName: icon, tint: iconColor)

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            if plusBadge {
                NotificationSettingsPlusBadge()
            }

            Spacer()

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(.holoPrimary)
                .disabled(disabled)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// 详情页时间行：可带前缀文本（如「周一」）+ 时分选择器
private struct DetailTimeRow: View {

    let title: String
    var prefix: String? = nil
    let time: Binding<Date>
    var disabled: Bool = false
    var onChange: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            NotificationSettingsIconBlock(systemName: "clock", tint: .holoTextSecondary)

            Text(title)
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            if let prefix {
                Text(prefix)
                    .font(.holoCaption)
                    .foregroundColor(.holoPrimaryDark)
            }

            DatePicker("", selection: time, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .disabled(disabled)
                .onChange(of: time.wrappedValue) { _, _ in
                    onChange()
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// 「预览通知样式」行：发送一条该类真实格式的即时通知
private struct PreviewButtonRow: View {

    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                NotificationSettingsIconBlock(systemName: "eye", tint: .holoPrimary)

                Text(title)
                    .font(.holoBody)
                    .foregroundColor(.holoPrimaryDark)

                Spacer()

                Image(systemName: "paperplane.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.holoPrimaryDark.opacity(0.6))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.holoPrimary.opacity(0.08))
            .cornerRadius(HoloRadius.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 30pt 圆角小底块图标（首页行与详情行共用）
private struct NotificationSettingsIconBlock: View {

    let systemName: String
    let tint: Color

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(tint)
            .frame(width: 30, height: 30)
            .background(tint.opacity(0.12))
            .cornerRadius(HoloRadius.sm)
    }
}

/// PLUS 小胶囊徽章（holoPrimaryLight 底 / holoPrimaryDark 字）
private struct NotificationSettingsPlusBadge: View {

    var body: some View {
        Text("PLUS")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.holoPrimaryDark)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.holoPrimaryLight)
            .cornerRadius(5)
    }
}

// MARK: - Preview 通知发送

/// 发送一条即时预览通知（identifier 带 preview 前缀，不与真实排程冲突）
private func sendPreviewNotification(title: String, body: String, category: String) {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = .default
    content.categoryIdentifier = category

    let request = UNNotificationRequest(
        identifier: "holo.preview.\(category).\(Int(Date().timeIntervalSince1970))",
        content: content,
        trigger: nil
    )

    Task {
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// (hour, minute) → 同日的 Date（DatePicker 绑定用）
private func notificationTimeDate(_ time: (hour: Int, minute: Int)) -> Date {
    var comps = DateComponents()
    comps.hour = time.hour
    comps.minute = time.minute
    return Calendar.current.date(from: comps) ?? Date()
}

// MARK: - Preview

#Preview {
    NotificationSettingsView()
}
