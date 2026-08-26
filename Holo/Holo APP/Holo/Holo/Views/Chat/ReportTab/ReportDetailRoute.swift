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
                    followUpController: followUpController.canFollowUp ? followUpController : nil,
                    onOpenFollowUpReport: { entry in
                        // DTO 行点击 → 完整消息快照（含完整分析结果）再进子详情
                        childMessage = ChatMessageRepository.shared.loadMessageViewData(id: entry.id)
                    }
                )
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

private extension ReportDetailRoute {
    /// agentResult 缺失的消息不会进详情（路由入口已保证）；此处仅满足 StateObject
    /// 非 nil 初值，canFollowUp 为 false 时 UI 不显示追问条，不会被触发。
    static let fallbackResult: HoloRenderedAgentResult = HoloRenderedAgentResult(
        title: "", summary: "", sections: [], evidenceReferences: []
    )
}
