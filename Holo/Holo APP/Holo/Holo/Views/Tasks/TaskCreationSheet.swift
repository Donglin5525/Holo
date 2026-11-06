//
//  TaskCreationSheet.swift
//  Holo
//
//  新建任务弹层（2026-11-05 原型 task-quadrant-redesign 拍板重做）：
//  标题 + 重要性（重要/不重要）与紧急性（紧急/不紧急）两组分段 + 截止 chip + 主按钮。
//  分段默认全不选、可再点取消；任一未选 → 任务落待确认；
//  两组都选 → 主按钮「添加到「目标格名」」且底色跟随目标格深色，否则「添加」（绿）。
//  时间细节（提醒/重复）仍走 TaskDatePickerSheet；描述/清单等进详情再补。
//

import SwiftUI

struct TaskCreationSheet: View {

    @ObservedObject var repository: TodoRepository

    @Environment(\.dismiss) private var dismiss

    @StateObject private var draft: TaskCreationDraft

    // MARK: 时间（截止·全天·提醒·重复，与详情同一弹窗编辑）

    @State private var selectedReminders: Set<TaskReminder> = []
    @State private var hasRepeat = false
    @State private var repeatType: RepeatType = .daily
    @State private var selectedWeekdays: Set<Weekday> = []
    @State private var monthDay: Int = 1
    @State private var monthWeekOrdinal: Int = 1
    @State private var monthWeekday: Weekday? = nil
    @State private var monthlyRepeatMode: MonthlyRepeatMode = .dayOfMonth
    @State private var endConditionType: EndConditionType = .never
    @State private var repeatEndDate: Date? = nil
    @State private var repeatEndCount: Int = 10
    @State private var showTimeSheet = false

    @State private var showDismissConfirm = false
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    /// 首次保存已建成的任务：后续步骤（重复规则）失败重试时跳过重建，杜绝重复任务（R11）
    @State private var createdTask: TodoTask? = nil

    init(
        repository: TodoRepository,
        context: TaskCreationContext = TaskCreationContext()
    ) {
        self.repository = repository
        _draft = StateObject(wrappedValue: TaskCreationDraft(context: context))
    }

