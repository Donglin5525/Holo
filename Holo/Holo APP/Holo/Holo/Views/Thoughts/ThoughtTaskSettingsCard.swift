//
//  ThoughtTaskSettingsCard.swift
//  Holo
//
//  想法转任务确认面板的「任务设置」批量设置卡：
//  截止日期/优先级/所属清单/提醒统一应用于本批全部任务；用户没碰过的字段各行保留 AI 预填值。
//

import SwiftUI

/// 批量设置状态。userTouched* 标记用户是否主动碰过对应字段——
/// 没碰过时各行用 AI 预填值；碰过后以统一值为准（覆盖所有行，行内徽章随之消失）。
struct ThoughtTaskBatchSettings {
    var userTouchedDate = false
    var hasDueDate = false
    var dueDate = Date()
    var isAllDay = true

    var userTouchedPriority = false
    var priority: TaskPriority = .medium

    var selectedList: TodoList?
    var reminders: Set<TaskReminder> = []

    func effectiveDueDate(for row: TaskCandidateRow) -> Date? {
        userTouchedDate ? (hasDueDate ? dueDate : nil) : row.aiDueDate
    }

    func effectiveIsAllDay(for row: TaskCandidateRow) -> Bool {
        userTouchedDate ? isAllDay : !row.aiDueDateHasTime
    }

    func effectivePriority(for row: TaskCandidateRow) -> TaskPriority {
        userTouchedPriority ? priority : (row.aiPriority ?? .medium)
    }
}

// MARK: - 设置卡

/// 批量设置卡：日期快速选项 + 优先级 + 清单 + 提醒
struct ThoughtTaskSettingsCard: View {

    @Binding var settings: ThoughtTaskBatchSettings

    /// 当前勾选的候选行，用于计算「AI 各行是否一致」的展示态
    let selectedRows: [TaskCandidateRow]

