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
    case disabled                    // 默认未开启：无胶囊；设置页显示已关闭
    case preparing                   // 首次确认后：无胶囊；设置页显示正在准备
    case waitingForMaterial          // 材料不足/无合格候选：无胶囊；设置页显示还在等足够的记录
    case available(findingID: String, viewed: Bool)   // 淡橙胶囊（未看）/普通胶囊（已看）
    case temporarilyUnavailable      // 网络失败/预算不足：旧内容可读否则无胶囊
    case serverUnsupported           // 后端不支持：无胶囊；开关不可完成开启
}

/// 设置页用的详情文案状态（与胶囊状态同源，描述更细）。
/// 1.1.5：原 waitingForMaterial 同时承载「材料不够」与「整理过了但没有合格的」，
/// 原 pausedTemporarily 承载所有失败——用户分不清「坏了」还是「太严」。现拆为：
/// waitingForMaterial（真材料不够）/ checkedNoFinding（整理过、无合格）/ failed（没整理成功）。
enum DiscoverySettingsDetailState: Sendable, Equatable {
    case disabled
    case preparing
    case waitingForMaterial
    case checkedNoFinding(checkedAt: Date)          // 整理过了，没有足够可靠的发现
    case hasFinding(viewed: Bool)
    case stale                      // 等待新的线索
    case failed(reason: DiscoveryLastOutcome.FailureReason, retry: DiscoveryLastOutcome.Retry)   // 没整理成功
    case revoked                    // 授权已撤回
    case serverUnsupported
}

/// 最近一次整理的结局（本机持久化，重启不丢；只存结局类别与时刻，不存任何记录内容）。
nonisolated struct DiscoveryLastOutcome: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case noFinding          // 跑完了：没有候选 / 本地、核验或发布环节全部未通过
        case failed             // 没跑完：网络、服务或当日次数原因
    }
    enum FailureReason: String, Codable, Sendable {
        case network            // 网络不可用
        case service            // 服务繁忙或出错（超时、截断、上游失败等）
        case dailyLimit         // 当日整理次数已用完
    }
    enum Retry: String, Codable, Sendable {
        case soon               // 之后会自动再试（同日）
        case tomorrow           // 明天自动再试
    }

    let kind: Kind
    let at: Date
    let failureReason: FailureReason?
    let retry: Retry?

    static func noFinding(at date: Date) -> DiscoveryLastOutcome {
        DiscoveryLastOutcome(kind: .noFinding, at: date, failureReason: nil, retry: nil)
    }

    static func failed(_ reason: FailureReason, retry: Retry, at date: Date) -> DiscoveryLastOutcome {
        DiscoveryLastOutcome(kind: .failed, at: date, failureReason: reason, retry: retry)
    }
}

/// 反馈动作（01 §3 反馈表；幂等，连续点击不重复写入）。
enum DiscoveryFeedbackAction: Sendable, Equatable {
    case accurate                   // 有点像：回执，不弹任务不写长期记忆
    case inaccurate(reason: DiscoveryInaccurateReason)
    case manageDismiss              // 关闭/退出：无数据后果
}

enum DiscoveryInaccurateReason: String, Sendable, Equatable {
    case wrongEvidence              // 依据不对：撤销候选并检查取数
    case wrongUnderstanding         // 理解不对：抑制同主题同含义
    case notApplicableNow           // 现在不适用：标时效失效
    case notInterested              // 不想看这类：持续抑制该类别，可恢复
}

/// UI 消费的发现内容（旧服务端发现卡遗留形状；v3 起恒为 nil，仅供协议签名兼容）。
struct DiscoveryFindingPresentation: Sendable, Equatable {
    let findingID: String
    let title: String
    let body: [String]
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
    /// 任一步取消/失败保持关闭；范围至少一类；失败返回可呈现的具体原因。
    func enable(selectedDomains: Set<DiscoverySourceDomain>, confirmTakeoverIfOwnedByOtherDevice: Bool) async -> DiscoveryEnableOutcome

    /// 关闭流程（01 §5）：本机先关（递增代数→隐藏→取消任务→删派生数据）→
    /// 服务端禁用；离线保留待提交意图，确认前不再发材料。
    func disable() async

    /// 点击胶囊 → 返回当前有效发现（过期/失效返回 nil 并即时撤下）。
    func openFinding() -> DiscoveryFindingPresentation?

    /// 反馈（幂等）。inaccurate 立即撤下并返回可选原因收集后续。
    func submitFeedback(_ action: DiscoveryFeedbackAction) async

    // MARK: 记忆联动（融合契约 §4–§6；v2.2 §6.1）

    /// 详情页内联区域的状态：未达门槛不显示保存按钮；成熟显示准确待保存理解；已保存显示「已记住」。
    /// 只读准确关联的保存/限制元数据，不触发全文检索、历史补建或模型调用。
    func knowledgeSaveState(for findingID: String) async -> DiscoveryKnowledgeSaveState

    /// 一次「确认并记住」：只提交界面明示的那条理解及其范围；复用统一知识控制事务与 operationID；
    /// 保存成功才回执，失败不显示成功。自动学习关闭时属一次手动保存，不开启自动学习。
    func confirmAndRemember(findingID: String, claimID: String) async -> DiscoveryKnowledgeSaveOutcome

    /// 「暂时不说」：最低限度不打扰记录（不构成认可/否定；与记忆推荐区共用冷却）。
    func recordMinimalDeference(findingID: String) async

    /// 「聊聊这个」：构建携带发现上下文的可编辑草稿（不自动发送；显示对象与来源范围）。
    func buildConversationDraft() -> DiscoveryConversationDraft?

    /// 恢复/重置本功能反馈（设置子页「已隐藏的发现」管理入口）。
    func resetFeedbackSuppression() async

    /// 刷新状态（前台激活/通知到达时轻量调用）。
    func refresh() async
}

enum DiscoveryEnableOutcome: Sendable, Equatable {
    case enabled
    case cancelled                   // 用户取消
    case failed(DiscoveryEnableFailure)
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