    /// 两轴都已判断（任一未选 → 落待确认）
    private var bothSelected: Bool {
        draft.importance != .unknown && draft.urgencyMode.isManual
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(TaskQuadrantPalette.dash)
                .frame(width: 40, height: 5)
                .padding(.top, 8)

            HStack(spacing: 8) {
                Text("新建任务")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(TaskQuadrantPalette.ink)
                Spacer()
                Button {
                    handleCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(TaskQuadrantPalette.inkSecondary)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(TaskQuadrantPalette.fill))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("关闭"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 6)
            .padding(.bottom, 10)

            TextField(String(localized: "要做点什么?"), text: Binding(
                get: { draft.title },
                set: { draft.title = $0; draft.markEdited() }
            ))
            .font(.system(size: 15))
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(TaskQuadrantPalette.fill)
            )
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .submitLabel(.done)
            .onSubmit(save)

            VStack(spacing: 6) {
                TaskCreationTwoWaySegment(
                    first: (String(localized: "重要"), TaskImportance.p1),
                    second: (String(localized: "不重要"), TaskImportance.p3),
                    selection: Binding(
                        get: { draft.importance == .p1 || draft.importance == .p3 ? draft.importance : nil },
                        set: { draft.importance = $0 ?? .unknown; draft.markEdited() }
                    )
                )
                TaskCreationTwoWaySegment(
                    first: (String(localized: "紧急"), TaskUrgencyMode.p1),
                    second: (String(localized: "不紧急"), TaskUrgencyMode.p3),
                    selection: Binding(
                        get: { draft.urgencyMode == .p1 || draft.urgencyMode == .p3 ? draft.urgencyMode : nil },
                        set: { draft.urgencyMode = $0 ?? .unknown; draft.markEdited() }
                    )
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Button {
                showTimeSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11))
                    Text(dueChipText)
                        .monospacedDigit()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11))
                }
                .font(.system(size: 11))
                .foregroundColor(TaskQuadrantPalette.inkSecondary)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(Capsule().fill(TaskQuadrantPalette.fill))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(dueChipText)

            Button {
                save()
            } label: {
                Text(primaryButtonTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(primaryButtonColor)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!draft.canSave || isSaving)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .accessibilityIdentifier("taskCreationSaveBar")
        }
        .padding(.bottom, 16)
        .background(Color.holoCardBackground)
        .presentationDetents([.height(372)])
        // 弹层背后全屏压暗（原型 scrim rgba(22,20,15,.25)）
        .presentationBackground(TaskQuadrantPalette.scrim(0.25))
        .sheet(isPresented: $showTimeSheet) {
            TaskDatePickerSheet(
                dueDate: $draft.dueDate,
                isAllDay: Binding(
                    get: { draft.dueIsAllDay },
                    set: { draft.dueIsAllDay = $0; draft.markEdited() }
                ),
                hasDueDate: Binding(
                    get: { draft.hasDueDate },
                    set: { draft.hasDueDate = $0; draft.markEdited() }
                ),
                selectedReminders: $selectedReminders,
                hasRepeat: $hasRepeat,
                repeatType: $repeatType,
                selectedWeekdays: $selectedWeekdays,
                monthDay: $monthDay,
                monthWeekOrdinal: $monthWeekOrdinal,
                monthWeekday: $monthWeekday,
                monthlyRepeatMode: $monthlyRepeatMode,
                endConditionType: $endConditionType,
                repeatEndDate: $repeatEndDate,
                repeatEndCount: $repeatEndCount
            )
        }
        .onChange(of: selectedReminders) { _, _ in
            draft.markEdited()
        }
        .onChange(of: hasRepeat) { _, _ in
            draft.markEdited()
        }
        .alert(String(localized: "未保存的修改"), isPresented: $showDismissConfirm) {
            Button(String(localized: "继续编辑"), role: .cancel) {}
            Button(String(localized: "放弃修改"), role: .destructive) { dismiss() }
        } message: {
            Text("已有输入的内容还没有保存，确定要关闭吗？")
        }
        .alert(
            String(localized: "没有保存成功"),
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { if !$0 { saveErrorMessage = nil } }
            )
        ) {
            Button(String(localized: "重试")) { save() }
            Button(String(localized: "知道了"), role: .cancel) {}
        } message: {
            Text(saveErrorMessage ?? String(localized: "请重试"))
        }
    }

    // MARK: - 分段与按钮状态

    private var dueChipText: String {
        guard draft.hasDueDate else { return String(localized: "截止:") + String(localized: "未设置") }
        return String(localized: "截止:") + TaskCreationSheet.formatDue(draft.dueDate, isAllDay: draft.dueIsAllDay)
    }

    private var primaryButtonTitle: String {
        guard bothSelected else { return String(localized: "添加") }
        return String(localized: "添加到「\(draft.previewQuadrant.displayTitle)」")
    }

    private var primaryButtonColor: Color {
        guard draft.canSave, !isSaving else { return Color.holoTextSecondary.opacity(0.3) }
        return bothSelected ? draft.previewQuadrant.tintColor : TaskQuadrantPalette.addGreen
    }

    // MARK: - 格式化

    static func formatDue(_ date: Date, isAllDay: Bool) -> String {
        let calendar = TaskAnalyticsPeriod.makeCalendar()
        if calendar.isDateInToday(date) {
            return isAllDay ? String(localized: "今天") : String(localized: "今天") + " " + Self.timeString(date)
        }
        if calendar.isDateInTomorrow(date) {
            return isAllDay ? String(localized: "明天") : String(localized: "明天") + " " + Self.timeString(date)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.setLocalizedDateFormatFromTemplate(isAllDay ? "M月d日" : "M月d日 HH:mm")
        return formatter.string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 动作

    private func handleCancel() {
        if draft.isBlank && selectedReminders.isEmpty && !hasRepeat {
            dismiss()
        } else {
            showDismissConfirm = true
        }
    }

    private func save() {
        guard let title = draft.submitTitle, draft.isPlannedRangeValid, !isSaving else { return }
        isSaving = true
        let quadrant = draft.previewQuadrant
        Task { @MainActor in
            do {
                // 主任务 + 计划时段同一次保存（原子，§7.2；重试续跑不重建，R11）
                let task: TodoTask
                if let createdTask {
                    task = createdTask
                } else {
                    task = try repository.createTask(
                        title: title,
                        description: nil,
                        list: draft.listID.flatMap { repository.findList(by: $0) },
                        importance: draft.importance,
                        urgencyMode: draft.urgencyMode,
                        dueDate: draft.hasDueDate ? draft.dueDate : nil,
                        isAllDay: draft.hasDueDate && draft.dueIsAllDay,
                        reminders: selectedReminders.isEmpty ? nil : selectedReminders,
                        checkItemTitles: nil,
                        plannedStart: draft.hasPlannedRange ? draft.plannedStart : nil,
                        plannedEnd: draft.hasPlannedRange ? draft.plannedEnd : nil
                    )
                    createdTask = task
                }

                // 重复规则（有截止日才有意义，与详情同一套规则创建）
                if hasRepeat && draft.hasDueDate {
                    _ = try repository.createRepeatRule(
                        type: repeatType,
                        for: task,
                        weekdays: repeatType == .custom ? Array(selectedWeekdays) : nil,
                        untilDate: endConditionType == .onDate ? repeatEndDate : nil
                    )
                    if repeatType == .monthly, let rule = task.repeatRule {
                        try repository.updateRepeatRuleMonthlyParams(
                            rule,
                            monthDay: monthlyRepeatMode == .dayOfMonth ? monthDay : nil,
                            monthWeekOrdinal: monthlyRepeatMode == .nthWeekday ? monthWeekOrdinal : nil,
                            monthWeekday: monthlyRepeatMode == .nthWeekday ? monthWeekday : nil,
                            untilCount: endConditionType == .afterCount ? repeatEndCount : nil
                        )
                    }
                }

                HapticManager.success()
                isSaving = false
                dismiss()
                // 统一创建回执：首页展开定位、容器切回任务页（底部+/统计页入口同样生效）
                NotificationCenter.default.post(
                    name: .taskExperienceCreated,
                    object: nil,
                    userInfo: ["id": task.id, "quadrant": quadrant]
                )
            } catch {
                // 失败保留草稿可重试；已建成的主任务在重试中续跑不重建（§5.4/R11）
                isSaving = false
                saveErrorMessage = String(localized: "没有保存成功，请重试")
            }
        }
    }
}

// MARK: - 二选一分段（默认全不选、可再点取消）

/// 两档分段（原型 tqp-seg）：轨道浅底 + 白色选中块；
/// 点选中项取消选择（selection 置 nil）。
private struct TaskCreationTwoWaySegment<T: Equatable>: View {
    let first: (title: String, value: T)
    let second: (title: String, value: T)
    @Binding var selection: T?

    var body: some View {
        HStack(spacing: 0) {
            segmentItem(title: first.title, value: first.value)
            segmentItem(title: second.title, value: second.value)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TaskQuadrantPalette.fill)
        )
    }

    private func segmentItem(title: String, value: T) -> some View {
        let isSelected = selection == value
        return Button {
            HapticManager.selection()
            // 再点取消：已选中 → 置空；未选中 → 选中
            selection = isSelected ? nil : value
        } label: {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? TaskQuadrantPalette.ink : TaskQuadrantPalette.inkSecondary)
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isSelected ? Color.holoCardBackground : Color.clear)
                        .shadow(color: isSelected ? Color.black.opacity(0.12) : .clear, radius: 2, y: 1)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
