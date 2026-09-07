//
//  ContextAccessStandaloneTests.swift
//  HoloTests
//
//  P2 权限与失效验证：advice 准入矩阵、敏感/高影响拦停、修订过期、
//  忘记改写重生拦截、同来源不同命题不误伤、跨设备键一致、历史基线/在途代际校验、
//  确认队列不打扰。standalone 运行见 scripts/run-personal-context-standalone.sh。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try ContextAccessStandaloneTests.main()
    }
}
#endif
struct ContextAccessStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        try testAdviceAdmissionMatrix()
        try testSensitivityAndStateHold()
        try testStaleSourceRevisionExcluded()
        try testForgetResurrectionBlockedNewContextID()
        try testSameSourceDifferentPropositionNotSuppressed()
        try testCrossDeviceSpanKeyConsistent()
        testAccessGuardDetectsVersionAndBaselineChange()
        testAccessGuardDetectsGateChange()
        try testConfirmationQueueNotSpammed()
        print("ContextAccessStandaloneTests: \(assertionCount) 断言全部通过")
    }

    // MARK: 工厂

    static func record(
        id: String = "r-1",
        statement: String = "用户的父亲被要求低盐饮食",
        admission: HoloContextAdmissionLevel = .adviceEligible,
        epistemicStatus: HoloContextEpistemicStatus = .declared,
        state: HoloMemoryState = .candidate,
        userDecision: HoloMemoryUserDecision = .none,
        sensitivity: HoloMemorySensitivity = .normal,
        basisSourceID: String = "thought-1",
        basisRevision: String = "rev-1",
        counterEvidence: [HoloMemoryEvidenceRef] = []
    ) throws -> HoloMemoryRecord {
        let payload = HoloPersonalContextPayloadV1(
            contextID: "99999999-0000-0000-0000-\(id.padding(toLength: 12, withPad: "0", startingAt: 0))",
            statement: statement,
            subjects: [HoloContextPartyRef(label: "父亲", scope: .person)],
            relationText: "被要求低盐饮食",
            epistemicStatus: epistemicStatus,
            basis: [HoloContextBasisRef(
                sourceID: basisSourceID,
                sourceRevision: basisRevision
            )],
            admission: HoloContextAdmissionV1(
                level: admission,
                policyVersion: 1,
                decidedAt: Date(timeIntervalSince1970: 1_780_000_000)
            )
        )
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: payload.contextAnchorValue)
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: .thought,
            sourceDomains: [.thought],
            subjectKey: "个人情境",
            anchorRefs: [anchor],
            claimKind: .observedFact,
            persistenceClass: .durable,
            displaySummary: statement,
            aiUseSummary: statement,
            prohibitedInferences: [],
            evidenceRefs: [],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: counterEvidence,
            confidenceScore: 0.5,
            freshnessScore: 0.5,
            scoringVersion: 1,
            scoreComputedAt: Date(timeIntervalSince1970: 1_780_000_000),
            extractorVersion: 1,
            promptVersion: 1,
            state: state,
            sensitivity: sensitivity,
            userDecision: userDecision,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            personalContext: HoloPersonalContextPayloadEnvelope(v1: payload)
        )
    }

    // MARK: 用例

    /// 准入矩阵：adviceEligible 过；unreviewed/confirmationOnly/forbidden 各自被挡。
    /// inferred 过但要求限定表达。
    static func testAdviceAdmissionMatrix() throws {
        let eligible = try record(id: "r-ok")
        let inferred = try record(id: "r-inf", epistemicStatus: .inferred)
        let unreviewed = try record(id: "r-un", admission: .unreviewed)
        let confirmOnly = try record(id: "r-cf", admission: .confirmationOnly)
        let forbidden = try record(id: "r-fb", admission: .forbidden)
        let plain = try record(id: "r-plain")  // 无载荷对照
        var noPayload = plain
        noPayload.personalContext = nil

        let result = HoloContextAccessPolicy.selectAdviceCandidates(
            records: [eligible, inferred, unreviewed, confirmOnly, forbidden, noPayload]
        )
        expect(result.selected.map(\.recordID) == ["r-ok", "r-inf"], "只有 adviceEligible 载荷可进建议背景")
        expect(result.selected.first { $0.recordID == "r-inf" }?.needsQualifiedExpression == true,
               "推断类建议必须限定表达")
        expect(result.selected.first { $0.recordID == "r-ok" }?.needsQualifiedExpression == false,
               "declared 不要求推断限定")
        expect(result.excluded["r-un"] == .admissionUnreviewed, "未审核被挡")
        expect(result.excluded["r-cf"] == .admissionConfirmationOnly, "仅待确认被挡")
        expect(result.excluded["r-fb"] == .admissionForbidden, "禁止使用被挡")
        expect(result.excluded["r-plain"] == .notPersonalContext, "无载荷记录跳过")
    }

    /// 敏感/高影响/失效态/用户拒绝：全部拦停。
    static func testSensitivityAndStateHold() throws {
        let sensitive = try record(id: "r-sen", sensitivity: .sensitive)
        let highImpact = try record(id: "r-hi", sensitivity: .highImpact)
        let invalidated = try record(id: "r-inv", state: .invalidated)
        let forgotten = try record(id: "r-fg", userDecision: .forgotten)
        let rejected = try record(id: "r-rj", userDecision: .rejected)
        let irrelevant = try record(id: "r-mi", userDecision: .markedIrrelevant)
        let contradicted = try record(
            id: "r-ct",
            counterEvidence: [HoloMemoryEvidenceRef(
                id: "ce-1",
                kind: .explicitUserStatement,
                sourceDomain: .thought,
                lineageKey: "thought-lineage",
                sourceID: "thought-9",
                revisionDigest: "rev-1",
                observedAt: Date(timeIntervalSince1970: 1_790_000_000)
            )]
        )
        let active = try record(id: "r-act", state: .active)

        let result = HoloContextAccessPolicy.selectAdviceCandidates(
            records: [sensitive, highImpact, invalidated, forgotten, rejected, irrelevant, contradicted, active]
        )
        expect(result.selected.map(\.recordID) == ["r-act"], "只有正常 active/candidate 可用")
        expect(result.excluded["r-sen"] == .sensitivityHold, "敏感拦停")
        expect(result.excluded["r-hi"] == .sensitivityHold, "高影响拦停")
        expect(result.excluded["r-inv"] == .stateNotUsable, "失效态拦停")
        expect(result.excluded["r-fg"] == .userDecisionBlocked, "被遗忘拦停")
        expect(result.excluded["r-rj"] == .userDecisionBlocked, "被拒绝拦停")
        expect(result.excluded["r-mi"] == .userDecisionBlocked, "标无关拦停")
        expect(result.excluded["r-ct"] == .contradicted, "存在反证先不进建议")
    }

    /// 证据修订过期：来源已改，依赖旧修订的情境不可用。
    static func testStaleSourceRevisionExcluded() throws {
        let fresh = try record(id: "r-fresh", basisRevision: "rev-2")
        let stale = try record(id: "r-stale", basisRevision: "rev-1")
        let unknownSource = try record(id: "r-unk", basisSourceID: "thought-other")

        let result = HoloContextAccessPolicy.selectAdviceCandidates(
            records: [fresh, stale, unknownSource],
            currentSourceRevisions: ["thought-1": "rev-2"]
        )
        expect(result.selected.map(\.recordID) == ["r-fresh", "r-unk"],
               "修订一致可过；来源修订表缺项视为未变")
        expect(result.excluded["r-stale"] == .staleSourceRevision, "修订过期被挡")
    }

    /// 忘记改写重生：换 contextID 重新萃取同一命题（同来源同修订）被墓碑拦截。
    static func testForgetResurrectionBlockedNewContextID() throws {
        let forgotten = try record(id: "r-gone", statement: "用户的父亲被要求低盐饮食")
        // 模拟 forget() 写入的墓碑：anchor + span 键。
        let anchorKeys = HoloMemoryIdentity.canonicalAnchors(forgotten.anchorRefs).map(\.stableKey)
            + HoloContextSuppressionKeys.spanKeys(for: forgotten.personalContext!.v1!)
        let tombstone = HoloMemoryTombstone(
            identityKey: forgotten.id,
            scope: forgotten.scope,
            claimKind: forgotten.claimKind,
            anchorKeys: anchorKeys,
            userDecisionVersion: 100,
            createdAt: Date(timeIntervalSince1970: 1_780_000_100)
        )
        // 新 contextID、同一命题、同一来源修订的重生候选。
        let reborn = try record(id: "r-new", statement: "用户的父亲被要求低盐饮食")
        expect(HoloSemanticTombstoneMatcher.matches(tombstone: tombstone, record: reborn),
               "换 contextID 重生同一命题必须被拦截")
    }

    /// 同来源不同命题不误伤：忘掉「低盐」不压制同文的「母亲晕车」。
    static func testSameSourceDifferentPropositionNotSuppressed() throws {
        let forgotten = try record(id: "r-gone", statement: "用户的父亲被要求低盐饮食")
        let anchorKeys = HoloMemoryIdentity.canonicalAnchors(forgotten.anchorRefs).map(\.stableKey)
            + HoloContextSuppressionKeys.spanKeys(for: forgotten.personalContext!.v1!)
        let tombstone = HoloMemoryTombstone(
            identityKey: forgotten.id,
            scope: forgotten.scope,
            claimKind: forgotten.claimKind,
            anchorKeys: anchorKeys,
            userDecisionVersion: 100,
            createdAt: Date(timeIntervalSince1970: 1_780_000_100)
        )
        let other = try record(id: "r-other", statement: "用户的母亲晕车，不适应山路汽车")
        expect(!HoloSemanticTombstoneMatcher.matches(tombstone: tombstone, record: other),
               "同来源不同命题不得被一刀切压制")
        // 来源修订变化后的重生（用户改过原文）：首版不压制（保守放过，交由语义校验层）。
        let editedSource = try record(id: "r-edit", statement: "用户的父亲被要求低盐饮食", basisRevision: "rev-9")
        expect(!HoloSemanticTombstoneMatcher.matches(tombstone: tombstone, record: editedSource),
               "不同修订的键不同，首版不拦截改写重生（记录为已知边界）")
    }

    /// 跨设备键一致：同一来源/修订/命题，contextID 不同 → span 键相同。
    static func testCrossDeviceSpanKeyConsistent() throws {
        let a = try record(id: "r-a", statement: "用户明年一月搬家")
        let b = try record(id: "r-b", statement: "用户明年一月搬家")
        // 换 contextID 模拟另一台设备。
        var payloadB = b.personalContext!.v1!
        payloadB = HoloPersonalContextPayloadV1(
            contextID: "88888888-different",
            statement: payloadB.statement,
            subjects: payloadB.subjects,
            objects: payloadB.objects,
            relationText: payloadB.relationText,
            facets: payloadB.facets,
            epistemicStatus: payloadB.epistemicStatus,
            applicability: payloadB.applicability,
            temporal: payloadB.temporal,
            basis: payloadB.basis,
            linkedContextIDs: payloadB.linkedContextIDs,
            openQuestions: payloadB.openQuestions,
            admission: payloadB.admission
        )
        let keysA = HoloContextSuppressionKeys.spanKeys(for: a.personalContext!.v1!)
        let keysB = HoloContextSuppressionKeys.spanKeys(for: payloadB)
        expect(keysA == keysB, "同一来源+修订+命题跨设备得到相同抑制键")
        expect(keysA.allSatisfy { $0.hasPrefix(HoloContextSuppressionKeys.spanPrefix) },
               "span 键带独立前缀")
    }

    /// 在途代际：用户决策版本或学习基线变化 → 旧结果丢弃。
    static func testAccessGuardDetectsVersionAndBaselineChange() {
        let controls = HoloPersonalContextControls.allOff()
        let guard0 = HoloContextAccessGuard(
            userDecisionVersion: 100,
            learningBaselineAt: nil,
            controls: controls
        )
        expect(guard0.isStillValid(currentUserDecisionVersion: 100, currentLearningBaselineAt: nil, currentControls: controls),
               "无变化时有效")
        expect(!guard0.isStillValid(currentUserDecisionVersion: 200, currentLearningBaselineAt: nil, currentControls: controls),
               "用户决策版本变化（忘记/清空）后过期")
        let baseline = Date(timeIntervalSince1970: 1_785_000_000)
        expect(!guard0.isStillValid(currentUserDecisionVersion: 100, currentLearningBaselineAt: baseline, currentControls: controls),
               "学习基线出现（清空）后过期")
        let guardBaseline = HoloContextAccessGuard(
            userDecisionVersion: 100,
            learningBaselineAt: baseline,
            controls: controls
        )
        expect(guardBaseline.isStillValid(currentUserDecisionVersion: 100, currentLearningBaselineAt: baseline, currentControls: controls),
               "基线一致时有效")
        expect(!guardBaseline.isStillValid(currentUserDecisionVersion: 100, currentLearningBaselineAt: nil, currentControls: controls),
               "基线被移除（历史重扫确认）后过期")
    }

    /// 控制闸变化：请求时的闸在返回前被关 → 结果不可用（requiredGate 复查）。
    static func testAccessGuardDetectsGateChange() {
        let onSnapshot = HoloPersonalContextControlSnapshot(
            extractionKillEnabled: true, retrievalKillEnabled: true,
            planningInjectionKillEnabled: true, rawFallbackKillEnabled: true,
            isInternalAccount: true, automaticMemoryEnabled: true,
            memoryAssistedAnsweringEnabled: true, aiDataProcessingConsentGranted: true
        )
        let guardOn = HoloContextAccessGuard(
            userDecisionVersion: 100,
            learningBaselineAt: nil,
            controls: onSnapshot
        )
        let injectionGate: (HoloPersonalContextControlSnapshot) -> Bool = { $0.allowsPlanningInjection }
        expect(guardOn.isStillValid(currentUserDecisionVersion: 100, currentLearningBaselineAt: nil, currentControls: onSnapshot, requiredGate: injectionGate),
               "闸未变化时有效")
        var offSnapshot = onSnapshot
        offSnapshot.planningInjectionKillEnabled = false
        expect(!guardOn.isStillValid(currentUserDecisionVersion: 100, currentLearningBaselineAt: nil, currentControls: offSnapshot, requiredGate: injectionGate),
               "注入闸被关后过期")
    }

    /// 确认队列区分：adviceEligible 的正常候选不进「想和你确认的」收件箱。
    static func testConfirmationQueueNotSpammed() throws {
        let background = try record(id: "r-bg")  // adviceEligible + normal
        expect(!HoloContextAccessPolicy.requiresUserConfirmation(record: background),
               "仅作建议背景的 candidate 不批量进确认收件箱")
        let unreviewed = try record(id: "r-un2", admission: .unreviewed)
        expect(HoloContextAccessPolicy.requiresUserConfirmation(record: unreviewed),
               "未审核需要用户决策")
        let sensitive = try record(id: "r-sen2", sensitivity: .sensitive)
        expect(HoloContextAccessPolicy.requiresUserConfirmation(record: sensitive),
               "敏感的 adviceEligible 仍需确认")
        var plain = try record(id: "r-none")
        plain.personalContext = nil
        expect(!HoloContextAccessPolicy.requiresUserConfirmation(record: plain),
               "非情境记录不进入情境确认队列")
    }
}
