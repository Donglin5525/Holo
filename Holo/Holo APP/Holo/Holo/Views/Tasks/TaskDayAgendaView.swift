//
//  TaskDayAgendaView.swift
//  Holo
//
//  选中日明细（月览下方，多视图方案 §5.1-7/8/9）：日期标题 + 新增、
//  当天摘要（任务数 / 有时间安排 / 占用并集）、当天任务连续列表；
//  空态保留月历与标题，主入口「从待安排中选择」。
//

import SwiftUI

struct TaskDayAgendaView: View {

    let projection: TaskCalendarProjection.DayProjection
    @ObservedObject var model: TaskExperienceViewModel
    @ObservedObject var session: TaskPresentationSession
    let calendar: Calendar
    let actions: TaskRowActionHandlers
    let onCreateForSelectedDay: () -> Void
    let onOpenUnplanned: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.xs) {
            HStack {
                Text(dayTitle)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                Text(weekdayTitle)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Button {
                    onCreateForSelectedDay()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("新增")
                            .font(.system(size: 13))
                    }
                    .foregroundColor(.holoPrimary)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "在\(dayTitle)新增任务"))
            }
            .padding(.top, HoloSpacing.sm)

            Text(summaryText)
                .font(.system(size: 12))
                .foregroundColor(.holoTextSecondary)

            if projection.members.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(projection.members) { member in
                        row(member)
                        if member.id != projection.members.last?.id {
                            Rectangle()
                                .fill(Color.holoDivider.opacity(0.5))
                                .frame(height: 0.5)
                                .padding(.leading, TaskExperienceRowLayout.textInset)
                        }
                    }
                }
                .background(
                    RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            }
        }
    }

    private var dayTitle: String {
        let components = calendar.dateComponents([.month, .day], from: session.selectedDay)
        return String(format: "%d月%d日", components.month ?? 0, components.day ?? 0)
    }

    private var weekdayTitle: String {
        session.isTodaySelected ? String(localized: "今天") : weekdayName(session.selectedDay)
    }

    private func weekdayName(_ day: Date) -> String {
        let symbols = calendar.veryShortWeekdaySymbols
        return symbols[calendar.component(.weekday, from: day) - 1]
    }

    /// 「N 项任务 · M 项有时间安排 · 已占用 X小时Y分钟」（§5.1-7）
    private var summaryText: String {
        var parts = [String(format: "%d 项任务", projection.members.count)]
        parts.append(String(format: "%d 项有时间安排", projection.plannedMembers.count))
        if projection.occupiedMinutes > 0 {
            parts.append(String(localized: "已占用 \(Self.formatMinutes(projection.occupiedMinutes))"))
        }
        return parts.joined(separator: " · ")
    }

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.sm) {
            Text("这天还没有安排")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Button {
                onOpenUnplanned()
            } label: {
                Text("从待安排中选择")
                    .font(.holoCaption.weight(.semibold))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.holoPrimary.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, HoloSpacing.lg)
    }

    private func row(_ member: TaskRecordSnapshot) -> some View {
        TaskExperienceRow(
            member: member,
            calendar: model.calendar,
            now: model.now,
            isCompleting: model.pendingCompletionTaskID == member.id,
            isCompleted: member.completed,
            isInTodayPlan: model.todayEntryIDs.contains(member.id),
            onToggleCompletion: { actions.onToggleCompletion(member) },
            onOpenDetail: { actions.onOpenDetail(member) },
            onClassify: { actions.onClassify(member) },
            onChangeDue: { actions.onChangeDue(member) },
            onPlanRange: { actions.onPlanRange(member) },
            onToggleToday: { actions.onToggleToday(member) },
            onArchive: { actions.onArchive(member) },
            onDelete: { actions.onDelete(member) },
            onToggleCheckItem: { actions.onToggleCheckItem(member, $0) },
            onAddCheckItem: { actions.onAddCheckItem(member, $0) }
        )
        .id("task-\(member.id.uuidString)")
    }

    /// 分钟 → 「X小时Y分钟 / Y分钟」
    static func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let hours = minutes / 60
            let rest = minutes % 60
            return rest > 0
                ? String(format: "%d小时%d分钟", hours, rest)
                : String(format: "%d小时", hours)
        }
        return String(format: "%d分钟", minutes)
    }
}
