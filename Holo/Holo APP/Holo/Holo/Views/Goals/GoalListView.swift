//
//  GoalListView.swift
//  Holo
//
//  「我的目标」列表视图
//

import SwiftUI
import CoreData

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
            VStack(spacing: HoloSpacing.md) {
                if let resumableSession {
                    resumeBanner(resumableSession)
                }
                Group {
                if goalColumnCount > 1 {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: HoloSpacing.md), count: goalColumnCount), spacing: HoloSpacing.md) {
                        goalCards
                    }
                } else {
                    VStack(spacing: HoloSpacing.md) {
                        goalCards
                    }
                }
                }
                .padding(HoloSpacing.lg)
                // 通览型页面对齐长廊 920 口径（通宵冲刺 D7）；iPhone 直通
                .holoContentColumn(maxWidth: HoloAdaptiveLayout.galleryColumnMaxWidth, paintsBackground: false)
            }
        }
        .background(Color.holoBackground)
        .navigationTitle("我的目标")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
                        Label("让 HoloAI 规划", systemImage: "sparkles")
                    }
                    Button {
                        showManualCreate = true
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
                onSaved: { result in
                    showManualCreate = false
                    // 创建后直接跳进详情
                    pendingGoalDetailId = result.goal.id
                },
                onCancel: { showManualCreate = false }
            )
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
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
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
            repository.loadGoals()
            hasLoadedOnce = true
            refreshEntryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .holoServerFlagsDidUpdate)) { _ in
            refreshEntryState()
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

    /// 入口显隐 + 恢复条状态统一刷新（onAppear/开关广播/共创页关闭三处共用）
    private func refreshEntryState() {
        workshopEnabled = HoloAIFeatureFlags.goalWorkshopEnabled
        resumableSession = (try? GoalWorkshopStore.shared.listResumable())?.first
    }

    /// 进行中共创会话恢复条：「进度已保存」在目标页的可见出口
    private func resumeBanner(_ session: GoalWorkshopSessionV1) -> some View {
        Button {
            goalWorkshopLaunch = .resume(sessionID: session.id)
        } label: {
            HStack(spacing: HoloSpacing.sm) {
                Image(systemName: "lightbulb")
                    .font(.system(size: 16))
                    .foregroundColor(.holoPrimary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("有一个想到一半的目标")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextPrimary)
                    Text(session.originalText.isEmpty ? "（未命名的心愿）" : session.originalText)
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("继续")
                    .font(.holoLabel)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoPrimary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundColor(.holoPrimary)
            }
            .padding(HoloSpacing.md)
            .background(Color.holoPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: HoloRadius.md))
        }
        .buttonStyle(PlainButtonStyle())
        .holoHover()
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.top, HoloSpacing.md)
    }

    @ViewBuilder
    private var goalCards: some View {
        if !hasLoadedOnce {
            // 首次加载前显示轻量占位，避免空态闪现
            ProgressView()
                .padding(.top, 80)
        } else if repository.goals.isEmpty {
            emptyState
        } else {
            ForEach(repository.goals, id: \.id) { goal in
                Button {
                    selectedGoalRoute = GoalDetailRoute(id: goal.id)
                } label: {
                    goalRow(goal)
                }
                .buttonStyle(PlainButtonStyle())
                .holoHover()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: HoloSpacing.lg) {
            Image(systemName: "target")
                .font(.system(size: 48))
                .foregroundColor(.holoPrimary)
            Text("还没有目标")
                .font(.holoTitle)
                .foregroundColor(.holoTextPrimary)
            Text("把模糊的想法变成能走的目标")
                .font(.holoBody)
                .foregroundColor(.holoTextSecondary)
                .multilineTextAlignment(.center)
            if workshopEnabled {
                Button {
                    goalWorkshopLaunch = .new(seedText: nil)
                } label: {
                    Text("和 Holo 一起想清楚第一个目标")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.holoPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
                Button {
                    onPlanGoal()
                } label: {
                    Text("或让 HoloAI 直接规划")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                        .underline()
                }
            } else {
                Button {
                    onPlanGoal()
                } label: {
                    Text("让 HoloAI 规划目标")
                        .font(.holoBody)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(Color.holoPrimary)
                        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                }
            }
            Button {
                showManualCreate = true
            } label: {
                Text("或手动创建")
                    .font(.holoLabel)
                    .foregroundColor(.holoTextSecondary)
                    .underline()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 80)
    }

    private func goalRow(_ goal: Goal) -> some View {
        let progress = GoalProgressEvaluator.evaluate(goal: goal)
        return HStack(spacing: HoloSpacing.md) {
            Text(goal.displayIcon)
                .font(.system(size: 20))
                .frame(width: 40, height: 40)
                .background(Color.holoPrimary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))

            VStack(alignment: .leading, spacing: 4) {
                Text(goal.title)
                    .font(.holoBody)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoTextPrimary)
                if goal.isQuantitative, let metric = GoalMetricEvaluator.evaluate(goal: goal) {
                    // 量化目标行：数字进度替代六档状态文案
                    Text(metricRowText(goal: goal, metric: metric))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.holoPrimary)
                        .lineLimit(1)
                } else {
                    Text("\(progress.state.displayName) · \(progress.taskSummary) · \(progress.habitSummary)")
                        .font(.system(size: 12))
                        .foregroundColor(.holoTextSecondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.holoTextSecondary.opacity(0.5))
        }
        .padding(HoloSpacing.md)
        .holoCard()
    }

    /// 「128/300 km」；达标型显示「已减 2.5/5 kg」基线视角
    private func metricRowText(goal: Goal, metric: GoalMetricProgress) -> String {
        let unit = goal.metricUnit.map { " \($0)" } ?? ""
        if goal.goalKindEnum == .target, let baseline = goal.baselineValueDouble {
            let target = goal.metricTargetValueDouble ?? 0
            let verb = target < baseline ? String(localized: "已减") : String(localized: "已增")
            return "\(verb) \(GoalMetricEvaluator.formatValue(abs(baseline - metric.currentValue)))/\(GoalMetricEvaluator.formatValue(abs(target - baseline)))\(unit)"
        }
        return "\(GoalMetricEvaluator.formatValue(metric.currentValue))/\(GoalMetricEvaluator.formatValue(goal.metricTargetValueDouble ?? 0))\(unit)"
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
}

private struct GoalDetailRoute: Identifiable, Hashable {
    let id: UUID
}

// MARK: - 手动创建目标 Sheet

struct GoalManualCreateSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: GoalDraft = GoalEditForm.emptyDraft()
    @State private var allowAIContext = true
    @State private var isSaving = false
    @State private var saveError: String?

    let onSaved: (GoalDraftSaveResult) -> Void
    let onCancel: () -> Void

    private var canSave: Bool {
        !isSaving
            && !draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && GoalEditForm.metricFieldsValid(in: draft)
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(spacing: HoloSpacing.lg) {
                    GoalEditForm(draft: $draft)
                    aiContextCard
                }
                .padding(.horizontal, HoloSpacing.lg)
                .padding(.top, HoloSpacing.md)
                .padding(.bottom, 100)
            }
            .background(Color.holoBackground)
            .navigationTitle("创建目标")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? String(localized: "保存中") : String(localized: "保存")) { save() }
                        .disabled(!canSave)
                        .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomActions
            }
            .alert("保存失败", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(saveError ?? "")
            }
        }
    }

    private var aiContextCard: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 16))
                    .foregroundColor(.holoPrimary)
                    .frame(width: 24, height: 24)
                Text("AI 上下文")
                    .font(.holoBody)
                    .foregroundColor(.holoTextPrimary)
                Spacer()
            }

            CardDivider()

            Toggle(isOn: $allowAIContext) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许 HoloAI 参考此目标")
                        .font(.holoCaption)
                        .foregroundColor(.holoTextPrimary)
                    Text("HoloAI 会基于此目标给出更精准的建议")
                        .font(.holoLabel)
                        .foregroundColor(.holoTextSecondary)
                }
            }
            .tint(.holoPrimary)
        }
        .padding(HoloSpacing.md)
        .background(Color.holoCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(
            RoundedRectangle(cornerRadius: HoloRadius.md)
                .stroke(Color.holoBorder, lineWidth: 1)
        )
        .shadow(color: HoloShadow.card, radius: 4, x: 0, y: 2)
    }

    private var bottomActions: some View {
        HStack(spacing: HoloSpacing.md) {
            Button {
                onCancel()
                dismiss()
            } label: {
                Text("取消")
                    .font(.holoBody)
                    .foregroundColor(.holoTextSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.holoCardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: HoloRadius.md)
                            .stroke(Color.holoBorder, lineWidth: 1)
                    )
            }

            Button {
                save()
            } label: {
                HStack(spacing: 6) {
                    if isSaving {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    }
                    Text(isSaving ? String(localized: "保存中") : String(localized: "创建目标"))
                        .font(.holoBody)
                        .foregroundColor(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(canSave ? Color.holoPrimary : Color.gray.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
            }
            .disabled(!canSave)
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.md)
        .background(Color.holoCardBackground)
        .shadow(color: .black.opacity(0.06), radius: 8, x: 0, y: -2)
    }

    private func save() {
        isSaving = true
        DispatchQueue.main.async {
            do {
                // source 在落库时直接标记为 manual（此前先建后补改的绕路写法已移除）
                let result = try GoalRepository.shared.saveDraft(
                    draft,
                    allowAIContext: allowAIContext,
                    source: "manual"
                )
                GoalNotificationService.broadcastGoalDataChange()
                onSaved(result)
                dismiss()
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }
}
