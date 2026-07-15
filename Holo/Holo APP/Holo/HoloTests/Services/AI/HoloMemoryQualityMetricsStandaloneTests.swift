import Foundation

@main
struct HoloMemoryQualityMetricsStandaloneTests {
    private static var assertions = 0

    static func main() async throws {
        try await testNumericOnlyMetrics()
        testRolloutAndKillSwitches()
        try testCompactionAndEncodedCapacity()
        testCriticalPathBudgets()
        print("HoloMemoryQualityMetricsStandaloneTests: \(assertions) assertions passed")
    }

    private static func testNumericOnlyMetrics() async throws {
        let metrics = HoloMemoryQualityMetrics(maximumLatencySamples: 100)
        for index in 1...20 {
            await metrics.recordQuery(
                durationMilliseconds: Double(index),
                selectedCount: index.isMultiple(of: 2) ? 1 : 0
            )
        }
        await metrics.recordValidation(generated: 10, rejected: 2)
        await metrics.recordFeedback(corrected: true, rejected: false)
        await metrics.recordFeedback(corrected: false, rejected: true)
        await metrics.recordChatPath(serialNetworkRoundTrips: 0)
        await metrics.recordConcurrentMemoryAIJobs(1)
        let snapshot = await metrics.snapshot()

        expect(snapshot.queryCount == 20, "应记录查询计数")
        expect(snapshot.queryHitRate == 0.5, "命中率应由计数计算")
        expect(snapshot.queryLatencyP95Milliseconds == 19, "p95 计算应稳定")
        expect(snapshot.validatorRejectionRate == 0.2, "validator 拒绝率应正确")
        expect(snapshot.correctionRate == 0.5, "纠正率应正确")
        expect(snapshot.userRejectionRate == 0.5, "用户拒绝率应正确")
        expect(snapshot.meetsQueryLatencySLO, "20ms 样本应满足 100ms p95")
        expect(snapshot.keepsChatPathNetworkFree, "聊天关键路径不得新增网络往返")
        expect(snapshot.keepsSingleMemoryAIJob, "后台记忆 AI job 不得超过 1")

        let data = try JSONEncoder().encode(snapshot)
        let json = String(decoding: data, as: UTF8.self)
        expect(!json.contains("summary"), "质量指标不得包含摘要字段")
        expect(!json.contains("evidence"), "质量指标不得包含 evidence 正文或元数据")
        expect(!json.contains("question"), "质量指标不得包含问题正文")
    }

    private static func testRolloutAndKillSwitches() {
        let shadow = HoloMemoryOperationalControlSnapshot(
            rolloutStage: .shadow,
            extractionEnabled: true,
            fusionEnabled: true,
            answerInjectionEnabled: true,
            isInternalAccount: false,
            isLimitedRolloutBucket: false
        )
        expect(shadow.allowsExtraction, "shadow 应生成领域候选")
        expect(shadow.allowsFusion, "shadow 应评估跨域融合")
        expect(!shadow.allowsAnswerInjection, "shadow 绝不能注入用户回答")
        expect(shadow.isShadowEvaluation, "shadow 状态应可观测")

        var internalStage = shadow
        internalStage.rolloutStage = .internalAccounts
        expect(!internalStage.allowsAnswerInjection, "非内部账号不能进入首轮灰度")
        internalStage.isInternalAccount = true
        expect(internalStage.allowsAnswerInjection, "内部账号可进入首轮灰度")

        var limited = shadow
        limited.rolloutStage = .limited
        limited.isLimitedRolloutBucket = true
        expect(limited.allowsAnswerInjection, "小流量桶可注入")

        var killed = limited
        killed.extractionEnabled = false
        expect(!killed.allowsExtraction, "extraction kill switch 应独立生效")
        expect(killed.allowsFusion, "关闭 extraction 不得隐式关闭 fusion")
        killed.fusionEnabled = false
        expect(!killed.allowsFusion, "fusion kill switch 应独立生效")
        killed.answerInjectionEnabled = false
        expect(!killed.allowsAnswerInjection, "answer injection kill switch 应独立生效")
    }