    @State private var showCustomDatePicker = false
    @State private var showListPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.md) {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.holoPrimary)
                Text("任务设置")
                    .font(.holoBody.bold())
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text("应用于本批全部任务")
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            dateSection
            prioritySection
            listRow

            ReminderPicker(selectedReminders: $settings.reminders, isEnabled: remindersEnabled)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
        .sheet(isPresented: $showCustomDatePicker) { customDatePicker }
        .sheet(isPresented: $showListPicker) { listPicker }
    }

    // MARK: 截止日期

    private var dateSection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("截止日期")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text(dateSummaryText)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            HStack(spacing: HoloSpacing.sm) {
                settingChip("不设置", isSelected: isChipActive(.none)) { clearDate() }
                settingChip("今天", isSelected: isChipActive(.today)) { pickQuickDate(0) }
                settingChip("明天", isSelected: isChipActive(.tomorrow)) { pickQuickDate(1) }
                settingChip("自选…", isSelected: isChipActive(.custom)) {
                    showCustomDatePicker = true
                }
            }
        }
    }

    private enum DateChipState { case none, today, tomorrow, custom }

    /// 快速选项的高亮反映「本批任务最终生效的日期」：统一无日期→不设置；
    /// 统一为今天/明天→对应项；统一为其他日期→自选。
    private func isChipActive(_ state: DateChipState) -> Bool {
        switch effectiveDateUniformity {
        case .none: return state == .none
        case .uniform(let day):
            let calendar = Calendar.current
            if calendar.isDateInToday(day) { return state == .today }
            if calendar.isDateInTomorrow(day) { return state == .tomorrow }
            return state == .custom
        case .mixed: return false
        }
    }

    private enum DateUniformity { case none, uniform(Date), mixed }

    /// 勾选行的最终生效日期是否一致（按天比较；无日期与有日期混处算不一致）
    private var effectiveDateUniformity: DateUniformity {
        let calendar = Calendar.current
        var sawEmpty = false
        var sawDay: Date?
        for row in selectedRows {
            guard let date = settings.effectiveDueDate(for: row) else {
                sawEmpty = true
                continue
            }
            let day = calendar.startOfDay(for: date)
            if let existing = sawDay, existing != day {
                return .mixed
            }
            sawDay = day
        }
        if sawEmpty {
            return sawDay == nil ? .none : .mixed
        }
        return sawDay.map { .uniform($0) } ?? .none
    }

    private var dateSummaryText: String {
        if settings.userTouchedDate {
            return settings.hasDueDate
                ? Self.summaryDateLabel(settings.dueDate, isAllDay: settings.isAllDay)
                : "不设置"
        }
        switch effectiveDateUniformity {
        case .none: return "不设置"
        case .uniform(let day): return Self.summaryDateLabel(day, isAllDay: true)
        case .mixed: return "各任务不同"
        }
    }

    static func summaryDateLabel(_ date: Date, isAllDay: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = isAllDay ? "M月d日 EEE" : "M月d日 EEE HH:mm"
        return formatter.string(from: date)
    }

    private func clearDate() {
        settings.userTouchedDate = true
        settings.hasDueDate = false
        // 相对提醒依赖截止日期，随日期一起清掉
        settings.reminders = []
    }

    private func pickQuickDate(_ daysFromNow: Int) {
        let calendar = Calendar.current
        let target = calendar.date(byAdding: .day, value: daysFromNow, to: Date()) ?? Date()
        var components = calendar.dateComponents([.year, .month, .day], from: target)
        if settings.hasDueDate, !settings.isAllDay {
            let time = calendar.dateComponents([.hour, .minute], from: settings.dueDate)
            components.hour = time.hour
            components.minute = time.minute
        }
        settings.dueDate = calendar.date(from: components) ?? target
        settings.hasDueDate = true
        settings.userTouchedDate = true
    }

    private var customDatePicker: some View {
        ThoughtTaskCustomDatePickerSheet(
            dueDate: settings.dueDate,
            isAllDay: settings.isAllDay,
            onCancel: { showCustomDatePicker = false },
            onConfirm: { date, allDay in
                settings.dueDate = date
                settings.isAllDay = allDay
                settings.hasDueDate = true
                settings.userTouchedDate = true
                showCustomDatePicker = false
            }
        )
    }

    // MARK: 优先级

    private var prioritySection: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("优先级")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text(prioritySummaryText)
                    .font(.holoTinyLabel)
                    .foregroundColor(.holoTextSecondary)
            }

            HStack(spacing: HoloSpacing.sm) {
                ForEach(TaskPriority.allCasesSorted, id: \.self) { priority in
                    settingChip(
                        priority.displayTitle,
                        tint: priority.color,
                        isSelected: effectivePriorityUniformity == priority
                    ) {
                        settings.userTouchedPriority = true
                        settings.priority = priority
                    }
                }
            }
        }
    }

    /// 勾选行的最终生效优先级是否一致（nil = 不一致；无勾选行时按默认「中」展示）
    private var effectivePriorityUniformity: TaskPriority? {
        guard let first = selectedRows.first else { return .medium }
        let value = settings.effectivePriority(for: first)
        return selectedRows.allSatisfy { settings.effectivePriority(for: $0) == value } ? value : nil
    }

    private var prioritySummaryText: String {
        if settings.userTouchedPriority {
            return settings.priority.displayTitle
        }
        return effectivePriorityUniformity?.displayTitle ?? "各任务不同"
    }

    // MARK: 所属清单

    private var listRow: some View {
        Button {
            showListPicker = true
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Text("所属清单")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                Text(settings.selectedList?.name ?? "不设置")
                    .font(.holoBody)
                    .foregroundColor(settings.selectedList == nil ? .holoTextSecondary : .holoTextPrimary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var listPicker: some View {
        ThoughtTaskListPickerSheet(selectedList: settings.selectedList) { list in
            settings.selectedList = list
            showListPicker = false
        }
    }

    // MARK: 提醒

    /// 相对提醒锚定在截止日期上：用户统一设置了日期时以卡片为准；
    /// 未碰过时只要任一勾选行有 AI 日期即可用（各行提醒只挂在有日期的任务上）
    private var remindersEnabled: Bool {
        settings.userTouchedDate
            ? settings.hasDueDate
            : selectedRows.contains { $0.aiDueDate != nil }
    }

    // MARK: 通用

    private func settingChip(
        _ title: String,
        tint: Color = .holoPrimary,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.holoCaption)
                .foregroundColor(isSelected ? .white : tint)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(isSelected ? tint : tint.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 自选日期弹层

/// 自选日期：日历 + 全天/定时 + 具体时间；草稿式编辑，确定后才提交
private struct ThoughtTaskCustomDatePickerSheet: View {

    @State private var draftDate: Date
    @State private var draftIsAllDay: Bool

    let onCancel: () -> Void
    let onConfirm: (Date, Bool) -> Void

    init(dueDate: Date, isAllDay: Bool, onCancel: @escaping () -> Void, onConfirm: @escaping (Date, Bool) -> Void) {
        _draftDate = State(initialValue: dueDate)
        _draftIsAllDay = State(initialValue: isAllDay)
        self.onCancel = onCancel
        self.onConfirm = onConfirm
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.md) {
                    VStack(spacing: HoloSpacing.sm) {
                        DatePicker(
                            "",
                            selection: $draftDate,
                            displayedComponents: .date
                        )
                        .datePickerStyle(.graphical)
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                        .labelsHidden()
                    }
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

                    VStack(spacing: 0) {
                        HStack {
                            Text("全天")
                                .font(.holoBody)
                                .foregroundColor(.holoTextPrimary)
                            Spacer()
                            Toggle("", isOn: $draftIsAllDay)
                                .labelsHidden()
                                .tint(.holoPrimary)
                        }
                        .frame(minHeight: 44)

                        if !draftIsAllDay {
                            Divider()
                                .padding(.vertical, HoloSpacing.xs)
                            HStack {
                                Text("具体时间")
                                    .font(.holoBody)
                                    .foregroundColor(.holoTextPrimary)
                                Spacer()
                                DatePicker("", selection: $draftDate, displayedComponents: .hourAndMinute)
                                    .datePickerStyle(.compact)
                                    .environment(\.locale, Locale(identifier: "zh_CN"))
                                    .labelsHidden()
                                    .tint(.holoPrimary)
                            }
                            .frame(minHeight: 44)
                        }
                    }
                    .padding(HoloSpacing.md)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.top, HoloSpacing.md)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("选择日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                        .foregroundColor(.holoTextSecondary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确定") {
                        onConfirm(draftDate, draftIsAllDay)
                    }
                    .foregroundColor(.holoPrimary)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - 清单选择弹层

/// 清单选择：不设置 + 全部有效清单（含未分组）
private struct ThoughtTaskListPickerSheet: View {

    let selectedList: TodoList?
    let onSelect: (TodoList?) -> Void

    private var allLists: [TodoList] {
        let repository = TodoRepository.shared
        var lists = repository.folders.flatMap { $0.listsArray }
        lists.insert(contentsOf: repository.unfiledLists, at: 0)
        return lists
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: HoloSpacing.xs) {
                    listRow(id: nil, name: "不设置")
                    ForEach(allLists, id: \.id) { list in
                        listRow(id: list.id, name: list.name)
                    }
                    if allLists.isEmpty {
                        Text("暂无清单，可先在任务模块创建")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .padding(.top, HoloSpacing.lg)
                    }
                }
                .padding(.horizontal, HoloSpacing.md)
                .padding(.top, HoloSpacing.md)
            }
            .background(Color.holoBackground.ignoresSafeArea())
            .navigationTitle("选择清单")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        onSelect(selectedList)
                    }
                    .foregroundColor(.holoPrimary)
                }
            }
            .onAppear {
                // 想法页可能从未打开过任务模块，进弹层时刷新一次清单数据
                TodoRepository.shared.loadFolders()
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func listRow(id: UUID?, name: String) -> some View {
        let isSelected = id == selectedList?.id
        return Button {
            onSelect(id == nil ? nil : allLists.first { $0.id == id })
        } label: {
            HStack {
                Text(name)
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoPrimary)
                }
            }
            .padding(HoloSpacing.md)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(isSelected ? Color.holoPrimary : Color.holoBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 候选行 AI 预填徽章

/// 候选行右侧的 AI 预填徽章（日期/优先级）；用户在设置卡统一覆盖后不再展示
struct ThoughtTaskAIBadge: View {

    let text: String
    var tint: Color = .holoPrimary

    var body: some View {
        Text(text)
            .font(.holoTinyLabel)
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.12)))
            .fixedSize()
    }
}

enum ThoughtTaskBadgeFormatter {

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    /// 徽章用的短日期文案：今天/明天/后天优先，其余 M月d日
    static func shortDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "今天" }
        if calendar.isDateInTomorrow(date) { return "明天" }
        if let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: Date()),
           calendar.isDate(date, inSameDayAs: dayAfterTomorrow) {
            return "后天"
        }
        return dayFormatter.string(from: date)
    }
}
