//
//  DiscoveryAccessPolicy.swift
//  Holo
//
//  「HoloAI 一个发现」统一门控纯逻辑（02 §1 DiscoveryAccessPolicy / §9.2 冻结检查）。
//
//  六个检查位：读源前 / candidates 前 / verify 前 / 提交前 / 展示前 / 续聊前。
//  全部输入（时钟、设置、授权快照、控制代数、预算）由调用方注入；
//  对接现有机制：
//  · 全局授权：HoloAIDataProcessingConsent（键 holo_ai_dataProcessingConsentGranted，Models/AI/HoloAICapability.swift）
//  · 功能设置：DiscoverySettings（holo.discovery.*）
//  · 想法域记录级排除：ThoughtAIAudience（用户关联标签 excludeFromAI），G2 适配器取数谓词必须叠加
//  纯 Foundation + CoreData；不 import UIKit。
//

import Foundation
import CoreData

// MARK: - 决定

/// 门控结论：allow，或 deny + 诊断原因码（不向用户展示为错误代码）
struct DiscoveryAccessDecision: Equatable, Sendable {
    let isAllowed: Bool
    let deniedReason: DiscoveryAccessDeniedReason?

    static let allowed = DiscoveryAccessDecision(isAllowed: true, deniedReason: nil)

    static func denied(_ reason: DiscoveryAccessDeniedReason) -> DiscoveryAccessDecision {
        DiscoveryAccessDecision(isAllowed: false, deniedReason: reason)
    }
}

/// 门控拒绝原因（内部诊断用，不直接展示给用户）
enum DiscoveryAccessDeniedReason: String, Equatable, Sendable, CaseIterable {
    /// 功能未开启（默认关闭，首次明确同意）
    case featureDisabled
    /// HoloAI 数据总授权未授予或已撤回
    case globalConsentMissing
    /// 授权范围为空（至少选择一类来源）
    case emptyScope
    /// 该来源域不在用户选择的范围内
    case domainNotGranted
    /// 冻结的 localGrantEpoch 已过期（关闭→重开/注销递增）
    case grantEpochStale
    /// 服务端控制快照不可用/未拉取
    case serverControlUnavailable
    /// 服务端控制代数已变化
    case serverControlChanged
    /// 授权范围摘要已变化
    case scopeChanged
    /// 当日自动批次预算耗尽
    case budgetExhausted
    /// 运行阶段与该检查位不符
    case runStateInvalid
    /// 提交时有显示句未获 supported 核验
    case verificationIncomplete
    /// 无有效发布发现
    case findingUnavailable
    /// 发现已过期（14 天初值，每次展示前检查）
    case findingExpired
    /// 依赖来源已失效（删除/排除/版本变化）
    case sourceInvalidated
    /// 用户已否定该主题（HMAC 指纹命中）
    case userRejected
}

// MARK: - 环境快照

/// 门控环境的纯值快照。测试与生产（.live）都构造这份值，策略不做任何 I/O。
struct DiscoveryAccessSnapshot: Equatable, Sendable {
    var now: Date
    /// 真源：HoloAIDataProcessingConsent（holo_ai_dataProcessingConsentGranted）
    var isGlobalConsentGranted: Bool
    var settings: DiscoverySettingsSnapshot
    /// 服务端控制代数；nil = 未拉到有效控制快照（capability 不可用同样拒绝）
    var serverControlRevision: Int?
    /// 当日剩余自动批次预算（V1 两档会员均每日最多 1）
    var dailyAutoBatchBudgetRemaining: Int

    init(
        now: Date = Date(),
        isGlobalConsentGranted: Bool = true,
        settings: DiscoverySettingsSnapshot = DiscoverySettingsSnapshot(
            isEnabled: true,
            allowedDomains: [.thought],
            localGrantEpoch: 1
        ),
        serverControlRevision: Int? = 1,
        dailyAutoBatchBudgetRemaining: Int = 1
    ) {
        self.now = now
        self.isGlobalConsentGranted = isGlobalConsentGranted
        self.settings = settings
        self.serverControlRevision = serverControlRevision
        self.dailyAutoBatchBudgetRemaining = dailyAutoBatchBudgetRemaining
    }
}

