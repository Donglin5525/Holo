//
//  GoalListView.swift
//  Holo
//
//  「我的目标」列表视图（2026-11-13 目标界面减法重设计 S1+S4，规格 §三）
//

import SwiftUI
import CoreData
import Combine

struct GoalListView: View {
    @ObservedObject private var repository = GoalRepository.shared
    let onPlanGoal: () -> Void
    let onOpenLinkedEntity: (DeepLinkTarget) -> Void
    @Binding var pendingGoalDetailId: UUID?
    @State private var selectedGoalRoute: GoalDetailRoute?
    @State private var operationError: String?

    /// 手动创建目标
    @State private var showManualCreate = false

    /// 目标共创（一起想清楚）流程
    @State private var goalWorkshopLaunch: GoalWorkshopLaunch?

    /// 共创开闸与否随服务端开关即时刷新（订阅状态异步落地后菜单/入口要跟着变）
    @State private var workshopEnabled = HoloAIFeatureFlags.goalWorkshopEnabled
    /// 进行中的共创会话（顶部恢复条入口；「进度已保存」必须找得到回家的路）
    @State private var resumableSession: GoalWorkshopSessionV1?

    /// 是否已完成首次加载（避免冷启动时空态先闪现、再被真实列表替换）
    @State private var hasLoadedOnce = false
    /// 目标闭环：到期待回顾的目标集合（加载路径计算，卡片只查集合）
    @State private var reviewDueGoalIDs: Set<UUID> = []
    /// 卡片行2/行3 的真实观测数据（加载路径算好，卡片只读）
    @State private var cardFacts: [UUID: GoalListCardFacts] = [:]
    /// 分段「进行中 | 已完成」（规格 A1）
    @State private var selectedSegment = Segment.ongoing

    /// 长按菜单「改期限」直开编辑 sheet（规格 A4）
    @State private var editRoute: GoalEditRoute?

    /// 长按菜单「删除」确认弹窗锚点（非空=待确认删除该目标）
    @State private var deleteConfirmGoalID: UUID?

    /// 长按菜单「再来一轮」的预填草案；nil=普通手动创建（规格 A4）
    @State private var createPrefillDraft: GoalDraft?

    private enum Segment {
        case ongoing, completed
    }

    init(
        onPlanGoal: @escaping () -> Void,
        onOpenLinkedEntity: @escaping (DeepLinkTarget) -> Void = { _ in },
        pendingGoalDetailId: Binding<UUID?> = .constant(nil)
    ) {
        self.onPlanGoal = onPlanGoal
        self.onOpenLinkedEntity = onOpenLinkedEntity
        self._pendingGoalDetailId = pendingGoalDetailId
    }

