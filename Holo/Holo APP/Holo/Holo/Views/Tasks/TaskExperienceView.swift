//
//  TaskExperienceView.swift
//  Holo
//
//  任务首页 V2（多视图方案 §3）：顶部「日历 / 四象限 / 列表」三段切换，
//  同一份范围与任务数据三个观察角度。三视图 ZStack 常驻保活——切换不丢
//  滚动位置与展开态；历史范围（已完成/归档）强制列表，点其他视图切回全部。
//  撤回提示统一：完成走 HoloTaskCompletionCoordinator，移动/计划走
//  TaskPresentationActionCoordinator，同一时间只展示一条。
//

import SwiftUI
import OSLog

struct TaskExperienceView: View {

    @ObservedObject var repository: TodoRepository
    let onBack: () -> Void
    /// 外层容器（TasksView）转发的搜索触发
    var searchTrigger: Int = 0
    /// 多视图会话（TasksView @StateObject 持有并注入；模块内往返不销毁）
    @ObservedObject var session: TaskPresentationSession

    @StateObject private var model: TaskExperienceViewModel
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared
    @ObservedObject private var actionCoordinator = TaskPresentationActionCoordinator.shared

    @Environment(\.holoContentWidth) private var contentWidth
    private var isWideLayout: Bool {
        HoloAdaptiveLayout.isExpandedWidth(contentWidth)
    }

    @State private var showScopeSheet = false
    @State private var showCreationSheet = false
    @State private var creationContext: TaskCreationContext = TaskCreationContext()
    @State private var showTriageSheet = false
    @State private var showSearchView = false
    @State private var showNotificationSettings = false
    @State private var showArchiveManagement = false
    @State private var detailSelection: UUID? = nil
    @State private var classificationTarget: TaskRecordSnapshot? = nil
    @State private var dueDateTarget: TaskRecordSnapshot? = nil
    @State private var plannedRangeTarget: TaskRecordSnapshot? = nil
    @State private var deferConfirmTarget: TaskRecordSnapshot? = nil
    @State private var moveSheetTarget: TaskRecordSnapshot? = nil
    /// 外层页面滚动代理（日历进日程首滚用，§5.2-4）
    @State private var pageScrollProxy: ScrollViewProxy? = nil
    /// 范围外新任务提示（提示+查看，用户点才切范围，§7.1）
    @State private var outOfScopeToastID: UUID? = nil
    /// Deep Link 状态（任务详情目标由本页消费，纪念日仍归容器）
    @ObservedObject private var deepLinkState = DeepLinkState.shared

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskExperienceView")

    init(
        repository: TodoRepository,
        onBack: @escaping () -> Void,
        searchTrigger: Int = 0,
        session: TaskPresentationSession
    ) {
        self.repository = repository
        self.onBack = onBack
        self.searchTrigger = searchTrigger
        self.session = session
        _model = StateObject(wrappedValue: TaskExperienceViewModel(repository: repository))
    }

    /// 历史范围强制列表（§3.3）
    private var effectiveViewMode: TaskViewMode {
        model.scope.isHistorical ? .list : session.viewMode
    }

