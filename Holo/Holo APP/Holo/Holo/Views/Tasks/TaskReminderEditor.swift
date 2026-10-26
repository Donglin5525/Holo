//
//  TaskReminderEditor.swift
//  Holo
//
//  共用提醒编辑器：AI 建任务确认卡与任务详情「日期与时间」弹窗共用。
//  交互契约（原型 task-datetime-redesign-prototype.html，2026-10-14 东林拍板）：
//  ① 档位 chips = 开关：橙实心 = 已设，再点即取消；已设档位不重复出现在下方列表。
//  ② 列表只放非档位条目（自定义时刻 / 非预设提前量），带类型小标签，点行进入编辑草稿行。
//  ③ 自定义添加 = 行级确认制：「⊕ 添加自定义时刻」展开草稿行（滚轮 + 取消/添加），
//     点「添加」才成条、不占角标数；编辑同理（取消恢复原值）。滚轮确认前不写穿。
//  ④ 按语义统一去重：绝对项按时刻（分钟粒度）、相对项按提前量判等，不看内部 id——
//     从库里读回的条目 id 与预设实例不同，按 id 判等会让选中态失灵、同语义条目重复（推送双响）。
//  ⑤ 滚轮原生高度独立成行，不压缩不叠行；同一时刻只允许一条。
//

import SwiftUI

// MARK: - 提醒编辑器（区块组件）

struct TaskReminderEditor: View {

    enum Mode {
        /// 有带时刻的截止时间：预设「截止前 N 分钟」chips 多选
        case relative
        /// 全天/无截止日：锚定任务日的快捷档位 chips + 自定义提醒时刻（绝对提醒）
        case absolute
    }

    let mode: TaskReminderEditor.Mode
    /// 绝对模式的默认时刻锚点（任务截止日）：添加提醒时锚定任务日 09:00，而非「现在」
    var anchorDate: Date? = nil
    @Binding var reminders: Set<TaskReminder>

    /// 行级草稿态：nil = 静息；adding = 新提醒草稿行；editing = 修改某条
    private enum Draft {
        case adding
        case editing(id: UUID, originalDate: Date)
    }
    @State private var draft: Draft?
    @State private var draftDate = Date()

    /// 锚定预设档（相对任务日的天偏移 + 时刻）；点选即开关、可多选
    private struct AnchoredPreset {
        let dayOffset: Int
        let hour: Int
        let minute: Int
        let label: String
    }
    private static let anchoredPresets: [AnchoredPreset] = [
        AnchoredPreset(dayOffset: 0, hour: 9, minute: 0, label: "当天 09:00"),
        AnchoredPreset(dayOffset: 0, hour: 18, minute: 0, label: "当天 18:00"),
        AnchoredPreset(dayOffset: -1, hour: 20, minute: 0, label: "前一天 20:00"),
    ]

    // MARK: - 语义判等（去重核心）

