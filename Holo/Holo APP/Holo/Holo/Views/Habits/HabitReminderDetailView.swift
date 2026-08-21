//
//  HabitReminderDetailView.swift
//  Holo
//
//  习惯打卡提醒详情页（推送管理 · 批次2 建页，批次3 挂进通知设置页详情导航）
//  兜底开关/时间 + 按习惯三态设置（跟随兜底 / 单独时间 / 不提醒）+ 规则说明。
//  由通知设置页 push 呈现，本页不再自带 NavigationStack；
//  同文件提供三处共用的三选一选择器 HabitReminderModePicker。
//

import SwiftUI

// MARK: - 习惯打卡提醒详情页

/// sheet(item:) 弹层目标：点击打卡型习惯行时携带该习惯
private struct HabitReminderEditTarget: Identifiable {
    let habit: Habit
    var id: UUID { habit.id }
}

/// 习惯打卡提醒详情页：①兜底卡片 ②按习惯设置列表 ③规则说明
struct HabitReminderDetailView: View {

    /// 习惯行数据（streak 等 Core Data 查询在加载时算好，不在 body 中执行）
    private struct HabitRow: Identifiable {
        let habit: Habit
        /// 连续打卡文案（如 "3天"，无展示价值时为 nil）
        let streakText: String?
        var id: UUID { habit.id }
    }

    // MARK: - State

    /// 兜底汇总子开关（HabitReminderScheduler.fallbackEnabled）；
    /// 总开关在通知设置首页的习惯行上
    @State private var fallbackEnabled: Bool = true
    @State private var fallbackTime: Date = Date()
    @State private var habits: [HabitRow] = []
    @State private var editTarget: HabitReminderEditTarget? = nil

