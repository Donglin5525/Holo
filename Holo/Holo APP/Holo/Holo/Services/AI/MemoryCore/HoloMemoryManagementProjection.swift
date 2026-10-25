//
//  HoloMemoryManagementProjection.swift
//  Holo
//
//  记忆管理页统一投影（方案《Holo 记忆管理独立与升级》§7.1 / §11.2）
//
//  所有页面、计数、入口对「一条记忆处于什么桶、能用什么操作」的判断唯一入口；
//  禁止各页面自行写 candidate/active/state 判断。
//  纯逻辑：不读存储、不触发萃取、不产生模型调用；now 由调用方注入以便测试边界。
//

import Foundation

// MARK: - 桶与分组

/// 管理视图四桶 + 不展示（删除/墓碑）。删除态不携带正文。
nonisolated enum HoloMemoryManagementBucket: Equatable, Sendable {
    case remembered
    case observing
    case history
    case stopped
    /// 已删除/墓碑：不展示正文，仅供深链解释「为什么不可用」。
    case removed
}

/// 已记住内部分组（方案 §4.1）。仅 remembered 桶有值。
nonisolated enum HoloMemoryManagementTimeGroup: Equatable, Sendable {
    case recent
    case longTerm
}

/// 形成方式标识（方案 §4.4：确认或推断标识）。
nonisolated enum HoloMemoryManagementOrigin: Equatable, Sendable {
    case userConfirmed
    case userCorrected
    case userAdded
    case autoFormed
}

/// 回答使用状态（方案 §7.1：内容分组与使用资格分开表达）。
nonisolated enum HoloMemoryManagementUseLabel: Equatable, Sendable {
    case usableFact
    case referenceOnly
    case notUsedForAnswers
    case conservativelyBlocked
}

/// 适用范围展示（方案 §7.2：区分证据覆盖日期与命题适用期；不虚构到期承诺）。
nonisolated enum HoloMemoryManagementEffectiveRange: Equatable, Sendable {
    case currentPhase
    case longTerm
    case bounded(until: Date)
}

/// 来源可用性（方案 §9.1：展示证据摘要前必须核验来源仍存在、未被排除）。
nonisolated enum HoloMemoryManagementSourceAvailability: Equatable, Sendable {
    case available
    case invalid
    case unknown
}

/// 观察中的具体状态（方案 §4.2：单条必须明确实际是「完全不使用」还是「仅可限定参考」）。
nonisolated enum HoloMemoryManagementObservingCause: Equatable, Sendable {
    case awaitingEvidence
    case conflictPending
    case observeOnly
    case awaitingClarification
    case unknownDecisionVersion
    case blockedByPolicy
}

/// 过去的记忆的具体原因（方案 M04）。
nonisolated enum HoloMemoryManagementHistoryCause: Equatable, Sendable {
    case expired(until: Date)
    case superseded
    case sourceInvalidated
    case archived
}

/// 停用原因（方案 §14.1：存量无法区分时不编造具体原因）。
nonisolated enum HoloMemoryManagementStoppedCause: Equatable, Sendable {
    case userStopped
    case markedInaccurate
    case legacyUnknown
}

// MARK: - 操作与不可用原因

/// 管理操作（方案 §6 操作矩阵）。投影只判定「允许发起」，落库语义由控制服务负责。
nonisolated enum HoloMemoryManagementAction: Equatable, Hashable, Sendable, CaseIterable {
    case confirm
    case correct
    case markOutdated
    case markInaccurate
    case disable
    case restore
    case delete
    case viewSource
}

nonisolated enum HoloMemoryManagementUnavailableReason: Equatable, Sendable {
    case deleted
    case sourceInvalid
    case unknownDecisionVersion
    case blockedByPolicy
}

// MARK: - 输入

/// 投影输入：record 之外的字段由读服务核验后传入（M03 控制事件落地后由事件链提供权威值）。
nonisolated struct HoloMemoryManagementProjectionInput: Sendable {
    var record: HoloMemoryRecord
    /// 该记录是否存在用户控制墓碑（noLongerUse 路径写入；用于区分停用原因）。
    var hasUserControlTombstone: Bool
    /// 证据来源当前可用性（读服务逐证据核验：软删/AI 排除/版本不符 → invalid）。
    var sourceAvailability: HoloMemoryManagementSourceAvailability

    init(
        record: HoloMemoryRecord,
        hasUserControlTombstone: Bool = false,
        sourceAvailability: HoloMemoryManagementSourceAvailability = .unknown
    ) {
        self.record = record
        self.hasUserControlTombstone = hasUserControlTombstone
        self.sourceAvailability = sourceAvailability
    }
}

