import Foundation

/// 五路决策策略 v4 验收（记忆低确认成本方案 P2 / §16.1 决策策略测试）。
///
/// 1. 冻结 fixtures 全量路由门：21 条场景（含对抗样本）必须命中期望五路结果；
/// 2. derivableToday 子集的权威性/核验/影响推导与冻结期望一致；
/// 3. ActivationPolicy 薄适配：v4 开=三入口（领域/跨域/个人情境）同结果，
///    v4 关=回滚矩阵保持 v3 行为；
/// 4. decision metadata 挂载、admission 单向投影、召回/建议通道 useLevel 门。

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try await HoloMemoryDecisionPolicyStandaloneTests.main()
    }
}
#endif
struct HoloMemoryDecisionPolicyStandaloneTests {
    private static var assertions = 0

    static func main() async throws {
        try frozenFixtureRouteGate()
        adapterAndChannels()
        try await compactionCoversCandidates()
        print("HoloMemoryDecisionPolicyStandaloneTests: \(assertions) assertions passed")
    }

    // MARK: - 冻结评测门（§16.4：一半场景来自 fixtures，规则调整不得偷偷改期望）

    private static func frozenFixtureRouteGate() throws {
        let now = HoloMemoryFiveWayFixtures.anchorNow
        for fixture in HoloMemoryFiveWayFixtures.all {
            let decision = withFlag(HoloMemoryDecisionPolicy.enabledKey, nil) {
                HoloMemoryDecisionPolicy.evaluate(fixture.record, now: now)
            }
            expect(
                decision.route == fixture.expectedRoute,
                "\(fixture.scenarioID) 路由应为 \(fixture.expectedRoute)，实际 \(decision.route)（\(fixture.note)）"
            )
            if fixture.derivation == .derivableToday {
                if let expectedAuthority = fixture.expectedAuthority {
                    expect(
                        decision.input.sourceAuthority == expectedAuthority,
                        "\(fixture.scenarioID) 权威性应为 \(expectedAuthority)，实际 \(decision.input.sourceAuthority)"
                    )
                }
                if let expectedVerdict = fixture.expectedVerdict {
                    expect(
                        decision.input.evidenceVerdict == expectedVerdict,
                        "\(fixture.scenarioID) 核验应为 \(expectedVerdict)，实际 \(decision.input.evidenceVerdict)"
                    )
                }
                if let expectedImpact = fixture.expectedImpact {
                    expect(
                        decision.input.impactLevel == expectedImpact,
                        "\(fixture.scenarioID) 影响应为 \(expectedImpact)，实际 \(decision.input.impactLevel)"
                    )
                }
            }
        }
        assertions += 1
    }

    // MARK: - 适配器与通道（§11.1/§11.2：三入口同结果、单一事实源）

