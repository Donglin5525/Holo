//
//  TimelineReplayView.swift
//  Holo
//
//  记忆长廊「轴」档（三期）：0–24 纵向刻度，双泳道同轴回放
//  左泳道=带时间段的任务（含已完成，带计划/实际对比），右泳道=系统日程（按需拉取，不限活跃窗口）。
//  拖拽反写：空白处长按拖出选区直接建带时间段任务（15 分钟吸附）；拖任务块上下缘调整时间段。
//
//  交互分层原则：默认一切触摸都给滚动；建任务/调时间必须长按成立（震动提示）后才接管手指，
//  让「能不能滑」的分界线可感知，而不是藏在不可见的 0.3 秒阈值里。
//  凌晨 0–7 默认折叠成一条摘要带（与周档同一交互语言），表头可展开收起，偏好持久化。
//  打开自动定位到「现在」（今天）或首个事件前一小时（历史日）；今天右上角常驻「此刻」回正。
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
    /// 空白长按已成立、选区尚未拖出：给「可拖动」提示条
    @State private var isPressArmed = false
    /// 折叠/展开切换后重定位用（ScrollViewProxy 只在 onAppear 后可用）
    @State private var scrollProxy: ScrollViewProxy?

    struct PlannedRangeDraft: Identifiable {
        let id = UUID()
        let start: Date
        let end: Date
    }

    // MARK: - 布局常量（换算统一走 axisLayout，此处只留手势阈值）

    /// 手势吸附粒度（分钟）
    private static let snapMinutes: CGFloat = 15
    /// 新建选区的最小时长（分钟）
    private static let minimumDraftMinutes: CGFloat = 15

    /// 凌晨 0–7 默认折叠（与周档同一交互语言；用户选择持久化）
    @AppStorage("holo.memoryGallery.timeline.collapseMorning")
    private var collapseMorning: Bool = true

    private var calendar: Calendar { Calendar.current }
    private var isToday: Bool { calendar.isDateInToday(focusedDate) }

    /// 分钟 ↔ 像素映射（折叠/展开两态；详见 TimelineAxisLayout）
    private var axisLayout: TimelineAxisLayout { TimelineAxisLayout(collapseMorning: collapseMorning) }

    private func minute(of date: Date) -> CGFloat {
        CGFloat(calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
    }

    var body: some View {
        ScrollViewReader { proxy in
            timelineScroll(proxy: proxy)
                .onAppear {
                    scrollProxy = proxy
                    loadData()
                    scrollToInitialAnchor(proxy, animated: false)
                }
                .onChange(of: focusedDate) { _, _ in
                    loadData()
                    scrollToInitialAnchor(proxy)
                }
                .onChange(of: collapseMorning) { _, _ in
                    // 折叠切换后总高度变化，滚动位置会飘：重新锚回当前关注点
                    scrollToInitialAnchor(proxy)
                }
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

    // MARK: - 时间轴主体

    private func timelineScroll(proxy: ScrollViewProxy) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .topLeading) {
                // 刻度列 + 横线（含凌晨折叠带）
                hourGrid

                // 当前时刻线（仅今天）
                if isToday {
                    nowLine
                }

                // 左右泳道：任务块 / 日程块
                GeometryReader { geometry in
                    let laneWidth = (geometry.size.width - TimelineAxisLayout.gutterWidth) / 2
                    ZStack(alignment: .topLeading) {
                        ForEach(visibleTimedTasks, id: \.id) { task in
                            let laneTop = axisLayout.laneYTop(startMinute: minute(of: effectiveStart(task)))
                            let laneBottom = axisLayout.y(minute:minute(of: effectiveEnd(task)))
                            taskBlock(task, laneWidth: laneWidth)
                                .frame(width: laneWidth - 6)
                                .position(
                                    x: TimelineAxisLayout.gutterWidth + (laneWidth - 6) / 2,
                                    y: laneTop + max(30, laneBottom - laneTop) / 2
                                )
                        }

                        ForEach(visibleSchedules) { item in
                            let laneTop = axisLayout.laneYTop(startMinute: minute(of: item.startDate))
                            let laneBottom = axisLayout.y(minute:minute(of: item.endDate))
                            scheduleBlock(item, laneWidth: laneWidth)
                                .frame(width: laneWidth - 6)
                                .position(
                                    x: TimelineAxisLayout.gutterWidth + laneWidth + (laneWidth - 6) / 2,
                                    y: laneTop + max(26, laneBottom - laneTop) / 2
                                )
                        }
                    }
                }
                .padding(.horizontal, 0)

                // 拖拽建任务选区
                if let draft = dragDraft {
                    selectionRect(draft)
                }

                // 空态引导（不拦截触摸：长按建任务在空轴上同样可用）
                if timedTasks.isEmpty && schedules.isEmpty {
                    emptyGuide
                }
            }
            .frame(height: axisLayout.contentHeight)
            .contentShape(Rectangle())
            .gesture(createTaskGesture)
        }
        .overlay(alignment: .top) {
            topOverlay(proxy: proxy)
        }
    }

    /// 折叠态隐藏完全落在凌晨段的块（计数进摘要带）；跨界块保留白天部分
    private var visibleTimedTasks: [TodoTask] {
        guard collapseMorning else { return timedTasks }
        return timedTasks.filter { !axisLayout.isMorningHidden(endMinute: minute(of: effectiveEnd($0))) }
    }

    private var visibleSchedules: [ScheduleItem] {
        let timed = schedules.filter { !$0.isAllDay }
        guard collapseMorning else { return timed }
        return timed.filter { !axisLayout.isMorningHidden(endMinute: minute(of: $0.endDate)) }
    }

    /// 与凌晨段（0–7 点）相交的任务与日程条数（摘要带口径）
    private var morningItemCount: Int {
        let morningTasks = timedTasks.filter { minute(of: effectiveStart($0)) < TimelineAxisLayout.morningEndMinute }
        let morningSchedules = schedules.filter { !$0.isAllDay && minute(of: $0.startDate) < TimelineAxisLayout.morningEndMinute }
        return morningTasks.count + morningSchedules.count
    }

    // MARK: - 刻度、凌晨折叠带与时刻线

    private var hourGrid: some View {
        VStack(spacing: 0) {
            if collapseMorning {
                morningBand
                ForEach(7..<24, id: \.self) { hour in
                    hourRow(hour)
                }
            } else {
                ForEach(0..<24, id: \.self) { hour in
                    hourRow(hour, isFirstHour: hour == 0)
                }
            }
        }
    }

    private func hourRow(_ hour: Int, isFirstHour: Bool = false) -> some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.holoBorder.opacity(0.35))
                .frame(height: 0.5)
                .padding(.leading, TimelineAxisLayout.gutterWidth - 8)
            HStack(spacing: 2) {
                Text(String(format: "%02d", hour))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.holoTextSecondary.opacity(0.65))
                // 展开态的收起入口固定在 0 点行（与周档「表头固定入口」同一交互语言）
                if isFirstHour {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.holoPrimary.opacity(0.8))
                }
            }
            .frame(width: TimelineAxisLayout.gutterWidth - 6, alignment: .trailing)
            .offset(y: -5)
            .contentShape(Rectangle())
            .onTapGesture {
                if isFirstHour { toggleMorning() }
            }
        }
        .frame(height: TimelineAxisLayout.hourHeight)
        .id(hour)
    }

    /// 凌晨折叠摘要带：与凌晨相交的条数 + 展开入口
    private var morningBand: some View {
        ZStack(alignment: .leading) {
            Rectangle()
                .fill(Color.holoBorder.opacity(0.35))
                .frame(height: 0.5)
                .padding(.leading, TimelineAxisLayout.gutterWidth - 8)
            HStack(spacing: 4) {
                Text("凌晨")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.holoTextSecondary.opacity(0.75))
                if morningItemCount > 0 {
                    Text("\(morningItemCount) 项")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.holoPrimary.opacity(0.85))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.holoPrimary.opacity(0.8))
            }
            .frame(width: TimelineAxisLayout.gutterWidth - 4, alignment: .trailing)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .offset(y: -5)
            .contentShape(Rectangle())
        }
        .frame(height: TimelineAxisLayout.morningBandHeight)
        .contentShape(Rectangle())
        .onTapGesture { toggleMorning() }
        .id("morning")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "凌晨零点到七点已折叠\(morningItemCount)项"))
        .accessibilityHint(String(localized: "轻点展开凌晨时间轴"))
    }

    private func toggleMorning() {
        withAnimation(HoloAnimation.quick) {
            collapseMorning.toggle()
        }
        HapticManager.light()
    }

    @ViewBuilder
    private var nowLine: some View {
        let y = axisLayout.y(minute:CGFloat(calendar.component(.hour, from: Date()) * 60 + calendar.component(.minute, from: Date())))
        HStack(spacing: 6) {
            Circle().fill(Color.holoError).frame(width: 6, height: 6)
            Rectangle().fill(Color.holoError.opacity(0.55)).frame(height: 1)
        }
        .padding(.leading, TimelineAxisLayout.gutterWidth - 10)
        .offset(y: y)
        .allowsHitTesting(false)
    }

    // MARK: - 顶部浮层：全天日程 / 此刻回正 / 下一个事项 / 长按提示

    private func topOverlay(proxy: ScrollViewProxy) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                let allDay = schedules.filter(\.isAllDay)
                if !allDay.isEmpty {
                    allDayBanner(allDay)
                }
                Spacer()
                if isToday {
                    nowChip(proxy: proxy)
                }
            }

            if isToday, let next = nextUpItem {
                nextUpBar(next, proxy: proxy)
            }

            if isPressArmed {
                Text("上下拖动选择时间，松手创建任务")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.holoPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.holoCardBackground.opacity(0.95)))
                    .overlay(Capsule().stroke(Color.holoPrimary.opacity(0.4), lineWidth: 1))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, HoloSpacing.md)
        .padding(.top, 4)
        .animation(HoloAnimation.quick, value: isPressArmed)
    }

    /// 回到此刻（仅今天）
    private func nowChip(proxy: ScrollViewProxy) -> some View {
        Button {
            scrollToNow(proxy)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                Text("此刻")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.holoPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.holoCardBackground.opacity(0.95)))
            .overlay(Capsule().stroke(Color.holoPrimary.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 下一个事项（今天的前瞻入口）

    private struct NextUpItem {
        let title: String
        let start: Date
        let isSchedule: Bool
    }

    private var nextUpItem: NextUpItem? {
        let now = Date()
        let taskEntries = timedTasks.compactMap { task -> NextUpItem? in
            guard let start = task.plannedStart, start > now else { return nil }
            return NextUpItem(title: task.title, start: start, isSchedule: false)
        }
        let scheduleEntries = schedules.filter { !$0.isAllDay && $0.startDate > now }
            .map { NextUpItem(title: $0.title, start: $0.startDate, isSchedule: true) }
        return (taskEntries + scheduleEntries).min { $0.start < $1.start }
    }

    private func nextUpBar(_ item: NextUpItem, proxy: ScrollViewProxy) -> some View {
        Button {
            let hour = calendar.component(.hour, from: item.start)
            withAnimation(HoloAnimation.quick) {
                proxy.scrollTo(scrollAnchorHour(forHour: hour), anchor: .center)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: item.isSchedule ? "calendar" : "checkmark.circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.holoPrimary)
                Text("接下来")
                    .font(.system(size: 11))
                    .foregroundColor(.holoTextSecondary)
                Text(Self.timeText(item.start))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.holoPrimary)
                Text(item.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.holoTextPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .fill(Color.holoCardBackground.opacity(0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HoloRadius.sm)
                    .stroke(Color.holoPrimary.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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
        }
    }

    // MARK: - 空态引导（轴常驻可建任务，引导不拦截触摸）

    private var emptyGuide: some View {
        VStack(spacing: HoloSpacing.sm) {
            Image(systemName: "hand.draw")
                .font(.system(size: 22))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text("长按空白处拖动，直接排一件事")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Text("接入系统日历后，日程也会自动铺到这里")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.75))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, TimelineAxisLayout.gutterWidth)
        .padding(.trailing, HoloSpacing.md)
        .offset(y: axisLayout.y(minute:9 * 60))
        .allowsHitTesting(false)
    }

    // MARK: - 滚动定位（初始锚点）

    /// 定位锚点小时（折叠态凌晨不落锚，统一从 7 点起）
    private func scrollAnchorHour(forHour hour: Int) -> Int {
        collapseMorning ? max(hour, 7) : hour
    }

    private func scrollToInitialAnchor(_ proxy: ScrollViewProxy, animated: Bool = true) {
        let anchor = initialAnchorHour()
        if animated {
            withAnimation(HoloAnimation.quick) {
                proxy.scrollTo(scrollAnchorHour(forHour: anchor), anchor: .top)
            }
        } else {
            proxy.scrollTo(scrollAnchorHour(forHour: anchor), anchor: .top)
        }
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        withAnimation(HoloAnimation.quick) {
            proxy.scrollTo(scrollAnchorHour(forHour: calendar.component(.hour, from: Date())), anchor: .center)
        }
    }

    /// 今天=当前小时；历史日=首个事件前一小时（无事件则上午 9 点）
    private func initialAnchorHour() -> Int {
        if isToday {
            return calendar.component(.hour, from: Date())
        }
        let starts = timedTasks.compactMap { $0.plannedStart }
            + schedules.filter { !$0.isAllDay }.map { $0.startDate }
        if let first = starts.min() {
            return max(calendar.component(.hour, from: first) - 1, 0)
        }
        return 9
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
        let topY = axisLayout.laneYTop(startMinute: minute(of: start))
        let height = max(30, axisLayout.y(minute:minute(of: end)) - topY)
        let isResizing = resizePreview[task.id] != nil

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
        .frame(height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(task.completed ? Color.holoSuccess.opacity(0.10) : Color.holoPrimary.opacity(0.13))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isResizing ? Color.holoPrimary : (task.completed ? Color.holoSuccess.opacity(0.4) : Color.holoPrimary.opacity(0.55)),
                    lineWidth: isResizing ? 1.8 : 1
                )
        )
        // 调整中的边缘强调线：把「正在拖哪条边」画出来
        .overlay(alignment: .top) {
            if isResizing {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.holoPrimary)
                    .frame(height: 2.5)
                    .padding(.horizontal, 10)
            }
        }
        .overlay(alignment: .bottom) {
            if isResizing {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.holoPrimary)
                    .frame(height: 2.5)
                    .padding(.horizontal, 10)
            }
        }
        .onTapGesture { openTask(task) }
        // 上下缘调整（长按 0.4s 有震动反馈后接管；15 分钟吸附；同天内夹取）
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
                LongPressGesture(minimumDuration: 0.4).sequenced(before: DragGesture(minimumDistance: 8))
                    .onChanged { value in
                        switch value {
                        case .first(true):
                            HapticManager.light()
                        case .second(true, let drag?):
                            applyResize(task, edge: edge, translationY: drag.translation.height)
                        default:
                            break
                        }
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
        let anchorMinute: CGFloat
        let delta: TimeInterval
        if edge == .top {
            anchorMinute = minute(of: original.0)
            delta = TimeInterval(translationY * axisLayout.minutesPerPoint(aroundMinute: anchorMinute))
            start = clampToDay(snap(original.0.addingTimeInterval(delta)), after: nil, before: end)
        } else {
            anchorMinute = minute(of: original.1)
            delta = TimeInterval(translationY * axisLayout.minutesPerPoint(aroundMinute: anchorMinute))
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

    @ViewBuilder
    private func scheduleBlock(_ item: ScheduleItem, laneWidth: CGFloat) -> some View {
        let topY = axisLayout.laneYTop(startMinute: minute(of: item.startDate))
        let height = max(26, axisLayout.y(minute:minute(of: item.endDate)) - topY)

        VStack(alignment: .leading, spacing: 2) {
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
        .frame(height: height, alignment: .topLeading)
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
        LongPressGesture(minimumDuration: 0.5).sequenced(before: DragGesture(minimumDistance: 5))
            .onChanged { value in
                switch value {
                case .first(true):
                    // 长按成立即接管并给反馈：滚动与建任务的分界线从此可感知
                    HapticManager.light()
                    isPressArmed = true
                case .second(true, let drag?):
                    isPressArmed = false
                    let a = axisLayout.snapMinute(axisLayout.minute(y: drag.startLocation.y), snap: Self.snapMinutes)
                    let b = axisLayout.snapMinute(axisLayout.minute(y: drag.location.y), snap: Self.snapMinutes)
                    guard abs(b - a) >= Self.minimumDraftMinutes else { return }
                    dragDraft = (min(a, b), max(a, b))
                default:
                    break
                }
            }
            .onEnded { _ in
                isPressArmed = false
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
        let y0 = axisLayout.y(minute:draft.startMinute)
        let height = axisLayout.y(minute:draft.endMinute) - y0
        RoundedRectangle(cornerRadius: 8)
            .stroke(Color.holoPrimary.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.holoPrimary.opacity(0.08)))
            .overlay(alignment: .center) {
                Text("松手创建任务 · \(Int(draft.endMinute - draft.startMinute)) 分钟")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.holoPrimary)
            }
            .padding(.horizontal, TimelineAxisLayout.gutterWidth + 4)
            .frame(height: max(height, 28), alignment: .top)
            .offset(y: y0)
            .allowsHitTesting(false)
    }

    // MARK: - 坐标换算

    private func snap(_ date: Date) -> Date {
        let dayStart = calendar.startOfDay(for: focusedDate)
        return dayStart.addingTimeInterval(TimeInterval(axisLayout.snapMinute(minute(of: date), snap: Self.snapMinutes)) * 60)
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

    static func timeText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