extension DiscoveryAccessSnapshot {
    /// 生产快照：实时读取全局授权（HoloAIDataProcessingConsent）与功能设置（DiscoverySettings）。
    /// 控制代数与预算由 G3 网络层/调度器传入（来源分别是 DiscoveryStore 控制快照与成本闸）。
    static func live(
        now: Date = Date(),
        serverControlRevision: Int?,
        dailyAutoBatchBudgetRemaining: Int
    ) -> DiscoveryAccessSnapshot {
        DiscoveryAccessSnapshot(
            now: now,
            isGlobalConsentGranted: HoloAIDataProcessingConsent.shared.isGranted,
            settings: DiscoverySettings.shared.snapshot(),
            serverControlRevision: serverControlRevision,
            dailyAutoBatchBudgetRemaining: dailyAutoBatchBudgetRemaining
        )
    }
}

// MARK: - 展示/续聊的发现状态

/// 展示前/续聊前检查位需要的发现当前状态（由调用方从 DiscoveryStore 读出后组装）
struct DiscoveryFindingDisplayState: Equatable, Sendable {
    var status: DiscoveryFindingStatus
    var expiresAt: Date
    /// 该发现主题的否定指纹是否命中（DiscoveryStore.hasNegativeFeedback）
    var subjectNegativeFeedbackHit: Bool
    /// 依赖来源是否全部仍有效（DiscoveryStore 失效依赖查询为空）
    var dependenciesValid: Bool
}

// MARK: - 范围摘要

/// 授权范围确定性摘要（进入 DiscoveryRunFreeze.scopeRevision）。
/// 范围变化 ⇒ 摘要变化 ⇒ 冻结比对失败 ⇒ 拒绝提交（02 §9.2）。
enum DiscoveryScopeRevision {
    static func digest(domains: Set<DiscoverySourceDomain>) -> String {
        DiscoveryContentDigest.sourceRevision(
            from: ["discovery.scope.v1"] + domains.map(\.rawValue).sorted()
        )
    }
}

// MARK: - 门控策略

/// 六检查位统一门控。无状态纯逻辑，可任意构造测试。
struct DiscoveryAccessPolicy: Sendable {

    // MARK: 检查位 1：读源前

    /// 读取任何来源数据之前（适配器取数入口）。
    /// 想法域还必须叠加记录级排除：谓词由 thoughtDomainAIRestrictedPredicate 提供。
    func canReadSources(domain: DiscoverySourceDomain, environment: DiscoveryAccessSnapshot) -> DiscoveryAccessDecision {
        if let denied = baselineCheck(environment) {
            return denied
        }
        guard environment.settings.allowedDomains.contains(domain) else {
            return .denied(.domainNotGranted)
        }
        return .allowed
    }

    /// 想法域的记录级 AI 可见口径（用户关联标签排除，ThoughtAIAudience）。
    /// G2 想法适配器的 fetch 谓词必须与它求交；任务/习惯域无对应机制。
    nonisolated static var thoughtDomainAIRestrictedPredicate: NSPredicate {
        ThoughtAIAudience.aiVisiblePredicate()
    }

    // MARK: 检查位 2：candidates 前

    /// 发起候选生成调用之前。核对：基线 + 冻结代数仍有效 + 控制快照可用 + 当日预算未耗尽。
    func canRequestCandidates(
        frozenGrantEpoch: Int,
        environment: DiscoveryAccessSnapshot
    ) -> DiscoveryAccessDecision {
        if let denied = baselineCheck(environment) {
            return denied
        }
        if let denied = epochCheck(frozenGrantEpoch, environment: environment) {
            return denied
        }
        guard environment.serverControlRevision != nil else {
            return .denied(.serverControlUnavailable)
        }
        guard environment.dailyAutoBatchBudgetRemaining >= 1 else {
            return .denied(.budgetExhausted)
        }
        return .allowed
    }

    // MARK: 检查位 3：verify 前