    private static func adapterAndChannels() {
        let now = HoloMemoryFiveWayFixtures.anchorNow

        // v4 开：三入口（ActivationPolicy 适配器 / 决策器直调 / 萃取器出口）同结果。
        withFlag(HoloMemoryDecisionPolicy.enabledKey, nil) {
            for fixture in HoloMemoryFiveWayFixtures.all {
                let decision = HoloMemoryDecisionPolicy.evaluate(fixture.record, now: now)
                let adapted = HoloMemoryActivationPolicy.evaluate(fixture.record, now: now)
                let consistent: Bool
                switch (adapted, decision.route) {
                case (.activateAutomatically, .factEligible),
                     (.activateAutomatically, .qualifiedAdvice),
                     (.requiresConfirmation, .observeOnly),
                     (.requiresConfirmation, .askWhenRelevant),
                     (.discard, .discard):
                    consistent = true
                default:
                    consistent = false
                }
                expect(
                    consistent,
                    "\(fixture.scenarioID) ActivationPolicy 适配器与决策器结论不一致：\(adapted) vs \(decision.route)"
                )
            }
            assertions += 1

            // apply：挂载 decision metadata + admission 投影 + 状态映射。
            let preference = HoloMemoryFiveWayFixtures.mtx03DeclaredPreference.record
            let applied = HoloMemoryActivationPolicy.apply(to: preference, now: now)
            expect(applied?.state == .active, "明确偏好（factEligible）应生效为 active")
            expect(
                applied?.decisionMetadata?.v2?.useLevel == .factEligible,
                "apply 应挂载 factEligible 决策元数据"
            )
            expect(
                applied?.adoptionMetadata?.policyVersion == HoloMemoryDecisionPolicy.currentVersion,
                "adoptionMetadata 应推进到 v4"
            )
            expect(
                applied?.personalContext?.v1?.admission.level == .adviceEligible,
                "admission 应由决策投影为 adviceEligible（不再独立裁决）"
            )

            let observe = HoloMemoryFiveWayFixtures.mtx07SingleOccurrence.record
            let observed = HoloMemoryActivationPolicy.apply(to: observe, now: now)
            expect(observed?.state == .candidate, "单次现象（observeOnly）应保持 candidate")
            expect(
                observed?.decisionMetadata?.v2?.attentionPolicy == .silent,
                "observeOnly 打扰策略应为 silent"
            )

            let medical = HoloMemoryFiveWayFixtures.mtx10HighImpactMedicalInference.record
            expect(
                HoloMemoryActivationPolicy.apply(to: medical, now: now) == nil,
                "医疗诊断推断应被丢弃，不能靠确认转正"
            )

            // 召回通道：只有 factEligible 进普通事实召回；qualifiedAdvice/不可靠解码被拦。
            var qualifiedActive = HoloMemoryFiveWayFixtures.mtx08FirstCrossDomainCorrelation.record
            qualifiedActive.state = .active
            qualifiedActive.decisionMetadata = HoloMemoryDecisionMetadataEnvelope(
                v2: HoloMemoryDecisionPolicy.evaluate(qualifiedActive, now: now).metadata
            )
            expect(
                HoloMemoryRecallPolicy.exclusionReason(for: qualifiedActive, now: now) == .useLevelRestricted,
                "qualifiedAdvice 不得进入普通事实召回（只走限定建议通道）"
            )
            var factActive = preference
            factActive.state = .active
            factActive.decisionMetadata = HoloMemoryDecisionMetadataEnvelope(
                v2: HoloMemoryDecisionPolicy.evaluate(factActive, now: now).metadata
            )
            expect(
                HoloMemoryRecallPolicy.exclusionReason(for: factActive, now: now) == nil,
                "factEligible 的 active 记忆应可进入事实召回"
            )
            var unreliable = factActive
            var mutated = HoloMemoryDecisionMetadataV2(
                policyVersion: 4,
                sourceAuthority: .explicitUserStatement,
                evidenceVerdict: .supported,
                impactLevel: .low,
                persistencePermission: .durable,
                useLevel: .factEligible,
                attentionPolicy: .silent,
                reasonCodes: [],
                evaluatedAt: now,
                evidenceRevision: "rev-1"
            )
            mutated.sourceAuthority = .unrecognized("fromTheFuture")
            unreliable.decisionMetadata = HoloMemoryDecisionMetadataEnvelope(v2: mutated)
            expect(
                HoloMemoryRecallPolicy.exclusionReason(for: unreliable, now: now) == .useLevelRestricted,
                "不可靠解码的元数据必须整体保守拦截（未知枚举不得放行）"
            )
        }

        // v4 关（回滚）：旧矩阵行为保持——敏感待确认、首次跨域待确认、假设待确认。
        withFlag(HoloMemoryDecisionPolicy.enabledKey, false) {
            let sensitive = HoloMemoryFiveWayFixtures.mtx05SensitiveFreeTextNoAuthorization.record
            expect(
                HoloMemoryActivationPolicy.evaluate(sensitive, now: now)
                    == .requiresConfirmation(.sensitiveMemory),
                "回滚：敏感记忆回到待确认（v3 口径）"
            )
            let firstCross = HoloMemoryFiveWayFixtures.mtx08FirstCrossDomainCorrelation.record
            expect(
                HoloMemoryActivationPolicy.evaluate(firstCross, isFirstCrossDomainInference: true, now: now)
                    == .requiresConfirmation(.firstCrossDomainInference),
                "回滚：首次跨域回到待确认（v3 口径）"
            )
        }
    }

