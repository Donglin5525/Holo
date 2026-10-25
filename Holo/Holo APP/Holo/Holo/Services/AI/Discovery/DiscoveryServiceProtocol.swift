//
//  DiscoveryServiceProtocol.swift
//  Holo
//
//  「一个发现」UI 面向的服务协议：视图层唯一依赖面。
//  实现方 DiscoveryCoordinator（G6）；UI（G5）只消费本协议，不触网络/store/协调细节。
//  状态语义对齐实施包 01 §1 的九行状态表。
//

import Foundation

/// 胶囊/设置子页共用的呈现状态（01 §1）。
enum DiscoveryPresentationState: Sendable, Equatable {
    case disabled                    // 默认未开启：无胶囊；设置「已关闭，可开启」
    case preparing                   // 首次确认后：无胶囊；设置「正在准备」
    case waitingForMaterial          // 材料不足/无合格候选：无胶囊；设置「有足够依据时再呈现」
    case available(findingID: String, viewed: Bool)   // 淡橙胶囊（未看）/普通胶囊（已看）
    case temporarilyUnavailable      // 网络失败/预算不足：旧内容可读否则无胶囊
    case serverUnsupported           // 后端不支持：无胶囊；开关不可完成开启
}

/// 设置页用的详情文案状态（与胶囊状态同源，描述更细）。
enum DiscoverySettingsDetailState: Sendable, Equatable {
    case disabled
    case preparing
    case waitingForMaterial
    case hasFinding(viewed: Bool)
    case stale                      // 等待新的线索
    case pausedTemporarily          // 暂未更新，不催用户重试
    case revoked                    // 授权已撤回
    case serverUnsupported
}

/// 反馈动作（01 §3 反馈表；幂等，连续点击不重复写入）。
enum DiscoveryFeedbackAction: Sendable, Equatable {
    case accurate                   // 有点像：回执，不弹任务不写长期记忆
    case inaccurate(reason: DiscoveryInaccurateReason)
    case manageDismiss              // 关闭/退出：无数据后果
}

enum DiscoveryInaccurateReason: Sendable, Equatable {
    case wrongEvidence              // 依据不对：撤销候选并检查取数
    case wrongUnderstanding         // 理解不对：抑制同主题同含义
    case notApplicableNow           // 现在不适用：标时效失效
    case notInterested              // 不想看这类：持续抑制该类别，可恢复
}

/// UI 消费的发现内容（payload + 依据可跳转信息）。
struct DiscoveryFindingPresentation: Sendable, Equatable {
    let findingID: String
    let title: String
    let body: [String]
    let citations: [DiscoveryPublishedPayload.Citation]
    /// 展示引用（对齐回原文的精确子串；evidenceID → 展示文本）。
    let displayQuotes: [String: String]
    let coverageNote: String
    let timeRangeText: String
    let publishedAt: Date
    let expiresAt: Date
    let viewed: Bool
    /// 「限制/反例」是否存在改变解释的反例（正文必须已体现边界）。
    let hasCounterEvidenceNote: Bool
}

// 注：协议不标 @MainActor——Xcode 26.2 工具链对「MainActor 隔离协议的存在类型」在
// 默认 MainActor 隔离工程下混淆崩溃（canonicalizeProtocols/ASTMangler EXC_BAD_ACCESS，
// swift-frontend .ips 2026-10-23 实证）。实现方（DiscoveryCoordinator）与全部调用方
// 均为 MainActor 上下文，隔离约束由实现侧保证。
protocol DiscoveryService: AnyObject {
    /// 胶囊与设置子页状态（单一事实源；撤权/失效立即变化）。
    var presentationState: DiscoveryPresentationState { get }
    var settingsDetailState: DiscoverySettingsDetailState { get }
    var currentFinding: DiscoveryFindingPresentation? { get }
    /// 正在展示详情（打开中不被新结果替换；撤权/失效立即关闭）。
    var isDetailPresented: Bool { get }

    /// 首次开启流程（01 §5）：检查登录与 capability → 全局授权（缺失时引导）→
    /// 来源范围选择 → 同意并开启（服务端确认+单设备租约）→ 本机保存并排队。
    /// 任一步取消/失败保持关闭；范围至少一类；返回 false=未开启。
    func enable(selectedDomains: Set<DiscoverySourceDomain>, confirmTakeoverIfOwnedByOtherDevice: Bool) async -> DiscoveryEnableOutcome

    /// 关闭流程（01 §5）：本机先关（递增代数→隐藏→取消任务→删派生数据）→
    /// 服务端禁用；离线保留待提交意图，确认前不再发材料。
    func disable() async

    /// 点击胶囊 → 返回当前有效发现（过期/失效返回 nil 并即时撤下）。
    func openFinding() -> DiscoveryFindingPresentation?

    /// 反馈（幂等）。inaccurate 立即撤下并返回可选原因收集后续。
    func submitFeedback(_ action: DiscoveryFeedbackAction) async

    /// 「聊聊这个」：构建携带发现上下文的可编辑草稿（不自动发送；显示对象与来源范围）。
    func buildConversationDraft() -> DiscoveryConversationDraft?

    /// 恢复/重置本功能反馈（设置子页「已隐藏的发现」管理入口）。
    func resetFeedbackSuppression() async

    /// 刷新状态（前台激活/通知到达时轻量调用）。
    func refresh() async
}

enum DiscoveryEnableOutcome: Sendable, Equatable {
    case enabled
    case cancelled                   // 用户取消/任一步失败保持关闭
    case needsGlobalConsent          // 缺全局授权，UI 先引导授权
    case needsTakeoverConfirmation(ownerDeviceID: String)   // 他设备占用，需用户确认接管
    case serverUnsupported
    case noDomainSelected
}

/// 续聊草稿：发现上下文最小化（来源重核、边界保留、用户最新表达优先——02 续聊约束）。
struct DiscoveryConversationDraft: Sendable, Equatable {
    let findingTitle: String
    let findingSummary: String
    let sourceScopeDescription: String
    /// 建议预填的草稿文本（用户可编辑；不自动发送）。
    let suggestedDraftText: String
    let findingID: String
}
