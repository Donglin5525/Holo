//
//  TaskDetailPropertiesSection.swift
//  Holo
//
//  任务详情属性区（时间 / 时间段 / 清单 / 轻重缓急 / 象限 / 状态 / 目标）——
//  2026-10-24 随真机主线程栈溢出排险从 TaskDetailView 拆出（纯搬移，界面/行为零变化）。
//

import SwiftUI

struct TaskDetailPropertiesSection: View {

    let existingTask: TodoTask?
    let selectedListName: String
    @Binding var taskStatus: TaskStatus
    @Binding var showTimeSheet: Bool
    @Binding var showPostponeSheet: Bool
    @Binding var showPlannedRangeSheet: Bool
    @Binding var showListPicker: Bool
    @Binding var showClassificationSheet: Bool
    @Binding var showMoveToQuadrantSheet: Bool
    @Binding var showGoalPicker: Bool
    @Binding var dueDate: Date
    @Binding var hasDueDate: Bool
    @Binding var hasTime: Bool
    @Binding var hasRepeat: Bool
    @Binding var repeatType: RepeatType
    @Binding var selectedReminders: Set<TaskReminder>
    @Binding var hasPlannedRange: Bool
    @Binding var plannedStart: Date
    @Binding var plannedEnd: Date
    @Binding var classificationImportance: TaskImportance
    @Binding var classificationUrgencyMode: TaskUrgencyMode

