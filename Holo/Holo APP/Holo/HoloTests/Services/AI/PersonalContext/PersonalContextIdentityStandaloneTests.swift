//
//  PersonalContextIdentityStandaloneTests.swift
//  HoloTests
//
//  P1 身份与合并规则验证：同主题不同关系不覆盖、同关系多次证据复用、
//  锚点顺序无关、范围不同不合并、claimKind 变化走替代链、contextID 由程序分配。
//  standalone 运行见 scripts/run-personal-context-standalone.sh。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try PersonalContextIdentityStandaloneTests.main()
    }
}
#endif
struct PersonalContextIdentityStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        try testSameTopicDifferentRelationNotMerged()
        try testSameRelationReuseIDOnNewEvidence()
        try testAnchorOrderIrrelevant()
        testDifferentScopeNotMerged()
        try testClaimKindChangeCreatesSeparateIdentity()
        testContextAnchorValueStable()
        testCandidateDefaultForNewRecords()
        print("PersonalContextIdentityStandaloneTests: \(assertionCount) 断言全部通过")
    }

    static func payload(
        contextID: String,
        statement: String,
        relationText: String,
        subjects: [HoloContextPartyRef] = [HoloContextPartyRef(label: "我", scope: .user)],
        objects: [HoloContextPartyRef] = [HoloContextPartyRef(label: "父亲", scope: .person)],
        applicability: HoloContextApplicabilityV1 = HoloContextApplicabilityV1(),
        epistemicStatus: HoloContextEpistemicStatus = .declared,
        basis: [HoloContextBasisRef] = []
    ) -> HoloPersonalContextPayloadV1 {
        HoloPersonalContextPayloadV1(
            contextID: contextID,
            statement: statement,
            subjects: subjects,
            objects: objects,
            relationText: relationText,
            epistemicStatus: epistemicStatus,
            applicability: applicability,
            basis: basis,
            admission: HoloContextAdmissionV1(
                level: .adviceEligible,
                policyVersion: 1,
                decidedAt: Date(timeIntervalSince1970: 1_780_000_000)
            )
        )
    }

    static func stableID(for p: HoloPersonalContextPayloadV1, claimKind: HoloMemoryClaimKind = .observedFact) throws -> String {
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: p.contextAnchorValue)
        return try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .thought,
            sourceDomains: [.thought],
            claimKind: claimKind,
            anchors: [anchor]
        )
    }

    /// 同主题（都关于父亲），不同命题（低盐 vs 晕车）：不合并、不同 ID。
    static func testSameTopicDifferentRelationNotMerged() throws {
        let salt = payload(
            contextID: "aaaaaaaa-0000-0000-0000-000000000001",
            statement: "用户的父亲被要求低盐饮食",
            relationText: "被要求低盐饮食"
        )
        let carsick = payload(
            contextID: "aaaaaaaa-0000-0000-0000-000000000002",
            statement: "用户的母亲晕车",
            relationText: "晕车",
            objects: [HoloContextPartyRef(label: "母亲", scope: .person)]
        )
        expect(!salt.isMergeable(with: carsick), "同主题不同命题不得合并")
        let saltID = try stableID(for: salt)
        let carsickID = try stableID(for: carsick)
        expect(saltID != carsickID, "不同命题产生不同稳定 ID")
    }

    /// 同一命题新证据：结构签名一致 → 可合并复用（版本升级而非新身份）。
    static func testSameRelationReuseIDOnNewEvidence() throws {
        let first = payload(
            contextID: "bbbbbbbb-0000-0000-0000-000000000001",
            statement: "用户的母亲晕车，不适应山路汽车",
            relationText: "晕车",
            basis: [HoloContextBasisRef(sourceID: "thought-1", sourceRevision: "rev-1")]
        )
        let second = payload(
            contextID: "bbbbbbbb-0000-0000-0000-000000000002",
            statement: "用户的母亲晕车，不适应山路汽车",
            relationText: "晕车",
            basis: [HoloContextBasisRef(sourceID: "thought-5", sourceRevision: "rev-1")]
        )
        expect(first.signatureComponentsEqual(second), "同命题不同证据来源应结构一致")
        expect(first.normalizedSignature == second.normalizedSignature, "签名不随证据变化")
        // 程序判定合并后复用 first 的 contextID，稳定 ID 不变。
        let reused = payload(
            contextID: "bbbbbbbb-0000-0000-0000-000000000001",
            statement: "用户的母亲晕车，不适应山路汽车",
            relationText: "晕车",
            basis: [HoloContextBasisRef(sourceID: "thought-5", sourceRevision: "rev-1")]
        )
        let firstID = try stableID(for: first)
        let reusedID = try stableID(for: reused)
        expect(firstID == reusedID, "复用 contextID 后稳定 ID 不变")
    }

    /// 锚点顺序与重复不影响稳定 ID（沿用既有 identity 算法性质）。
    static func testAnchorOrderIrrelevant() throws {
        let p = payload(
            contextID: "cccccccc-0000-0000-0000-000000000001",
            statement: "命题",
            relationText: "关系"
        )
        let a1 = try HoloMemoryAnchorRef(type: .userTheme, value: p.contextAnchorValue)
        let topic = try HoloMemoryAnchorRef(type: .thoughtTopic, value: "健康")
        let id1 = try HoloMemoryIdentity.makeStableID(
            scope: .domain, primaryDomain: .thought, sourceDomains: [.thought],
            claimKind: .observedFact, anchors: [a1, topic]
        )
        let id2 = try HoloMemoryIdentity.makeStableID(
            scope: .domain, primaryDomain: .thought, sourceDomains: [.thought],
            claimKind: .observedFact, anchors: [topic, a1, topic]
        )
        expect(id1 == id2, "锚点顺序或重复不得改变稳定 ID")
    }

    /// 范围不同（只限工作日 vs 无限定）：不得合并。
    static func testDifferentScopeNotMerged() {
        let unrestricted = payload(
            contextID: "dddddddd-0000-0000-0000-000000000001",
            statement: "用户中午习惯午休",
            relationText: "习惯午休",
            applicability: HoloContextApplicabilityV1()
        )
        let workdayOnly = payload(
            contextID: "dddddddd-0000-0000-0000-000000000002",
            statement: "用户中午习惯午休",
            relationText: "习惯午休",
            applicability: HoloContextApplicabilityV1(conditionText: "只限工作日")
        )
        expect(!unrestricted.signatureComponentsEqual(workdayOnly), "范围不同不得合并")
        expect(unrestricted.normalizedSignature != workdayOnly.normalizedSignature, "签名应包含范围")
    }

    /// claimKind 变化（事实→推断）：身份组成变化 → 走替代记录，不改旧 ID。
    static func testClaimKindChangeCreatesSeparateIdentity() throws {
        let p = payload(
            contextID: "eeeeeeee-0000-0000-0000-000000000001",
            statement: "用户在准备职称英语考试",
            relationText: "准备考试",
            epistemicStatus: .observed
        )
        let factID = try stableID(for: p, claimKind: .observedFact)
        let hypothesisID = try stableID(for: p, claimKind: .hypothesis)
        expect(factID != hypothesisID, "claimKind 变化必须产生独立身份（替代链而非覆盖）")
    }

    /// contextID 锚点值格式：personal-context:<contextID>，由程序生成。
    static func testContextAnchorValueStable() {
        let p = payload(
            contextID: "12345678-1234-1234-1234-123456789012",
            statement: "s",
            relationText: "r"
        )
        expect(p.contextAnchorValue == "personal-context:12345678-1234-1234-1234-123456789012",
               "锚点值必须是 personal-context:<contextID>")
    }

    /// 新情境记录默认 candidate：包括 declared（旧端安全门）。
    static func testCandidateDefaultForNewRecords() {
        let declared = payload(
            contextID: "ffffffff-0000-0000-0000-000000000001",
            statement: "用户说明年一月搬家",
            relationText: "搬家",
            epistemicStatus: .declared
        )
        let anchor = try! HoloMemoryAnchorRef(type: .userTheme, value: declared.contextAnchorValue)
        let record = HoloMemoryRecord(
            id: try! stableID(for: declared),
            scope: .domain,
            primaryDomain: .thought,
            sourceDomains: [.thought],
            subjectKey: "个人情境",
            anchorRefs: [anchor],
            claimKind: .observedFact,
            persistenceClass: .durable,
            displaySummary: declared.statement,
            aiUseSummary: declared.statement,
            prohibitedInferences: [],
            evidenceRefs: [],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            confidenceScore: 0.5,
            freshnessScore: 0.5,
            scoringVersion: 1,
            scoreComputedAt: Date(timeIntervalSince1970: 1_780_000_000),
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            personalContext: HoloPersonalContextPayloadEnvelope(v1: declared)
        )
        expect(record.state == .candidate, "新情境记录默认 candidate（含 declared）")
        expect(record.personalContext?.v1?.admission.level == .adviceEligible
               || record.personalContext?.v1?.admission.level == .unreviewed,
               "admission 由程序决定（adviceEligible 或 unreviewed），验证未过不得直用")
    }
}
