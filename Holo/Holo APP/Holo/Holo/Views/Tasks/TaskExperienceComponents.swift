//
//  TaskExperienceComponents.swift
//  Holo
//
//  任务首页 V2 的行组件与快捷编辑弹层（方案 §4.4/§4.5/§6.3）：
//  行内只保留完成按钮、标题、截止信息与清单、更多入口；不依赖滑动/长按发现关键动作。
//

import SwiftUI

// MARK: - 任务行

enum TaskExperienceRowLayout {
    static let horizontalInset: CGFloat = 14
    static let gap: CGFloat = 14
    static let actionSide: CGFloat = 44
    static let textInset: CGFloat = horizontalInset + actionSide + gap
}

struct TaskExperienceRow: View {
    let member: TaskRecordSnapshot
    let calendar: Calendar
    let now: Date
    var isCompleting: Bool = false
    var isCompleted: Bool = false
    var isHistoryRow: Bool = false

    /// 是否已加入今日安排（长按菜单文案与动作状态化）
    var isInTodayPlan: Bool = false

    let onToggleCompletion: () -> Void
    let onOpenDetail: () -> Void
    let onClassify: () -> Void
    let onChangeDue: () -> Void
    let onPlanRange: () -> Void
    let onToggleToday: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void
    let onToggleCheckItem: (CheckItemSnapshot) -> Void
    let onAddCheckItem: (String) -> Bool

    /// 展开态（点行就地展开子任务，无弹窗）；LazyVStack 里按行自身 id 保持
    @State private var isExpanded = false
    @State private var newStepTitle = ""
    @State private var stepSaveFailed = false
    @FocusState private var isNewStepFocused: Bool

    private var isOverdueRow: Bool {
        !member.completed && member.isOverdue(asOf: now, calendar: calendar)
    }

    private var showsChevron: Bool {
        !member.checkItems.isEmpty
    }

