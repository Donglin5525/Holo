//
//  GoalAnalysisSection.swift
//  Holo
//
//  目标详情原位增量「目标分析」区（最终规格 §2.2）：只显示最新一份有效报告的简短结论、
//  生成时间、分析范围与状态；没有报告时显示下次回顾时间与「分析目标」。
//  状态机：首次未到期 / 到期提示 / 生成中 / 完成 / 无数据或部分数据 / 失败 / 建议待确认 / 依据已变化。
//  「去记录」按来源跳原模块，不在此弹第二套记录表单；报告在现有导航容器内打开共用的
//  ReportDetailRoute（同一 reportMessageID 在 HoloAI 可见）。开关关闭时整区不渲染。
//

import SwiftUI
import Combine
import CoreData

@MainActor
final class GoalAnalysisSectionModel: ObservableObject {
    @Published private(set) var state: GoalReviewState?
    @Published private(set) var loadError: String?
    @Published private(set) var isLaunching = false
    @Published var launchNotice: String?
    @Published var needsConsent = false
    /// 用户点了「稍后」：本次会话不再重复弹到期提示（不写库）
    @Published var dueDismissed = false

    private let coordinator: GoalReviewCoordinator
    private var cancellables: Set<AnyCancellable> = []

    init(coordinator: GoalReviewCoordinator = .shared) {
        self.coordinator = coordinator
    }

