//
//  TaskExperienceComponents.swift
//  Holo
//
//  任务首页 V2 的行组件与快捷编辑弹层（方案 §4.4/§4.5/§6.3）：
//  行内只保留完成按钮、标题、截止信息与清单、更多入口；不依赖滑动/长按发现关键动作。
//

import SwiftUI

// MARK: - 任务行

struct TaskExperienceRow: View {
    let member: TaskRecordSnapshot
    let calendar: Calendar
    let now: Date
    var isCompleting: Bool = false
    var isCompleted: Bool = false
    var isHistoryRow: Bool = false

    /// 是否已加入今日安排（菜单文案与动作状态化）
    var isInTodayPlan: Bool = false

    let onToggleCompletion: () -> Void
    let onOpenDetail: () -> Void
    let onClassify: () -> Void
    let onChangeDue: () -> Void
    let onPlanRange: () -> Void
    let onToggleToday: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    private var quadrant: TaskQuadrant {
        member.quadrant(now: now, calendar: calendar)
    }

    private var isOverdueRow: Bool {
        !member.completed && member.isOverdue(asOf: now, calendar: calendar)
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            // 完成按钮（独立，不触发详情）
            Button(action: onToggleCompletion) {
                Image(systemName: isCompleting || isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundColor(isCompleting || isCompleted ? .holoSuccess : .holoTextPlaceholder)
                    .frame(width: 32, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "完成\(member.title)"))

            // 行主体：点开详情
            Button(action: onOpenDetail) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        // 象限色点（辅助，文字才是主信息）
                        if !isHistoryRow {
                            Circle()
                                .fill(quadrant.tintColor)
                                .frame(width: 6, height: 6)
                        }
                        Text(member.title)
                            .font(.system(size: 17))
                            .foregroundColor(isCompleted ? .holoTextSecondary : .holoTextPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .strikethrough(isCompleted, color: .holoTextPlaceholder)
                    }

                    HStack(spacing: 8) {
                        // 历史·已完成：展示完成时间（缺失明示），不再显示截止
                        if isHistoryRow && isCompleted {
                            if let completedAt = member.completedAt {
                                Text(String(localized: "完成于 ") + Self.historyTimeFormatter.string(from: completedAt))
                            } else {
                                Text("完成时间未记录")
                            }
                        } else {
                            // 截止信息（今天/明天/后天自然语言；全天只显示自然日，§4.4）
                            dueText
                        }
                        Text("·")
                            .foregroundColor(.holoTextPlaceholder)
                        Text(listLabel)
                        // 紧急分徽章（2026-10-07）：待整理无分不显示；分数即组内次序
                        if !isHistoryRow, let score = member.urgencyScore(now: now, calendar: calendar) {
                            Spacer(minLength: 6)
                            Text("\(score)")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundColor(quadrant.tintColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1.5)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(quadrant.backgroundColor.opacity(0.8))
                                )
                                .fixedSize()
                                .accessibilityLabel(Text(String(localized: "紧急分 \(score)")))
                        }
                    }
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)