    /// 分钟粒度的时刻键：滚轮与预设档生成的都是整分时刻，键相等即同一时刻
    private static func minuteKey(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 60)
    }

    /// 该时刻是否已被占用（编辑草稿时排除自身）
    private func isDateTaken(_ date: Date, excluding excludedId: UUID?) -> Bool {
        reminders.contains { reminder in
            reminder.id != excludedId
                && reminder.isAbsolute
                && Self.minuteKey(reminder.triggerDate!) == Self.minuteKey(date)
        }
    }

    private func hasAbsoluteReminder(at date: Date) -> Bool {
        reminders.contains { reminder in
            reminder.isAbsolute && Self.minuteKey(reminder.triggerDate!) == Self.minuteKey(date)
        }
    }

    private func hasRelativeReminder(matchingOffset offsetMinutes: Int) -> Bool {
        reminders.contains { !$0.isAbsolute && $0.offsetMinutes == offsetMinutes }
    }

    /// 当前锚定档位对应的时刻键集合：列表据此排除已设档位（档位只在 chips 上表达）
    private var presetDateKeys: Set<Int> {
        guard anchorDate != nil else { return [] }
        return Set(
            Self.anchoredPresets.compactMap { preset in
                presetDate(preset).map { Self.minuteKey($0) }
            }
        )
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            headerRow

            switch mode {
            case .relative:
                relativeSection
            case .absolute:
                absoluteSection
            }
        }
    }

    // MARK: - 头部行

    /// 头部行：角标数字 = 当前（草稿）条目数，所见即所得
    private var headerRow: some View {
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
        }
    }

    // MARK: - 相对模式（截止前 N 分钟）

    private var relativeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            FlowLayout(spacing: HoloSpacing.sm) {
                ForEach(TaskReminder.presetOptions, id: \.offsetMinutes) { reminder in
                    presetChipButton(
                        label: reminder.displayTitle,
                        isSelected: hasRelativeReminder(matchingOffset: reminder.offsetMinutes),
                        isDisabled: false
                    ) {
                        togglePresetReminder(offsetMinutes: reminder.offsetMinutes)
                    }
                }
            }

            reminderList
        }
    }

    // MARK: - 绝对模式（锚定任务日）

    private var absoluteSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if anchorDate != nil {
                anchoredPresetChips
                    .padding(.top, 2)
            } else {
                Text("没有具体时间时，设置一个提醒时刻")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding(.top, 2)
            }

            reminderList

            addReminderButton
        }
    }

    /// 锚定预设 chips：选中态与已设条目按时刻联动；落在过去的档位置灰不可点
    private var anchoredPresetChips: some View {
        FlowLayout(spacing: HoloSpacing.sm) {
            ForEach(Array(Self.anchoredPresets.enumerated()), id: \.offset) { _, preset in
                if let date = presetDate(preset) {
                    presetChipButton(
                        label: preset.label,
                        isSelected: hasAbsoluteReminder(at: date),
                        isDisabled: date < Date()
                    ) {
                        togglePreset(date)
                    }
                }
            }
        }
    }

    private func presetChipButton(
        label: String,
        isSelected: Bool,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(label)
                .font(.holoCaption)
                .foregroundColor(isSelected ? .white : .holoTextPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.holoPrimary : Color.holoTextSecondary.opacity(0.15))
                )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.35 : 1)
    }

    // MARK: - 非档位条目列表（两种模式同构）

    /// 列表只放 chips 表达不了的条目：绝对模式 = 非档位时刻的自定义提醒 + 相对残留；
    /// 相对模式 = 绝对提醒 + 非预设提前量。绝对项在前按时刻升序，相对项在后按提前量从远到近。
    private var visibleReminders: [TaskReminder] {
        let presetKeys = presetDateKeys
        let absolute = reminders
            .filter { reminder in
                guard reminder.isAbsolute, let date = reminder.triggerDate else { return false }
                return !presetKeys.contains(Self.minuteKey(date))
            }
            .sorted { ($0.triggerDate ?? .distantFuture) < ($1.triggerDate ?? .distantFuture) }
        let relative = reminders
            .filter { !$0.isAbsolute }
            .filter { reminder in
                mode == .absolute
                    || !TaskReminder.presetOptions.contains(where: { $0.offsetMinutes == reminder.offsetMinutes })
            }
            .sorted { $0.offsetMinutes > $1.offsetMinutes }
        return absolute + relative
    }

    private var reminderList: some View {
        VStack(spacing: 8) {
            ForEach(visibleReminders, id: \.id) { reminder in
                if case .editing(let editingId, let originalDate) = draft, editingId == reminder.id {
                    draftRow(originalDate: originalDate, editingId: editingId)
                } else {
                    reminderRow(reminder)
                }
            }
            if case .adding = draft {
                draftRow(originalDate: nil, editingId: nil)
            }
        }
    }

    /// 条目行：⏰ + 时刻 + 类型小标签 + ✕ 删除；点行进入编辑草稿行（绝对项专属）
    private func reminderRow(_ reminder: TaskReminder) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "alarm")
                .font(.system(size: 14))
                .foregroundColor(.holoPrimary)

            Button {
                guard let date = reminder.triggerDate else { return }
                draftDate = date
                draft = .editing(id: reminder.id, originalDate: date)
            } label: {
                HStack(spacing: 6) {
                    Text(reminder.displayTitle)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Text(reminder.isAbsolute ? String(localized: "自定义") : String(localized: "截止前"))
                        .font(.holoTinyLabel)
                        .foregroundColor(.holoTextSecondary)
                }
                // contentShape 必须在 label 内：挂在外层会让整行点击识别失效（真机实锤坑）
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!reminder.isAbsolute)

            Spacer()

            Button {
                if case .editing(let editingId, _) = draft, editingId == reminder.id {
                    draft = nil
                }
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

    // MARK: - 草稿行（添加 / 编辑共用，行级确认制）

    /// 草稿行不是条目：不点「添加/完成」永远不进列表、不占角标数；
    /// 点「取消」或关闭所在弹窗，什么都不留下。滚轮绑本地草稿值，确认前不写穿。
    private func draftRow(originalDate: Date?, editingId: UUID?) -> some View {
        let taken = isDateTaken(draftDate, excluding: editingId)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(originalDate == nil ? String(localized: "新提醒") : String(localized: "修改提醒"))
                    .font(.holoCaption)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoPrimary)

                Text(
                    originalDate == nil
                        ? draftReminderLabel(draftDate)
                        : String(format: String(localized: "原 %@"), draftReminderLabel(originalDate!))
                )
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)

                Spacer()

                Button(String(localized: "取消")) {
                    draft = nil
                }
                .foregroundColor(.holoTextSecondary)

                Button(originalDate == nil ? String(localized: "添加") : String(localized: "完成")) {
                    commitDraft()
                }
                .fontWeight(.semibold)
                .foregroundColor(.holoPrimary)
                .opacity(taken ? 0.35 : 1)
                .disabled(taken)
            }

            DatePicker(
                "",
                selection: $draftDate,
                displayedComponents: [.date, .hourAndMinute]
            )
            #if canImport(UIKit)
            .datePickerStyle(.wheel)
            #else
            .datePickerStyle(.automatic)
            #endif
            .labelsHidden()
            .environment(\.locale, Locale(identifier: "zh_CN"))

            if taken {
                Text("该时刻已有提醒")
                    .font(.holoTinyLabel)
                    .foregroundColor(Color(red: 255 / 255, green: 179 / 255, blue: 64 / 255))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color(red: 255 / 255, green: 179 / 255, blue: 64 / 255).opacity(0.12))
                    .cornerRadius(8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.holoPrimary.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.sm)
                .stroke(Color.holoPrimary, lineWidth: 2)
        )
    }

    private func draftReminderLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdHHmm")
        return formatter.string(from: date)
    }

    /// 确认草稿：添加/修改走同一入口，按时刻去重（编辑时排除自身）
    private func commitDraft() {
        switch draft {
        case .adding:
            guard !isDateTaken(draftDate, excluding: nil) else { return }
            reminders.insert(TaskReminder(triggerDate: draftDate))
        case .editing(let id, _):
            guard !isDateTaken(draftDate, excluding: id) else { return }
            if reminders.contains(where: { $0.id == id }) {
                reminders = reminders.filter { $0.id != id }
                reminders.insert(TaskReminder(id: id, triggerDate: draftDate))
            }
        case nil:
            break
        }
        draft = nil
    }

    /// 添加入口：草稿行展开期间变淡禁用（一次只有一个草稿行）
    private var addReminderButton: some View {
        Button {
            // 锚定任务日给默认时刻（09:00/当日最近整点）：
            // 「明天的任务」配「现在+1h」的提醒会响在任务日之前，属无效提醒
            draftDate = TaskPendingDefaults.defaultAbsoluteTrigger(anchorDate: anchorDate)
            draft = .adding
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                Text("添加自定义时刻")
                    .font(.holoBody)
            }
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .opacity(draft == nil ? 1 : 0.35)
        .disabled(draft != nil)
    }

    // MARK: - 预设档计算

    private func presetDate(_ preset: AnchoredPreset) -> Date? {
        guard let anchorDate else { return nil }
        return TaskPendingDefaults.anchoredPresetDate(
            anchorDate: anchorDate,
            dayOffset: preset.dayOffset,
            hour: preset.hour,
            minute: preset.minute
        )
    }

    /// 点绝对档位 chip：按时刻语义 toggle——有则删净（含历史重复条目），没有则加
    private func togglePreset(_ date: Date) {
        if hasAbsoluteReminder(at: date) {
            reminders = reminders.filter { reminder in
                !reminder.isAbsolute || Self.minuteKey(reminder.triggerDate!) != Self.minuteKey(date)
            }
        } else {
            reminders.insert(TaskReminder(triggerDate: date))
        }
    }

    /// 点相对档位 chip：按提前量语义 toggle——有则删净，没有则加预设实例
    private func togglePresetReminder(offsetMinutes: Int) {
        if hasRelativeReminder(matchingOffset: offsetMinutes) {
            reminders = reminders.filter { reminder in
                reminder.isAbsolute || reminder.offsetMinutes != offsetMinutes
            }
        } else if let preset = TaskReminder.presetOptions.first(where: { $0.offsetMinutes == offsetMinutes }) {
            reminders.insert(preset)
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
            #if canImport(UIKit)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