    private static func testCompactionAndEncodedCapacity() throws {
        let now = Date(timeIntervalSince1970: 1_752_595_200)
        var records: [HoloMemoryRecord] = []
        for index in 0..<55 {
            records.append(try makeDomainRecord(
                domain: .finance,
                index: index,
                decision: index < 3 ? .confirmed : .none,
                now: now.addingTimeInterval(Double(index))
            ))
        }
        for index in 0..<105 {
            records.append(try makeCrossDomainRecord(index: index, now: now.addingTimeInterval(Double(index))))
        }
        let tombstone = HoloMemoryTombstone(
            identityKey: "forgotten-stable-id",
            scope: .domain,
            claimKind: .recurringPattern,
            anchorKeys: ["merchant:private"],
            userDecisionVersion: 9,
            createdAt: now
        )

        let plan = HoloMemoryCompactionService().plan(
            records: records,
            tombstones: [tombstone]
        )
        expect(plan.archiveRecordIDs.count == 10, "finance 应归档 5 条，跨域应归档 5 条")
        let confirmedIDs = Set(records.filter { $0.userDecision == .confirmed }.map(\.id))
        expect(confirmedIDs.isDisjoint(with: plan.archiveRecordIDs), "不得归档用户确认事实")
        expect(plan.preservedTombstoneIDs == [tombstone.identityKey], "compaction 不得删除 tombstone")
        expect(plan.protectedOverflowByScope.isEmpty, "本样本保护记录未超容量")
        expect(plan.encodedFootprint.historicalRecordBytes > 0, "必须以真实 JSON 编码测量历史体积")
        expect(plan.encodedFootprint.evidenceMetadataBytes > 0, "必须独立测量 evidence metadata")
        expect(!plan.encodedFootprint.exceedsHistoricalRecordLimit, "样本不应超过 8 MiB 历史上限")
        expect(!plan.encodedFootprint.exceedsEvidenceMetadataLimit, "样本不应超过 4 MiB evidence 上限")
    }

    private static func testCriticalPathBudgets() {
        expect(HoloMemoryQueryBudgetPolicy.p95LatencyTargetMilliseconds == 100, "召回 p95 目标应为 100ms")
        expect(HoloMemoryQueryBudgetPolicy.defaultMaximumRecords == 8, "普通回答最多注入 8 条")
        expect(HoloMemoryQueryBudgetPolicy.defaultTokenBudget == 2_000, "默认上下文预算应为 2000 tokens")
        expect(HoloMemoryQueryBudgetPolicy.serialNetworkRoundTripsOnCriticalPath == 0,
               "普通聊天关键路径不得新增串行网络往返")
    }

    private static func makeDomainRecord(
        domain: HoloMemoryDomain,
        index: Int,
        decision: HoloMemoryUserDecision,
        now: Date
    ) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: "domain-\(domain.rawValue)-\(index)")
        let evidence = HoloMemoryEvidenceRef(
            id: "e-\(domain.rawValue)-\(index)",
            kind: .aggregateSnapshot,
            sourceDomain: domain,
            lineageKey: "lineage-\(domain.rawValue)-\(index)",
            revisionDigest: "rev-\(index)",
            observedAt: now,
            validFrom: now.addingTimeInterval(-7 * 86_400),
            validTo: now,
            aggregateDefinition: "quality-test",
            sampleCount: 7,
            summary: "encoded-size-sample-\(index)"
        )
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            claimKind: .recurringPattern,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: .recurringPattern,
            persistenceClass: .phase,
            displaySummary: "domain memory \(index)",
            aiUseSummary: "domain memory \(index)",
            prohibitedInferences: [],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: evidence.validFrom,
            validTo: evidence.validTo,
            lastSupportedAt: now,
            confidenceScore: 0.7,
            freshnessScore: 0.8,
            scoringVersion: 2,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: .normal,
            userDecision: decision,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func makeCrossDomainRecord(index: Int, now: Date) throws -> HoloMemoryRecord {
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: "cross-\(index)")
        let evidence = [HoloMemoryDomain.finance, .health].map { domain in
            HoloMemoryEvidenceRef(
                id: "cross-e-\(domain.rawValue)-\(index)",
                kind: .aggregateSnapshot,
                sourceDomain: domain,
                lineageKey: "cross-lineage-\(domain.rawValue)-\(index)",
                revisionDigest: "rev-\(index)",
                observedAt: now,
                validFrom: now.addingTimeInterval(-7 * 86_400),
                validTo: now,
                aggregateDefinition: "quality-test",
                sampleCount: 7,
                summary: "cross encoded sample"
            )
        }
        let id = try HoloMemoryIdentity.makeStableID(
            scope: .crossDomain,
            primaryDomain: nil,
            sourceDomains: [.finance, .health],
            claimKind: .association,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: .crossDomain,
            primaryDomain: nil,
            sourceDomains: [.finance, .health],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: .association,
            persistenceClass: .phase,
            displaySummary: "cross memory \(index)",
            aiUseSummary: "cross memory \(index)",
            prohibitedInferences: ["causality"],
            evidenceRefs: evidence,
            upstreamMemoryIDs: ["finance-\(index)", "health-\(index)"],
            counterEvidenceRefs: [],
            validFrom: evidence.first?.validFrom,
            validTo: evidence.first?.validTo,
            lastSupportedAt: now,
            confidenceScore: 0.7,
            freshnessScore: 0.8,
            scoringVersion: 2,
            scoreComputedAt: now,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: .sensitive,
            userDecision: .none,
            createdAt: now,
            updatedAt: now
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
}
