//
//  DeepLinkState.swift
//  Holo
//
//  Deep Link 状态管理
//  用于通知点击后的导航跳转
//

import Foundation
import Combine

struct FinanceAnalysisDeepLink: Equatable {
    var label: String
    var start: Date
    var end: Date
    var sourceEvidenceID: String?
}

struct FinanceEvidenceReviewDeepLink: Equatable {
    var title: String
    var label: String
    var keyword: String?
    var start: Date
    var end: Date
    var baselineStart: Date?
    var baselineEnd: Date?
    var sourceEvidenceID: String?
}

/// 图片自动记账复核深链的 sheet(item:) 包装（UUID 不满足 Identifiable）
struct ReceiptReviewDeepLinkID: Equatable, Identifiable {
    var id: UUID
}

extension DeepLinkState {
    /// 报告证据「点按核对」→ 账单复核页的统一跳转入口。
    /// 聊天页 / 收藏夹等所有报告入口共用，避免 DeepLink 构造漂移。
    static func openFinanceEvidenceReview(_ drilldown: HoloRenderedFinanceDrilldown) {
        let keyword = drilldown.keyword?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKeyword = keyword?.isEmpty == false ? keyword : nil
        DeepLinkState.shared.navigate(to: .financeEvidenceReview(FinanceEvidenceReviewDeepLink(
            title: normalizedKeyword.map { String(localized: "\($0)数据依据") } ?? String(localized: "财务数据依据"),
            label: drilldown.label,
            keyword: normalizedKeyword,
            start: drilldown.start,
            end: drilldown.end,
            baselineStart: drilldown.baselineStart,
            baselineEnd: drilldown.baselineEnd,
            sourceEvidenceID: drilldown.sourceEvidenceID
        )))
    }
}

/// Deep Link 跳转目标
/// 各模块通过匹配对应 case 决定是否响应跳转
enum DeepLinkTarget: Equatable {
    case ai(voiceInput: Bool)
    /// 跨模块跳转到 AI 对话页，可预填文本（如「就这条问问 Holo」）
    case chat(prefill: String?)
    case taskDetail(taskId: UUID)
    case goalDetail(goalId: UUID)
    case dailyReminder
    case habitDetail(habitId: UUID)
    /// 习惯页（习惯打卡提醒点击进入）
    case habits
    /// 周一晨报：打开今日看板并展示上周小结卡
    case weeklyBrief
    /// 从 AI Chat 卡片跳转到对应模块
    case finance
    case transactionDetail(transactionId: UUID)
    case financeAnalysis(FinanceAnalysisDeepLink)
    case financeEvidenceReview(FinanceEvidenceReviewDeepLink)
    case addTransaction
    case tasks
    case addTask
    case recordThought
    case thoughtDetail(thoughtId: UUID)
    /// 纪念日模块
    case anniversaries
    case anniversaryDetail(anniversaryId: UUID)
    /// 从 AI Chat 卡片跳转到记忆长廊；focusNewMemories=true 时由长廊切到洞察 Tab 并高亮新记忆
    case memoryGallery(focusNewMemories: Bool)
    /// 精准打开指定洞察：由 ChatView 消费，在聊天流直接落成该洞察的回放卡片
    case memoryInsight(insightId: UUID)
    /// 图片自动记账：直达指定待复核项（§25.3，通知点击进入；FinanceView 消费）
    case receiptReview(draftID: UUID)
    /// 图片自动记账：打开最近结果（设置页结果区；FinanceView 消费）
    case receiptBookingResult(resultID: UUID)
}

/// Deep Link 状态管理器
/// 管理通知点击后的待跳转目标，各层视图监听此状态实现自动导航
@MainActor
class DeepLinkState: ObservableObject {

    // MARK: - Singleton

    static let shared = DeepLinkState()

    // MARK: - Published Properties

    /// 待跳转的目标
    /// 设置后，HomeView 会自动打开对应模块，模块内部视图会自动弹出详情页
    @Published var pendingTarget: DeepLinkTarget?

    // MARK: - Navigation

    /// 设置跳转目标
    /// 自动处理连续跳转相同目标的情况：先清空再异步设置，确保 onChange 一定能触发
    func navigate(to target: DeepLinkTarget) {
        if pendingTarget == target {
            // 相同目标：先清空让 onChange 检测到变化，再异步设置新值
            pendingTarget = nil
            DispatchQueue.main.async { [weak self] in
                self?.pendingTarget = target
            }
        } else {
            pendingTarget = target
        }
    }

    func handle(url: URL) {
        guard let widgetTarget = HoloWidgetDeepLink.parse(url) else { return }
        // 权益判断用本地快照（冷启动即从磁盘恢复，弱网不误判），不阻塞在网络刷新上——
        // 否则点小组件拉起 App 后要等最多 30 秒服务端响应才导航；正式权益仍由
        // 冷启动/回前台的既有刷新通道保持准确。
        guard HoloEntitlementState.shared.isPlusActive else {
            // 免费用户点小组件拉起：弹付费墙；无论购买成功（resume）还是直接关闭
            // （onDismiss，深链落点页面本身不需要 Plus），都续跳到目标页，
            // 避免用户关掉付费墙后被丢在首页。
            let navigateToTarget = {
                self.navigate(to: DeepLinkTarget(widgetTarget))
            }
            HoloPlusActionCoordinator.shared.requirePlus(
                context: .desktopWidget,
                resume: navigateToTarget,
                onDismiss: navigateToTarget
            )
            return
        }
        navigate(to: DeepLinkTarget(widgetTarget))
    }

    // MARK: - Initialization

    private init() {}
}

private extension DeepLinkTarget {
    init(_ widgetTarget: HoloWidgetDeepLink) {
        switch widgetTarget {
        case .ai(let voiceInput):
            self = .ai(voiceInput: voiceInput)
        case .addTransaction:
            self = .addTransaction
        case .financeAnalysis:
            // 今日收支小组件 → 财务分析页，默认展示本月概览
            let monthRange = TimeRange.month.dateRange()
            self = .financeAnalysis(FinanceAnalysisDeepLink(
                label: String(localized: "本月收支"),
                start: monthRange.start,
                end: monthRange.end
            ))
        case .recordThought:
            self = .recordThought
        case .addTask:
            self = .addTask
        case .thoughtDetail(let id):
            self = .thoughtDetail(thoughtId: id)
        case .habits:
            self = .habits
        case .tasks:
            self = .tasks
        case .goalDetail(let id):
            self = .goalDetail(goalId: id)
        case .anniversaries:
            self = .anniversaries
        }
    }
}
