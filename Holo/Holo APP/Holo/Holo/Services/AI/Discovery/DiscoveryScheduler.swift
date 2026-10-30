//
//  DiscoveryScheduler.swift
//  Holo
//
//  「一个发现」调度纯逻辑（实施包 03 §4.3 dirty 与资格、§4.4 失败与退避）。
//  决策核心零系统依赖（时钟/资源/资格全部注入）；OS 触碰（热状态/电量/前台事件）
//  由 Coordinator 通过闭包供给，此处不 import UIKit。
//

import Foundation

/// 来源变更登记。三域适配器把「实质变化」折算成 mark；
/// 仅查看、同步相同版本、改展示设置不得产生 mark（03 §4.3）。
nonisolated struct DiscoveryDirtyMark: Sendable, Equatable {
    let domain: DiscoverySourceDomain
    let changedAt: Date
    /// 参与判断的内容摘要增量（同一来源改回原样不累积新材料）。
    let digestContribution: String
}

/// noFinding / 模型拒绝的成功终态记录：材料不变次日不再跑（03 §4.4、T20）。
nonisolated struct DiscoveryProcessedRecord: Sendable, Equatable {
    let sourceManifestDigest: String
    let processedAt: Date
    /// policyVersion/promptVersion 变化可安排一次受控重评估；同版本不重跑。
    let policyVersion: Int
    let promptVersion: Int
}

/// 资源与环境快照（Coordinator 采集；纯逻辑只读判断）。
nonisolated struct DiscoveryResourceSnapshot: Sendable, Equatable {
    var isTextInputActive = false
    var isRecording = false
    var isManualAIRunning = false
    var isThermallyConstrained = false
    var isLowPowerMode = false
    var isLowDataMode = false
    var isNetworkAvailable = true

    var shouldYield: Bool {
        isTextInputActive || isRecording || isManualAIRunning
            || isThermallyConstrained || isLowPowerMode || isLowDataMode
    }
}

/// 调度决策。
nonisolated enum DiscoveryScheduleDecision: Sendable, Equatable {
    /// 现在可以准备（含原因快照，供日志/状态机）。
    case prepare(now: Date)
    /// 推迟（资源让位/静默窗未到/网络不可用且未 dispatch 等）。
    case deferred(DiscoveryDeferredReason)
    /// 材料不足，等待新记录（不消耗批次、不报「生成中」）。
    case waitingForMaterial
    /// 控制不合法：立即停止并隐藏（账号/撤权/范围失效）。
    case stopAndHide(DiscoveryStopReason)
}

nonisolated enum DiscoveryDeferredReason: Sendable, Equatable {
    case silenceWindow(remaining: TimeInterval)
    case resourceYield
    case networkUnavailable
    case dailyBudgetExhausted(resetAt: Date?)
    case alreadyProcessedToday
    case leaseActive
}

nonisolated enum DiscoveryStopReason: Sendable, Equatable {
    case disabledLocally
    case controlDisabled
    case consentWithdrawn
    case scopeInvalid
}