/// 投影上下文：固定 now 便于测试时区/到期边界；回答总开关只影响使用标注，不改分组。
nonisolated struct HoloMemoryManagementProjectionContext: Equatable, Sendable {
    var now: Date
    var answeringEnabled: Bool

    init(now: Date, answeringEnabled: Bool = true) {
        self.now = now
        self.answeringEnabled = answeringEnabled
    }
}

// MARK: - 投影输出（§11.2 最小契约）

nonisolated struct HoloMemoryManagementProjection: Equatable, Sendable {
    let recordID: String
    let contentVersion: Int
    let bucket: HoloMemoryManagementBucket
    let timeGroup: HoloMemoryManagementTimeGroup?
    /// removed 桶不携带正文，置空串。
    let displayText: String
    let originLabel: HoloMemoryManagementOrigin
    let useLabel: HoloMemoryManagementUseLabel
    /// 「记忆辅助回答」总开关关闭：已记住统一标注暂停使用；分组与生命周期不变。
    let isPausedForAnswering: Bool
    let effectiveRange: HoloMemoryManagementEffectiveRange
    let sourceAvailability: HoloMemoryManagementSourceAvailability
    var observingCause: HoloMemoryManagementObservingCause?
    var historyCause: HoloMemoryManagementHistoryCause?
    var stoppedCause: HoloMemoryManagementStoppedCause?
    let allowedActions: Set<HoloMemoryManagementAction>
    var unavailableReason: HoloMemoryManagementUnavailableReason?
    /// 列表排序键：内容更新时间倒序，相同时按稳定 ID 升序（§4.1）。
    let sortUpdatedAt: Date
    let sortID: String
}

// MARK: - 计数（与列表同一投影，§4.3）

nonisolated struct HoloMemoryManagementProjectionSummary: Equatable, Sendable {
    var remembered = 0
    var observing = 0
    var history = 0
    var stopped = 0
}

// MARK: - 投影计算

extension HoloMemoryManagementProjection {

