//
//  HoloMemoryUserControlContract.swift
//  Holo
//
//  用户控制契约（方案《Holo 记忆管理独立与升级》§6 / §11.3 / §11.4）
//
//  纯值类型：管理页发出的控制意图、控制服务返回的结果、落库前的控制事件
//  与并发因果规则。不依赖 Core Data（M03-b 持久化层另行接入），
//  不依赖 UIKit/SwiftUI，可独立单测。
//

import Foundation

// MARK: - 控制动作（§6 操作矩阵）

nonisolated enum HoloMemoryUserControlAction: Equatable, Sendable {
    /// 符合现在的情况
    case confirm
    /// 改一下（修订同一命题；携带新陈述）
    case correct(statement: String)
    /// 已经过时
    case markOutdated
    /// 不准确（判错）
    case markInaccurate(reason: String?)
    /// 不再使用（停用）
    case disable
    /// 恢复 / 重新启用
    case restore
    /// 删除记忆（正文清除，保留最小阻断）
    case forget
    /// 撤销最近一次操作（本身是新的受控写操作）
    indirect case undo(operationID: String)

    var eventKind: HoloMemoryControlEventKind {
        switch self {
        case .confirm: return .confirmed
        case .correct: return .corrected
        case .markOutdated: return .outdated
        case .markInaccurate: return .inaccurate
        case .disable: return .disabled
        case .restore: return .restored
        case .forget: return .forgotten
        case .undo: return .undo
        }
    }
}

// MARK: - 控制请求（§11.3）

/// 结构校验错误。请求由 UI 产生，属于必须校验的外部输入边界。
nonisolated enum HoloMemoryUserControlStructuralError: Equatable, Sendable {
    case emptyOperationID
    case emptyRecordID
    case invalidContentVersion
    case emptyCorrectionStatement
}

nonisolated struct HoloMemoryUserControlRequest: Equatable, Sendable {
    /// 本次意图的幂等标识：重试复用同一 ID，服务端据此去重；
    /// 重新编辑提交才生成新 ID（§11.3）。
    let operationID: String
    let recordID: String
    /// 发起方基于的内容版本；与当前不符即冲突，不静默覆盖。
    let expectedContentVersion: Int
    /// 发起方已见的该记录控制事件集合（因果校验输入；从未见过为空）。
    let knownControlEventIDs: Set<String>
    let action: HoloMemoryUserControlAction
    let issuedAt: Date

    init(
        operationID: String,
        recordID: String,
        expectedContentVersion: Int,
        knownControlEventIDs: Set<String> = [],
        action: HoloMemoryUserControlAction,
        issuedAt: Date
    ) {
        self.operationID = operationID
        self.recordID = recordID
        self.expectedContentVersion = expectedContentVersion
        self.knownControlEventIDs = knownControlEventIDs
        self.action = action
        self.issuedAt = issuedAt
    }

    var structuralError: HoloMemoryUserControlStructuralError? {
        if operationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyOperationID
        }
        if recordID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyRecordID
        }
        if expectedContentVersion <= 0 {
            return .invalidContentVersion
        }
        if case .correct(let statement) = action,
           statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .emptyCorrectionStatement
        }
        return nil
    }
}

// MARK: - 语义预检（投影 allowedActions 是唯一依据）

nonisolated enum HoloMemoryUserControlDenialReason: Equatable, Sendable {
    /// 来源已失效，不能靠确认绕过门禁（§5.1）
    case sourceInvalid
    /// 禁止性推断不可确认
    case prohibitedInference
    /// 决策元数据版本未知，保守拒绝
    case unknownDecisionVersion
    /// 记录已删除/墓碑，不接受任何控制
    case recordRemoved
    /// 该动作在当前桶不可用（携带桶，供 UI 解释）
    case actionNotAvailable(bucket: HoloMemoryManagementBucket)
}

nonisolated enum HoloMemoryUserControlPrecheck: Equatable, Sendable {
    case allowed
    case denied(reason: HoloMemoryUserControlDenialReason)
}

nonisolated enum HoloMemoryUserControlRequestValidator {
    /// 语义预检：动作是否被当前投影允许。投影的 allowedActions 是唯一判据，
    /// 校验器不重复实现桶/状态规则（§11.2 禁止各处自行判断）。
    static func precheck(
        _ request: HoloMemoryUserControlRequest,
        against projection: HoloMemoryManagementProjection
    ) -> HoloMemoryUserControlPrecheck {
        guard request.recordID == projection.recordID else {
            return .denied(reason: .actionNotAvailable(bucket: projection.bucket))
        }
        guard projection.bucket != .removed else {
            return .denied(reason: .recordRemoved)
        }
        guard let requiredAction = request.action.requiredProjectionAction else {
            // undo 不依赖投影动作集：能否撤销由控制链因果规则判定（Algebra）。
            return .allowed
        }
        guard projection.allowedActions.contains(requiredAction) else {
            if projection.unavailableReason == .sourceInvalid {
                return .denied(reason: .sourceInvalid)
            }
            if projection.observingCause == .blockedByPolicy
                || projection.unavailableReason == .blockedByPolicy {
                return .denied(reason: .prohibitedInference)
            }
            if projection.unavailableReason == .unknownDecisionVersion
                || projection.observingCause == .unknownDecisionVersion {
                return .denied(reason: .unknownDecisionVersion)
            }
            return .denied(reason: .actionNotAvailable(bucket: projection.bucket))
        }
        return .allowed
    }
}

extension HoloMemoryUserControlAction {
    /// 除 undo 外，每个动作对应投影中的一个可用操作。
    var requiredProjectionAction: HoloMemoryManagementAction? {
        switch self {
        case .confirm: return .confirm
        case .correct: return .correct
        case .markOutdated: return .markOutdated
        case .markInaccurate: return .markInaccurate
        case .disable: return .disable
        case .restore: return .restore
        case .forget: return .delete
        case .undo: return nil
        }
    }
}

