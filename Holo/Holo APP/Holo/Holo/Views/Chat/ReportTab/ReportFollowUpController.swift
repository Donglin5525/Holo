//
//  ReportFollowUpController.swift
//  Holo
//
//  报告详情页的「报告内追问」控制器：
//  把详情页输入条的文字接上既有 continuation 锚点链路（不弹回对话页），
//  并维护本报告的追问记录（按 lineage.parentResultID 挂载的子报告）。
//
//  发送复用 ChatViewModel.sendMessage 全链路——额度预检、取消、落库、
//  聊天页同步呈现都走同一套，不另起炉灶。
//

import Foundation
import Combine

@MainActor
final class ReportFollowUpController: ObservableObject {
    typealias ReportArchiveDTO = ChatMessageRepository.ReportArchiveDTO

    enum Phase: Equatable {
        case idle
        /// 追问已发送、正在生成
        case running
        /// 追问失败（可重试）；文案面向用户
        case failed(String)
    }

    // MARK: - 状态

    @Published private(set) var followUps: [ReportArchiveDTO] = []
    @Published private(set) var phase: Phase = .idle
    /// 生成中的追问问题（进行中卡片展示）
    @Published private(set) var runningQuestion: String?
    /// 生成中的追问消息快照（状态文案与聊天卡同源，不虚构进度）
    @Published private(set) var runningMessage: ChatMessageViewData?
    /// 输入条草稿（失败/取消后保留，改完可重发）
    @Published var draftText = ""

    let parentResult: HoloRenderedAgentResult

    private let chatViewModel: ChatViewModel?
    private let repository = ChatMessageRepository.shared
    private var cancellables: Set<AnyCancellable> = []
    /// 我们发起的追问正在等消息流落定
    private var awaitingSettlement = false
    /// 进入页面时聊天里已有在途分析（非本页发起）；落定后静默刷新追问记录
    private var observingExternalAnalysis = false

    // MARK: - 初始化

    init(parentResult: HoloRenderedAgentResult, chatViewModel: ChatViewModel?) {
        self.parentResult = parentResult
        self.chatViewModel = chatViewModel

        // 消息流派生落定检测（与报告 Tab 红点同款手法）：
        // streaming 的 query_analysis 出现→消失 即一次分析落定。
        chatViewModel?.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] messages in
                self?.handleMessagesUpdate(messages)
            }
            .store(in: &cancellables)
    }

    // MARK: - 派生

    /// 详情页是否具备追问能力：父结果有可追溯身份才能锚定血统，
    /// 且发送需要活的 ChatViewModel（走它的全链路）。
    var canFollowUp: Bool {
        chatViewModel != nil
            && parentResult.agentJobID != nil
            && parentResult.agentResultID != nil
    }

    /// 深度洞察池剩余额度；nil = 状态未知（不显示数字，发送仍可尝试）
    var quotaRemaining: Int? {
        HoloEntitlementState.shared.quotas["deepAnalysis"]?.remaining
    }

    // MARK: - 追问记录

    func loadFollowUps() async {
        guard let parentResultID = parentResult.agentResultID else { return }
        followUps = await repository.loadFollowUpReportsAsync(parentResultID: parentResultID)
    }

    // MARK: - 发送 / 取消 / 重试

    func sendDraft() {
        let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, phase != .running else { return }
        send(text: text)
    }

    func retryLast(text: String) {
        guard phase != .running else { return }
        send(text: text)
    }

    private func send(text: String) {
        guard canFollowUp, let chatViewModel else { return }
        chatViewModel.startContinuation(from: parentResult)
        chatViewModel.inputText = text
        draftText = text
        runningQuestion = text
        awaitingSettlement = true
        phase = .running
        Task { await chatViewModel.sendMessage() }
    }

    func cancelRunning() {
        chatViewModel?.cancelStreaming()
        // 落定回调会把 userCancelled 消息归为「回到 idle」；这里先恢复输入态，
        // 草稿保留在 draftText 里等用户改。
    }

    // MARK: - 落定检测

    private func handleMessagesUpdate(_ messages: [ChatMessageViewData]) {
        let streaming = messages.last(where: { $0.isQueryAnalysis && $0.isStreaming })
        runningMessage = streaming

        if awaitingSettlement {
            guard streaming == nil,
                  let settled = messages.last(where: { $0.isQueryAnalysis && !$0.isStreaming })
            else { return }
            awaitingSettlement = false
            runningQuestion = nil
            applySettlement(settled)
            return
        }

        // 外部在途分析（从聊天页发起的追问）：出现时记账、消失时刷新记录
        if streaming != nil {
            observingExternalAnalysis = true
        } else if observingExternalAnalysis {
            observingExternalAnalysis = false
            Task { await loadFollowUps() }
        }
    }

    private func applySettlement(_ message: ChatMessageViewData) {
        // 用户主动取消：不算失败，回输入态（草稿还在）
        if message.messageType == .userCancelled {
            phase = .idle
            return
        }
        // 发送前预检拦截：额度耗尽落专属卡片（无 agentResult）
        if message.isQuotaExhausted {
            phase = .failed(HoloQuotaError.deepAnalysisExhaustedMessage(
                isPlusActive: HoloEntitlementState.shared.isPlusActive
            ))
            return
        }
        if let failure = message.agentResult?.failure {
            switch failure {
            case .quotaExhausted(let userMessage):
                phase = .failed(userMessage)
            case .continuationUnavailable(let userMessage):
                phase = .failed(userMessage)
            case .analysisFailed:
                phase = .failed("这次追问没能完成，可能是网络中断。点「重试」原样再问一次，不消耗额外额度。")
            case .executionSuspended:
                phase = .failed("系统收回了后台执行时间，这次追问中断了。点「重试」接着问。")
            }
            return
        }
        // 成功：新报告落库，追问记录刷新
        phase = .idle
        draftText = ""
        Task { await loadFollowUps() }
    }
}