    /// §7.1 展示优先级（高→低）：删除 → 停用 → 过去（过期/替代/失效/归档）→
    /// 冲突 → 观察 → 已记住 → 未知版本保守。单一函数产出全部展示字段与可用操作。
    static func project(
        _ input: HoloMemoryManagementProjectionInput,
        context: HoloMemoryManagementProjectionContext
    ) -> HoloMemoryManagementProjection {
        let record = input.record
        let now = context.now

        // 优先级 1：删除/忘记已生效——不展示正文（§7.1）。
        if record.state == .deleted || record.state == .tombstoned {
            return HoloMemoryManagementProjection(
                recordID: record.id,
                contentVersion: record.recordVersion,
                bucket: .removed,
                timeGroup: nil,
                displayText: "",
                originLabel: .autoFormed,
                useLabel: .conservativelyBlocked,
                isPausedForAnswering: false,
                effectiveRange: effectiveRange(of: record),
                sourceAvailability: input.sourceAvailability,
                observingCause: nil,
                historyCause: nil,
                stoppedCause: nil,
                allowedActions: [],
                unavailableReason: .deleted,
                sortUpdatedAt: record.updatedAt,
                sortID: record.id
            )
        }

        // 优先级 2：用户停用/判错（§7.1）。原因由墓碑有无区分（M03 后由控制事件提供权威值；
        // 读服务无法判定时传 legacyUnknown，界面标「此前已停用」，不编造原因）。
        if record.state == .suppressed {
            let cause: HoloMemoryManagementStoppedCause
            if input.hasUserControlTombstone {
                cause = .userStopped
            } else if record.userDecision == .rejected {
                cause = .markedInaccurate
            } else {
                cause = .legacyUnknown
            }
            return HoloMemoryManagementProjection(
                recordID: record.id,
                contentVersion: record.recordVersion,
                bucket: .stopped,
                timeGroup: nil,
                displayText: record.displaySummary,
                originLabel: originLabel(of: record),
                useLabel: .notUsedForAnswers,
                isPausedForAnswering: false,
                effectiveRange: effectiveRange(of: record),
                sourceAvailability: input.sourceAvailability,
                observingCause: nil,
                historyCause: nil,
                stoppedCause: cause,
                allowedActions: [.restore, .delete],
                unavailableReason: nil,
                sortUpdatedAt: record.updatedAt,
                sortID: record.id
            )
        }

        // 优先级 3：过期、被替代、来源失效、归档 → 过去的记忆（读取时立即判定，§7.2）。
        let historyCause = historyCauseIfAny(of: record, sourceAvailability: input.sourceAvailability, now: now)
        if record.state == .archived || record.state == .superseded || record.state == .invalidated
            || input.sourceAvailability == .invalid || historyCause != nil {
            let cause: HoloMemoryManagementHistoryCause
            if record.state == .superseded {
                cause = .superseded
            } else if record.state == .invalidated || input.sourceAvailability == .invalid {
                cause = .sourceInvalidated
            } else if let historyCause {
                cause = historyCause
            } else {
                cause = .archived
            }
            let viewSource: Set<HoloMemoryManagementAction> =
                input.sourceAvailability == .invalid ? [] : [.viewSource]
            return HoloMemoryManagementProjection(
                recordID: record.id,
                contentVersion: record.recordVersion,
                bucket: .history,
                timeGroup: nil,
                displayText: record.displaySummary,
                originLabel: originLabel(of: record),
                useLabel: .notUsedForAnswers,
                isPausedForAnswering: false,
                effectiveRange: effectiveRange(of: record),
                sourceAvailability: input.sourceAvailability,
                observingCause: nil,
                historyCause: cause,
                stoppedCause: nil,
                allowedActions: viewSource.union([.correct, .disable, .delete]),
                unavailableReason: input.sourceAvailability == .invalid ? .sourceInvalid : nil,
                sortUpdatedAt: record.updatedAt,
                sortID: record.id
            )
        }

        // 优先级 4：未解决冲突 → 观察中「信息有变化」（§7.3）。
        if record.state == .disputed {
            return observingProjection(
                input, context: context,
                cause: .conflictPending,
                useLabel: .notUsedForAnswers,
                unavailableReason: nil
            )
        }

        // 优先级 5：候选 → 观察中（不默认进入审批流程，§4.2）。
        if record.state == .candidate {
            return observingProjection(
                input, context: context,
                cause: .awaitingEvidence,
                useLabel: .notUsedForAnswers,
                unavailableReason: nil
            )
        }

        // 优先级 6/7：active 按决策元数据分派；无信封的存量记录回退 state 口径，
        // 信封存在但不可读（未知版本）保守进观察并阻断确认（§11.4 未知版本保守不使用）。
        let envelope = record.decisionMetadata
        if envelope == nil {
            return rememberedProjection(input, context: context, useLabel: .usableFact, unavailableReason: nil)
        }
        guard let decision = envelope?.v2 else {
            return observingProjection(
                input, context: context,
                cause: .unknownDecisionVersion,
                useLabel: .conservativelyBlocked,
                unavailableReason: .unknownDecisionVersion
            )
        }

        // 未完成澄清的 askWhenRelevant 不进普通回答（§4.2）。
        if decision.attentionPolicy == .askWhenRelevant && decision.clarification != nil {
            return observingProjection(
                input, context: context,
                cause: .awaitingClarification,
                useLabel: .notUsedForAnswers,
                unavailableReason: nil
            )
        }

        switch decision.useLevel {
        case .factEligible:
            return rememberedProjection(input, context: context, useLabel: .usableFact, unavailableReason: nil)
        case .qualifiedAdvice:
            return rememberedProjection(input, context: context, useLabel: .referenceOnly, unavailableReason: nil)
        case .observeOnly:
            return observingProjection(
                input, context: context,
                cause: .observeOnly,
                useLabel: .notUsedForAnswers,
                unavailableReason: nil
            )
        case .blocked:
            // 禁止性推断：不展示为正常内容，也不提供「符合」绕过（§5.1）。
            return observingProjection(
                input, context: context,
                cause: .blockedByPolicy,
                useLabel: .conservativelyBlocked,
                unavailableReason: .blockedByPolicy
            )
        case .unrecognized:
            return observingProjection(
                input, context: context,
                cause: .unknownDecisionVersion,
                useLabel: .conservativelyBlocked,
                unavailableReason: .unknownDecisionVersion
            )
        }
    }

    // MARK: 列表排序与计数（§4.1 / §4.3：计数与列表同一投影）

    /// 组内排序：内容更新时间倒序；相同时间按稳定 ID 升序。
    /// 使用统计（usageCount/lastUsedAt）不参与排序，也不改变 updatedAt。
    static func isInOrder(
        _ lhs: HoloMemoryManagementProjection,
        before rhs: HoloMemoryManagementProjection
    ) -> Bool {
        if lhs.sortUpdatedAt != rhs.sortUpdatedAt {
            return lhs.sortUpdatedAt > rhs.sortUpdatedAt
        }
        return lhs.sortID < rhs.sortID
    }

    static func summarize(
        _ projections: [HoloMemoryManagementProjection]
    ) -> HoloMemoryManagementProjectionSummary {
        var summary = HoloMemoryManagementProjectionSummary()
        for projection in projections {
            switch projection.bucket {
            case .remembered: summary.remembered += 1
            case .observing: summary.observing += 1
            case .history: summary.history += 1
            case .stopped: summary.stopped += 1
            case .removed: break
            }
        }
        return summary
    }

    // MARK: - 私有构件