            // 更多入口（独立）
            rowMenu
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.vertical, 9)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        .opacity(isCompleting ? 0.55 : 1)
    }

    @ViewBuilder
    private var dueText: some View {
        if let due = member.effectiveDue(calendar: calendar) {
            if isOverdueRow {
                Text("\(Self.formatNatural(due, member: member, calendar: calendar)) · 已逾期")
                    .foregroundColor(.holoError)
            } else {
                Text(Self.formatNatural(due, member: member, calendar: calendar))
            }
        } else {
            Text("未设截止日期")
        }
    }

    private var listLabel: String {
        if member.listID == nil { return String(localized: "收件箱") }
        return member.listAvailable ? (member.listName ?? String(localized: "未归属清单")) : String(localized: "未归属清单")
    }

    private static let historyTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate("M月d日 HH:mm")
        return formatter
    }()

    /// 自然语言截止（今天/明天/后天；具体时刻附时间，§4.4）
    static func formatNatural(_ due: Date, member: TaskRecordSnapshot, calendar: Calendar) -> String {
        let base: String
        if calendar.isDateInToday(due) {
            base = String(localized: "今天")
        } else if calendar.isDateInTomorrow(due) {
            base = String(localized: "明天")
        } else if calendar.isDate(due, inSameDayAs: calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: Date())) ?? due) {
            base = String(localized: "后天")
        } else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.setLocalizedDateFormatFromTemplate("M月d日")
            base = formatter.string(from: due)
        }
        if member.isAllDay { return base }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "zh_CN")
        timeFormatter.dateFormat = "HH:mm"
        return base + " " + timeFormatter.string(from: due)
    }

    private var rowMenu: some View {
        Menu {
            Button(action: onClassify) {
                Label(String(localized: "调整轻重缓急"), systemImage: "square.grid.2x2")
            }
            Button(action: onChangeDue) {
                Label(String(localized: "修改截止日期"), systemImage: "calendar")
            }
            Button(action: onPlanRange) {
                Label(String(localized: member.hasValidPlannedRange ? "调整执行时段" : "安排执行时段"), systemImage: "clock")
            }
            Button(action: onToggleToday) {
                Label(
                    isInTodayPlan ? String(localized: "放下今日安排") : String(localized: "加入今日安排"),
                    systemImage: isInTodayPlan ? "moon.zzz" : "sun.max"
                )
            }
            Button(action: onArchive) {
                Label(String(localized: "归档"), systemImage: "archivebox")
            }
            Button(role: .destructive, action: onDelete) {
                Label(String(localized: "删除"), systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(String(localized: "更多操作"))
    }
}

// MARK: - 截止快捷编辑（不改分类/时段/今日，§3.3）

struct TaskDueQuickEditSheet: View {
    @ObservedObject var repository: TodoRepository
    let snapshot: TaskRecordSnapshot
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hasDue: Bool
    @State private var dueDate: Date
    @State private var isAllDay: Bool
    @State private var errorMessage: String?

    init(repository: TodoRepository, snapshot: TaskRecordSnapshot, onDone: @escaping () -> Void) {
        self.repository = repository
        self.snapshot = snapshot
        self.onDone = onDone
        _hasDue = State(initialValue: snapshot.dueDate != nil)
        _dueDate = State(initialValue: snapshot.dueDate ?? Date())
        _isAllDay = State(initialValue: snapshot.isAllDay)
    }

    var body: some View {
        NavigationStack {
            Form {
                Toggle(String(localized: "设置截止"), isOn: $hasDue)
                if hasDue {
                    Toggle(String(localized: "全天"), isOn: $isAllDay)
                    if isAllDay {
                        DatePicker(String(localized: "截止日期"), selection: $dueDate, displayedComponents: [.date])
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                    } else {
                        DatePicker(String(localized: "截止时间"), selection: $dueDate)
                            .environment(\.locale, Locale(identifier: "zh_CN"))
                    }
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.holoCaption)
                        .foregroundColor(.holoError)
                }
            }
            .navigationTitle(String(localized: "截止日期"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) { save() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let task = repository.findTask(by: snapshot.id) else {
            dismiss()
            return
        }
        do {
            try repository.updateTask(
                task,
                dueDate: hasDue ? .set(isAllDay ? TaskAnalyticsPeriod.makeCalendar().startOfDay(for: dueDate) : dueDate) : .clear,
                isAllDay: hasDue ? isAllDay : false
            )
            dismiss()
            onDone()
        } catch {
            errorMessage = String(localized: "保存失败，请重试")
        }
    }
}

// MARK: - 执行时段快捷编辑（成对保存或成对清空，§6.3）

struct TaskPlannedRangeQuickSheet: View {
    @ObservedObject var repository: TodoRepository
    let snapshot: TaskRecordSnapshot
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hasRange: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var errorMessage: String?

    init(repository: TodoRepository, snapshot: TaskRecordSnapshot, onDone: @escaping () -> Void) {
        self.repository = repository
        self.snapshot = snapshot
        self.onDone = onDone
        _hasRange = State(initialValue: snapshot.hasValidPlannedRange)
        _start = State(initialValue: snapshot.hasValidPlannedRange
            ? (repository.findTask(by: snapshot.id)?.plannedStart ?? Date())
            : Date())
        _end = State(initialValue: snapshot.hasValidPlannedRange
            ? (repository.findTask(by: snapshot.id)?.plannedEnd ?? Date().addingTimeInterval(3600))
            : Date().addingTimeInterval(3600))
    }

    private var isValid: Bool {
        !hasRange || TodoTask.isValidPlannedRange(start, end)
    }

    var body: some View {
        NavigationStack {
            Form {
                Toggle(String(localized: "安排执行时段"), isOn: $hasRange)
                if hasRange {
                    DatePicker(String(localized: "日期"), selection: $start, displayedComponents: [.date])
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    DatePicker(String(localized: "开始"), selection: $start, displayedComponents: [.hourAndMinute])
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                    DatePicker(String(localized: "结束"), selection: $end, displayedComponents: [.hourAndMinute])
                        .environment(\.locale, Locale(identifier: "zh_CN"))
                }
                // 非法时段在字段附近解释，不闪退（§6.3）
                if hasRange && !isValid {
                    Label(String(localized: "时段需要同一天且开始早于结束"), systemImage: "exclamationmark.triangle")
                        .font(.holoCaption)
                        .foregroundColor(.holoError)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.holoCaption)
                        .foregroundColor(.holoError)
                }
            }
            .navigationTitle(String(localized: "执行时段"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "保存")) { save() }
                        .disabled(!isValid)
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let task = repository.findTask(by: snapshot.id) else {
            dismiss()
            return
        }
        do {
            try repository.updateTask(
                task,
                plannedTime: hasRange ? .set(start: start, end: end) : .clear
            )
            dismiss()
            onDone()
        } catch {
            errorMessage = String(localized: "保存失败，请重试")
        }
    }
}

// MARK: - 搜索（全部未删除任务，含已完成和归档，§4.5）

struct TaskExperienceSearchView: View {
    @ObservedObject var model: TaskExperienceViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var keyword = ""

    private struct SearchItem: Identifiable {
        let snapshot: TaskRecordSnapshot
        var id: UUID { snapshot.id }
    }

    private var results: [TaskRecordSnapshot] {
        model.searchResults(keyword: keyword)
    }

    var body: some View {
        NavigationStack {
            Group {
                if keyword.trimmingCharacters(in: .whitespaces).isEmpty {
                    VStack(spacing: HoloSpacing.md) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 34, weight: .light))
                            .foregroundColor(.holoTextPlaceholder)
                        Text("搜索全部任务")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                        Text("包含已完成和归档任务")
                            .font(.holoCaption)
                            .foregroundColor(.holoTextPlaceholder)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if results.isEmpty {
                    // 零结果显示查询词与清除入口（§4.5）
                    VStack(spacing: HoloSpacing.md) {
                        Text("没有找到「\(keyword)」相关任务")
                            .font(.holoBody)
                            .foregroundColor(.holoTextSecondary)
                        Button(String(localized: "清除搜索")) {
                            keyword = ""
                        }
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(results) { snapshot in
                        searchRow(snapshot)
                    }
                }
            }
            .navigationTitle(String(localized: "搜索任务"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "取消")) { dismiss() }
                }
            }
        }
        .searchable(
            text: $keyword,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: String(localized: "标题、描述、清单名")
        )
        .holoEdgeSwipeBack { dismiss() }
    }

    @ViewBuilder
    private func searchRow(_ snapshot: TaskRecordSnapshot) -> some View {
        let task = repositoryTask(snapshot.id)
        if let task {
            Button {
                // 搜索不修改首页范围（§4.5）：直接进详情
                dismiss()
                Task { @MainActor in
                    NotificationCenter.default.post(
                        name: .taskExperienceOpenDetail,
                        object: task.id
                    )
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(snapshot.title)
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)
                            .lineLimit(2)
                            .strikethrough(snapshot.completed, color: .holoTextPlaceholder)
                        Spacer()
                        statusBadge(snapshot)
                    }
                    Text(statusDescription(snapshot))
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func repositoryTask(_ id: UUID) -> TodoTask? {
        model.repositoryTask(id)
    }

    @ViewBuilder
    private func statusBadge(_ snapshot: TaskRecordSnapshot) -> some View {
        if snapshot.archived {
            Text("已归档")
                .font(.holoTinyLabel)
                .foregroundColor(.holoTextSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.holoBorder))
        } else if snapshot.completed {
            Text("已完成")
                .font(.holoTinyLabel)
                .foregroundColor(.holoSuccess)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.holoSuccess.opacity(0.12)))
        } else {
            Text(snapshot.quadrant(now: Date(), calendar: model.calendar).displayTitle)
                .font(.holoTinyLabel)
                .foregroundColor(snapshot.quadrant(now: Date(), calendar: model.calendar).tintColor)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(snapshot.quadrant(now: Date(), calendar: model.calendar).backgroundColor))
        }
    }

    private func statusDescription(_ snapshot: TaskRecordSnapshot) -> String {
        var parts: [String] = []
        if let note = snapshot.note, !note.isEmpty {
            parts.append(String(note.prefix(30)))
        }
        parts.append(snapshot.listID == nil ? String(localized: "收件箱") : (snapshot.listName ?? String(localized: "未归属清单")))
        return parts.joined(separator: " · ")
    }
}
