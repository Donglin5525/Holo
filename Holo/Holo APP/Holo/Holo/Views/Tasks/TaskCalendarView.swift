//
//  TaskCalendarView.swift
//  Holo
//
//  日历容器（多视图方案 §5.1）：年月导航 + 月览/日程二级切换 + 月格/周条 +
//  计数说明 + 待安排 + 逾期入口 + 选中日明细（月览）或 24 小时时间轴（日程）。
//  不自行取库：成员与投影全部来自 TaskExperienceViewModel 的同一份快照派生。
//

import SwiftUI

struct TaskCalendarView: View {

    @ObservedObject var model: TaskExperienceViewModel
    @ObservedObject var session: TaskPresentationSession
    let repository: TodoRepository
    let actions: TaskRowActionHandlers
    let onOpenDetail: (UUID) -> Void
    let onCreateForSelectedDay: () -> Void
    let onCreateAtHour: (Int) -> Void
    /// 外层页面滚动代理（进入日程首滚定位，§5.2-4）
    var scrollProxy: ScrollViewProxy? = nil

    @State private var showUnplannedSheet = false
    @State private var showOverdueSheet = false
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

    private var calendar: Calendar { model.calendar }

    /// 日历投影成员（显示已完成变体）
    private var members: [TaskRecordSnapshot] {
        model.calendarMembers(showsCompleted: session.calendarShowsCompleted)
    }

    var body: some View {
        VStack(spacing: 0) {
            calendarHead
            modeSwitch
            if session.calendarMode == .month {
                monthSection
            } else {
                weekSection
            }
            unplannedTray
            overdueEntry
            if session.calendarMode == .month {
                agendaSection
            } else {
                daySection
            }
        }
        .sheet(isPresented: $showUnplannedSheet) {
            TaskPresentationListSheet(
                title: String(localized: "待安排 · \(monthDayText(session.selectedDay))"),
                members: TaskCalendarProjection.unplannedMembers(from: model.activeMembers, now: model.now, calendar: calendar),
                model: model,
                actions: actions,
                onUndoCompletion: {
                    completionCoordinator.undo(in: repository)
                    HapticManager.light()
                },
                footnote: String(localized: "没有计划时段的任务，包括已设截止的任务。选择任务后可安排到当前选中日。")
            )
        }
        .sheet(isPresented: $showOverdueSheet) {
            TaskPresentationListSheet(
                title: String(localized: "逾期任务"),
                members: TaskCalendarProjection.overdueMembers(from: model.activeMembers, asOf: model.now, calendar: calendar),
                model: model,
                actions: actions,
                onUndoCompletion: {
                    completionCoordinator.undo(in: repository)
                    HapticManager.light()
                },
                footnote: String(localized: "当前范围内已过截止时间的任务，与选中日期无关。")
            )
        }
        .onChange(of: session.calendarMode) { _, newMode in
            guard newMode == .day else { return }
            scrollToDayStart()
        }
    }

    // MARK: - 年月导航

