//
//  TaskReminderEditor.swift
//  Holo
//
//  共用提醒编辑器：AI 建任务确认卡与任务详情「日期与时间」弹窗共用。
//  两种模式：相对预设（截止前 N 分钟 chips，需带时刻的截止时间）/
//  绝对时刻（全天或无截止日任务直接选几点提醒）。
//

import SwiftUI

// MARK: - 提醒编辑器（区块组件）

struct TaskReminderEditor: View {

    enum Mode {
        /// 有带时刻的截止时间：预设「截止前 N 分钟」chips 多选 + 明细入口
        case relative
        /// 全天/无截止日：直接选具体提醒时刻（绝对提醒，不依赖截止时间）
        case absolute
    }

    let mode: TaskReminderEditor.Mode
    /// 绝对模式的默认时刻锚点（任务截止日）：添加提醒时锚定任务日 09:00，而非「现在」
    var anchorDate: Date? = nil
    @Binding var reminders: Set<TaskReminder>

    @State private var newAbsoluteReminderId: UUID? = nil
    @State private var showReminderDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            switch mode {
            case .relative:
                FlowLayout(spacing: HoloSpacing.sm) {
                    ForEach(TaskReminder.presetOptions, id: \.offsetMinutes) { reminder in
                        ReminderChip(
                            reminder: reminder,
                            isSelected: reminders.contains(reminder),
                            onTap: { toggleReminder(reminder) }
                        )
                    }
                }
                .padding(.top, 4)

            case .absolute:
                Text("没有具体时间时，设置一个提醒时刻")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.top, 2)

                let absoluteReminders = reminders.filter { $0.isAbsolute }
                ForEach(Array(absoluteReminders), id: \.id) { reminder in
                    HStack {
                        Image(systemName: "alarm")
                            .font(.system(size: 14))
                            .foregroundColor(.holoPrimary)

                        Text(reminder.displayTitle)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer()

                        Button {
                            reminders.remove(reminder)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 18))
                                .foregroundColor(.holoTextSecondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.holoPrimary.opacity(0.08))
                    .cornerRadius(HoloRadius.sm)
                }

                Button {
                    // 锚定任务日给默认时刻（09:00/当日最近整点）：
                    // 「明天的任务」配「现在+1h」的提醒会响在任务日之前，属无效提醒
                    let newReminder = TaskReminder(
                        triggerDate: TaskPendingDefaults.defaultAbsoluteTrigger(anchorDate: anchorDate)
                    )
                    reminders.insert(newReminder)
                    newAbsoluteReminderId = newReminder.id
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 16))
                        Text("添加提醒时刻")
                            .font(.holoBody)
                    }
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)

                if let reminderId = newAbsoluteReminderId,
                   let reminder = reminders.first(where: { $0.id == reminderId }) {
                    DatePicker(
                        "提醒时间",
                        selection: Binding(
                            get: { reminder.triggerDate ?? Date() },
                            set: { newDate in
                                var updated = reminders
                                updated.remove(reminder)
                                updated.insert(TaskReminder(id: reminderId, triggerDate: newDate))
                                reminders = updated
                            }
                        ),
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .labelsHidden()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                }
            }
        }
    }

    /// 头部行：有已设提醒时可点开明细弹窗——绝对提醒时刻（AI 建的多提醒/自定义时刻）
    /// 不在预设 chips 里，明细弹窗承担「看得见 + 可删除」
    private var headerRow: some View {
        let showsDetailEntry = mode == .relative && !reminders.isEmpty
        return Button {
            showReminderDetail = true
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "bell")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.holoTextSecondary)

                Text("提醒")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                if !reminders.isEmpty {
                    Text("\(reminders.count)")
                        .font(.holoCaption)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.holoPrimary)
                        .clipShape(Capsule())
                }

                Spacer()

                if showsDetailEntry {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.holoTextSecondary.opacity(0.6))
                }
            }
            // contentShape 必须在 label 内：挂在外层会让整行点击识别失效（真机实锤坑）
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!showsDetailEntry)
        .sheet(isPresented: $showReminderDetail) {
            ReminderDetailSheet(reminders: $reminders)
        }
    }

    private func toggleReminder(_ reminder: TaskReminder) {
        if reminders.contains(reminder) {
            reminders.remove(reminder)
        } else {
            reminders.insert(reminder)
        }
    }
}

