//
//  TimelineReplayView.swift
//  Holo
//
//  记忆长廊「时间轴」档（三期）：0–24 纵向刻度，双泳道同轴回放
//  左泳道=带时间段的任务（含已完成，带计划/实际对比），右泳道=系统日程（按需拉取，不限活跃窗口）。
//  拖拽反写：空白处长按拖出选区直接建带时间段任务（15 分钟吸附）；拖任务块上下缘调整时间段。
//

import SwiftUI
import CoreData
import EventKit

struct TimelineReplayView: View {

    let focusedDate: Date

    // MARK: - 数据

    @State private var timedTasks: [TodoTask] = []
    @State private var schedules: [ScheduleItem] = []
    @State private var selectedSchedule: ScheduleItem?
    /// 拖拽建任务的选区（松手弹新建）
    @State private var newTaskDraft: PlannedRangeDraft?
    /// 边缘调整中的实时预览（taskId → 调整后范围）
    @State private var resizePreview: [UUID: (start: Date, end: Date)] = [:]

    struct PlannedRangeDraft: Identifiable {
        let id = UUID()
        let start: Date
        let end: Date
    }

    // MARK: - 布局常量

    /// 每小时像素高度（24h ≈ 1344pt，滚动查看）
    private static let hourHeight: CGFloat = 56
    /// 刻度列宽
    private static let gutterWidth: CGFloat = 46
    /// 手势吸附粒度（分钟）
    private static let snapMinutes: CGFloat = 15
    /// 新建选区的最小时长（分钟）
    private static let minimumDraftMinutes: CGFloat = 15

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        Group {
            if timedTasks.isEmpty && schedules.isEmpty {
                emptyState
            } else {
                timelineScroll
            }
        }
        .onAppear { loadData() }
        .onChange(of: focusedDate) { _, _ in loadData() }
        .sheet(item: $selectedSchedule) { item in
            ScheduleDetailSheet(item: item)
        }
        .sheet(item: $newTaskDraft) { draft in
            TaskDetailView(
                repository: TodoRepository.shared,
                list: nil,
                defaultDueDate: draft.start,
                prefilledPlannedRange: (start: draft.start, end: draft.end)
            )
        }
    }

    // MARK: - 数据加载（历史日程按需拉取）

    private func loadData() {
        let context = CoreDataStack.shared.viewContext
        let request = NSFetchRequest<TodoTask>(entityName: "TodoTask")
        let dayStart = calendar.startOfDay(for: focusedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        request.predicate = NSPredicate(
            format: "plannedStart != nil AND plannedStart >= %@ AND plannedStart < %@ AND deletedAt == nil AND archived == NO",
            dayStart as NSDate, dayEnd as NSDate
        )
        timedTasks = (try? context.fetch(request)) ?? []

        schedules = []
        let store = ScheduleStore.shared
        if store.isEnabled, store.authorizationStatus == .fullAccess {
            Task {
                let items = await store.fetchSchedules(onDay: focusedDate)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        schedules = items
                    }
                }
            }
        }
    }

    // MARK: - 空态

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.md) {
            Image(systemName: "chart.timeline.selection")
                .font(.system(size: 34))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text("这一天没有时间段记录")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Text("给任务设置时间段，或接入系统日历后，这里会铺出一天的时间流")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(HoloSpacing.xl)
        .onAppear { loadData() }
    }

    // MARK: - 时间轴主体

    private var timelineScroll: some View {
        ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                // 刻度列 + 横线
                hourGrid

                // 当前时刻线（仅今天）
                if calendar.isDateInToday(focusedDate) {
                    nowLine
                }

                // 左泳道：任务块
                GeometryReader { geometry in
                    let laneWidth = (geometry.size.width - Self.gutterWidth) / 2
                    ZStack(alignment: .topLeading) {
                        ForEach(timedTasks, id: \.id) { task in
                            taskBlock(task, laneWidth: laneWidth)
                                .frame(width: laneWidth - 6)
                                .position(
                                    x: Self.gutterWidth + (laneWidth - 6) / 2,
                                    y: y(for: effectiveStart(task)) + blockHeight(start: effectiveStart(task), end: effectiveEnd(task)) / 2
                                )
                        }

                        // 右泳道：日程块
                        ForEach(schedules.filter { !$0.isAllDay }) { item in
                            scheduleBlock(item, laneWidth: laneWidth)
                                .frame(width: laneWidth - 6)
                                .position(
                                    x: Self.gutterWidth + laneWidth + (laneWidth - 6) / 2,
                                    y: y(for: item.startDate) + blockHeight(start: item.startDate, end: item.endDate) / 2
                                )
                        }
                    }
                }
                .padding(.horizontal, 0)

                // 拖拽建任务选区
                if let draft = dragDraft {
                    selectionRect(draft)
                }
            }
            .frame(height: 24 * Self.hourHeight)
            .contentShape(Rectangle())
            .gesture(createTaskGesture)
        }
        .overlay(alignment: .top) {
            // 全天日程折叠条
            let allDay = schedules.filter(\.isAllDay)
            if !allDay.isEmpty {
                allDayBanner(allDay)
                    .padding(.horizontal, HoloSpacing.md)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - 刻度与时刻线

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.holoBorder.opacity(0.35))
                        .frame(height: 0.5)
                        .padding(.leading, Self.gutterWidth - 8)
                    Text(String(format: "%02d", hour))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.holoTextSecondary.opacity(0.65))
                        .frame(width: Self.gutterWidth - 14, alignment: .trailing)
                        .offset(y: -5)
                }
                .frame(height: Self.hourHeight)
            }
        }
    }

    @ViewBuilder
    private var nowLine: some View {
        let minutes = calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())
        let y = CGFloat(minutes) / 60 * Self.hourHeight
        HStack(spacing: 6) {
            Circle().fill(Color.holoError).frame(width: 6, height: 6)
            Rectangle().fill(Color.holoError.opacity(0.55)).frame(height: 1)
        }
        .padding(.leading, Self.gutterWidth - 10)
        .offset(y: y)
        .allowsHitTesting(false)
    }

    private func allDayBanner(_ items: [ScheduleItem]) -> some View {
        HStack(spacing: 6) {
            ForEach(items.prefix(3)) { item in
                HStack(spacing: 4) {
                    Circle().fill(item.calendarColor).frame(width: 7, height: 7)
                    Text(item.title)
                        .font(.system(size: 11))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.holoCardBackground.opacity(0.92)))
            }
            if items.count > 3 {
                Text("+\(items.count - 3)")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
            }
            Spacer()
        }
    }

    // MARK: - 任务块（左泳道，含边缘调整）

    private func effectiveStart(_ task: TodoTask) -> Date {
        resizePreview[task.id]?.start ?? task.plannedStart ?? Date()
    }

    private func effectiveEnd(_ task: TodoTask) -> Date {
        resizePreview[task.id]?.end ?? task.plannedEnd ?? Date()
    }

    @ViewBuilder
    private func taskBlock(_ task: TodoTask, laneWidth: CGFloat) -> some View {
        let start = effectiveStart(task)
        let end = effectiveEnd(task)
        let height = blockHeight(start: start, end: end)

        VStack(alignment: .leading, spacing: 2) {
            Text(task.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(task.completed ? .holoTextSecondary : .holoTextPrimary)
                .strikethrough(task.completed, color: .holoTextSecondary)
                .lineLimit(height > 60 ? 2 : 1)

            if height > 40 {
                HStack(spacing: 4) {
                    Text(Self.rangeText(start, end))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.holoTextSecondary)
                    if task.completed, let actual = task.actualDurationMinutes?.intValue,
                       let planned = task.plannedDurationMinutes, actual != planned {
                        Text("实际\(ActualDurationSheet.durationText(actual))")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.holoError)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(height: max(30, height), alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(task.completed ? Color.holoSuccess.opacity(0.10) : Color.holoPrimary.opacity(0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(task.completed ? Color.holoSuccess.opacity(0.4) : Color.holoPrimary.opacity(0.55), lineWidth: 1)
        )
        .onTapGesture { openTask(task) }
        // 上下缘调整（长按 0.25s 后拖动；15 分钟吸附；同天内夹取）
        .overlay(alignment: .top) {
            edgeHandle(task, edge: .top).frame(height: 14)
        }
        .overlay(alignment: .bottom) {
            edgeHandle(task, edge: .bottom).frame(height: 14)
        }
    }

    private func edgeHandle(_ task: TodoTask, edge: Edge) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                LongPressGesture(minimumDuration: 0.25).sequenced(before: DragGesture(minimumDistance: 2))
                    .onChanged { value in
                        guard case .second(true, let drag?) = value else { return }
                        applyResize(task, edge: edge, translationY: drag.translation.height)
                    }
                    .onEnded { _ in
                        commitResize(task)
                    }
            )
    }

    private func applyResize(_ task: TodoTask, edge: Edge, translationY: CGFloat) {
        let original = (task.plannedStart ?? Date(), task.plannedEnd ?? Date())
        var start = original.0
        var end = original.1
        let delta = timeDelta(fromPoints: translationY)
        if edge == .top {
            start = clampToDay(snap(original.0.addingTimeInterval(delta)), after: nil, before: end)
        } else {
            end = clampToDay(snap(original.1.addingTimeInterval(delta)), after: start, before: nil)
        }
        guard TodoTask.isValidPlannedRange(start, end) else { return }
        resizePreview[task.id] = (start, end)
    }

    private func commitResize(_ task: TodoTask) {
        guard let preview = resizePreview[task.id] else { return }
        resizePreview[task.id] = nil
        try? TodoRepository.shared.updateTask(
            task,
            plannedTime: .set(start: preview.start, end: preview.end)
        )
        HapticManager.medium()
    }

    private func openTask(_ task: TodoTask) {
        DeepLinkState.shared.navigate(to: .taskDetail(taskId: task.id))
    }

    // MARK: - 日程块（右泳道）

    private func scheduleBlock(_ item: ScheduleItem, laneWidth: CGFloat) -> some View {
        let height = blockHeight(start: item.startDate, end: item.endDate)
        return VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.holoTextPrimary)
                .lineLimit(height > 60 ? 2 : 1)
            if height > 40 {
                Text(Self.rangeText(item.startDate, item.endDate))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.holoTextSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(height: max(26, height), alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(item.calendarColor.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(item.calendarColor.opacity(0.65), lineWidth: 1)
        )
        .onTapGesture { selectedSchedule = item }
    }

    // MARK: - 拖拽建任务

    @State private var dragDraft: (startMinute: CGFloat, endMinute: CGFloat)?

    private var createTaskGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3).sequenced(before: DragGesture(minimumDistance: 5))
            .onChanged { value in
                switch value {
                case .first(true):
                    break
                case .second(true, let drag?):
                    let anchor = drag.startLocation.y
                    let current = drag.location.y
                    let a = snapMinute(anchor / Self.hourHeight * 60)
                    let b = snapMinute(current / Self.hourHeight * 60)
                    guard abs(b - a) >= Self.minimumDraftMinutes else { return }
                    dragDraft = (min(a, b), max(a, b))
                default:
                    break
                }
            }
            .onEnded { _ in
                guard let draft = dragDraft else { return }
                dragDraft = nil
                let dayStart = calendar.startOfDay(for: focusedDate)
                let start = dayStart.addingTimeInterval(TimeInterval(draft.startMinute) * 60)
                let end = dayStart.addingTimeInterval(TimeInterval(draft.endMinute) * 60)
                newTaskDraft = PlannedRangeDraft(start: start, end: end)
            }
    }

    @ViewBuilder
    private func selectionRect(_ draft: (startMinute: CGFloat, endMinute: CGFloat)) -> some View {
        let y0 = draft.startMinute / 60 * Self.hourHeight
        let height = (draft.endMinute - draft.startMinute) / 60 * Self.hourHeight
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.holoPrimary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.holoPrimary.opacity(0.08)))
            .overlay(alignment: .center) {
                Text("松手创建任务 · \(Int(draft.endMinute - draft.startMinute)) 分钟")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.holoPrimary)
            }
            .padding(.horizontal, Self.gutterWidth + 4)
            .frame(height: max(height, 28), alignment: .top)
            .offset(y: y0)
            .allowsHitTesting(false)
    }

    // MARK: - 坐标换算

    private func y(for date: Date) -> CGFloat {
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return CGFloat(minutes) / 60 * Self.hourHeight
    }

    private func blockHeight(start: Date, end: Date) -> CGFloat {
        max(28, CGFloat(end.timeIntervalSince(start)) / 3600 * Self.hourHeight)
    }

    private func snapMinute(_ raw: CGFloat) -> CGFloat {
        let snapped = (raw / Self.snapMinutes).rounded() * Self.snapMinutes
        return min(max(snapped, 0), 24 * 60)
    }

    private func snap(_ date: Date) -> Date {
        let dayStart = calendar.startOfDay(for: focusedDate)
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return dayStart.addingTimeInterval(TimeInterval(snapMinute(CGFloat(minutes))) * 60)
    }

    /// 像素位移 → 秒（向下为正）
    private func timeDelta(fromPoints points: CGFloat) -> TimeInterval {
        TimeInterval(points / Self.hourHeight * 3600)
    }

    private func clampToDay(_ date: Date, after lower: Date?, before upper: Date?) -> Date {
        let dayStart = calendar.startOfDay(for: focusedDate)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        var result = max(dayStart, min(dayEnd, date))
        if let lower { result = max(result, lower) }
        if let upper { result = min(result, upper) }
        return result
    }

    static func rangeText(_ start: Date, _ end: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return "\(formatter.string(from: start))-\(formatter.string(from: end))"
    }
}