    var body: some View {
        VStack(spacing: 0) {
            // 时间（日期/全天/提醒/重复合并在同一入口）+ 延期快捷入口
            HStack(spacing: 0) {
                Button {
                    showTimeSheet = true
                } label: {
                    HStack(spacing: HoloSpacing.sm) {
                        rowIcon("calendar")

                        Text("时间")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer(minLength: HoloSpacing.md)

                        Text(timeSummaryText)
                            .font(.holoCaption)
                            .foregroundColor(hasDueDate ? timeValueColor : .holoTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.trailing)

                        rowChevron
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

                // 延期：与时间行同层而非嵌套（避免按钮嵌按钮的误触）；有截止日期的非重复任务才出现
                if canPostponeExistingTask {
                    Button {
                        showPostponeSheet = true
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 11, weight: .semibold))
                            Text("延期")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundColor(.holoPrimaryDark)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.holoPrimary.opacity(0.12)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 12)
                }
            }

            Divider().padding(.horizontal, 12)

            // 计划时间段（时间块）：打算做事的时段，与「时间」（截止）语义分离
            Button {
                showPlannedRangeSheet = true
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    rowIcon("clock")

                    Text("时间段")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer(minLength: HoloSpacing.md)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text(plannedRangeSummaryText)
                            .font(.holoCaption)
                            .foregroundColor(hasPlannedRange ? .holoPrimary : .holoTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.trailing)

                        if let actualText {
                            Text(actualText)
                                .font(.system(size: 10))
                                .foregroundColor(.holoTextSecondary)
                        }
                    }

                    rowChevron
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Divider().padding(.horizontal, 12)

            // 清单
            Button {
                showListPicker = true
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    rowIcon("folder")

                    Text("清单")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer(minLength: HoloSpacing.md)

                    Text(selectedListName)
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.trailing)

                    rowChevron
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            Divider().padding(.horizontal, 12)

            // 轻重缓急（§6.2-2）：当前象限/待整理 + 判断方式；点击编辑两个维度
            Button {
                showClassificationSheet = true
            } label: {
                HStack(spacing: HoloSpacing.sm) {
                    rowIcon("square.grid.2x2")

                    Text("轻重缓急")
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)

                    Spacer(minLength: HoloSpacing.md)

                    Text(classificationSummaryText)
                        .font(.holoCaption)
                        .foregroundColor(classificationImportance == .unknown ? .holoTextSecondary : .holoPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .multilineTextAlignment(.trailing)

                    rowChevron
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .buttonStyle(.plain)

            // 移动到象限（多视图方案 §7/§6.3-10：非拖动的完整等价路径）
            if existingTask != nil {
                Divider().padding(.horizontal, 12)
                Button {
                    showMoveToQuadrantSheet = true
                } label: {
                    HStack(spacing: HoloSpacing.sm) {
                        rowIcon("arrow.up.and.down.and.sparkles")

                        Text("移动到象限")
                            .font(.holoBody)
                            .foregroundColor(.holoTextPrimary)

                        Spacer(minLength: HoloSpacing.md)

                        Text(currentQuadrantLabel)
                            .font(.holoCaption)
                            .foregroundColor(.holoTextSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .multilineTextAlignment(.trailing)

                        rowChevron
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }


            // 状态（编辑模式）
            if existingTask != nil {
                Divider().padding(.horizontal, 12)
                statusRow
            }

            // 目标归属（可改：弹单选目标 sheet，由 GoalRepository 落库）
            if existingTask != nil {
                Divider().padding(.horizontal, 12)
                goalRow
            }
        }
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.lg))
    }

    private var timeValueColor: Color {
        guard hasDueDate else { return .holoTextSecondary }
        if let task = existingTask, dueDate < Date(), !task.completed,
           !Calendar.current.isDateInToday(dueDate) {
            return .holoError
        }
        return Calendar.current.isDateInToday(dueDate) ? .holoPrimary : .holoTextPrimary
    }

    /// 移动到象限行摘要：当前实时解析格（未判断=待整理，多视图 §7）
    private var currentQuadrantLabel: String {
        let effectiveDue = TodoTaskDatePolicy.effectiveDueDate(
            dueDate: hasDueDate ? dueDate : nil,
            isAllDay: !hasTime
        )
        return TaskQuadrantResolver.quadrant(
            importance: classificationImportance,
            mode: classificationUrgencyMode,
            effectiveDue: effectiveDue,
            now: Date(),
            calendar: TaskAnalyticsPeriod.makeCalendar()
        ).displayTitle
    }

    /// 轻重缓急行摘要：P 档 · 紧急分 · 去向（未判断=待整理）（2026-10-07 紧急分体系）
    private var classificationSummaryText: String {        let effectiveDue = TodoTaskDatePolicy.effectiveDueDate(
            dueDate: hasDueDate ? dueDate : nil,
            isAllDay: !hasTime
        )
        let quadrant = TaskQuadrantResolver.quadrant(
            importance: classificationImportance,
            mode: classificationUrgencyMode,
            effectiveDue: effectiveDue,
            now: Date(),
            calendar: TaskAnalyticsPeriod.makeCalendar()
        )
        guard classificationImportance != .unknown else {
            return "\(quadrant.displayTitle) · \(String(localized: "未判断"))"
        }
        let score = TaskQuadrantResolver.urgencyScore(
            importance: classificationImportance,
            mode: classificationUrgencyMode,
            effectiveDue: effectiveDue,
            now: Date(),
            calendar: TaskAnalyticsPeriod.makeCalendar()
        ).map { "\($0)" } ?? "—"
        return "\(classificationImportance.displayTitle) · \(String(localized: "紧急分")) \(score) · \(quadrant.displayTitle)"
    }

    /// 时间段行右侧摘要：「今天 10:00–12:00」；非今明用「M/d」
    private var plannedRangeSummaryText: String {
        guard hasPlannedRange else { return String(localized: "未设置") }
        let calendar = Calendar.current
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "M/d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        let dayText = calendar.isDateInToday(plannedStart)
            ? String(localized: "今天")
            : (calendar.isDateInTomorrow(plannedStart) ? String(localized: "明天") : dayFormatter.string(from: plannedStart))
        return "\(dayText) \(timeFormatter.string(from: plannedStart))–\(timeFormatter.string(from: plannedEnd))"
    }

    /// 时间段行副行：实际 vs 计划对比（已记录实际用时时显示）
    private var actualText: String? {
        guard let actual = existingTask?.actualDurationMinutes?.intValue,
              let planned = existingTask?.plannedDurationMinutes else { return nil }
        let actualText = ActualDurationSheet.durationText(actual)
        let plannedText = ActualDurationSheet.durationText(planned)
        return actual == planned ? String(localized: "实际 \(actualText)") : String(localized: "实际 \(actualText)（计划 \(plannedText)）")
    }

    /// 延期入口条件：编辑模式 + 有截止日期 + 未完成 + 非重复（重复任务一期不接延期）。
    /// 显隐跟编辑态走：时间弹窗里关掉截止日期/打开重复后立即消失，不必等保存重进。
    private var canPostponeExistingTask: Bool {
        guard let task = existingTask else { return false }
        return TaskPostponePolicy.canPostpone(
            dueDate: hasDueDate ? dueDate : nil,
            completed: task.completed,
            repeatRuleExists: hasRepeat
        )
    }

    private var statusRow: some View {
        HStack(spacing: HoloSpacing.sm) {
            rowIcon(taskStatus.iconName)

            Text("状态")
                .font(.holoBody)
                .foregroundColor(.holoTextPrimary)

            Spacer()

            Menu {
                ForEach(TaskStatus.allCases, id: \.self) { status in
                    Button {
                        taskStatus = status
                    } label: {
                        HStack {
                            Text(status.displayTitle)
                            if taskStatus == status {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(taskStatus.color)
                        .frame(width: 8, height: 8)
                    Text(taskStatus.displayTitle)
                        .font(.holoBody)
                        .foregroundColor(.holoTextPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoTextSecondary)
                }
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var goalRow: some View {
        Button {
            showGoalPicker = true
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                rowIcon(existingTask?.goal?.goalDomain.icon ?? "target")

                Text("目标")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)

                Spacer(minLength: HoloSpacing.md)

                Text(existingTask?.goal?.title ?? String(localized: "无"))
                    .font(.holoCaption)
                    .foregroundColor(existingTask?.goal.map { $0.goalDomain.badgeColor } ?? .holoTextSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.trailing)

                rowChevron
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }

    private func rowIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundColor(.holoTextSecondary)
            .frame(width: 22)
    }

    private var rowChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.holoTextSecondary)
    }

    // MARK: - 时间摘要

    /// 是否全天（由 hasTime 反向推导）
    private var isAllDay: Bool { !hasTime }

    private var timeSummaryText: String {
        var parts: [String] = []
        if hasDueDate {
            parts.append(hasTime ? "\(formattedDueDateSummary) \(formattedTime)" : "\(formattedDueDateSummary)")
        }
        if !selectedReminders.isEmpty {
            let absoluteCount = selectedReminders.filter { $0.isAbsolute }.count
            if hasDueDate {
                parts.append(String(localized: "提醒\(selectedReminders.count)项"))
            } else {
                // 无截止日时，摘要直接展示绝对提醒时刻
                let reminder = selectedReminders.first(where: { $0.isAbsolute })
                if let reminder = reminder {
                    parts.append("⏰ \(reminder.displayTitle)")
                    if absoluteCount > 1 {
                        parts[parts.count - 1] += String(localized: " 等\(absoluteCount)项")
                    }
                }
            }
        }
        if hasRepeat {
            parts.append(String(localized: "重复\(repeatType.displayTitle)"))
        }
        return parts.isEmpty ? String(localized: "设置时间、提醒") : parts.joined(separator: " · ")
    }

    private var formattedDueDateSummary: String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("MMMdE")
        return formatter.string(from: dueDate)
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: dueDate)
    }
}