    /// 宽屏卡墙分档（通宵冲刺 D7）：expanded 档目标卡两两并排（每列 ≥340pt），
    /// 对齐知识树/习惯磁贴的通览口径；iPhone/竖屏单列不变
    @Environment(\.holoContentWidth) private var goalWindowWidth
    private var goalColumnCount: Int {
        HoloAdaptiveLayout.isExpandedWidth(goalWindowWidth) ? 2 : 1
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            Group {
                if !hasLoadedOnce {
                    // 首次加载前显示轻量占位，避免空态闪现
                    ProgressView()
                        .padding(.top, 80)
                        .frame(maxWidth: .infinity)
                } else if repository.goals.isEmpty {
                    emptyState
                } else {
                    listContent
                }
            }
            // 通览型页面对齐长廊 920 口径（通宵冲刺 D7）；iPhone 直通
            .holoContentColumn(maxWidth: HoloAdaptiveLayout.galleryColumnMaxWidth, paintsBackground: false)
        }
        .background(Color.holoToolBackground)
        // 导航栏返回「<」与右上「+」统一模块行动色（规格 A12：全页只有一个橙，R4）
        .tint(GoalJourneyStyle.action)
        .navigationTitle("我的目标")
        #if canImport(UIKit)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: HoloToolbarPlacement.topBarTrailing) {
                Menu {
                    if workshopEnabled {
                        Button {
                            goalWorkshopLaunch = .new(seedText: nil)
                        } label: {
                            Label("一起想清楚", systemImage: "lightbulb")
                        }
                    }
                    Button {
                        onPlanGoal()
                    } label: {
                        Label("去 AI 对话里规划", systemImage: "sparkles")
                    }
                    Divider()
                    Button {
                        openManualCreate(prefill: nil)
                    } label: {
                        Label("手动创建", systemImage: "square.and.pencil")
                    }
                } label: {
                    Label("新建", systemImage: "plus")
                }
                .accessibilityLabel(String(localized: "新建目标"))
            }
        }
        .sheet(item: $goalWorkshopLaunch) { launch in
            GoalWorkshopFlowView(launch: launch)
        }
        .sheet(isPresented: $showManualCreate) {
            GoalManualCreateSheet(
                initialDraft: createPrefillDraft,
                onSaved: { result in
                    showManualCreate = false
                    createPrefillDraft = nil
                    // 创建后直接跳进详情
                    pendingGoalDetailId = result.goal.id
                },
                onCancel: {
                    showManualCreate = false
                    createPrefillDraft = nil
                }
            )
        }
        .sheet(item: $editRoute) { route in
            if let goal = repository.findGoal(by: route.id) {
                GoalEditSheet(goal: goal) { }
            }
        }
        .confirmationDialog("删除目标", isPresented: Binding(
            get: { deleteConfirmGoalID != nil },
            set: { if !$0 { deleteConfirmGoalID = nil } }
        ), titleVisibility: .visible) {
            Button("删除目标", role: .destructive) {
                if let goalId = deleteConfirmGoalID {
                    requestDelete(goalId)
                }
                deleteConfirmGoalID = nil
            }
            Button("取消", role: .cancel) {
                deleteConfirmGoalID = nil
            }
        } message: {
            Text("删除目标后，基于该目标创建的任务和习惯不会被删除，只会解除与该目标的关联。")
        }
        .navigationDestination(item: $selectedGoalRoute) { route in
            if let goal = repository.findGoal(by: route.id) {
                GoalDetailView(
                    goal: goal,
                    onOpenLinkedEntity: onOpenLinkedEntity,
                    onDeleteRequested: requestDelete
                )
            } else {
                Text("目标不存在或已被删除")
                    .holoText(.body)
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
        .onAppear {
            // Core Data 未就绪时 fetch 静默返回空，首次加载交给 .task 等就绪后执行
            refreshEntryState()
            guard CoreDataStack.shared.isReady else {
                openPendingGoalIfNeeded()
                return
            }
            repository.loadGoals()
            hasLoadedOnce = true
            openPendingGoalIfNeeded()
        }
        .task {
            // 等 Core Data 就绪后再加载，避免入场时空态闪现
            await CoreDataStack.shared.waitUntilReady()
            #if DEBUG && targetEnvironment(simulator)
            GoalProgressUITestSeeder.seedIfNeeded()
            GoalProgressUITestSeeder.seedListStatesIfNeeded()
            #endif
            repository.loadGoals()
            hasLoadedOnce = true
            refreshEntryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .holoServerFlagsDidUpdate)) { _ in
            refreshEntryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: GoalReviewCoordinator.reviewStateDidChange)) { _ in
            refreshReviewDueState()
        }
        .onReceive(Publishers.Merge3(NotificationCenter.default.publisher(for: .habitDataDidChange),
                                    NotificationCenter.default.publisher(for: .financeDataDidChange),
                                    NotificationCenter.default.publisher(for: .todoDataDidChange))
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)) { _ in refreshCardFacts() }
        .onReceive(NotificationCenter.default.publisher(for: .goalDataDidChange)) { _ in
            refreshCardFacts()
            refreshReviewDueState()
        }
        .onChange(of: goalWorkshopLaunch) { _, _ in
            // 共创页关闭后回到本页：恢复条/入口显隐按最新状态刷新
            refreshEntryState()
        }
        .onChange(of: pendingGoalDetailId) { _, _ in
            openPendingGoalIfNeeded()
        }
        .alert("操作失败", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
    }

    // MARK: - 列表主体（恢复条 + 分段 + 卡片）

    private var listContent: some View {
        VStack(spacing: 0) {
            if let resumableSession {
                resumeBanner(resumableSession)
                    .padding(.top, 4)
            }
            Picker(String(localized: "目标分段"), selection: $selectedSegment) {
                Text("进行中").tag(Segment.ongoing)
                Text("已完成").tag(Segment.completed)
            }
            .pickerStyle(.segmented)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Group {
                if selectedSegment == .ongoing {
                    ongoingSegment
                } else {
                    completedSegment
                }
            }
            .padding(.top, 12)
            .animation(.easeInOut(duration: 0.2), value: selectedSegment)
        }
        .padding(.horizontal, GoalJourneyStyle.pageInset)
    }

    @ViewBuilder
    private var ongoingSegment: some View {
        let goals = sortedOngoingGoals
        if goals.isEmpty {
            // 目标都在已完成段时，进行中段保持空白（无占位文案）
            EmptyView()
        } else {
            cardContainer(goals)
        }
    }

    /// 已完成段：completedAt 倒序、无进度条（卡片按状态自裁）；段空一行 13pt 次文字（规格 A3 v2）
    @ViewBuilder
    private var completedSegment: some View {
        if completedGoals.isEmpty {
            Text("还没有完成的目标")
                .goalJourneyText(.metadata)
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.vertical, 48)
                .frame(maxWidth: .infinity)
        } else {
            cardContainer(completedGoals)
        }
    }

    /// 卡片容器：单列间距 16；iPad 宽屏双列网格沿用现有分档（水平边距对齐 22）
    @ViewBuilder
    private func cardContainer(_ goals: [Goal]) -> some View {
        if goalColumnCount > 1 {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HoloSpacing.md), count: goalColumnCount),
                      spacing: HoloSpacing.md) {
                goalCards(goals)
            }
            .padding(.bottom, 40)
        } else {
            VStack(spacing: HoloSpacing.md) {
                goalCards(goals)
            }
            .padding(.bottom, 40)
        }
    }

    private func goalCards(_ goals: [Goal]) -> some View {
        ForEach(goals, id: \.id) { goal in
            Button {
                selectedGoalRoute = GoalDetailRoute(id: goal.id)
            } label: {
                GoalListCard(
                    goal: goal,
                    isReviewDue: reviewDueGoalIDs.contains(goal.id),
                    facts: cardFacts[goal.id] ?? GoalListCardFacts()
                )
            }
            .buttonStyle(HoloPressStyle())
            .contextMenu { cardContextMenu(for: goal) }
        }
    }

    // MARK: - 卡片长按菜单（规格 A4-A6，S4）

    /// 原生 contextMenu：进行中/已暂停=标记完成+暂停·继续+改期限+删除；
    /// 已完成=再来一轮+恢复为进行中+删除（红队 U10：误触标记完成可逆）。
    /// 删除走确认弹窗（与详情页同文案）
    @ViewBuilder
    private func cardContextMenu(for goal: Goal) -> some View {
        if goal.goalStatus == .completed {
            Button {
                createPrefillDraft = Self.newRoundDraft(from: goal)
                showManualCreate = true
            } label: {
                Label("再来一轮", systemImage: "arrow.clockwise")
            }
            Button {
                performStatusChange(goal, to: .active)
            } label: {
                Label("恢复为进行中", systemImage: "arrow.uturn.backward")
            }
            Divider()
            deleteMenuButton(for: goal)
        } else {
            Button {
                performStatusChange(goal, to: .completed)
            } label: {
                Label("标记完成", systemImage: "checkmark.circle")
            }
            Button {
                performStatusChange(goal, to: goal.goalStatus == .paused ? .active : .paused)
            } label: {
                Label(goal.goalStatus == .paused ? "继续" : "暂停",
                      systemImage: goal.goalStatus == .paused ? "play.circle" : "pause.circle")
            }
            Divider()
            Button {
                editRoute = GoalEditRoute(id: goal.id)
            } label: {
                Label("改期限", systemImage: "calendar")
            }
            Divider()
            deleteMenuButton(for: goal)
        }
    }

    private func deleteMenuButton(for goal: Goal) -> some View {
        Button(role: .destructive) {
            deleteConfirmGoalID = goal.id
        } label: {
            Label("删除", systemImage: "trash")
        }
    }

    /// 状态流转走 GoalRepository（completedAt 由模型自动写），成功后重拉列表换段
    private func performStatusChange(_ goal: Goal, to status: GoalStatus) {
        do {
            try repository.updateStatus(goal, status: status)
            GoalNotificationService.broadcastGoalDataChange()
        } catch {
            operationError = error.localizedDescription
        }
    }

    /// 「再来一轮」预填草案（规格 A4）：复制标题/类型/数字与来源链路；
    /// 期限不继承（旧期限多半已过），落库时领域按标题重新认领；
    /// 达标型不继承旧基线（红队 U3）：旧「现在」多半已过期，预填后开屏 100%，
    /// 由 GoalEditForm 入场按当前余额/最新记录重取（applyAutoBaselineForPrefilledDraft）
    static func newRoundDraft(from goal: Goal) -> GoalDraft {
        GoalDraft(
            id: UUID().uuidString,
            title: goal.title,
            summary: nil,
            domain: goal.goalDomain,
            iconEmoji: goal.iconEmoji,
            desiredOutcome: nil,
            motivation: nil,
            deadlineText: nil,
            tasks: [],
            habits: [],
            missingInfoWarnings: [],
            goalKind: goal.goalKindEnum,
            metricSource: goal.metricSourceEnum,
            metricUnit: goal.metricUnit,
            metricTargetValue: goal.metricTargetValueDouble,
            metricBaselineValue: nil,
            sourceHabitId: goal.sourceHabitId,
            ledgerScope: goal.metricSourceEnum == .ledger ? goal.ledgerScopePayload : nil
        )
    }

    // MARK: - 分组与排序（规格 A3；排序抽成纯函数供单测）

    private var sortedOngoingGoals: [Goal] {
        Self.sortedOngoingGoals(repository.goals, reviewDueIDs: reviewDueGoalIDs, now: Date())
    }

    private var completedGoals: [Goal] {
        Self.sortedCompletedGoals(repository.goals)
    }

    /// 进行中段排序：待回顾置顶 → 有期限未到期近→远 → 无期限 → 已到期 → 已暂停垫底；
    /// 桶内按创建时间倒序（新建目标置顶，配合创建成功自动 push 详情）
    static func sortedOngoingGoals(_ goals: [Goal], reviewDueIDs: Set<UUID>, now: Date) -> [Goal] {
        goals.filter { $0.goalStatus != .completed }.sorted { lhs, rhs in
            let left = Self.ongoingRank(of: lhs, reviewDueIDs: reviewDueIDs, now: now)
            let right = Self.ongoingRank(of: rhs, reviewDueIDs: reviewDueIDs, now: now)
            if left != right { return left < right }
            if left == 1, let lhsDeadline = lhs.deadline, let rhsDeadline = rhs.deadline,
               lhsDeadline != rhsDeadline {
                return lhsDeadline < rhsDeadline
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    static func ongoingRank(of goal: Goal, reviewDueIDs: Set<UUID>, now: Date) -> Int {
        if goal.goalStatus == .paused { return 4 }
        if reviewDueIDs.contains(goal.id) { return 0 }
        if let deadline = goal.deadline { return deadline >= now ? 1 : 3 }
        return 2
    }

    /// 已完成段排序：completedAt 倒序（无值垫底）
    static func sortedCompletedGoals(_ goals: [Goal]) -> [Goal] {
        goals.filter { $0.goalStatus == .completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    // MARK: - 空态（规格 A4：图标+标题+副文+主按钮+至多两条文字链接，垂直居中）

    private var emptyState: some View {
        VStack(spacing: 0) {
            Image(systemName: "target")
                .font(.system(size: 44))
                .foregroundStyle(GoalJourneyStyle.action)
                .padding(.bottom, 18)
            Text("想先做成什么？")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.holoToolText)
            Text("一句话，捋成能走的目标")
                .goalJourneyText(.body)
                .foregroundStyle(Color.holoToolTextSecondary)
                .padding(.top, 8)
            Button {
                if workshopEnabled {
                    goalWorkshopLaunch = .new(seedText: nil)
                } else {
                    onPlanGoal()
                }
            } label: {
                Text(workshopEnabled ? String(localized: "和 Holo 一起想清楚") : String(localized: "让 HoloAI 规划"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.holoToolOnAction)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(GoalJourneyStyle.action, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(HoloPressStyle())
            .padding(.top, 28)
            emptyStateLinks
                .padding(.top, 18)
        }
        .padding(.horizontal, GoalJourneyStyle.pageInset)
        .padding(.top, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    /// 关闸去重（v2）：主按钮已是「让 HoloAI 规划」时链接只留「手动创建」
    private var emptyStateLinks: some View {
        HStack(spacing: 22) {
            if workshopEnabled {
                Button {
                    onPlanGoal()
                } label: {
                    Text("或让 HoloAI 规划").underline()
                }
            }
            Button {
                openManualCreate(prefill: nil)
            } label: {
                Text("手动创建").underline()
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(Color.holoToolTextSecondary)
    }

    // MARK: - 恢复条（规格 A0/A11：行动色 8% 底、圆角 12、继续胶囊 + 小 X 放弃）

    private func resumeBanner(_ session: GoalWorkshopSessionV1) -> some View {
        HStack(spacing: 12) {
            Button {
                goalWorkshopLaunch = .resume(sessionID: session.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("有一个想到一半的目标")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(GoalJourneyStyle.action)
                    Text(session.originalText.isEmpty ? String(localized: "（未命名的心愿）") : session.originalText)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.holoToolTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(HoloPressStyle())
            Button {
                goalWorkshopLaunch = .resume(sessionID: session.id)
            } label: {
                Text("继续")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.holoToolOnAction)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(GoalJourneyStyle.action, in: Capsule())
            }
            .buttonStyle(HoloPressStyle())
            Button {
                discardWorkshopSession(session)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(HoloPressStyle())
            .accessibilityLabel(Text(String(localized: "放弃这个想法")))
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .background(GoalJourneyStyle.action.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    /// 小 X=废弃共创会话，条随刷新消失（GoalWorkshopStore.discard）
    private func discardWorkshopSession(_ session: GoalWorkshopSessionV1) {
        do {
            try GoalWorkshopStore.shared.discard(id: session.id)
        } catch {
            operationError = error.localizedDescription
        }
        refreshEntryState()
    }

    // MARK: - 状态刷新

    /// 入口显隐 + 恢复条状态统一刷新（onAppear/开关广播/共创页关闭三处共用）
    private func refreshEntryState() {
        refreshCardFacts()
        workshopEnabled = HoloAIFeatureFlags.goalWorkshopEnabled
        do {
            resumableSession = try GoalWorkshopStore.shared.listResumable().first
        } catch {
            operationError = String(localized: "暂时无法读取规划进度，原记录已保留。请稍后重试。")
        }
        refreshReviewDueState()
    }

    private func refreshCardFacts() {
        guard CoreDataStack.shared.isReady else { return }
        for goal in repository.goals where !goal.isDeleted && goal.deletedAt == nil {
            do {
                cardFacts[goal.id] = GoalListCard.facts(goal: goal, snapshot: try GoalReviewCoordinator.shared.loadState(goal: goal).snapshot)
            } catch {
                // 读不到真实观测：行2 整行不渲染，不放「正在读取进展」类占位（规格 A9）
                cardFacts[goal.id] = GoalListCardFacts()
            }
        }
    }

    /// 待回顾集合在加载路径计算（不在卡片渲染里查库）；开关关闭时为空
    private func refreshReviewDueState() {
        guard HoloAIFeatureFlags.goalClosedLoopEnabled, CoreDataStack.shared.isReady else {
            reviewDueGoalIDs = []
            return
        }
        let context = CoreDataStack.shared.viewContext
        reviewDueGoalIDs = Set(repository.goals
            .filter { $0.goalStatus == .active }
            .map(\.id)
            .filter { GoalReviewCoordinator.isReviewDue(goalID: $0, in: context) })
    }

    private func openPendingGoalIfNeeded() {
        guard let goalId = pendingGoalDetailId else { return }
        selectedGoalRoute = GoalDetailRoute(id: goalId)
        pendingGoalDetailId = nil
    }

    private func requestDelete(_ goalId: UUID) {
        selectedGoalRoute = nil
        DispatchQueue.main.async {
            do {
                try repository.deleteGoal(id: goalId)
                GoalNotificationService.broadcastGoalDataChange()
            } catch {
                operationError = error.localizedDescription
            }
        }
    }

    /// 打开手动创建 sheet；prefill 非空=「再来一轮」预填（长按菜单进入）
    private func openManualCreate(prefill: GoalDraft?) {
        createPrefillDraft = prefill
        showManualCreate = true
    }
}

private struct GoalDetailRoute: Identifiable, Hashable {
    let id: UUID
}

/// 长按菜单「改期限」的编辑 sheet 路由
private struct GoalEditRoute: Identifiable {
    let id: UUID
}

// MARK: - 手动创建目标 Sheet（HoloSheetScaffold 壳，表单见 GoalEditForm）

struct GoalManualCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GoalDraft
    @State private var isSaving = false
    @State private var saveError: String?
    /// 是否存在活跃账本账户（红队 U1）：无账户时账本源不可保存（恒 0% 目标）；
    /// 与 GoalEditForm.loadAccounts 同源，onAppear 取一次不在 body 里反复 fetch
    @State private var hasActiveLedgerAccounts = true

    let onSaved: (GoalDraftSaveResult) -> Void
    let onCancel: () -> Void

    /// 预填草案（列表「再来一轮」入口传入）；nil=空白创建
    init(
        initialDraft: GoalDraft? = nil,
        onSaved: @escaping (GoalDraftSaveResult) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self._draft = State(initialValue: initialDraft ?? GoalEditForm.emptyDraft())
        self.onSaved = onSaved
        self.onCancel = onCancel
    }

    private var canSave: Bool {
        !isSaving
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && GoalEditForm.metricFieldsValid(in: draft, hasActiveLedgerAccounts: hasActiveLedgerAccounts)
    }

    /// 禁用文案（规格 B0 + 红队 U1）：随输入即时消失
    private var disabledHint: String? {
        isSaving ? nil : GoalEditForm.disabledHint(for: draft, hasActiveLedgerAccounts: hasActiveLedgerAccounts)
    }

    var body: some View {
        HoloSheetScaffold(
            title: String(localized: "新建目标"),
            onClose: {
                onCancel()
                dismiss()
            },
            primaryTitle: isSaving ? String(localized: "保存中") : String(localized: "创建"),
            primaryAction: { save() },
            primaryDisabled: !canSave,
            primaryHint: disabledHint,
            primaryActionColor: GoalJourneyStyle.action,
            footerBackground: GoalJourneyStyle.sheetFooterCream
        ) {
            ScrollView(showsIndicators: false) {
                GoalEditForm(draft: $draft)
                    .padding(.horizontal, HoloSpacing.page)
                    .padding(.top, 4)
                    .padding(.bottom, 20)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .onAppear {
            hasActiveLedgerAccounts = !FinanceRepository.shared.getAccounts().isEmpty
        }
        .presentationDetents([.large])
        .alert("保存失败", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private func save() {
        isSaving = true
        DispatchQueue.main.async {
            do {
                // source 在落库时直接标记为 manual（此前先建后补改的绕路写法已移除）；
                // AI 上下文开关已移至目标设置面板，创建流默认允许；
                // 领域按标题自动认领（S3b，规格 v3）：认领结果落库，认不出=其他
                var draftToSave = draft
                draftToSave.domain = GoalDomain.infer(from: draftToSave.title)
                let result = try GoalRepository.shared.saveDraft(draftToSave, allowAIContext: true, source: "manual")
                GoalNotificationService.broadcastGoalDataChange()
                HapticManager.success()
                onSaved(result)
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}
