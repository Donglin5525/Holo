//
//  ReportDetailRoute.swift
//  Holo
//
//  报告详情的统一入口：按消息形态分流（深度分析 → 叙事详情 + 报告内追问；
//  周期回放 → 阅读版）。报告 Tab / 收藏夹 / 聊天流分析卡共用，
//  保证任何入口进来的报告都有同一套阅读与追问体验。
//
//  追问记录里的子报告经由本路由递归打开——每层详情自带自己的追问控制器，
//  链式钻取（子报告页里可以继续追问），深度由血统滚动机制自然封顶。
//

import SwiftUI

struct ReportDetailRoute: View {
    let message: ChatMessageViewData
    /// 追问能力（发送走 ChatViewModel 全链路）。nil 时深度分析详情不显示追问条。
    let chatViewModel: ChatViewModel?
    /// 财务证据深链（回账单复核页）；入口方不具备跳转条件时传 nil。
    var onFinanceDrilldown: ((HoloRenderedFinanceDrilldown) -> Void)? = nil
    /// 详情关闭/子详情返回时回调（收藏夹用它刷新列表计数）。
    var onDismiss: () -> Void = {}

    @StateObject private var followUpController: ReportFollowUpController

    /// 子报告详情（追问记录条目点开）。
    @State private var childMessage: ChatMessageViewData?

    init(
        message: ChatMessageViewData,
        chatViewModel: ChatViewModel?,
        onFinanceDrilldown: ((HoloRenderedFinanceDrilldown) -> Void)? = nil,
        onDismiss: @escaping () -> Void = {}
    ) {
        self.message = message
        self.chatViewModel = chatViewModel
        self.onFinanceDrilldown = onFinanceDrilldown
        self.onDismiss = onDismiss
        _followUpController = StateObject(wrappedValue: ReportFollowUpController(
            parentResult: message.agentResult ?? ReportDetailRoute.fallbackResult,
            chatViewModel: chatViewModel
        ))
    }

    var body: some View {
        Group {
            if let result = message.agentResult {
                AgentDeepAnalysisDetailSheet(
                    result: result,
                    onFinanceDrilldown: onFinanceDrilldown,
                    askedAt: message.timestamp,
                    followUpController: followUpController.canFollowUp ? followUpController : nil,
                    onOpenFollowUpReport: { entry in
                        // DTO 行点击 → 完整消息快照（含完整分析结果）再进子详情
                        childMessage = ChatMessageRepository.shared.loadMessageViewData(id: entry.id)
                    }
                )
                .safeAreaInset(edge: .bottom) {
                    // 目标闭环 §2.3：目标报告展示关联目标，可返回目标详情 / 进入修正单；非目标报告不渲染
                    if let scope = result.goalScope {
                        GoalReportLinkBar(scope: scope, draft: result.goalAdjustmentDraft, reportMessageID: message.id)
                    }
                }
                .fullScreenCover(item: $childMessage) { child in
                    ReportDetailRoute(
                        message: child,
                        chatViewModel: chatViewModel,
                        onFinanceDrilldown: onFinanceDrilldown
                    )
                    .holoContentColumn()
                }
            } else {
                ReportReplayReaderView(message: message)
            }
        }
        .onDisappear {
            onDismiss()
        }
    }
}

/// 报告详情底部的关联目标条（目标报告专用）：同一 reportMessageID 两入口共用，
/// 「打开目标」走现有 .goalDetail 深链，「查看调整」进入差异确认单（确认前不改任何对象）。
struct GoalReportLinkBar: View {
    @Environment(\.dismiss) private var dismiss
    let scope: HoloAgentGoalScope
    let draft: GoalAdjustmentDraftV2?
    let reportMessageID: UUID
    @State private var adjustmentContext: GoalAdjustmentReviewContext?
    @State private var notice: String?

    private var goal: Goal? { GoalRepository.shared.findGoal(by: scope.goalID) }

    var body: some View {
        HStack(spacing: HoloSpacing.sm) {
            Image(systemName: "target").foregroundColor(.holoPrimary)
            VStack(alignment: .leading, spacing: 2) {
                Text(goal?.title ?? String(localized: "关联目标已删除"))
                    .holoText(.supporting)
                    .fontWeight(.semibold)
                    .foregroundColor(.holoToolText)
                    .lineLimit(1)
                Text(Self.revisionText(revisionID: scope.planRevisionID))
                    .holoText(.metadata)
                    .foregroundColor(.holoToolTextSecondary)
            }
            Spacer(minLength: 0)
            if goal != nil {
                if draft != nil, HoloAIFeatureFlags.goalClosedLoopEnabled {
                    Button("查看调整") { openAdjustment() }
                        .buttonStyle(.bordered)
                        .holoText(.supporting)
                        .accessibilityIdentifier("report.goal.openAdjustment")
                }
                Button("打开目标") {
                    dismiss()
                    DeepLinkState.shared.navigate(to: .goalDetail(goalId: scope.goalID))
                }
                .buttonStyle(.borderedProminent)
                .tint(.holoPrimary)
                .holoText(.supporting)
                .accessibilityIdentifier("report.goal.open")
            }
        }
        .padding(.horizontal, HoloSpacing.lg)
        .padding(.vertical, HoloSpacing.sm)
        .background(Color.holoToolSurface)
        .overlay(alignment: .top) { Divider() }
        .sheet(item: $adjustmentContext) { context in
            GoalAdjustmentReviewSheet(context: context) {}
        }
        .alert("暂不能查看调整", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private func openAdjustment() {
        guard let goal, let draft else { return }
        do {
            let state = try GoalReviewCoordinator.shared.loadState(goal: goal)
            if state.isAdjustmentStale || state.plan.revisionID != draft.baseRevisionID {
                notice = String(localized: "依据或计划已变化，这份调整建议需要重新分析后再确认。")
                return
            }
            adjustmentContext = GoalAdjustmentReviewContext(goal: goal, draft: draft, state: state)
        } catch let error as GoalPlanResolveError {
            notice = GoalReviewCoordinator.describe(error)
        } catch {
            notice = error.localizedDescription
        }
    }

    static func revisionText(revisionID: UUID) -> String {
        if let row = GoalPlanRevisionStore.revisionRow(id: revisionID, in: CoreDataStack.shared.viewContext) {
            return String(localized: "按计划第 \(row.revisionNumber) 版分析")
        }
        return String(localized: "分析所依据的计划版本已不存在")
    }
}

private extension ReportDetailRoute {
    /// agentResult 缺失的消息不会进详情（路由入口已保证）；此处仅满足 StateObject
    /// 非 nil 初值，canFollowUp 为 false 时 UI 不显示追问条，不会被触发。
    static let fallbackResult: HoloRenderedAgentResult = HoloRenderedAgentResult(
        title: "", summary: "", sections: [], evidenceReferences: []
    )
}