    var body: some View {
        HStack(alignment: .top, spacing: TaskExperienceRowLayout.gap) {
            // 进度环：点=完成/撤回整卡；弧=子任务进度（无子任务是细空环）
            Button(action: onToggleCompletion) {
                progressRing.frame(width: TaskExperienceRowLayout.actionSide, height: TaskExperienceRowLayout.actionSide, alignment: .top)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .accessibilityLabel(isCompleted ? String(localized: "取消完成\(member.title)") : String(localized: "完成\(member.title)"))
                .accessibilityIdentifier("task.completion.\(member.id.uuidString)")
                .accessibilityValue(Text(isCompleting ? "等待完成" : (isCompleted ? "已完成" : "未完成")))

            // 标题负责展开，子任务和输入框独立，避免 Button 内嵌 Button 吞掉操作。
            VStack(alignment: .leading, spacing: HoloSpacing.xs) {
                Button {
                    guard !member.checkItems.isEmpty else {
                        onOpenDetail()
                        return
                    }
                    withAnimation(HoloAnimation.snappy) { isExpanded.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(member.title)
                            .holoText(.body)
                            .fontWeight(.semibold)
                            .foregroundColor(isCompleted ? .holoToolTextSecondary : .holoTextPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .strikethrough(isCompleted, color: .holoTextPlaceholder)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        // 唯一辅助信息：历史行报完成时间；进行中报截止（今天橙/逾期红）
                        if let auxiliary = auxiliaryText {
                            Text(auxiliary.text)
                                .holoText(.metadata)
                                .foregroundColor(auxiliary.color)
                        }

                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("task.row.\(member.id.uuidString)")
                if isExpanded { expandedContent }
            }

            if showsChevron {
                // 展开箭头是真按钮（真机实报「点不动」：初版只当装饰画，点了没反应）
                Button {
                    withAnimation(HoloAnimation.snappy) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isExpanded ? .holoToolTextSecondary : .holoTextPlaceholder)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? String(localized: "收起子任务") : String(localized: "展开子任务"))
            }
        }
        .padding(.horizontal, TaskExperienceRowLayout.horizontalInset)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .contextMenu { rowActions }
        .opacity(isCompleting ? 0.55 : 1)
    }

    // MARK: 进度环（「还有 N 步」的图形化继任者）

    private var progressRing: some View {
        let items = member.checkItems
        let fraction = items.isEmpty ? 0 : Double(items.filter(\.isChecked).count) / Double(items.count)
        return ZStack {
            Circle()
                .stroke(Color.holoToolTextSecondary.opacity(0.24), lineWidth: 1.2)
            if !items.isEmpty {
                // 至少留一粒起点弧：0 完成也能看出「这行有进度系统」
                Circle()
                    .trim(from: 0, to: max(fraction, 0.05))
                    .stroke(Color.holoTextPrimary,
                            style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(HoloAnimation.snappy, value: fraction)
            }
            if isCompleting || isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.holoTextPrimary)
            }
        }
        .frame(width: 26, height: 26)
        .padding(.top, 1)
        .contentShape(Circle())
    }

    // MARK: 展开态：子任务就地勾选 + 加一步 + 注脚

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(member.checkItems) { item in
                Button {
                    onToggleCheckItem(item)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle()
                                .strokeBorder(item.isChecked ? Color.holoToolTextSecondary : Color.holoTextPlaceholder,
                                              lineWidth: 1.5)
                                .frame(width: 17, height: 17)
                            if item.isChecked {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.holoBackground)
                            }
                        }
                        .frame(width: 17, height: 17)
                        .padding(.top, 1.5)
                        Text(item.title)
                            .holoText(.supporting)
                            .foregroundColor(item.isChecked ? .holoTextPlaceholder : .holoToolTextSecondary)
                            .strikethrough(item.isChecked, color: .holoTextPlaceholder)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("task.step.\(item.id.uuidString)")
                .accessibilityValue(Text(item.isChecked ? "已完成" : "未完成"))
            }

            // 加一步（行内输入，回车落库）
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.holoTextPlaceholder)
                TextField(String(localized: "加一步，回车保存"), text: $newStepTitle)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                    .focused($isNewStepFocused)
                    .submitLabel(.done)
                    .onSubmit(commitNewStep)
            }
            .padding(.top, 4)
            if stepSaveFailed {
                HoloInlineState(kind: .failure, message: String(localized: "这一步未保存，内容已保留，请重试。"),
                                actionTitle: String(localized: "重试"), action: commitNewStep)
            }

            // 注脚：清单名（收起态不上屏，展开态才出现）+ 详情入口
            HStack(spacing: 6) {
                Text(verbatim: String(localized: "清单：\(Self.listLabel(for: member))"))
                Text(verbatim: "·")
                Button(String(localized: "详情 ›")) { onOpenDetail() }
            }
            .font(.system(size: 11.5))
            .foregroundColor(.holoTextPlaceholder)
            .padding(.top, 8)
        }
        .padding(.top, 6)
    }

    private func commitNewStep() {
        let trimmed = newStepTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if onAddCheckItem(trimmed) {
            newStepTitle = ""
            stepSaveFailed = false
        } else {
            stepSaveFailed = true
        }
    }

    // MARK: 唯一辅助信息

    private var auxiliaryText: (text: String, color: Color)? {
        if isHistoryRow {
            if let completedAt = member.completedAt {
                return (String(localized: "完成于 ") + Self.historyTimeFormatter.string(from: completedAt),
                        .holoToolTextSecondary)
            }
            return nil
        }
        guard let due = member.effectiveDue(calendar: calendar) else { return nil }
        let natural = Self.formatNatural(due, member: member, calendar: calendar)
        if isOverdueRow {
            return (natural + String(localized: " · 已逾期"), .holoToolError)
        }
        if calendar.isDateInToday(due) {
            return (natural, .holoPrimary)
        }
        return (natural, .holoToolTextSecondary)
    }

    /// 清单名（展开态注脚显示）
    static func listLabel(for member: TaskRecordSnapshot) -> String {
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

    // MARK: 长按菜单（原「⋯」的继任者：低频操作收进长按，不占常驻视觉）

    @ViewBuilder
    private var rowActions: some View {
        Button {
            onOpenDetail()
        } label: {
            Label(String(localized: "打开详情"), systemImage: "doc.text")
        }
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
                            .foregroundColor(.holoToolTextSecondary)
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
                            .foregroundColor(.holoToolTextSecondary)
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
                        .foregroundColor(.holoToolTextSecondary)
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
                .foregroundColor(.holoToolTextSecondary)
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
