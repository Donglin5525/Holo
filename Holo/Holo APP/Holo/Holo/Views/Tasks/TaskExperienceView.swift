//
//  TaskExperienceView.swift
//  Holo
//
//  任务首页 V2（2026-10-06 任务重构方案 §4）：返回与标题、范围菜单、
//  紧凑四象限、待整理入口、四象限分组任务列表；历史范围走连续列表。
//  删除大幅今日进度卡与横向范围胶囊；今日推进属于 Today 与统计。
//

import SwiftUI
import OSLog

struct TaskExperienceView: View {

    @ObservedObject var repository: TodoRepository
    let onBack: () -> Void
    /// 外层容器（TasksView）转发的搜索触发
    var searchTrigger: Int = 0

    @StateObject private var model: TaskExperienceViewModel
    @ObservedObject private var completionCoordinator = HoloTaskCompletionCoordinator.shared

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
    /// Deep Link 状态（任务详情目标由本页消费，纪念日仍归容器）
    @ObservedObject private var deepLinkState = DeepLinkState.shared

    private static let logger = Logger(subsystem: "com.holo.app", category: "TaskExperienceView")

    init(repository: TodoRepository, onBack: @escaping () -> Void, searchTrigger: Int = 0) {
        self.repository = repository
        self.onBack = onBack
        self.searchTrigger = searchTrigger
        _model = StateObject(wrappedValue: TaskExperienceViewModel(repository: repository))
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
        // 统一创建回执：无论从本页、底部+还是统计页新建，都展开定位（§5.4/§4.5）
        .onReceive(NotificationCenter.default.publisher(for: .taskExperienceCreated)) { notification in
            if let taskID = notification.userInfo?["id"] as? UUID,
               let quadrant = notification.userInfo?["quadrant"] as? TaskQuadrant {
                model.handleCreated(taskID: taskID, quadrant: quadrant)
            }
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
                snapshot: target.snapshot
            ) {
                plannedRangeTarget = nil
                model.reload()
            }
        }
        .fullScreenCover(isPresented: $showSearchView) {
            TaskExperienceSearchView(model: model)
                .holoContentColumn()
        }
        .sheet(isPresented: $showNotificationSettings) {
            NotificationSettingsView()
        }
        .sheet(isPresented: $showArchiveManagement) {
            ArchiveManagementView(repository: repository)
        }
        .sheet(item: Binding(
            get: { isWideLayout ? nil : detailSelection },
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
            if model.loadFailed {
                failBanner
            }
            ScrollView {
                ScrollViewReader { proxy in
                    LazyVStack(spacing: 0) {
                        if model.scope.isHistorical {
                            historicalContent
                        } else {
                            quadrantContent
                        }
                    }
                    .padding(.horizontal, HoloSpacing.page)
                    .padding(.top, HoloSpacing.xs)
                    .padding(.bottom, 100)
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
            .overlay(alignment: .bottom) {
                undoBannerIfVisible
            }
        }
    }

    // MARK: - 头部（返回 + 标题 + 搜索/更多 + 范围菜单）

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

            // 范围菜单：默认全部未完成，可看到当前范围名称（§4.1-2）；
            // 计数收进统一灰徽章（2026-10-12 橙纪律：数字不再用品牌色）
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
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "查看范围，当前\(model.scopeTitle)"))
            .padding(.horizontal, HoloSpacing.page)
            .padding(.bottom, HoloSpacing.xs)
        }
        .background(Color.holoBackground)
    }

    private var moreMenu: some View {
        Menu {
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
                .foregroundColor(.holoError)
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

    // MARK: - 四象限内容

    private var quadrantContent: some View {
        VStack(spacing: 0) {
            if model.isLoading {
                loadingView
            } else if model.conservedTotal == 0 && model.unclassifiedCount == 0 {
                emptyStateView
            } else {
                // 象限概览胶囊行退役（2026-10-12 大改 v2）：
                // 与下方分组头同名同计数出现两次，是判读点名的层级噪音；
                // 轻重缓急的导航由分组头与长按菜单承载
                if let selected = model.selectedQuadrant {
                    singleGroupSection(selected)
                } else {
                    ForEach(model.groupedMembers, id: \.quadrant) { group in
                        groupSection(group.quadrant, members: group.members)
                    }
                    unclassifiedSection
                }

                moveToastView
            }
        }
    }

    // 2026-10-11 列表减法：待整理入口横幅整行删除，
    // 「整理」动作并入 unclassifiedSection 的分组头（见 groupHeader trailingAction）

    /// 单组（点象限后仅显示该组全部任务，§4.3）
    @ViewBuilder
    private func singleGroupSection(_ quadrant: TaskQuadrant) -> some View {
        let members = model.groupedMembers.first { $0.quadrant == quadrant }?.members ?? []
        if members.isEmpty {
            VStack(spacing: HoloSpacing.sm) {
                Text("这个象限暂无任务")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                Button {
                    openCreation(forQuadrant: quadrant)
                } label: {
                    Text("在此添加任务")
                        .font(.holoCaption.weight(.semibold))
                        .foregroundColor(.holoPrimary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.holoPrimary.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HoloSpacing.xl)
        } else {
            groupHeader(quadrant, count: members.count, expanded: true)
            rowsContainer(members)
        }
    }

    @ViewBuilder
    private func groupSection(_ quadrant: TaskQuadrant, members: [TaskRecordSnapshot]) -> some View {
        if !members.isEmpty {
            let expanded = model.expandedGroups.contains(quadrant)
            groupHeader(quadrant, count: members.count, expanded: expanded)
            let displayed = expanded ? members : Array(members.prefix(3))
            rowsContainer(displayed)
            if !expanded && members.count > 3 {
                Button {
                    withAnimation(HoloAnimation.smooth) {
                        _ = model.expandedGroups.insert(quadrant)
                    }
                } label: {
                    Text("展开全部 · \(members.count) 项")
                        .font(.holoCaption)
                        .foregroundColor(.holoPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HoloSpacing.sm)
                }
                .buttonStyle(.plain)
            }
            if expanded {
                Button {
                    withAnimation(HoloAnimation.smooth) {
                        _ = model.expandedGroups.remove(quadrant)
                    }
                } label: {
                    Text("收起")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, HoloSpacing.sm)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// 分组头：圆点 + 名称 + 计数；trailingAction 供「待整理」组挂「整理」动作
    /// （2026-10-12 视觉改版：计数用统一徽章、动作胶囊去橙改灰描边、左缘与卡片同线）
    private func groupHeader(
        _ quadrant: TaskQuadrant,
        count: Int,
        expanded: Bool,
        trailingAction: (title: String, handler: () -> Void)? = nil
    ) -> some View {
        HStack(spacing: 7) {
            Text(quadrant.displayTitle)
                .font(.system(size: 12.5, weight: .bold))
                .foregroundColor(.holoTextSecondary)
            Text(verbatim: "\(count)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.holoTextPlaceholder)
            Spacer()
            if let action = trailingAction {
                Button(action: action.handler) {
                    HStack(spacing: 3) {
                        Text(action.title)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .font(.system(size: 12.5))
                    .foregroundColor(.holoTextSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "整理待整理任务"))
            }
        }
        .padding(.top, HoloSpacing.md)
        .padding(.bottom, HoloSpacing.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var unclassifiedSection: some View {
        let members = model.unclassifiedMembers
        if !members.isEmpty {
            groupHeader(
                .unclassified,
                count: members.count,
                expanded: true,
                trailingAction: (title: String(localized: "整理"), handler: { showTriageSheet = true })
            )
            rowsContainer(members)
        }
    }

    /// 行组容器（2026-10-12 大改 v2）：极淡底色分组，行透明+行间细线，
    /// 卡片底色退役——层级靠留白与分组容器，一行只有一个落点
    private func rowsContainer(_ members: [TaskRecordSnapshot], isHistory: Bool = false) -> some View {
        VStack(spacing: 0) {
            ForEach(members) { member in
                taskRow(member, isHistoryRow: isHistory)
                if member.id != members.last?.id {
                    Rectangle()
                        .fill(Color.holoDivider.opacity(0.5))
                        .frame(height: 0.5)
                        .padding(.leading, 54)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: HoloRadius.lg, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
    }

    // MARK: - 历史范围内容（已完成/归档连续列表，§4.2）

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

    // MARK: - 任务行（2026-10-12 大改 v2：进度环 + 就地展开子任务 + 长按菜单；
    // 紧急分/清单名/「还有N步」文字全部退场）

    private func taskRow(
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
            onToggleCompletion: {
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
            },
            onOpenDetail: {
                detailSelection = member.id
            },
            onClassify: {
                classificationTarget = member
            },
            onChangeDue: {
                dueDateTarget = member
            },
            onPlanRange: {
                plannedRangeTarget = member
            },
            onToggleToday: {
                toggleToday(member)
            },
            onArchive: {
                archiveTask(member)
            },
            onDelete: {
                deleteTask(member)
            },
            onToggleCheckItem: { snapshot in
                toggleCheckItem(member: member, snapshot: snapshot)
            },
            onAddCheckItem: { title in
                addCheckItem(member: member, title: title)
            }
        )
        .id("task-\(member.id.uuidString)")
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
        }
    }

    /// 展开态「加一步」：行内输入回车落库
    private func addCheckItem(member: TaskRecordSnapshot, title: String) {
        guard let task = repository.findTask(by: member.id) else { return }
        do {
            let order = Int16(task.checkItems?.count ?? 0)
            try repository.addCheckItem(title: title, to: task, order: order)
        } catch {
            Self.logger.error("列表加一步失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 移动提示（§4.3）

    @ViewBuilder
    private var moveToastView: some View {
        if let toast = model.moveToast {
            HStack(spacing: 8) {
                Text(String(localized: "已移至「\(toast.targetQuadrant.displayTitle)」"))
                    .font(.holoCaption)
                    .foregroundColor(.holoTextSecondary)
                Button(String(localized: "查看")) {
                    model.revealMovedTask()
                }
                .font(.holoCaption.weight(.semibold))
                .foregroundColor(.holoPrimary)
                Spacer()
                Button {
                    model.moveToast = nil
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
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - 撤回 banner

    /// 键盘高度（真机实报：展开态输「加一步」时完成任务的撤回 toast 被键盘盖住）
    @State private var keyboardHeight: CGFloat = 0

    @ViewBuilder
    private var undoBannerIfVisible: some View {
        if model.pendingCompletionTaskID != nil {
            HoloUndoToast(
                message: String(localized: "已完成 · \(Int(HoloTaskCompletionCoordinator.confirmDelay)) 秒内可撤回"),
                onUndo: {
                    completionCoordinator.undo(in: repository)
                    HapticManager.light()
                }
            )
            .padding(.horizontal, HoloSpacing.lg)
            // 上移到 FAB 上方：真机实报撤回钮被「加一步」键盘挡住；判读又实锤
            // toast 右端与右下 FAB 同高水平线互压——底部 74 一并避开两者（键盘另算）
            .padding(.bottom, 80 + keyboardHeight)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue ?? .zero
                withAnimation(HoloAnimation.quick) {
                    // 收起（frame 落到屏外）归零；弹出时上移键盘可视高度
                    keyboardHeight = end.minY >= UIScreen.main.bounds.height - 1 ? 0 : end.height
                }
            }
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

    // MARK: - 动作

    private func openCreation(forQuadrant quadrant: TaskQuadrant? = nil) {
        var context = TaskCreationContext()
        if let quadrant = quadrant {
            // 象限新增：明示并预填该象限（手动紧急方式保持无日期也归该象限，§5.2）
            context.importance = quadrantImportance(quadrant)
            context.urgencyMode = quadrantUrgencyMode(quadrant)
            context.sourceQuadrant = quadrant
        }
        switch model.scope {
        case .list(let listID):
            context.listID = listID
        case .todayDue:
            if quadrant == nil {
                // 今天到期范围新增（未选象限）：今天全天（§5.2）
                context.dueDate = TaskAnalyticsPeriod.makeCalendar().startOfDay(for: Date())
                context.dueIsAllDay = true
            } else {
                // 范围内选象限再新增：继承象限手动方式 + 今天全天
                context.dueDate = TaskAnalyticsPeriod.makeCalendar().startOfDay(for: Date())
                context.dueIsAllDay = true
            }
        default:
            break
        }
        creationContext = context
        showCreationSheet = true
    }

    private func quadrantImportance(_ quadrant: TaskQuadrant) -> TaskImportance {
        switch quadrant {
        case .doFirst, .scheduleTime: return .p1
        // 另一侧预填中性的 P2（2026-10-07 分组口径：P1 归重要侧，P2/P3 归另一侧）
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