// MARK: - 弹层壳（AI 建任务确认卡用）

/// 提醒选择弹层：完成时整体回传选中的提醒集合。
/// 空选 = 显式不要提醒（写回侧编码为空数组哨兵，不再回落默认 15 分钟）。
struct TaskReminderPickerSheet: View {
    let mode: TaskReminderEditor.Mode
    var anchorDate: Date? = nil
    let onDone: (Set<TaskReminder>) -> Void

    @State private var reminders: Set<TaskReminder>
    @Environment(\.dismiss) private var dismiss

    init(
        mode: TaskReminderEditor.Mode,
        initialReminders: Set<TaskReminder>,
        anchorDate: Date? = nil,
        onDone: @escaping (Set<TaskReminder>) -> Void
    ) {
        self.mode = mode
        self.anchorDate = anchorDate
        self.onDone = onDone
        self._reminders = State(initialValue: initialReminders)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.holoBackground.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    TaskReminderEditor(mode: mode, anchorDate: anchorDate, reminders: $reminders)
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.vertical, HoloSpacing.md)
                        .background(Color.holoCardBackground)
                        .cornerRadius(HoloRadius.md)
                        .padding(.horizontal, HoloSpacing.lg)
                        .padding(.top, HoloSpacing.md)
                }
            }
            .navigationTitle(mode == .relative ? "截止前提醒" : "提醒时刻")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        onDone(reminders)
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // 「提醒我…」的全天任务：打开弹层即预填一条任务日 09:00 的建议提醒。
            // 用户原话已表达提醒诉求（AI 只是不该替他猜几点），预填=把诉求落成可见可改的值；
            // 草稿态仅写回于「完成」，删掉或全清 = 不要提醒。仅绝对模式且尚无提醒时给一次——
            // 相对模式（带截止时刻）已有「15 分钟前」默认，显式清空过的不再强行塞回。
            if mode == .absolute, reminders.isEmpty, let anchorDate {
                reminders.insert(TaskReminder(
                    triggerDate: TaskPendingDefaults.defaultAbsoluteTrigger(anchorDate: anchorDate)
                ))
            }
        }
    }
}

// MARK: - 提醒明细弹窗

/// 已设提醒的逐项明细：绝对提醒（AI 建/自定义时刻）显示完整触发时间，
/// 相对提醒显示提前量；每条可删除。
/// 独立 struct（视图树类型边界），不复用宿主的泛型参数
struct ReminderDetailSheet: View {
    @Binding var reminders: Set<TaskReminder>
    @Environment(\.dismiss) private var dismiss

    /// 绝对项按触发时间升序在前，相对项按提前量从远到近在后
    private var sortedReminders: [TaskReminder] {
        let absolute = reminders
            .filter { $0.isAbsolute }
            .sorted { ($0.triggerDate ?? .distantPast) < ($1.triggerDate ?? .distantPast) }
        let relative = reminders
            .filter { !$0.isAbsolute }
            .sorted { $0.offsetMinutes > $1.offsetMinutes }
        return absolute + relative
    }

    var body: some View {
        NavigationStack {
            Group {
                if sortedReminders.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "bell.slash")
                            .font(.system(size: 28))
                            .foregroundColor(.holoTextSecondary.opacity(0.5))
                        Text("暂无提醒")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            ForEach(sortedReminders) { reminder in
                                reminderRow(reminder)
                            }
                        } footer: {
                            Text("「独立提醒」按设定时刻准时提醒，与截止时间无关；其余为截止时间前的提前提醒。")
                                .font(.holoCaption)
                        }
                    }
                }
            }
            .navigationTitle("提醒明细")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func reminderRow(_ reminder: TaskReminder) -> some View {
        HStack(spacing: 12) {
            Image(systemName: reminder.isAbsolute ? "alarm" : "bell")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.holoPrimary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle(for: reminder))
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Text(reminder.isAbsolute ? "独立提醒" : "截止时间前提醒")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
            }

            Spacer()

            Button {
                reminders.remove(reminder)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.holoTextSecondary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    /// 绝对项带星期的完整时刻（与任务详情「时间」行口径一致），相对项沿用模型文案
    private func displayTitle(for reminder: TaskReminder) -> String {
        guard let date = reminder.triggerDate else {
            return reminder.displayTitle
        }
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdEHHmm")
        return formatter.string(from: date)
    }
}
