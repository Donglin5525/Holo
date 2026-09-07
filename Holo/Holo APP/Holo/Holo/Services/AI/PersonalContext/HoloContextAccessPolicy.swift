//
//  HoloContextAccessPolicy.swift
//  Holo
//
//  通用个人情境的 advice 消费政策（实施方案 §5）。
//
//  - prepareAdviceContext 类查询必须经过这里，不得把 Repository.query(.all) 直接注入聊天。
//  - candidate 与 active 都可读，但仅限 admission == adviceEligible 的载荷；
//    旧 active 查询不会自动使用推断（旧端安全门）。
//  - 敏感/高影响、来源修订过期、存在反证 → 待确认/不可用，不能借 raw fallback 重新推断。
//  - 在途请求携带 generation（用户决策版本+学习基线+控制闸快照），返回前复查，旧结果丢弃。
//  - 「仅作为建议背景」的 candidate 不批量进入「想和你确认的」收件箱。
//
//  纯逻辑，无 App 运行时依赖，可被 standalone 测试直接编译。
//

import Foundation

// MARK: - 选取结果

nonisolated struct HoloContextAdviceCandidate: Equatable, Sendable {
    var recordID: String
    var versionID: String
    var payload: HoloPersonalContextPayloadV1
    /// 推断类建议必须限定表达（「从记录看/可能/目前」），不把概率打印给用户。
    var needsQualifiedExpression: Bool
}

nonisolated enum HoloContextExclusionReason: String, Equatable, Sendable, CaseIterable {
    case notPersonalContext
    case unknownSchemaVersion
    case admissionForbidden
    case admissionUnreviewed
    case admissionConfirmationOnly
    case stateNotUsable
    case userDecisionBlocked
    case sensitivityHold
    case staleSourceRevision
    case contradicted
}

// MARK: - 政策

nonisolated enum HoloContextAccessPolicy {
    /// advice 入口的唯一读取通道：从候选记录集中筛出可作为建议背景的情境。
    /// - Parameter currentSourceRevisions: sourceID → 当前修订摘要；缺项表示来源仍有效未变。
    static func selectAdviceCandidates(
        records: [HoloMemoryRecord],
        currentSourceRevisions: [String: String] = [:]
    ) -> (selected: [HoloContextAdviceCandidate], excluded: [String: HoloContextExclusionReason]) {
        var selected: [HoloContextAdviceCandidate] = []
        var excluded: [String: HoloContextExclusionReason] = [:]

        for record in records {
            guard let envelope = record.personalContext else {
                excluded[record.id] = .notPersonalContext
                continue
            }
            guard let payload = envelope.v1 else {
                excluded[record.id] = .unknownSchemaVersion
                continue
            }
            // 准入：只有程序判定的 adviceEligible 可进建议背景。
            switch payload.admission.level {
            case .forbidden:
                excluded[record.id] = .admissionForbidden
                continue
            case .unreviewed:
                excluded[record.id] = .admissionUnreviewed
                continue
            case .confirmationOnly:
                excluded[record.id] = .admissionConfirmationOnly
                continue
            case .adviceEligible:
                break
            }
            // 状态：非可用态一律不可用（含 disputed：有分歧先不进建议）。
            guard [.candidate, .active].contains(record.state) else {
                excluded[record.id] = .stateNotUsable
                continue
            }
            // 用户控制：新控制胜过旧请求。
            guard ![.rejected, .markedIrrelevant, .forgotten, .corrected].contains(record.userDecision) else {
                excluded[record.id] = .userDecisionBlocked
                continue
            }
            // 敏感/高影响：保持待确认，不能借 raw fallback 重新推断并作为事实使用。
            guard record.sensitivity == .normal else {
                excluded[record.id] = .sensitivityHold
                continue
            }
            // 证据修订：载荷证据指向的来源已被修改/删除 → 不可用（P4 会在失效传播后标记状态，
            // 这里兜底挡住在途竞态）。
            let hasStaleBasis = payload.basis.contains { basis in
                guard let current = currentSourceRevisions[basis.sourceID] else { return false }
                return current != basis.sourceRevision
            }
            guard !hasStaleBasis else {
                excluded[record.id] = .staleSourceRevision
                continue
            }
            guard record.counterEvidenceRefs.isEmpty else {
                excluded[record.id] = .contradicted
                continue
            }

            selected.append(HoloContextAdviceCandidate(
                recordID: record.id,
                versionID: record.versionID,
                payload: payload,
                needsQualifiedExpression: payload.epistemicStatus == .inferred
            ))
        }
        return (selected, excluded)
    }

    /// 「仅作为观察/建议背景」与「真正需要用户决策」的区分：
    /// 前者不批量进入「想和你确认的」收件箱（不打扰原则，§5）。
    static func requiresUserConfirmation(record: HoloMemoryRecord) -> Bool {
        guard let payload = record.personalContext?.v1 else { return false }
        switch payload.admission.level {
        case .adviceEligible:
            // 正常背景候选不需要确认；敏感/高影响仍需。
            return record.sensitivity != .normal
        case .unreviewed, .confirmationOnly, .forbidden:
            return true
        }
    }
}

// MARK: - 在途 generation 校验

/// 请求发出时捕获的权限代际；结果返回/保存前复查，过期即丢弃。
/// 由 userDecisionVersion（用户忘记/清空/纠正都会推进）+ 学习基线 + 控制闸快照组成。
nonisolated struct HoloContextAccessGuard: Codable, Equatable, Sendable {
    var userDecisionVersion: Int64
    var learningBaselineAt: Date?
    var controls: HoloPersonalContextControlSnapshot
    var capturedAt: Date

    init(
        userDecisionVersion: Int64,
        learningBaselineAt: Date?,
        controls: HoloPersonalContextControlSnapshot,
        capturedAt: Date = Date()
    ) {
        self.userDecisionVersion = userDecisionVersion
        self.learningBaselineAt = learningBaselineAt
        self.controls = controls
        self.capturedAt = capturedAt
    }

    /// 结果落库/展示前调用：任一组成变化即视为过期。
    /// - Parameters:
    ///   - currentUserDecisionVersion: 当前控制状态的用户决策版本。
    ///   - currentLearningBaselineAt: 当前学习基线。
    ///   - currentControls: 当前控制闸快照。
    ///   - requiredGate: 本次结果需要的最低能力闸。
    func isStillValid(
        currentUserDecisionVersion: Int64,
        currentLearningBaselineAt: Date?,
        currentControls: HoloPersonalContextControlSnapshot,
        requiredGate: (HoloPersonalContextControlSnapshot) -> Bool = { _ in true }
    ) -> Bool {
        userDecisionVersion == currentUserDecisionVersion
            && learningBaselineAt == currentLearningBaselineAt
            && requiredGate(currentControls)
    }
}