    var body: some View {
        HoloListDetailSplit {
            masterColumn
        } detail: {
            detailPane
        }
        .task {
            await CoreDataStack.shared.waitUntilReady()
            repository.setup()
            model.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .taskExperienceOpenDetail)) { notification in
            if let taskID = notification.object as? UUID {
                detailSelection = taskID
            }
        }
        // 外层 FAB 转发：按当前视图组装创建上下文（§7.1——日历预填选中日计划且不预填截止）
        .onReceive(NotificationCenter.default.publisher(for: .taskExperienceRequestCreation)) { _ in
            guard !showCreationSheet else { return }
            if session.viewMode == .calendar && !model.scope.isHistorical {
                openCreationForSelectedDay()
            } else {
                openCreation()
            }
        }
        // 统一创建回执：按当前视图定位（§7.2）；范围外任务提示+查看
        .onReceive(NotificationCenter.default.publisher(for: .taskExperienceCreated)) { notification in
            guard let taskID = notification.userInfo?["id"] as? UUID else { return }
            handleCreated(taskID: taskID)
        }
        // 任务深链（通知/来源想法）：新首页接住，不被切换截断（§4.5）
        .onAppear {
            consumeDeepLink()
            // 冒烟/UITest 通道：带参启动落页即弹新建页（模拟器无头走查用，见 docs 踩坑录）
            if ProcessInfo.processInfo.arguments.contains("-holo-smoke-open-creation") {
                showCreationSheet = true
            }
        }
        .onChange(of: deepLinkState.pendingTarget) { _, _ in
            consumeDeepLink()
        }
        .onChange(of: searchTrigger) { _, _ in
            showSearchView = true
        }
        .onChange(of: model.scope) { _, newScope in
            // 选择历史范围（已完成/归档）：进入列表视图（§3.3）
            if newScope.isHistorical {
                session.viewMode = .list
            }
        }
        .onChange(of: outOfScopeToastID) { _, newValue in
            guard newValue != nil else { return }
            // 提示 6 秒后自动消失（用户也可点「查看」）
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                if outOfScopeToastID == newValue {
                    outOfScopeToastID = nil
                    model.createdOutOfScopeTaskID = nil
                }
            }
        }
    }

    private var scopeBinding: Binding<TaskExperienceScope> {
        Binding(
            get: { model.scope },
            set: { model.scope = $0 }
        )
    }

    // MARK: - 主列

    private var masterColumn: some View {
        VStack(spacing: 0) {
            headerView
            viewSwitcher
            if model.loadFailed {
                failBanner
            }
            ZStack {
                listLayer
                matrixLayer
                calendarLayer
            }
            .clipped()
            .overlay(alignment: .bottom) {
                undoBannerIfVisible
                    .animation(HoloAnimation.snappy, value: showsCompletionUndoBanner)
            }
        }
        .sheet(isPresented: $showScopeSheet) {
            TaskScopeSheet(repository: repository, scope: scopeBinding, scopeCounts: model.scopeCounts)
        }
        .sheet(isPresented: $showCreationSheet) {
            // 创建回执走 .taskExperienceCreated 统一通知（含底部+/统计页入口）
            TaskCreationSheet(repository: repository, context: creationContext)
        }
        .sheet(isPresented: $showTriageSheet) {
            TaskTriageSheet(repository: repository, queue: model.makeTriageQueue())
                .onDisappear { model.reload() }
        }
        .sheet(item: Binding(
            get: { classificationTarget.map { ClassificationTarget(snapshot: $0) } },
            set: { classificationTarget = $0?.snapshot }
        )) { target in
            TaskClassificationSheet(
                initialImportance: target.snapshot.importance,
                initialUrgencyMode: target.snapshot.urgencyMode,
                contextEffectiveDue: target.snapshot.effectiveDue(calendar: model.calendar)
            ) { importance, urgencyMode in
                model.applyClassification(
                    taskID: target.snapshot.id,
                    importance: importance,
                    urgencyMode: urgencyMode
                )
            }
        }
        .sheet(item: Binding(
            get: { dueDateTarget.map { ClassificationTarget(snapshot: $0) } },
            set: { dueDateTarget = $0?.snapshot }
        )) { target in
            TaskDueQuickEditSheet(
                repository: repository,
                snapshot: target.snapshot
            ) {
                dueDateTarget = nil
                model.reload()
            }
        }
        .sheet(item: Binding(
            get: { plannedRangeTarget.map { ClassificationTarget(snapshot: $0) } },
            set: { plannedRangeTarget = $0?.snapshot }
        )) { target in
            TaskPlannedRangeQuickSheet(
                repository: repository,
                snapshot: target.snapshot,
                defaultDay: session.viewMode == .calendar ? session.selectedDay : nil,
                onApplied: { plannedDay in
                    // 成功后选中新的计划日，月标题同步（§5.4）
                    if let plannedDay {
                        session.revealDay(plannedDay)
                    }
                    model.reload()
                }
            )
        }
        .sheet(item: Binding(
            get: { moveSheetTarget.map { ClassificationTarget(snapshot: $0) } },
            set: { moveSheetTarget = $0?.snapshot }
        )) { target in
            TaskQuadrantMoveSheet(
                snapshot: target.snapshot,
                repository: repository,
                now: model.now,
                calendar: model.calendar
            )
        }
        #if canImport(UIKit)
        .fullScreenCover(isPresented: $showSearchView) {
            TaskExperienceSearchView(model: model)
                .holoContentColumn()
        }
        #else
                .sheet(isPresented: $showSearchView) {
            TaskExperienceSearchView(model: model)
                .holoContentColumn()
        }
        #endif
        .sheet(isPresented: $showNotificationSettings) {
            NotificationSettingsView()
        }
        .sheet(isPresented: $showArchiveManagement) {
            ArchiveManagementView(repository: repository)
        }
        .sheet(item: Binding(
            get: isWideLayout ? { nil } : { detailSelection },
            set: { detailSelection = $0 }
        ), onDismiss: { model.reload() }) { taskID in
            if let task = repository.findTask(by: taskID) {
                TaskDetailView(task: task, repository: repository)
            } else {
                Text("该任务已被删除")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                    .padding()
            }
        }
        .alert(
            String(localized: "放下今日安排"),
            isPresented: Binding(
                get: { deferConfirmTarget != nil },
                set: { if !$0 { deferConfirmTarget = nil } }
            )
        ) {
            Button(String(localized: "继续放下"), role: .destructive) {
                if let target = deferConfirmTarget {
                    performDefer(target, acknowledge: true)
                }
                deferConfirmTarget = nil
            }
            Button(String(localized: "取消"), role: .cancel) {
                deferConfirmTarget = nil
            }
        } message: {
            Text("这项任务今天到期或已逾期。放下后它仍在任务列表和逾期提醒里，确定放下吗？")
        }
    }

    // MARK: - 三视图层（ZStack 常驻保状态：滚动/展开/日期切换不丢，V02）

    private var listLayer: some View {
        ScrollView {
            ScrollViewReader { proxy in
                LazyVStack(spacing: 0) {
                    if model.scope.isHistorical {
                        historicalContent
                    } else {
                        listContent
                    }
                }
                .padding(.horizontal, HoloSpacing.page)
                .padding(.top, HoloSpacing.xs)
                .padding(.bottom, 100)
                .onAppear { pageScrollProxy = proxy }
                .onChange(of: model.locateTaskID) { _, newValue in
                    guard let id = newValue else { return }
                    withAnimation(HoloAnimation.smooth) {
                        proxy.scrollTo("task-\(id.uuidString)", anchor: .center)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        if model.locateTaskID == id {
                            model.locateTaskID = nil
                        }
                    }
                }
            }
        }
        .opacity(effectiveViewMode == .list ? 1 : 0)
        .allowsHitTesting(effectiveViewMode == .list)
        .accessibilityHidden(effectiveViewMode != .list)
    }

    private var matrixLayer: some View {
        ScrollView {
            TaskQuadrantBoardView(
                model: model,
                session: session,
                repository: repository,
                onOpenDetail: { detailSelection = $0 },
                onCreateInQuadrant: { openCreation(forQuadrant: $0) },
                onOpenTriage: { showTriageSheet = true }
            )
            .padding(.horizontal, HoloSpacing.page)
            .padding(.top, HoloSpacing.xs)
            .padding(.bottom, 100)
        }
        .opacity(effectiveViewMode == .matrix ? 1 : 0)
        .allowsHitTesting(effectiveViewMode == .matrix)
        .accessibilityHidden(effectiveViewMode != .matrix)
    }

    private var calendarLayer: some View {
        ScrollView {
            TaskCalendarView(
                model: model,
                session: session,
                repository: repository,
                actions: rowActions,
                onOpenDetail: { detailSelection = $0 },
                onCreateForSelectedDay: { openCreationForSelectedDay() },
                onCreateAtHour: { hour in openCreationAtHour(hour) },
                scrollProxy: pageScrollProxy
            )
            .padding(.horizontal, HoloSpacing.page)
            .padding(.top, HoloSpacing.xs)
            .padding(.bottom, 100)
        }
        .opacity(effectiveViewMode == .calendar ? 1 : 0)
        .allowsHitTesting(effectiveViewMode == .calendar)
        .accessibilityHidden(effectiveViewMode != .calendar)
    }

    // MARK: - 头部（返回 + 标题 + 搜索/更多 + 三段切换 + 范围）

    private var headerView: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.holoTextSecondary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.holoNestedCardBackground))
                }
                .accessibilityLabel(Text("返回"))
                Spacer()
                Text("任务")
                    .font(.holoHeading)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
                HStack(spacing: 8) {
                    Button {
                        showSearchView = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.holoTextSecondary)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(Color.holoNestedCardBackground))
                    }
                    .accessibilityLabel(String(localized: "搜索任务"))
                    moreMenu
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HoloSpacing.page)
            .padding(.vertical, HoloSpacing.sm)

            // 范围菜单：三视图同一份（§3.3）；计数收进统一灰徽章
            Button {
                showScopeSheet = true
            } label: {
                HStack(spacing: 6) {
                    Text(model.scopeTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if !model.scope.isHistorical {
                        HoloCountBadge(count: model.conservedTotal)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundColor(.holoTextSecondary)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "查看范围，当前\(model.scopeTitle)"))
            .accessibilityIdentifier("tasks.scope")
            .overlay(alignment: .trailing) {
                // 日历视图右侧轻解释（§9.2 范围行）
                if effectiveViewMode == .calendar && !model.scope.isHistorical {
                    Text("按计划与截止显示")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextPlaceholder)
                        .allowsHitTesting(false)
                        .padding(.trailing, HoloSpacing.page)
                }
            }
            .padding(.horizontal, HoloSpacing.page)
            .padding(.bottom, HoloSpacing.xs)
        }
        .background(Color.holoBackground)
    }

    // MARK: - 三段切换（§9.2：44 热区 + 3 padding = 50 容器）

    private var viewSwitcher: some View {
        HStack(spacing: 3) {
            ForEach(TaskViewMode.allCases) { mode in
                segmentButton(mode)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .padding(.horizontal, HoloSpacing.page)
        .padding(.bottom, HoloSpacing.xs)
    }

    private func segmentButton(_ mode: TaskViewMode) -> some View {
        let isSelected = effectiveViewMode == mode
        return Button {
            guard effectiveViewMode != mode else { return }
            HapticManager.selection()
            // 历史范围切走：显式切回全部未完成并提示（不禁用按钮，§3.3）
            if model.scope.isHistorical {
                model.scope = .allUncompleted
                HoloToastCenter.shared.show(String(localized: "已切回全部未完成"), type: .info)
            }
            withAnimation(HoloAnimation.quick) {
                session.viewMode = mode
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: mode.iconName)
                    .font(.system(size: 16, weight: .medium))
                Text(mode.displayTitle)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
            }
            .foregroundColor(isSelected ? .holoTextPrimary : .holoTextSecondary)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? Color.holoCardBackground : Color.clear)
                    .shadow(color: isSelected ? HoloShadow.card : .clear, radius: 2, y: 1)
            )
            .overlay(
                // 深色下选中块贴轨道底色：细描边兜出选中边界（浅色下近似隐形）
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(isSelected ? Color.holoToolBorder : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mode.displayTitle)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("tasks.view.\(mode.rawValue)")
    }

    private var moreMenu: some View {
        Menu {
            if session.viewMode == .calendar && !model.scope.isHistorical {
                Toggle(String(localized: "显示已完成"), isOn: Binding(
                    get: { session.calendarShowsCompleted },
                    set: { session.calendarShowsCompleted = $0 }
                ))
            }
            Button {
                showNotificationSettings = true
            } label: {
                Label(String(localized: "提醒设置"), systemImage: "bell")
            }
            Button {
                showArchiveManagement = true
            } label: {
                Label(String(localized: "归档管理"), systemImage: "archivebox")
            }
            Toggle(String(localized: "新版任务体验"), isOn: v2ToggleBinding)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.holoTextSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.holoNestedCardBackground))
        }
    }

    /// 开发验收开关（§15.1）：关闭只切回旧 UI，不动数据与模型
    private var v2ToggleBinding: Binding<Bool> {
        Binding(
            get: { UserDefaults.standard.object(forKey: "taskExperienceV2Enabled") as? Bool ?? true },
            set: { UserDefaults.standard.set($0, forKey: "taskExperienceV2Enabled") }
        )
    }

    private var failBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 13))
                .foregroundColor(.holoToolError)
            Text("更新失败，以下为上次数据")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
            Spacer()
            Button(String(localized: "重试")) {
                model.reload()
            }
            .font(.holoCaption)
            .foregroundColor(.holoPrimary)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, 6)
        .background(Color.holoError.opacity(0.08))
    }

    // MARK: - 列表内容：清单分组（§3.4）

    private var listContent: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                loadingView
            } else if model.conservedTotal == 0 && model.unclassifiedCount == 0 {
                emptyStateView
            } else {
                Text("按清单查看任务，包含未安排与待判断重要性的任务。")
                    .font(.system(size: 12))
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, HoloSpacing.xs)

                ForEach(model.listGroups) { group in
                    if !omitsGroupHeader {
                        listGroupHeader(group)
                    }
                    rowsContainer(group.members)
                }
            }
        }
    }

    /// 指定清单/收件箱范围省略与范围名重复的组标题（§3.4）
    private var omitsGroupHeader: Bool {
        switch model.scope {
        case .list, .inbox: return true
        default: return false
        }
    }

    private func listGroupHeader(_ group: TaskExperienceViewModel.TaskListGroup) -> some View {
        HStack(spacing: 7) {
            Text(group.title)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(.holoTextSecondary)
            HoloCountBadge(count: group.members.count)
            Spacer()
        }
        .padding(.top, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    /// 行组容器：极淡底色分组，行透明+行间细线（沿用视觉改版范式）
    private func rowsContainer(_ members: [TaskRecordSnapshot], isHistory: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(members) { member in
                row(member, isHistoryRow: isHistory)
                if member.id != members.last?.id {
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
        .padding(.bottom, HoloSpacing.md)
    }

    // MARK: - 历史范围内容（已完成/归档连续列表，§3.4 末段）

    private var historicalContent: some View {
        let members = model.historicalMembers
        return Group {
            if members.isEmpty {
                emptyStateView
            } else {
                rowsContainer(members, isHistory: true)
            }
        }
    }

    // MARK: - 行与动作句柄

    /// 行动作句柄：列表/日历明细/各弹层共用同一套（§3.1 三视图共用操作）
    private var rowActions: TaskRowActionHandlers {
        TaskRowActionHandlers(
            onToggleCompletion: { member in toggleCompletion(member) },
            onOpenDetail: { member in detailSelection = member.id },
            onClassify: { member in classificationTarget = member },
            onChangeDue: { member in dueDateTarget = member },
            onPlanRange: { member in plannedRangeTarget = member },
            onToggleToday: { member in toggleToday(member) },
            onArchive: { member in archiveTask(member) },
            onDelete: { member in deleteTask(member) },
            onToggleCheckItem: { member, snapshot in toggleCheckItem(member: member, snapshot: snapshot) },
            onAddCheckItem: { member, title in addCheckItem(member: member, title: title) }
        )
    }

    private func row(
        _ member: TaskRecordSnapshot,
        isHistoryRow: Bool = false
    ) -> some View {
        TaskExperienceRow(
            member: member,
            calendar: model.calendar,
            now: model.now,
            isCompleting: model.pendingCompletionTaskID == member.id,
            isCompleted: member.completed,
            isHistoryRow: isHistoryRow,
            isInTodayPlan: model.todayEntryIDs.contains(member.id),
            onToggleCompletion: { toggleCompletion(member) },
            onOpenDetail: { detailSelection = member.id },
            onClassify: { classificationTarget = member },
            onChangeDue: { dueDateTarget = member },
            onPlanRange: { plannedRangeTarget = member },
            onToggleToday: { toggleToday(member) },
            onArchive: { archiveTask(member) },
            onDelete: { deleteTask(member) },
            onToggleCheckItem: { toggleCheckItem(member: member, snapshot: $0) },
            onAddCheckItem: { addCheckItem(member: member, title: $0) }
        )
        .id("task-\(member.id.uuidString)")
    }

    /// 完成/撤回（三视图共用协调器，§8）
    private func toggleCompletion(_ member: TaskRecordSnapshot) {
        if member.completed {
            reopenTask(member)
        } else if model.pendingCompletionTaskID == member.id {
            completionCoordinator.undo(in: repository)
            HapticManager.light()
        } else {
            completionCoordinator.requestCompletion(
                taskID: member.id, source: .taskList, in: repository
            )
            HapticManager.taskCompletion()
        }
    }

    /// 卡上勾子任务：经仓储切状态（勾掉即清等待态），通知链路刷新列表
    private func toggleCheckItem(member: TaskRecordSnapshot, snapshot: CheckItemSnapshot) {
        guard let task = repository.findTask(by: member.id),
              let item = (task.checkItems?.allObjects as? [CheckItem])?.first(where: { $0.id == snapshot.id })
        else { return }
        do {
            try repository.toggleCheckItem(item)
            HapticManager.light()
        } catch {
            Self.logger.error("列表勾选子任务失败：\(error.localizedDescription)")
            HoloToastCenter.shared.show(String(localized: "步骤状态未保存，请重试。"), type: .error)
        }
    }

    /// 展开态「加一步」：行内输入回车落库
    private func addCheckItem(member: TaskRecordSnapshot, title: String) -> Bool {
        guard let task = repository.findTask(by: member.id) else { return false }
        do {
            let order = Int16(task.checkItems?.count ?? 0)
            try repository.addCheckItem(title: title, to: task, order: order)
            return true
        } catch {
            Self.logger.error("列表加一步失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 撤回/操作提示（同一时间一条，§8）

    /// 键盘高度（真机实报：展开态输「加一步」时完成任务的撤回 toast 被键盘盖住）
    @State private var keyboardHeight: CGFloat = 0

    /// 完成横条只在完成由本页（列表视图）发起时展示；跨页来源由发起页自己出横条
    private var showsCompletionUndoBanner: Bool {
        model.pendingCompletionTaskID != nil
            && completionCoordinator.pending?.source == .taskList
    }

    @ViewBuilder
    private var undoBannerIfVisible: some View {
        // 完成横条只展示本页发起的完成：pending 是跨页共享的单一状态，
        // 不按 source 过滤会同一次完成在首页/详情各弹一条。
        if showsCompletionUndoBanner {
            HoloUndoToast(
                message: String(localized: "已完成 · \(Int(HoloTaskCompletionCoordinator.confirmDelay)) 秒内可撤回"),
                onUndo: {
                    completionCoordinator.undo(in: repository)
                    HapticManager.light()
                }
            )
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.bottom, 80 + keyboardHeight)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            #if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                withAnimation(HoloAnimation.quick) {
                    keyboardHeight = end.minY >= holoScreenHeight() - 1 ? 0 : end.height
                }
            }
            #endif
        } else if let undoable = actionCoordinator.undoable {
            HoloUndoToast(
                message: undoable.message,
                onUndo: {
                    actionCoordinator.undoCurrent(repository: repository)
                    HapticManager.light()
                }
            )
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.bottom, 80)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if let failure = actionCoordinator.failureMessage {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13))
                    .foregroundColor(.holoToolError)
                Text(failure)
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Button {
                    actionCoordinator.dismissPrompt()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.holoTextPlaceholder)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 9)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            .shadow(color: HoloShadow.card, radius: 8, x: 0, y: 3)
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.bottom, 80)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        } else if outOfScopeToastID != nil {
            // 范围外新任务：提示 + 查看（用户点才切范围，§7.1）
            HStack(spacing: 8) {
                Text("已新增，当前范围不包含此任务")
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Spacer()
                Button(String(localized: "查看")) {
                    model.revealOutOfScopeTask()
                    outOfScopeToastID = nil
                }
                .font(.holoCaption.weight(.semibold))
                .foregroundColor(.holoPrimary)
            }
            .padding(.horizontal, HoloSpacing.md)
            .padding(.vertical, 9)
            .background(Color.holoCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md, style: .continuous))
            .shadow(color: HoloShadow.card, radius: 8, x: 0, y: 3)
            .padding(.horizontal, HoloSpacing.lg)
            .padding(.bottom, 80)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 空态/加载态

    private var loadingView: some View {
        VStack(spacing: HoloSpacing.md) {
            ProgressView()
            Text("正在读取任务…")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checklist")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
            Text("暂无任务")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
            Text("告诉 Holo 要做什么，或手动创建")
                .font(.holoCaption)
                .foregroundColor(.holoTextSecondary.opacity(0.7))
            Button {
                openCreation()
            } label: {
                Label(String(localized: "创建第一个任务"), systemImage: "plus.circle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.holoTextSecondary)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.holoDivider, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("taskEmptyCtaV2")
        }
        .padding(.top, 60)
    }

    // MARK: - 详情右栏（宽屏）

    @ViewBuilder
    private var detailPane: some View {
        if let taskID = detailSelection, let task = repository.findTask(by: taskID) {
            TaskDetailView(task: task, repository: repository, onBack: { detailSelection = nil })
                .id(taskID)
        } else {
            VStack(spacing: HoloSpacing.sm) {
                Image(systemName: "checklist")
                    .font(.system(size: 30))
                    .foregroundColor(.holoTextPlaceholder)
                Text("选一条任务查看")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.holoBackground)
        }
    }

    // MARK: - 创建上下文（§7.1 表）

    private func openCreation(
        forQuadrant quadrant: TaskQuadrant? = nil,
        plannedStart: Date? = nil,
        plannedEnd: Date? = nil
    ) {
        var context = TaskCreationContext()
        if let quadrant = quadrant {
            // 象限新增：明示并预填该象限（新任务非重要侧默认 P2，§7.1）
            context.importance = quadrantImportance(quadrant)
            context.urgencyMode = quadrantUrgencyMode(quadrant)
            context.sourceQuadrant = quadrant
        }
        switch model.scope {
        case .list(let listID):
            context.listID = listID
        case .todayDue:
            // 日历视图不预填截止（即使范围今天到期，§7.1）
            if session.viewMode != .calendar {
                context.dueDate = TaskAnalyticsPeriod.makeCalendar().startOfDay(for: Date())
                context.dueIsAllDay = true
            }
        default:
            break
        }
        context.plannedStart = plannedStart
        context.plannedEnd = plannedEnd
        creationContext = context
        showCreationSheet = true
    }

    /// 日历选中日新增：计划=当天默认规则（其他日 09:00–10:00）；不预填截止
    private func openCreationForSelectedDay() {
        let range = TaskPlannedTimeDefaults.defaultRange(
            on: session.selectedDay, from: model.now, calendar: model.calendar
        )
        openCreation(plannedStart: range.start, plannedEnd: range.end)
    }

    /// 日程空白整点：该点至后一小时（23 点至 23:59），不跨日（§5.2-10）
    private func openCreationAtHour(_ hour: Int) {
        let range = TaskPlannedTimeDefaults.hourSlot(day: session.selectedDay, hour: hour, calendar: model.calendar)
        openCreation(plannedStart: range.start, plannedEnd: range.end)
    }

    private func quadrantImportance(_ quadrant: TaskQuadrant) -> TaskImportance {
        switch quadrant {
        case .doFirst, .scheduleTime: return .p1
        case .batchHandle, .reviewLater: return .p2
        case .unclassified: return .unknown
        }
    }

    private func quadrantUrgencyMode(_ quadrant: TaskQuadrant) -> TaskUrgencyMode {
        switch quadrant {
        case .doFirst, .batchHandle: return .p1
        case .scheduleTime, .reviewLater: return .p3
        case .unclassified: return .auto
        }
    }

    // MARK: - 范围与创建回执

    /// 统一创建回执（§7.2）：日历定位计划日；列表按清单定位；
    /// 范围外任务提示+查看；矩阵快照刷新即达
    private func handleCreated(taskID: UUID) {
        model.handleCreated(taskID: taskID, quadrant: .unclassified)
        if model.createdOutOfScopeTaskID == taskID {
            outOfScopeToastID = taskID
            return
        }
        switch session.viewMode {
        case .calendar:
            // 有计划定位计划日；无计划有截止定位截止日；都无提示已加入待安排（§7.2）
            let snapshot = model.snapshots.first { $0.id == taskID }
            if let plannedDay = snapshot.flatMap({ TaskCalendarProjection.plannedDay(of: $0, calendar: model.calendar) }) {
                session.revealDay(plannedDay)
            } else if let dueDay = snapshot.flatMap({ TaskCalendarProjection.dueDay(of: $0, calendar: model.calendar) }) {
                session.revealDay(dueDay)
            } else {
                HoloToastCenter.shared.show(String(localized: "已新增任务，已加入待安排"), type: .success)
            }
        case .list, .matrix:
            break // locateTaskID 已定位（矩阵四格常显，快照刷新即达）
        }
    }

    /// 任务详情深链：延迟半拍等 fullScreenCover 层级就绪（与旧首页同法）
    private func consumeDeepLink() {
        guard case .taskDetail(let taskID) = deepLinkState.pendingTarget else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            detailSelection = taskID
            self.deepLinkState.pendingTarget = nil
        }
    }

    private func reopenTask(_ member: TaskRecordSnapshot) {
        guard let task = repository.findTask(by: member.id) else { return }
        do {
            try repository.uncompleteTask(task)
        } catch {
            Self.logger.error("重新打开失败: \(error.localizedDescription)")
        }
    }

    private func archiveTask(_ member: TaskRecordSnapshot) {
        guard let task = repository.findTask(by: member.id) else { return }
        do {
            try repository.archiveTask(task)
            HapticManager.medium()
        } catch {
            Self.logger.error("归档失败: \(error.localizedDescription)")
        }
    }

    private func deleteTask(_ member: TaskRecordSnapshot) {
        guard let task = repository.findTask(by: member.id) else { return }
        do {
            try repository.deleteTask(task)
            HapticManager.medium()
        } catch {
            Self.logger.error("删除失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 今日安排（§6.4：加入/放下走 HoloTodayPlanService，不改截止）

    private func toggleToday(_ member: TaskRecordSnapshot) {
        Task { @MainActor in
            let scope = HoloTodayDayScope.current()
            let heads = KanbanTaskSection.currentTodayPlanHeadIDs(scope: scope)
            do {
                if isTaskInTodayPlan(member.id, scope: scope) {
                    // 放下：今天到期/逾期需行内确认（沿用既有截止约束确认语义）
                    if HoloTodayReliefPolicy.needsDeadlineAcknowledgement(
                        dueDate: member.dueDate, isAllDay: member.isAllDay, scope: scope
                    ) {
                        deferConfirmTarget = member
                        return
                    }
                    performDefer(member, acknowledge: false)
                } else {
                    _ = try await HoloTodayPlanService.shared.addTask(
                        taskID: member.id,
                        goal: .taskResult,
                        scope: scope,
                        expectedHeads: heads,
                        operationID: UUID().uuidString
                    )
                    HapticManager.light()
                }
            } catch {
                Self.logger.error("今日安排调整失败: \(error.localizedDescription)")
            }
        }
    }

    private func performDefer(_ member: TaskRecordSnapshot, acknowledge: Bool) {
        Task { @MainActor in
            let scope = HoloTodayDayScope.current()
            let heads = KanbanTaskSection.currentTodayPlanHeadIDs(scope: scope)
            let acknowledgement: HoloTodayDeadlineAcknowledgement?
            if acknowledge,
               let fingerprint = HoloTodayReliefPolicy.deadlineFingerprint(
                   dueDate: member.dueDate, isAllDay: member.isAllDay
               ) {
                acknowledgement = HoloTodayDeadlineAcknowledgement(
                    taskID: member.id, deadlineFingerprint: fingerprint
                )
            } else {
                acknowledgement = nil
            }
            do {
                _ = try await HoloTodayPlanService.shared.deferTask(
                    taskID: member.id,
                    acknowledgement: acknowledgement,
                    scope: scope,
                    expectedHeads: heads,
                    operationID: UUID().uuidString
                )
                HapticManager.light()
            } catch {
                Self.logger.error("放下今日失败: \(error.localizedDescription)")
            }
        }
    }

    private func isTaskInTodayPlan(_ taskID: UUID, scope: HoloTodayDayScope) -> Bool {
        let read = HoloTodayPlanRepository(context: CoreDataStack.shared.viewContext)
            .currentPlan(scope: scope)
        if case .active(let payload, _) = read.state {
            return payload.entries.contains { $0.taskID == taskID }
        }
        return false
    }
}

// MARK: - sheet item 包装

private struct ClassificationTarget: Identifiable {
    let snapshot: TaskRecordSnapshot
    var id: UUID { snapshot.id }
}