    private var calendarHead: some View {
        HStack {
            Text(yearMonthText)
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(.holoTextPrimary)
            Spacer()
            HStack(spacing: 2) {
                Button {
                    navigateBackward()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(navigationBackwardLabel)

                Button {
                    session.goToday()
                } label: {
                    Text("今天")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .padding(.horizontal, 8)
                        .frame(minHeight: 44)
                        .background(
                            Capsule().strokeBorder(Color.holoBorder, lineWidth: 1)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)

                Button {
                    navigateForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(navigationForwardLabel)
            }
        }
        .padding(.top, HoloSpacing.xs)
    }

    private func navigateBackward() {
        if session.calendarMode == .day {
            session.shiftWeek(direction: -1)
        } else {
            session.shiftMonth(direction: -1)
        }
    }

    private func navigateForward() {
        if session.calendarMode == .day {
            session.shiftWeek(direction: 1)
        } else {
            session.shiftMonth(direction: 1)
        }
    }

    private var navigationBackwardLabel: String {
        session.calendarMode == .day ? String(localized: "上一周") : String(localized: "上一月")
    }

    private var navigationForwardLabel: String {
        session.calendarMode == .day ? String(localized: "下一周") : String(localized: "下一月")
    }

    private var yearMonthText: String {
        let components = calendar.dateComponents([.year, .month], from: session.displayedMonth)
        return String(format: "%d年%d月", components.year ?? 0, components.month ?? 0)
    }

    // MARK: - 月览/日程二级切换（§9.2：无第二个橙胶囊）

    private var modeSwitch: some View {
        HStack(spacing: 24) {
            modeButton(String(localized: "月览"), mode: .month)
            modeButton(String(localized: "日程"), mode: .day)
            Spacer()
        }
        .padding(.bottom, 2)
    }

    private func modeButton(_ title: String, mode: TaskCalendarMode) -> some View {
        let isSelected = session.calendarMode == mode
        return Button {
            session.calendarMode = mode
        } label: {
            Text(title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)
                .frame(minHeight: 44, alignment: .bottom)
                .overlay(alignment: .bottom) {
                    if isSelected {
                        Capsule()
                            .fill(Color.holoTextPrimary)
                            .frame(height: 2)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - 月览

    private var monthGridDays: [Date] {
        TaskCalendarGridModel.monthGridDays(anchor: session.displayedMonth, calendar: calendar)
    }

    private var monthDayCounts: [Date: Int] {
        // 网格含邻月补齐日：把投影也按整网格一次索引（P01：不逐格全量扫描）
        let allDays = monthGridDays + TaskCalendarGridModel.weekDays(around: session.selectedDay, calendar: calendar)
        return TaskCalendarProjection.dayCounts(days: allDays, members: members, calendar: calendar)
    }

    private var monthSection: some View {
        VStack(spacing: 0) {
            TaskCalendarMonthGrid(
                monthAnchor: session.displayedMonth,
                selectedDay: session.selectedDay,
                today: model.now,
                calendar: calendar,
                dayCounts: monthDayCounts,
                onSelectDay: { session.selectDay($0) }
            )
            HStack {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.holoTextSecondary)
                        .frame(width: 5, height: 5)
                    Text("数字为当天任务数（去重）")
                }
                Spacer()
                Text("计划 / 截止均计入")
            }
            .font(.system(size: 11))
            .foregroundColor(.holoTextSecondary)
            .padding(.vertical, 10)
        }
        // 左右轻扫月份＝箭头等价操作（§5.1-10；非唯一入口）
        .simultaneousGesture(
            DragGesture(minimumDistance: 60)
                .onEnded { value in
                    let dx = value.translation.width
                    let dy = value.translation.height
                    guard abs(dx) > 70, abs(dx) > abs(dy) * 2 else { return }
                    session.shiftMonth(direction: dx < 0 ? 1 : -1)
                }
        )
    }

    // MARK: - 日程（周条）

    private var weekSection: some View {
        TaskCalendarWeekStrip(
            selectedDay: session.selectedDay,
            today: model.now,
            calendar: calendar,
            dayCounts: monthDayCounts,
            onSelectDay: { session.selectDay($0) }
        )
        .padding(.top, 4)
    }

    // MARK: - 待安排与逾期（§5.3）

    private var unplannedCount: Int {
        TaskCalendarProjection.unplannedMembers(from: model.activeMembers, now: model.now, calendar: calendar).count
    }

    private var unplannedTray: some View {
        Button {
            showUnplannedSheet = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.holoTextSecondary)
                Text("待安排")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                HoloCountBadge(count: unplannedCount)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.holoTextPlaceholder)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(minHeight: 48)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .accessibilityLabel(String(localized: "待安排，\(unplannedCount)项"))
    }

    private var overdueCount: Int {
        TaskCalendarProjection.overdueMembers(from: model.activeMembers, asOf: model.now, calendar: calendar).count
    }

    @ViewBuilder
    private var overdueEntry: some View {
        if overdueCount > 0 {
            Button {
                showOverdueSheet = true
            } label: {
                Text("查看当前范围逾期任务 \(overdueCount) 项")
                    .font(.system(size: 13))
                    .foregroundColor(.holoError)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                            .strokeBorder(Color.holoBorder, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    // MARK: - 选中日内容

    private var dayProjection: TaskCalendarProjection.DayProjection {
        TaskCalendarProjection.dayProjection(
            day: session.selectedDay,
            members: members,
            now: model.now,
            calendar: calendar
        )
    }

    private var agendaSection: some View {
        TaskDayAgendaView(
            projection: dayProjection,
            model: model,
            session: session,
            calendar: calendar,
            actions: actions,
            onCreateForSelectedDay: onCreateForSelectedDay,
            onOpenUnplanned: { showUnplannedSheet = true }
        )
    }

    private var daySection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(monthDayText(session.selectedDay))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.holoTextPrimary)
                Text(session.isTodaySelected ? String(localized: "今天") : "")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Text(daySummary)
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
            }
            .padding(.top, HoloSpacing.sm)
            .padding(.bottom, 2)

            if dayProjection.members.isEmpty {
                Text("这天还没有安排，点击时间轴空白处创建任务。")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous)
                            .strokeBorder(Color.holoDivider, lineWidth: 1)
                    )
                    .padding(.bottom, 8)
            }

            TaskDayTimelineView(
                projection: dayProjection,
                model: model,
                session: session,
                calendar: calendar,
                actions: actions,
                repository: repository,
                onOpenDetail: onOpenDetail,
                onCreateAtHour: onCreateAtHour
            )
        }
    }

    private var daySummary: String {
        let projection = dayProjection
        var parts = [String(format: "%d 项任务", projection.members.count)]
        if projection.occupiedMinutes > 0 {
            parts.append(String(localized: "已占用 \(TaskDayAgendaView.formatMinutes(projection.occupiedMinutes))"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 进入日程首滚（§5.2-4）

    /// 最早计划开始前一小时；无安排滚到 08:00
    private func scrollToDayStart() {
        guard let proxy = scrollProxy else { return }
        let planned = dayProjection.plannedMembers
        let targetHour: Int
        if let earliest = planned.compactMap(\.plannedStart).min() {
            targetHour = max(0, calendar.component(.hour, from: earliest) - 1)
        } else {
            targetHour = 8
        }
        DispatchQueue.main.async {
            withAnimation {
                proxy.scrollTo("hour-\(targetHour)", anchor: .top)
            }
        }
    }

    private func monthDayText(_ day: Date) -> String {
        let components = calendar.dateComponents([.month, .day], from: day)
        return String(format: "%d月%d日", components.month ?? 0, components.day ?? 0)
    }
}
