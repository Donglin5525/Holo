//
//  HoloLifeUnderstandingRelationTests.swift
//  HoloTests
//
//  R2 生活关系门禁测试（方案 2026-09-23 §4.2 R2）：
//    - Q0 四域来源能聚合出带限定的合法责任候选（inferred + adviceEligible + 限定表达）；
//    - Q3 反证不成立：纯代购/引用他人来源不得支撑本人 declared 断言（Validator authorship 门禁）；
//      反转场景的「用户有宠物照护责任」候选被核验 unsupported + inferred → 丢弃；
//    - 独立血缘正确：同根派生记录的 basis 去重（A07 只算一证）。
//
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
        try await HoloLifeUnderstandingRelationTests.main()
    }
}
#endif

struct HoloLifeUnderstandingRelationTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        testQ0AggregatedResponsibilityCandidate()
        testQ3ThirdPartyOnlyDeclaredRejected()
        testQ3UnsupportedResponsibilityDiscarded()
        testLineageDedupKeepsSingleEvidence()
        print("HoloLifeUnderstandingRelationTests: \(assertionCount) 断言全部通过")
    }

    // MARK: 工厂

    static func source(
        _ id: String,
        domain: String,
        kind: String,
        text: String,
        authorship: String? = nil,
        lineageRootIDs: [String]? = nil,
        updatedAt: Date = Date(timeIntervalSince1970: 1_775_000_000)
    ) -> HoloContextSourceSnapshot {
        HoloContextSourceSnapshot(
            sourceID: id,
            sourceDomain: domain,
            sourceKind: kind,
            revisionDigest: "rev-\(id)",
            sourceCreatedAt: updatedAt,
            sourceUpdatedAt: updatedAt,
            plainText: text,
            sensitivity: .normal,
            accessGeneration: 1,
            authorship: authorship,
            lineageRootIDs: lineageRootIDs
        )
    }

    /// Q0 四域来源（与 HoloLifeUnderstandingFixtures.fullRecords 同语义的快照形态）。
    static var q0Sources: [HoloContextSourceSnapshot] {
        [
            source("finance:tx-01", domain: "finance", kind: "transaction",
                   text: "【支出·宠物用品】猫粮 2kg（备注：家附近宠物店）"),
            source("task:task-01", domain: "task", kind: "todoTask",
                   text: "任务「给摩卡换水」"),
            source("habit:habit-01#checkin-20260915", domain: "habit", kind: "habitCheckin",
                   text: "完成习惯打卡「给摩卡换水」", lineageRootIDs: ["evt-checkin-0915"]),
            source("thought:note-01", domain: "thought", kind: "userNote",
                   text: "上次出门找过人上门喂猫。"),
        ]
    }

    static func candidate(
        ref: String,
        statement: String,
        epistemic: String,
        basisSourceIDs: [String],
        quotes: [String?]? = nil
    ) -> HoloContextExtractionCandidateDTO {
        var basis: [HoloContextExtractionBasisDTO] = []
        for (index, sourceID) in basisSourceIDs.enumerated() {
            basis.append(HoloContextExtractionBasisDTO(
                sourceID: sourceID,
                quote: quotes?[index] ?? nil,
                stance: nil,
                revision: "rev-\(sourceID)"
            ))
        }
        return HoloContextExtractionCandidateDTO(
            candidateRef: ref,
            statement: statement,
            relationText: statement,
            epistemicStatus: epistemic,
            basis: basis
        )
    }

    static func verdict(
        _ ref: String,
        _ result: String,
        qualifiers: [String] = []
    ) -> HoloContextVerificationVerdict {
        HoloContextVerificationVerdict(
            candidateRef: ref,
            verdict: result == "supported" ? .supported : (result == "qualified" ? .qualified : .unsupported),
            requiredQualifiers: qualifiers,
            reason: "测试"
        )
    }

    // MARK: R2 门禁

    /// Q0：四域弱证据聚合出带限定的责任候选（合法 = inferred + adviceEligible + 限定表达 + 保留血缘）。
    static func testQ0AggregatedResponsibilityCandidate() {
        let sources = q0Sources
        let response = HoloContextExtractionResponse(candidates: [
            candidate(
                ref: "c1",
                statement: "用户可能存在宠物照料责任（多来源弱证据，身份未确认）",
                epistemic: "inferred",
                basisSourceIDs: [
                    "finance:tx-01", "task:task-01",
                    "habit:habit-01#checkin-20260915", "thought:note-01",
                ]
            ),
        ])
        let (valid, findings) = HoloPersonalContextValidator.validate(
            response: response, packageSources: sources
        )
        expect(valid.count == 1, "Q0 聚合候选应通过结构校验（findings: \(findings.map(\.code.rawValue))）")

        let decisions = HoloContextReconciler.reconcile(
            candidates: valid,
            verdicts: [verdict("c1", "qualified", qualifiers: ["身份未确认"])],
            existingRecords: [],
            packageSources: sources,
            now: Date(timeIntervalSince1970: 1_775_000_000)
        )
        guard decisions.count == 1, let decision = decisions.first else {
            fatalError("应产生一条决策")
        }
        guard case .create = decision.action else {
            fatalError("Q0 聚合候选应建新记录（实际 \(decision.action)）")
        }
        expect(decision.admissionLevel == .adviceEligible, "qualified 核验 → adviceEligible")
        expect(
            decision.payload?.statement.contains("可能") == true,
            "推断候选保留限定表达（实际：\(decision.payload?.statement ?? "")）"
        )
        expect(decision.payload?.basis.count == 4, "四源证据全部保留（无同根源）")
    }

    /// Q3 前半：纯代购/引用他人来源不得支撑本人 declared 断言（Validator 门禁）。
    static func testQ3ThirdPartyOnlyDeclaredRejected() {
        let sources = [
            source("finance:tx-01", domain: "finance", kind: "transaction",
                   text: "【支出·宠物用品】帮同事代购猫粮 2kg", authorship: "proxyPurchase"),
            source("thought:note-01", domain: "thought", kind: "userNote",
                   text: "朋友说他上次出门找过人上门喂猫。", authorship: "quotedOther"),
        ]
        let response = HoloContextExtractionResponse(candidates: [
            candidate(
                ref: "c1",
                statement: "用户养猫",
                epistemic: "declared",
                basisSourceIDs: ["finance:tx-01", "thought:note-01"]
            ),
        ])
        let (valid, findings) = HoloPersonalContextValidator.validate(
            response: response, packageSources: sources
        )
        expect(valid.isEmpty, "纯第三方来源的 declared 断言必须被拒")
        expect(
            findings.contains { $0.code == .thirdPartyOnlyBasis },
            "拒绝原因必须是 thirdPartyOnlyBasis"
        )

        // 对照：inferred 弱线索候选允许存在（代购仍是弱线索，不得变事实但可观察）。
        let weak = HoloContextExtractionResponse(candidates: [
            candidate(
                ref: "c2",
                statement: "用户可能接触过宠物用品（代购记录）",
                epistemic: "inferred",
                basisSourceIDs: ["finance:tx-01"]
            ),
        ])
        let (validWeak, _) = HoloPersonalContextValidator.validate(
            response: weak, packageSources: sources
        )
        expect(validWeak.count == 1, "inferred 弱线索不被 authorship 门禁误伤")
    }

    /// Q3 后半：反转场景的「用户有宠物照护责任」候选 → 核验 unsupported + inferred → 丢弃。
    static func testQ3UnsupportedResponsibilityDiscarded() {
        let sources = [
            source("finance:tx-01", domain: "finance", kind: "transaction",
                   text: "【支出·宠物用品】帮同事代购猫粮 2kg", authorship: "proxyPurchase"),
        ]
        let response = HoloContextExtractionResponse(candidates: [
            candidate(
                ref: "c1",
                statement: "用户本人有宠物照护责任",
                epistemic: "inferred",
                basisSourceIDs: ["finance:tx-01"]
            ),
        ])
        let (valid, _) = HoloPersonalContextValidator.validate(response: response, packageSources: sources)
        let decisions = HoloContextReconciler.reconcile(
            candidates: valid,
            verdicts: [verdict("c1", "unsupported")],
            existingRecords: [],
            packageSources: sources,
            now: Date(timeIntervalSince1970: 1_775_000_000)
        )
        guard case .discard = decisions.first?.action else {
            fatalError("unsupported + inferred 必须丢弃（实际 \(String(describing: decisions.first?.action))）")
        }
    }

    /// A07 独立血缘：同一真实事件派生的任务完成与打卡（同根）只算一份证据。
    static func testLineageDedupKeepsSingleEvidence() {
        let sources = [
            source("task:task-01", domain: "task", kind: "todoTask",
                   text: "任务「给摩卡换水」", lineageRootIDs: ["evt-care-0912"]),
            source("habit:habit-01#checkin-20260912", domain: "habit", kind: "habitCheckin",
                   text: "完成习惯打卡「给摩卡换水」", lineageRootIDs: ["evt-care-0912"]),
            source("habit:habit-01#checkin-20260915", domain: "habit", kind: "habitCheckin",
                   text: "完成习惯打卡「给摩卡换水」", lineageRootIDs: ["evt-checkin-0915"]),
        ]
        let response = HoloContextExtractionResponse(candidates: [
            candidate(
                ref: "c1",
                statement: "用户可能存在宠物照料责任",
                epistemic: "inferred",
                basisSourceIDs: [
                    "task:task-01",
                    "habit:habit-01#checkin-20260912",
                    "habit:habit-01#checkin-20260915",
                ]
            ),
        ])
        let (valid, _) = HoloPersonalContextValidator.validate(response: response, packageSources: sources)
        let decisions = HoloContextReconciler.reconcile(
            candidates: valid,
            verdicts: [verdict("c1", "supported")],
            existingRecords: [],
            packageSources: sources,
            now: Date(timeIntervalSince1970: 1_775_000_000)
        )
        expect(
            decisions.first?.payload?.basis.count == 2,
            "同根两条只算一证（3 basis → 2，实际 \(decisions.first?.payload?.basis.count ?? -1)）"
        )
    }
}

// MARK: - 决策便捷读取

extension HoloContextReconcileDecision {
    var admissionLevel: HoloContextAdmissionLevel? {
        payload?.admission.level
    }
}