    /// 发起独立核验调用之前。核对：基线 + 冻结代数 + 运行阶段处于 preparing（候选与反例已就绪）。
    func canRequestVerification(
        runPhase: DiscoveryRunPhase,
        frozenGrantEpoch: Int,
        environment: DiscoveryAccessSnapshot
    ) -> DiscoveryAccessDecision {
        if let denied = baselineCheck(environment) {
            return denied
        }
        if let denied = epochCheck(frozenGrantEpoch, environment: environment) {
            return denied
        }
        guard runPhase == .preparing else {
            return .denied(.runStateInvalid)
        }
        return .allowed
    }

    // MARK: 检查位 4：提交前

    /// 本地发布提交之前。核对：基线 + 冻结十三字段中可本地比对的四项
    /// （localGrantEpoch / serverControlRevision / scopeRevision）+ 核验全 supported。
    /// （anchorNow/manifest 等 freezing 其余字段的归属校验在 G3 网络层与 G4 发布策略执行。）
    func canCommit(
        freeze: DiscoveryRunFreeze,
        allDisplayedClaimsSupported: Bool,
        environment: DiscoveryAccessSnapshot
    ) -> DiscoveryAccessDecision {
        if let denied = baselineCheck(environment) {
            return denied
        }
        if let denied = epochCheck(freeze.localGrantEpoch, environment: environment) {
            return denied
        }
        guard let currentControlRevision = environment.serverControlRevision else {
            return .denied(.serverControlUnavailable)
        }
        guard currentControlRevision == freeze.serverControlRevision else {
            return .denied(.serverControlChanged)
        }
        guard DiscoveryScopeRevision.digest(domains: environment.settings.allowedDomains) == freeze.scopeRevision else {
            return .denied(.scopeChanged)
        }
        guard allDisplayedClaimsSupported else {
            return .denied(.verificationIncomplete)
        }
        return .allowed
    }

    // MARK: 检查位 5：展示前

    /// 展示当前发现之前（每次展示执行，含过期检查，02 §9.3）。
    func canDisplay(
        finding: DiscoveryFindingDisplayState,
        environment: DiscoveryAccessSnapshot
    ) -> DiscoveryAccessDecision {
        if let denied = baselineCheck(environment) {
            return denied
        }
        guard finding.status == .published || finding.status == .viewed else {
            return .denied(.findingUnavailable)
        }
        guard environment.now <= finding.expiresAt else {
            return .denied(.findingExpired)
        }
        guard finding.dependenciesValid else {
            return .denied(.sourceInvalidated)
        }
        guard !finding.subjectNegativeFeedbackHit else {
            return .denied(.userRejected)
        }
        return .allowed
    }

    // MARK: 检查位 6：续聊前

    /// 就当前发现继续对话之前。续聊会把材料交外部 AI：总授权为硬前提，
    /// 发现必须仍有效（过期/失效/已否定一律拒绝，让用户重新等待新批次）。
    func canContinueConversation(
        finding: DiscoveryFindingDisplayState,
        environment: DiscoveryAccessSnapshot
    ) -> DiscoveryAccessDecision {
        guard environment.isGlobalConsentGranted else {
            return .denied(.globalConsentMissing)
        }
        guard environment.settings.isEnabled else {
            return .denied(.featureDisabled)
        }
        return canDisplay(finding: finding, environment: environment)
    }

    // MARK: - 私有公共检查

    /// 基线三查：总授权 → 功能开启 → 范围非空。任一失败返回 deny。
    private func baselineCheck(_ environment: DiscoveryAccessSnapshot) -> DiscoveryAccessDecision? {
        guard environment.isGlobalConsentGranted else {
            return .denied(.globalConsentMissing)
        }
        guard environment.settings.isEnabled else {
            return .denied(.featureDisabled)
        }
        guard !environment.settings.allowedDomains.isEmpty else {
            return .denied(.emptyScope)
        }
        return nil
    }

    /// 冻结代数比对：关闭→重开/注销后旧代数全部作废
    private func epochCheck(_ frozenEpoch: Int, environment: DiscoveryAccessSnapshot) -> DiscoveryAccessDecision? {
        guard frozenEpoch == environment.settings.localGrantEpoch else {
            return .denied(.grantEpochStale)
        }
        return nil
    }
}