// MARK: - 控制结果（§11.3）

nonisolated enum HoloMemoryUserControlOutcome: Equatable, Sendable {
    /// 已生效：携带新内容版本与可撤销操作 ID（无可撤销性时为 nil）。
    case applied(newContentVersion: Int, undoableOperationID: String?)
    /// 同一 operationID 已生效过（幂等重试），对用户即成功。
    case alreadyApplied
    /// 内容版本或控制头不符：保留草稿，提示查看新版本（§5.2 / A18）。
    case conflict(currentContentVersion: Int)
    case notFound
    case notAllowed(reason: HoloMemoryUserControlDenialReason)
    case persistenceFailed(underlyingDescription: String)

    /// 「保存成功才展示成功」（§2.3 不变量 4）：仅 applied/alreadyApplied 视为成功。
    var isSuccess: Bool {
        switch self {
        case .applied, .alreadyApplied: return true
        case .conflict, .notFound, .notAllowed, .persistenceFailed: return false
        }
    }
}

// MARK: - 控制事件（§11.4，持久化形态由 M03-b 决定）

nonisolated enum HoloMemoryControlEventKind: String, Equatable, CaseIterable, Sendable {
    case confirmed
    case corrected
    case outdated
    case inaccurate
    case disabled
    case restored
    case forgotten
    case undo

    /// 是否限制使用。并发时限制优先（§11.4）。
    var isUsageRestricting: Bool {
        switch self {
        case .outdated, .inaccurate, .disabled, .forgotten:
            return true
        case .confirmed, .corrected, .restored, .undo:
            return false
        }
    }
}

nonisolated struct HoloMemoryUserControlEvent: Equatable, Sendable, Identifiable {
    let id: String
    let targetRecordID: String
    let kind: HoloMemoryControlEventKind
    /// 本事件已见的前序控制事件（直接前驱集合；因果闭包由 Algebra 计算）。
    let priorEventIDs: Set<String>
    let basedOnContentVersion: Int
    let resultingContentVersion: Int
    /// 展示与诊断用；跨设备优先级只由因果关系决定，不比较时间戳（§11.4）。
    let occurredAt: Date
    /// 与请求的幂等标识关联。
    let operationID: String
    /// 变化载荷摘要标识（差异指纹，非正文）；正文差异的存储形态由 M05 决定。
    var payloadDigest: String? = nil
}

// MARK: - 并发因果规则（§11.4）

nonisolated enum HoloMemoryConcurrentControlResolution: Equatable, Sendable {
    /// 限制与放宽并发：限制优先，放宽方需重新校验，不静默覆盖。
    case restrictiveWins(HoloMemoryUserControlEvent)
    /// 两次内容编辑并发：不静默二选一，转「需核对」状态。
    case needsReview([HoloMemoryUserControlEvent])
    /// 同向并发（同限制向/同放宽向且非编辑冲突）：可共存，由服务层按幂等合并。
    case compatible
}

nonisolated enum HoloMemoryControlEventAlgebra {

    /// 因果可见性：later 是否（经 priorEventIDs 传递闭包）见过 earlier。
    /// 闭包需要同记录的全部事件；事件缺失时只按直接前驱判定（保守）。
    static func sees(_ later: HoloMemoryUserControlEvent, earlierID: String,
                     allEvents: [HoloMemoryUserControlEvent]) -> Bool {
        if later.priorEventIDs.contains(earlierID) { return true }
        let byID = Dictionary(allEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var frontier = later.priorEventIDs
        var visited: Set<String> = []
        while let current = frontier.popFirst() {
            guard !visited.contains(current),
                  let event = byID[current] else { continue }
            visited.insert(current)
            if event.priorEventIDs.contains(earlierID) { return true }
            frontier.formUnion(event.priorEventIDs)
        }
        return false
    }

    /// 两事件是否并发（互不在对方因果前驱中）。
    static func isConcurrent(
        _ a: HoloMemoryUserControlEvent,
        _ b: HoloMemoryUserControlEvent,
        allEvents: [HoloMemoryUserControlEvent] = []
    ) -> Bool {
        guard a.targetRecordID == b.targetRecordID, a.id != b.id else { return false }
        return !sees(a, earlierID: b.id, allEvents: allEvents)
            && !sees(b, earlierID: a.id, allEvents: allEvents)
    }

    /// 并发解决（§11.4 契约，规则不可删减）：
    /// 限制优先；两次编辑转需核对；其余同向可共存。
    static func resolveConcurrent(
        _ a: HoloMemoryUserControlEvent,
        _ b: HoloMemoryUserControlEvent
    ) -> HoloMemoryConcurrentControlResolution {
        if a.kind.isUsageRestricting != b.kind.isUsageRestricting {
            return .restrictiveWins(a.kind.isUsageRestricting ? a : b)
        }
        if a.kind == .corrected && b.kind == .corrected {
            return .needsReview([a, b])
        }
        return .compatible
    }

    /// 恢复有效性：恢复/撤销必须基于已见的**全部**限制事件——
    /// 存在它没见过的限制事件时，不能解除该限制（§6.2 / §11.4）。
    static func canLiftRestrictions(
        _ lifting: HoloMemoryUserControlEvent,
        restrictions: [HoloMemoryUserControlEvent]
    ) -> Bool {
        restrictions
            .filter { $0.targetRecordID == lifting.targetRecordID && $0.kind.isUsageRestricting }
            .allSatisfy { lifting.priorEventIDs.contains($0.id) }
    }
}