    // MARK: - 压缩覆盖 candidate（§10.2 observeOnly 不无限积累）

    private static func compactionCoversCandidates() async throws {
        let now = HoloMemoryFiveWayFixtures.anchorNow

        // freshness 见底的 observe 类 candidate 应被归档。
        let staleCandidate = try makeStaleCandidate(now: now)
        let freshCandidate = HoloMemoryFiveWayFixtures.mtx07SingleOccurrence.record
        let plan = HoloMemoryCompactionService().plan(records: [staleCandidate, freshCandidate], tombstones: [], now: now)
        expect(
            plan.archiveRecordIDs.contains(staleCandidate.id),
            "freshness 见底的 candidate 应纳入归档（不再无限积累）"
        )
        expect(
            !plan.archiveRecordIDs.contains(freshCandidate.id),
            "新鲜 candidate 不应被归档"
        )

        // 未确认的 permanentFact candidate 不得借永久事实逃避衰减。
        var permanentCandidate = try makeStaleCandidate(now: now)
        permanentCandidate.persistenceClass = .permanentFact
        let permanentPlan = HoloMemoryCompactionService().plan(
            records: [permanentCandidate],
            tombstones: [],
            now: now
        )
        expect(
            permanentPlan.archiveRecordIDs.contains(permanentCandidate.id),
            "未确认 permanentFact candidate 也应随 freshness 归档（§10.2）"
        )

        // 用户确认过的 permanentFact 仍受保护。
        var confirmedPermanent = permanentCandidate
        confirmedPermanent.userDecision = .confirmed
        confirmedPermanent.state = .active
        let confirmedPlan = HoloMemoryCompactionService().plan(
            records: [confirmedPermanent],
            tombstones: [],
            now: now
        )
        expect(
            !confirmedPlan.archiveRecordIDs.contains(confirmedPermanent.id),
            "用户确认过的 permanentFact 不得自然归档"
        )
    }

    private static func makeStaleCandidate(now: Date) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .habit, value: "decision-stale-candidate")
        let evidence = HoloMemoryEvidenceRef(
            id: "stale-candidate-evidence",
            kind: .aggregateSnapshot,
            sourceDomain: .habit,
            lineageKey: "habit-stale-window",
            revisionDigest: "rev-1",
            observedAt: now.addingTimeInterval(-120 * 86_400),
            validFrom: now.addingTimeInterval(-150 * 86_400),
            validTo: now.addingTimeInterval(-120 * 86_400),
            aggregateDefinition: "window=30d",
            sampleCount: 3,
            summary: "很久以前的一次节奏观察"
        )
        let stableID = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            claimKind: .observedFact,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: stableID,
            scope: .domain,
            primaryDomain: .habit,
            sourceDomains: [.habit],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: .observedFact,
            persistenceClass: .currentState,
            displaySummary: "很久以前的一次节奏观察",
            aiUseSummary: "很久以前的一次节奏观察",
            prohibitedInferences: [],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            lastSupportedAt: now.addingTimeInterval(-120 * 86_400),
            confidenceScore: 0.5,
            freshnessScore: 0.05,
            scoringVersion: 1,
            scoreComputedAt: now.addingTimeInterval(-120 * 86_400),
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: now.addingTimeInterval(-150 * 86_400),
            updatedAt: now.addingTimeInterval(-120 * 86_400)
        )
    }

    // MARK: - 助手

    private static func withFlag<T>(_ key: String, _ value: Bool?, _ body: () -> T) -> T {
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return body()
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
}