    func observe(goalID: UUID, goal: Goal) {
        guard cancellables.isEmpty else { return }
        NotificationCenter.default.publisher(for: GoalReviewCoordinator.reviewStateDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                guard (notification.object as? UUID) == goalID else { return }
                self?.load(goal: goal)
            }
            .store(in: &cancellables)
        Publishers.Merge3(NotificationCenter.default.publisher(for: .habitDataDidChange),
                          NotificationCenter.default.publisher(for: .financeDataDidChange),
                          NotificationCenter.default.publisher(for: .todoDataDidChange))
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.load(goal: goal) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .goalDataDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.load(goal: goal) }
            .store(in: &cancellables)
    }

    func load(goal: Goal) {
        guard goal.deletedAt == nil, !goal.isDeleted else { return }
        do {
            state = try coordinator.loadState(goal: goal)
            loadError = nil
        } catch let error as GoalPlanResolveError {
            loadError = GoalReviewCoordinator.describe(error)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// 返回需要内联打开的报告消息 id（已存在的报告）；生成中/新发起返回 nil（在区内显示进度）
    func analyze(goal: Goal, forceNew: Bool) async -> UUID? {
        guard !isLaunching else { return nil }
        isLaunching = true
        defer { isLaunching = false }
        let outcome = await coordinator.startOrOpenReview(goal: goal, forceNew: forceNew)
        load(goal: goal)
        switch outcome {
        case .openedExisting(_, let messageID):
            return messageID
        case .started, .resumedRunning:
            return nil
        case .needsConsent:
            needsConsent = true
            return nil
        case .unavailable(let reason), .failed(let reason):
            launchNotice = reason
            return nil
        }
    }
}

struct GoalAnalysisSection: View {
    @ObservedObject var goal: Goal
    let onOpenLinkedEntity: (DeepLinkTarget) -> Void

    @StateObject private var model = GoalAnalysisSectionModel()
    @State private var reportMessage: ChatMessageViewData?
    @State private var showHistory = false
    @State private var adjustmentContext: GoalAdjustmentReviewContext?

    var body: some View {
        VStack(alignment: .leading, spacing: HoloSpacing.sm) {
            HStack {
                Text("目标分析").holoText(.body).fontWeight(.semibold)
                Spacer()
                if let state = model.state, !state.history.isEmpty {
                    Button("历史分析") { showHistory = true }
                        .holoText(.supporting)
                        .foregroundColor(.holoPrimary)
                        .accessibilityIdentifier("goal.analysis.history")
                }
            }
            content
        }
        .padding(HoloSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.holoToolSurface)
        .clipShape(RoundedRectangle(cornerRadius: HoloRadius.md))
        .overlay(RoundedRectangle(cornerRadius: HoloRadius.md).stroke(Color.holoBorder, lineWidth: 1))
        .onAppear {
            model.observe(goalID: goal.id, goal: goal)
            model.load(goal: goal)
        }
        .fullScreenCover(item: $reportMessage) { message in
            ReportDetailRoute(message: message, chatViewModel: nil, onDismiss: { model.load(goal: goal) })
                .holoContentColumn()
        }
        .sheet(isPresented: $showHistory) {
            GoalReviewHistorySheet(goalTitle: goal.title, entries: model.state?.history ?? []) { messageID in
                showHistory = false
                openReport(messageID)
            }
        }
        .sheet(item: $adjustmentContext) { context in
            GoalAdjustmentReviewSheet(context: context) {
                model.load(goal: goal)
            }
        }
        .sheet(isPresented: $model.needsConsent) {
            GoalReviewConsentHintSheet {
                model.needsConsent = false
                onOpenLinkedEntity(.ai(voiceInput: false))
            }
        }
        .alert("没能发起分析", isPresented: Binding(
            get: { model.launchNotice != nil },
            set: { if !$0 { model.launchNotice = nil } }
        )) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(model.launchNotice ?? "")
        }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        if let error = model.loadError {
            Label { Text(error).holoText(.supporting) } icon: { Image(systemName: "lock") }
                .foregroundColor(.holoToolTextSecondary)
        } else if let state = model.state {
            stateContent(state)
        } else {
            Text("正在读取计划…").holoText(.supporting).foregroundColor(.holoToolTextSecondary)
        }
    }

    @ViewBuilder
    private func stateContent(_ state: GoalReviewState) -> some View {
        if goal.goalStatus != .active {
            Text(goal.goalStatus == .paused ? "目标已暂停，专属回顾已停止；恢复后从当前事实重估。" : "目标已完成，专属回顾已停止。")
                .holoText(.supporting)
                .foregroundColor(.holoToolTextSecondary)
        }

        if let running = state.running {
            runningRow(running)
        } else if let latest = state.latestCompleted {
            completedRows(state, latest: latest)
        } else {
            firstTimeRows(state)
        }

        resultRows(state)
        coverageRow(state)

        if goal.goalStatus == .active {
            actionRow(state)
        }
    }

    private func firstTimeRows(_ state: GoalReviewState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if state.isDue, !model.dueDismissed {
                Label {
                    Text("该回顾一下了：按计划回看最近 \(state.snapshot.observationWindow.dayCount) 天的执行与结果。")
                        .holoText(.supporting)
                } icon: {
                    Image(systemName: "bell.badge")
                }
                .foregroundColor(.holoPrimary)
            } else if let next = state.snapshot.review.nextReviewAt {
                infoLine(icon: "calendar", text: String(localized: "下次回顾 \(Self.dayText(next))；现在也可以主动分析"))
            } else {
                infoLine(icon: "calendar", text: String(localized: "未设定期回顾；可随时主动分析"))
            }
        }
    }

    private func runningRow(_ running: GoalReviewLinkSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("分析生成中…可以先离开，完成后这里和 HoloAI 都会出现同一份报告。")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            }
            if let messageID = running.reportMessageID {
                Button("在 HoloAI 查看进度") {
                    onOpenLinkedEntity(.cloudAnalysisReport(messageID: messageID))
                }
                .holoText(.supporting)
                .foregroundColor(.holoPrimary)
            }
        }
    }

    @ViewBuilder
    private func completedRows(_ state: GoalReviewState, latest: GoalReviewLinkSummary) -> some View {
        let rendered = latest.reportMessageID.flatMap { ChatMessageRepository.shared.loadMessageViewData(id: $0)?.agentResult }
        VStack(alignment: .leading, spacing: 6) {
            if latest.status == .unavailable {
                infoLine(icon: "trash", text: String(localized: "上次的报告已被删除；可以重新分析"))
            } else if let rendered {
                Text(rendered.keyInsight ?? rendered.narrativeSummary ?? rendered.summary)
                    .holoText(.body)
                    .foregroundColor(.holoToolText)
                    .lineLimit(4)
                infoLine(icon: "clock",
                         text: String(localized: "生成于 \(Self.dayText(latest.completedAt ?? latest.createdAt)) · 范围 \(Self.dayText(latest.windowStart))–\(Self.dayText(latest.snapshotCutoffAt))"))
            }
            if let failure = latest.failureReason, latest.status == .failed {
                infoLine(icon: "exclamationmark.triangle", text: failure)
            }
            if state.isDue, !model.dueDismissed {
                Label { Text("又到回顾时间了").holoText(.supporting) } icon: { Image(systemName: "bell.badge") }
                    .foregroundColor(.holoPrimary)
            }
            if state.adjustmentDraft != nil {
                if state.isAdjustmentStale {
                    infoLine(icon: "arrow.triangle.2.circlepath",
                             text: String(localized: "依据或计划已变化，上次的调整建议待刷新；重新分析后再确认"))
                } else {
                    infoLine(icon: "slider.horizontal.3", text: String(localized: "有可采纳的调整建议，确认前不会改动任何安排"))
                }
            }
        }
    }

    @ViewBuilder
    private func resultRows(_ state: GoalReviewState) -> some View {
        let result = state.snapshot.result
        switch result.status {
        case .pendingSource:
            HStack(spacing: HoloSpacing.sm) {
                infoLine(icon: "questionmark.circle", text: String(localized: "结果来源待补齐：计划照常执行，报告里结果按未知处理"))
                Spacer(minLength: 0)
                recordButton(for: result)
            }
        case .unavailable:
            HStack(spacing: HoloSpacing.sm) {
                infoLine(icon: "exclamationmark.triangle", text: result.unavailableReason ?? String(localized: "结果来源不可用"))
                Spacer(minLength: 0)
                recordButton(for: result)
            }
        case .missing:
            HStack(spacing: HoloSpacing.sm) {
                infoLine(icon: "circle.dashed", text: String(localized: "\(result.sourceLabel)尚无观测：能看执行，暂不能判断成果"))
                Spacer(minLength: 0)
                recordButton(for: result)
            }
        case .stale:
            HStack(spacing: HoloSpacing.sm) {
                infoLine(icon: "clock.arrow.circlepath", text: result.note ?? String(localized: "最近观测已过期"))
                Spacer(minLength: 0)
                recordButton(for: result)
            }
        case .observed, .notApplicable:
            EmptyView()
        }
    }

    private func coverageRow(_ state: GoalReviewState) -> some View {
        let coverage = state.snapshot.coverage
        return Group {
            if !coverage.unknown.isEmpty {
                infoLine(icon: "info.circle",
                         text: String(localized: "已知 \(coverage.known.count) 项 · 未知 \(coverage.unknown.count) 项：\(coverage.unknown.prefix(2).joined(separator: "；"))"))
            }
        }
    }

    private func actionRow(_ state: GoalReviewState) -> some View {
        HStack(spacing: HoloSpacing.sm) {
            if state.running == nil {
                Button {
                    Task { await analyze(forceNew: state.latestCompleted != nil && !state.isAdjustmentStale && !state.isDue) }
                } label: {
                    Label(state.latestCompleted == nil ? String(localized: "分析目标") : String(localized: "重新分析"),
                          systemImage: "sparkles")
                        .holoText(.supporting)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .tint(.holoPrimary)
                .disabled(model.isLaunching)
                .accessibilityIdentifier("goal.analysis.analyze")
            }
            if let latest = state.latestCompleted, let messageID = latest.reportMessageID, latest.status != .unavailable {
                Button("查看报告") { openReport(messageID) }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("goal.analysis.openReport")
            }
            if let draft = state.adjustmentDraft, !state.isAdjustmentStale {
                Button("查看调整") {
                    adjustmentContext = GoalAdjustmentReviewContext(goal: goal, draft: draft, state: state)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("goal.analysis.openAdjustment")
            }
            if state.isDue, !model.dueDismissed, state.running == nil {
                Button("稍后") { model.dueDismissed = true }
                    .buttonStyle(.plain)
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
            }
        }
    }

    /// 「去记录」：按来源跳原模块（财务 / 习惯 / 任务），不在目标页另开记录表单
    @ViewBuilder
    private func recordButton(for result: GoalResultObservation) -> some View {
        switch result.sourceKind {
        case .ledger:
            Button("去财务") { onOpenLinkedEntity(.finance) }
                .holoText(.supporting).foregroundColor(.holoPrimary)
        case .habit:
            Button("去习惯") {
                if let habitID = model.state?.plan.payload.resultSource?.sourceID {
                    onOpenLinkedEntity(.habitDetail(habitId: habitID))
                } else {
                    onOpenLinkedEntity(.habits)
                }
            }
            .holoText(.supporting).foregroundColor(.holoPrimary)
        case .manual, .none:
            EmptyView()
        }
    }

    // MARK: - 动作

    private func analyze(forceNew: Bool) async {
        if let messageID = await model.analyze(goal: goal, forceNew: forceNew) {
            openReport(messageID)
        }
    }

    private func openReport(_ messageID: UUID) {
        guard let message = ChatMessageRepository.shared.loadMessageViewData(id: messageID) else {
            model.launchNotice = String(localized: "这份报告已不存在")
            model.load(goal: goal)
            return
        }
        reportMessage = message
    }

    // MARK: - 小件

    private func infoLine(icon: String, text: String) -> some View {
        Label {
            Text(text).holoText(.supporting).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: icon)
        }
        .foregroundColor(.holoToolTextSecondary)
    }

    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

// MARK: - 历史分析

struct GoalReviewHistorySheet: View {
    @Environment(\.dismiss) private var dismiss
    let goalTitle: String
    let entries: [GoalReviewLinkSummary]
    let onOpen: (UUID) -> Void

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    Text("还没有分析记录").holoText(.supporting).foregroundColor(.holoToolTextSecondary)
                }
                ForEach(entries) { entry in
                    Button {
                        if let messageID = entry.reportMessageID, entry.status == .completed || entry.status == .stale {
                            onOpen(messageID)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(GoalAnalysisSection.dayText(entry.completedAt ?? entry.createdAt))
                                    .holoText(.body).foregroundColor(.holoToolText)
                                Spacer()
                                Text(Self.statusText(entry.status))
                                    .holoText(.metadata)
                                    .foregroundColor(entry.status == .completed ? .holoPrimary : .holoToolTextSecondary)
                            }
                            Text("范围 \(GoalAnalysisSection.dayText(entry.windowStart))–\(GoalAnalysisSection.dayText(entry.snapshotCutoffAt))")
                                .holoText(.metadata).foregroundColor(.holoToolTextSecondary)
                            if let reason = entry.failureReason {
                                Text(reason).holoText(.metadata).foregroundColor(.holoToolTextSecondary)
                            }
                        }
                    }
                    .disabled(!(entry.status == .completed || entry.status == .stale) || entry.reportMessageID == nil)
                }
            }
            .listStyle(.plain)
            .navigationTitle("历史分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .holoSheetShell()
    }

    static func statusText(_ status: GoalReviewLinkStatus) -> String {
        switch status {
        case .running: return String(localized: "生成中")
        case .completed: return String(localized: "已完成")
        case .failed: return String(localized: "失败")
        case .cancelled: return String(localized: "已取消")
        case .stale: return String(localized: "依据已变化")
        case .unavailable: return String(localized: "报告已删除")
        }
    }
}

// MARK: - 云端分析需先同意

struct GoalReviewConsentHintSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onGoToAI: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: HoloSpacing.md) {
                Text("目标分析使用 HoloAI 的云端深度分析，需要先在 HoloAI 里同意一次「分析数据上云」。")
                    .holoText(.body)
                Text("同意后回到这里再点「分析目标」即可；原计划不受影响。")
                    .holoText(.supporting)
                    .foregroundColor(.holoToolTextSecondary)
                Spacer()
                Button("去 HoloAI") { dismiss(); onGoToAI() }
                    .buttonStyle(.borderedProminent)
                    .tint(.holoPrimary)
                    .frame(maxWidth: .infinity)
            }
            .padding(HoloSpacing.lg)
            .navigationTitle("需要先同意云端分析")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
        }
        .holoSheetShell()
        .presentationDetents([.medium])
    }
}

extension GoalObservationWindow {
    /// 窗口覆盖的自然日数（展示用）
    var dayCount: Int {
        max(Int((effectiveEndExclusive.timeIntervalSince(start) / 86_400).rounded(.up)), 1)
    }
}
