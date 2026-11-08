import Foundation

/// 「一个发现」本机服务（v3：权威与状态全部在本机，iCloud 为唯一用户存储）。
///
/// 旧版 Coordinator 的服务端批链路（扫描 → runs → candidates → verify →
/// 八门禁 → 发布）已于 1.1.6 整体退役，服务端 kill switch 已关闭。本类型
/// 实现同一 `DiscoveryService` 协议，供既有 UI（首开弹层 / 设置页 / 胶囊 /
/// 评审页宿主）继续消费：
///
/// - enable / disable：纯本机开关与来源范围（服务端不再确认，无设备租约）；
/// - 发现内容：由 `DiscoveryMemoryReviewService`（记忆萃取复核 + 确定性统计）
///   在评审页内产出，不再有「服务端发布的发现卡」——`currentFinding` 恒 nil；
/// - 评审页三键动作（对，记住 / 不太准确 / 先放一放）直接走
///   `DiscoveryMemoryReviewService.apply`，不经本类型；
/// - 一期胶囊为常驻入口（开启即显示，点击进入评审页看实际状态），
///   「有新内容才亮起」待 1.1.7 观察池与展示队列接入。
@MainActor
final class DiscoveryLocalService: DiscoveryService {

    static let shared = DiscoveryLocalService()

    private init() {}

    // MARK: - 状态（拉取式：开关变化与关键动作后由调用方 refresh）

    private(set) var presentationState: DiscoveryPresentationState = .disabled
    private(set) var settingsDetailState: DiscoverySettingsDetailState = .disabled

    var currentFinding: DiscoveryFindingPresentation? { nil }

    var isDetailPresented: Bool { false }

    // MARK: - 开关（纯本机）

    func enable(selectedDomains: Set<DiscoverySourceDomain>, confirmTakeoverIfOwnedByOtherDevice: Bool) async -> DiscoveryEnableOutcome {
        do {
            try DiscoverySettings.shared.enable(domains: selectedDomains)
        } catch {
            return .noDomainSelected
        }
        HoloProductAnalytics.shared.track(.discoveryEnabled)
        await refresh()
        return .enabled
    }

    func disable() async {
        DiscoverySettings.shared.disable()
        HoloProductAnalytics.shared.track(.discoveryDisabled)
        await refresh()
    }

    // MARK: - 旧发现卡语义（已退役）

    func openFinding() -> DiscoveryFindingPresentation? { nil }

    func submitFeedback(_ action: DiscoveryFeedbackAction) async {
        // 评审页的「不太准确 / 先放一放」由 DiscoveryMemoryReviewService.apply
        // 落库；旧反馈通道随发现卡退役，这里保留协议占位。
    }

    func knowledgeSaveState(for findingID: String) async -> DiscoveryKnowledgeSaveState {
        .notEligible
    }

    func confirmAndRemember(findingID: String, claimID: String) async -> DiscoveryKnowledgeSaveOutcome {
        .notEligible
    }

    func recordMinimalDeference(findingID: String) async {}

    func buildConversationDraft() -> DiscoveryConversationDraft? { nil }

    func resetFeedbackSuppression() async {
        DiscoverySettings.shared.resetAll()
        await refresh()
    }

    // MARK: - 刷新

    func refresh() async {
        let settings = DiscoverySettings.shared
        guard settings.snapshot().isEnabled else {
            presentationState = .disabled
            settingsDetailState = .disabled
            return
        }
        // v3：有待展示的今日卡 → 淡橙胶囊（未看态）；无卡常驻普通胶囊随时可进评审页。
        let hasCard = DiscoveryTopicStore.shared.todayCard() != nil
        presentationState = .available(findingID: Self.reviewEntryID, viewed: !hasCard)
        settingsDetailState = hasCard ? .hasFinding(viewed: false) : .preparing
    }

    /// 评审页入口标识（胶囊点击统一打开评审页，不指向具体发现卡）。
    nonisolated static let reviewEntryID = "memory-review"
}