/// 调度决策核心。所有阈值可注入（首发初值先测再调，不做用户设置项）。
nonisolated final class DiscoverySchedulerCore {

    struct Thresholds: Sendable {
        /// 有效来源变更后的静默窗（03 §4.3 初值 15 分钟）。
        var silenceWindow: TimeInterval = 15 * 60
        /// 尝试生成前的最小独立可定位材料数（初值 2）。
        var minimumIndependentAnchors = 2
        init() {}
    }

    let thresholds: Thresholds

    init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    /// 主决策。
    /// - Parameters:
    ///   - marks: 未消费的来源变更（含静默窗内最新时刻）。
    ///   - qualification: 当前可独立定位材料数（由证据构建器计数，不是段数）。
    ///   - isFirstEnableAfterGrant: 首次开启的受限历史准备（无需等新增记录）。
    ///   - dailyBatchAvailable: 服务端当日批次是否可用（capability/control 拉取结果）。
    ///   - budgetResetAt: 后台总预算不足时的服务端 resetAt（不轮询撞 429）。
    ///   - processedToday: 今日已成功终态（noFinding/rejected）的记录。
    ///   - controlEnabled: 本机许可+服务端控制均有效。
    func decide(
        marks: [DiscoveryDirtyMark],
        qualification: Int,
        isFirstEnableAfterGrant: Bool,
        controlEnabled: Bool,
        consentGranted: Bool,
        scopeValid: Bool,
        dailyBatchAvailable: Bool,
        budgetResetAt: Date?,
        processedToday: DiscoveryProcessedRecord?,
        currentSourceManifestDigest: String?,
        policyVersion: Int,
        promptVersion: Int,
        resource: DiscoveryResourceSnapshot,
        now: Date
    ) -> DiscoveryScheduleDecision {
        // 控制链先于一切：撤权/关闭立即停，不进入任何等待（03 §5 检查位 1）
        guard controlEnabled else { return .stopAndHide(.controlDisabled) }
        guard consentGranted else { return .stopAndHide(.consentWithdrawn) }
        guard scopeValid else { return .stopAndHide(.scopeInvalid) }

        // 资格：首开受限历史准备 或 有未消费的实质变更
        let hasFreshMaterial = marks.contains { mark in
            now.timeIntervalSince(mark.changedAt) >= 0
        }
        if !isFirstEnableAfterGrant {
            guard hasFreshMaterial else { return .waitingForMaterial }
            // 静默窗：以最新变更时刻起算
            if let latest = marks.map(\.changedAt).max(),
               now.timeIntervalSince(latest) < thresholds.silenceWindow {
                return .deferred(.silenceWindow(
                    remaining: thresholds.silenceWindow - now.timeIntervalSince(latest)
                ))
            }
        }
        // 独立材料门槛（首开也要满足：无材料不消耗批次）
        guard qualification >= thresholds.minimumIndependentAnchors else {
            return .waitingForMaterial
        }
        // 材料未变不重跑（T20：同 digest 的 noFinding/拒绝，版本升级除外）
        if let processed = processedToday,
           let digest = currentSourceManifestDigest,
           processed.sourceManifestDigest == digest,
           processed.policyVersion == policyVersion,
           processed.promptVersion == promptVersion {
            return .deferred(.alreadyProcessedToday)
        }
        // 资源让位（03 §4.3：输入/录音/手动 AI/热/低电/低数据延后；网络不可用且未 dispatch 等待）
        if resource.shouldYield { return .deferred(.resourceYield) }
        if !resource.isNetworkAvailable { return .deferred(.networkUnavailable) }
        // 预算：后台总预算不足遵循服务端 resetAt；日批次不可用同样推迟到次日
        if let resetAt = budgetResetAt, resetAt > now {
            return .deferred(.dailyBudgetExhausted(resetAt: resetAt))
        }
        guard dailyBatchAvailable else { return .deferred(.dailyBudgetExhausted(resetAt: nil)) }

        return .prepare(now: now)
    }

    /// 失败后的下一次尝试资格（03 §4.4 退避表）。
    /// - Parameter attempt: 连续失败次数（从 0 起），仅网络退避使用阶梯。
    /// 返回 nil = 本日不再尝试（保守终态）。
    func nextAttemptAfterFailure(
        failure: DiscoveryFailureKind,
        now: Date,
        attempt: Int = 0
    ) -> Date? {
        switch failure {
        case .networkUnavailablePreDispatch:
            // 未 dispatch：保持 dirty，有限退避阶梯（5/15/45 分钟，封顶 45），不报「生成中」
            let ladder: [TimeInterval] = [5 * 60, 15 * 60, 45 * 60]
            let interval = ladder[min(attempt, ladder.count - 1)]
            return now.addingTimeInterval(interval)
        case .schemaRejectedByModel, .semanticRejected:
            // 同材料不隔天重跑（digest 已记为已处理）；等新材料再来
            return nil
        case .stageResultLost, .upstreamErrorPostDispatch, .leaseExpired:
            // 本阶段不重复调用，本批终止；下一资格=次日新批次（由日批次闸控制）
            return nil
        case .budgetExceeded:
            // 采用服务端 resetAt；无 resetAt 时保守等 6 小时
            return now.addingTimeInterval(6 * 3600)
        }
    }
}

nonisolated enum DiscoveryFailureKind: Sendable {
    case networkUnavailablePreDispatch
    case schemaRejectedByModel
    case semanticRejected
    case stageResultLost
    case upstreamErrorPostDispatch
    case leaseExpired
    case budgetExceeded
}

/// 前台激活轻量检查的结果：只安排 utility 优先级任务，不阻塞主线程（03 §4.3）。
nonisolated enum DiscoveryForegroundCheckOutcome: Sendable {
    case scheduleUtilityCheck
    case skip
}