    private static func rememberedProjection(
        _ input: HoloMemoryManagementProjectionInput,
        context: HoloMemoryManagementProjectionContext,
        useLabel: HoloMemoryManagementUseLabel,
        unavailableReason: HoloMemoryManagementUnavailableReason?
    ) -> HoloMemoryManagementProjection {
        let record = input.record
        let viewSource: Set<HoloMemoryManagementAction> =
            input.sourceAvailability == .invalid ? [] : [.viewSource]
        return HoloMemoryManagementProjection(
            recordID: record.id,
            contentVersion: record.recordVersion,
            bucket: .remembered,
            timeGroup: timeGroup(of: record),
            displayText: record.displaySummary,
            originLabel: originLabel(of: record),
            useLabel: useLabel,
            isPausedForAnswering: !context.answeringEnabled,
            effectiveRange: effectiveRange(of: record),
            sourceAvailability: input.sourceAvailability,
            observingCause: nil,
            historyCause: nil,
            stoppedCause: nil,
            allowedActions: viewSource.union([.correct, .markOutdated, .markInaccurate, .disable, .delete]),
            unavailableReason: unavailableReason,
            sortUpdatedAt: record.updatedAt,
            sortID: record.id
        )
    }

    private static func observingProjection(
        _ input: HoloMemoryManagementProjectionInput,
        context: HoloMemoryManagementProjectionContext,
        cause: HoloMemoryManagementObservingCause,
        useLabel: HoloMemoryManagementUseLabel,
        unavailableReason: HoloMemoryManagementUnavailableReason?
    ) -> HoloMemoryManagementProjection {
        let record = input.record
        var actions: Set<HoloMemoryManagementAction> = [.correct, .markInaccurate, .disable, .delete]
        if input.sourceAvailability != .invalid {
            actions.insert(.viewSource)
            // 不能确认的情况：来源失效、禁止性推断、未知版本（§5.1）。
            if cause != .blockedByPolicy && cause != .unknownDecisionVersion {
                actions.insert(.confirm)
            }
        }
        return HoloMemoryManagementProjection(
            recordID: record.id,
            contentVersion: record.recordVersion,
            bucket: .observing,
            timeGroup: nil,
            displayText: record.displaySummary,
            originLabel: originLabel(of: record),
            useLabel: useLabel,
            isPausedForAnswering: false,
            effectiveRange: effectiveRange(of: record),
            sourceAvailability: input.sourceAvailability,
            observingCause: cause,
            historyCause: nil,
            stoppedCause: nil,
            allowedActions: actions,
            unavailableReason: unavailableReason ?? (input.sourceAvailability == .invalid ? .sourceInvalid : nil),
            sortUpdatedAt: record.updatedAt,
            sortID: record.id
        )
    }

    /// 过期判定：validTo（命题适用期）优先于 expiresAt（系统复核）。
    private static func historyCauseIfAny(
        of record: HoloMemoryRecord,
        sourceAvailability: HoloMemoryManagementSourceAvailability,
        now: Date
    ) -> HoloMemoryManagementHistoryCause? {
        if let validTo = record.validTo, validTo < now {
            return .expired(until: validTo)
        }
        if let expiresAt = record.expiresAt, expiresAt < now {
            return .expired(until: expiresAt)
        }
        if sourceAvailability == .invalid {
            return .sourceInvalidated
        }
        return nil
    }

    /// §4.1：用户指定的更窄范围（有界适用期）优先；未知不猜成长期。
    private static func timeGroup(of record: HoloMemoryRecord) -> HoloMemoryManagementTimeGroup {
        if case .bounded = effectiveRange(of: record) {
            return .recent
        }
        switch record.persistenceClass {
        case .currentState, .phase:
            return .recent
        case .durable, .permanentFact:
            return .longTerm
        }
    }

    private static func effectiveRange(of record: HoloMemoryRecord) -> HoloMemoryManagementEffectiveRange {
        if let validTo = record.validTo {
            return .bounded(until: validTo)
        }
        if let expiresAt = record.expiresAt {
            return .bounded(until: expiresAt)
        }
        switch record.persistenceClass {
        case .currentState, .phase:
            return .currentPhase
        case .durable, .permanentFact:
            return .longTerm
        }
    }

    private static func originLabel(of record: HoloMemoryRecord) -> HoloMemoryManagementOrigin {
        if record.userDecision == .corrected {
            return .userCorrected
        }
        if record.userDecision == .confirmed {
            return .userConfirmed
        }
        if let adoption = record.adoptionMetadata, adoption.disposition == .userConfirmed {
            return .userConfirmed
        }
        switch record.decisionMetadata?.v2?.sourceAuthority {
        case .explicitMemoryRequest:
            return .userAdded
        case .explicitUserStatement:
            return .userConfirmed
        default:
            return .autoFormed
        }
    }
}