    private let repository = HabitRepository.shared

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                fallbackSection
                perHabitSection
                rulesSection
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, HoloSpacing.sm)
        }
        .background(Color.holoBackground)
        .navigationTitle("习惯打卡提醒")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            loadSchedulerSettings()
            loadHabits()
        }
        .onReceive(NotificationCenter.default.publisher(for: .habitDataDidChange)) { _ in
            loadHabits()
        }
        .sheet(item: $editTarget) { target in
            HabitReminderEditSheet(target: target)
        }
    }

    // MARK: - 兜底提醒

    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("兜底提醒")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                // 兜底汇总子开关（绑 fallbackEnabled，只管汇总；总开关在通知设置首页）
                HStack {
                    Image(systemName: "moon.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.holoTextSecondary)

                    Text("兜底汇总提醒")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer()

                    Toggle("", isOn: $fallbackEnabled)
                        .labelsHidden()
                        .tint(.holoPrimary)
                        .onChange(of: fallbackEnabled) { _, newValue in
                            HabitReminderScheduler.shared.fallbackEnabled = newValue
                        }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)

                Divider()
                    .padding(.horizontal, 12)

                Text("跟随兜底的习惯会在兜底时间收到一条汇总提醒；关闭后，单独设了时间的习惯仍按自己的时间提醒。")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)

                if fallbackEnabled {
                    Divider()
                        .padding(.horizontal, 12)

                    HStack {
                        Image(systemName: "clock")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.holoTextSecondary)

                        Text("兜底时间")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer()

                        DatePicker(
                            "",
                            selection: $fallbackTime,
                            displayedComponents: .hourAndMinute
                        )
                        .labelsHidden()
                        .onChange(of: fallbackTime) { _, _ in
                            saveFallbackTime()
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
            }
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
        }
    }

    // MARK: - 按习惯设置

    private var perHabitSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            Text("按习惯设置")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            VStack(spacing: 0) {
                if habits.isEmpty {
                    Text("暂无习惯")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else {
                    ForEach(habits) { row in
                        if row.habit.isCheckInType {
                            checkInRow(row)
                        } else {
                            numericRow(row)
                        }

                        if row.id != habits.last?.id {
                            Divider()
                                .padding(.horizontal, 12)
                        }
                    }
                }
            }
            .background(Color.holoCardBackground)
            .cornerRadius(HoloRadius.md)
        }
    }

    /// 打卡型习惯行：图标 + 名字 + 连续天数 + 当前模式值，点击弹三选一
    private func checkInRow(_ row: HabitRow) -> some View {
        Button {
            editTarget = HabitReminderEditTarget(habit: row.habit)
        } label: {
            HStack(spacing: 10) {
                row.habit.iconImage(size: 20)
                    .foregroundColor(row.habit.habitColor)

                Text(row.habit.name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)

                if let streakText = row.streakText {
                    Text("🔥\(streakText)")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()

                Text(modeSummary(for: row.habit))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 数值型习惯行：置灰，不参与提醒
    private func numericRow(_ row: HabitRow) -> some View {
        HStack(spacing: 10) {
            row.habit.iconImage(size: 20)
                .foregroundColor(.holoTextSecondary)

            Text(row.habit.name)
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .lineLimit(1)

            Spacer()

            Text("数值型 · 不参与提醒")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .opacity(0.7)
    }

    /// 当前模式值的行内摘要
    private func modeSummary(for habit: Habit) -> String {
        switch habit.habitReminderMode {
        case .follow:
            let time = HabitReminderScheduler.shared.reminderTime
            return "兜底 \(Self.timeText(time.hour, time.minute))"
        case .solo:
            return "单独 \(Self.timeText(Int(habit.reminderHour), Int(habit.reminderMinute)))"
        case .none:
            return "不提醒"
        }
    }

    // MARK: - 规则说明

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("规则说明")
                .font(.holoLabel)
                .foregroundColor(.holoTextSecondary)

            ruleText("单独设了时间的习惯按自己的时间提醒，当天不再进兜底汇总——同一习惯一天最多提醒一次")
            ruleText("当天已打卡的习惯不会收到任何提醒")
            ruleText("只有打卡型习惯能设提醒，数值型不参与")
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoCardBackground)
        .cornerRadius(HoloRadius.md)
    }

    private func ruleText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("·")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Text(text)
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 数据加载

    private func loadSchedulerSettings() {
        let scheduler = HabitReminderScheduler.shared
        let calendar = Calendar.current

        fallbackEnabled = scheduler.fallbackEnabled
        var comps = DateComponents()
        let time = scheduler.reminderTime
        comps.hour = time.hour
        comps.minute = time.minute
        fallbackTime = calendar.date(from: comps) ?? Date()
    }

    private func loadHabits() {
        habits = repository.getActiveHabits()
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { habit in
                let streak = repository.calculateStreakInfo(for: habit)
                return HabitRow(
                    habit: habit,
                    streakText: habit.isCheckInType && streak.value >= 2 ? streak.displayText : nil
                )
            }
    }

    private func saveFallbackTime() {
        let calendar = Calendar.current
        HabitReminderScheduler.shared.reminderTime = (
            hour: calendar.component(.hour, from: fallbackTime),
            minute: calendar.component(.minute, from: fallbackTime)
        )
    }

    /// 时:分 文本（如 "20:30"）
    private static func timeText(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }
}

// MARK: - 单习惯三选一弹层

/// 单个习惯的打卡提醒三选一弹层（.sheet(item:) 惯例，避免 confirmationDialog 失焦竞态坑）
/// 确认后经 HabitRepository.updateHabit 落库，随 .habitDataDidChange 触发调度器重排
private struct HabitReminderEditSheet: View {

    @Environment(\.dismiss) private var dismiss

    let target: HabitReminderEditTarget

    @State private var mode: HabitReminderMode
    @State private var time: Date

    init(target: HabitReminderEditTarget) {
        self.target = target
        _mode = State(initialValue: target.habit.habitReminderMode)

        var comps = DateComponents()
        comps.hour = Int(target.habit.reminderHour)
        comps.minute = Int(target.habit.reminderMinute)
        _time = State(initialValue: Calendar.current.date(from: comps) ?? Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text("「\(target.habit.name)」的打卡提醒")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)

                    HabitReminderModePicker(mode: $mode, time: $time)
                }
                .padding(HoloSpacing.md)
            }
            .background(Color.holoBackground)
            .navigationTitle("打卡提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(.holoTextSecondary)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("确定") {
                        confirm()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func confirm() {
        let calendar = Calendar.current
        try? HabitRepository.shared.updateHabit(target.habit, updates: HabitUpdates(
            reminderMode: mode,
            reminderTime: (
                hour: calendar.component(.hour, from: time),
                minute: calendar.component(.minute, from: time)
            )
        ))
        dismiss()
    }
}

// MARK: - 三选一选择器（共用组件）

/// 打卡提醒三选一选择器：radio 风格三张可选卡 + solo 选中展开时间行。
/// 新建/编辑习惯表单、习惯详情页、单习惯弹层三处共用。
struct HabitReminderModePicker: View {

    /// 当前提醒模式
    @Binding var mode: HabitReminderMode
    /// solo 模式的提醒时刻（只取 hour/minute）
    @Binding var time: Date

    var body: some View {
        VStack(spacing: 8) {
            optionCard(.follow, subtitle: "每天 \(fallbackTimeText) 与其他习惯一起汇总提醒")
            optionCard(.solo, subtitle: "按自己设置的时间单独提醒")
            if mode == .solo {
                timeRow
            }
            optionCard(.none, subtitle: "不为这个习惯发送打卡提醒")
        }
    }

    /// 兜底时间文本（从调度器读全局兜底设置）
    private var fallbackTimeText: String {
        let time = HabitReminderScheduler.shared.reminderTime
        return String(format: "%02d:%02d", time.hour, time.minute)
    }

    private func optionCard(_ value: HabitReminderMode, subtitle: String) -> some View {
        Button {
            withAnimation(HoloAnimation.standard) {
                mode = value
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: mode == value ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(mode == value ? .holoPrimary : .holoTextSecondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(value.displayName)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(subtitle)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .fill(Color.holoCardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                    .stroke(mode == value ? Color.holoPrimary : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    /// solo 展开的时间行
    private var timeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.holoPrimary)

            Text("提醒时间")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)

            Spacer()

            DatePicker(
                "",
                selection: $time,
                displayedComponents: .hourAndMinute
            )
            .labelsHidden()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .fill(Color.holoCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                .stroke(Color.holoPrimary.opacity(0.4), lineWidth: 1)
        )
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        HabitReminderDetailView()
    }
}
