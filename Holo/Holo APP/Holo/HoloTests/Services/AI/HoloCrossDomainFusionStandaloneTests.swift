import Foundation

@main
struct HoloCrossDomainFusionStandaloneTests {
    private static var assertionCount = 0

    static func main() throws {
        let now = Date(timeIntervalSince1970: 1_752_422_400)
        let anchor = try HoloMemoryAnchorRef(type: .userTheme, value: "恢复状态")
        let otherAnchor = try HoloMemoryAnchorRef(type: .userTheme, value: "阅读")

        let finance = try makeRecord(
            domain: .finance,
            anchor: anchor,
            lineage: "finance-event-1",
            start: now.addingTimeInterval(-7 * 86_400),
            end: now
        )
        let health = try makeRecord(
            domain: .health,
            anchor: anchor,
            lineage: "health-sleep-1",
            start: now.addingTimeInterval(-5 * 86_400),
            end: now.addingTimeInterval(2 * 86_400)
        )

        let candidates = HoloCrossDomainCandidateBuilder.build(from: [finance, health])
        expect(candidates.count == 1, "共同时间、共同 anchor、两域和独立 lineage 应生成候选")
        let candidate = try require(candidates.first, "候选不存在")
        expect(candidate.sourceDomains == [.finance, .health], "候选领域应稳定排序")
        expect(candidate.evidenceRefs.count == 2, "候选应保留两条独立底层证据")
        expect(candidate.commonWindow.start == health.validFrom, "共同窗口应取较晚起点")
        expect(candidate.commonWindow.end == finance.validTo, "共同窗口应取较早终点")

        let duplicateLineageHealth = try makeRecord(
            domain: .health,
            anchor: anchor,
            lineage: "finance-event-1",
            start: now.addingTimeInterval(-5 * 86_400),
            end: now
        )
        expect(
            HoloCrossDomainCandidateBuilder.build(from: [finance, duplicateLineageHealth]).isEmpty,
            "同一用户消息或业务事件只能算一个来源"
        )

        let noTimeOverlap = try makeRecord(
            domain: .health,
            anchor: anchor,
            lineage: "health-old",
            start: now.addingTimeInterval(-30 * 86_400),
            end: now.addingTimeInterval(-20 * 86_400)
        )
        expect(
            HoloCrossDomainCandidateBuilder.build(from: [finance, noTimeOverlap]).isEmpty,
            "没有共同时间不得融合"
        )

        let noSharedAnchor = try makeRecord(
            domain: .health,
            anchor: otherAnchor,
            lineage: "health-reading",
            start: now.addingTimeInterval(-5 * 86_400),
            end: now
        )
        expect(
            HoloCrossDomainCandidateBuilder.build(from: [finance, noSharedAnchor]).isEmpty,
            "没有共同 anchor 不得融合"
        )
        expect(
            HoloCrossDomainCandidateBuilder.build(from: [finance, finance]).isEmpty,
            "同一领域不得伪装成跨域候选"
        )

        let insightBackedHealth = try makeRecord(
            domain: .health,
            anchor: anchor,
            lineage: "memory-insight:card-1",
            start: now.addingTimeInterval(-5 * 86_400),
            end: now,
            sourceID: "memory-insight:card-1"
        )
        expect(
            HoloCrossDomainCandidateBuilder.build(from: [finance, insightBackedHealth]).isEmpty,
            "MemoryInsight 只能触发重查，不能作为事实证据"
        )

        let safeOutput = HoloCrossDomainFusionOutput(
            claimKind: .association,
            displaySummary: "近一周晚间餐饮支出偏高与睡眠偏短同时出现",
            aiUseSummary: "财务餐饮变化与睡眠时长变化在同一窗口并发，不能据此判断因果",
            anchors: [anchor],
            upstreamMemoryIDs: candidate.sourceMemoryIDs,
            evidenceIDs: candidate.evidenceRefs.map(\.id),
            prohibitedInferences: ["causality", "medicalDiagnosis"],
            requestedStorageClass: .normal
        )
        let transient = HoloCrossDomainFusionService.evaluate(
            safeOutput,
            for: candidate,
            priorOccurrenceCount: 0,
            userConfirmed: false,
            now: now
        )
        guard case .transient(let preview) = transient else {
            fatalError("首次动态状态只能组合展示，不能落盘")
        }
        expect(preview.sensitivity == .sensitive, "包含健康的临时结果也必须按敏感数据处理")

        let persisted = HoloCrossDomainFusionService.evaluate(
            safeOutput,
            for: candidate,
            priorOccurrenceCount: 1,
            userConfirmed: false,
            now: now
        )
        guard case .persist(let record) = persisted else {
            fatalError("连续第二个周期成立后应允许持久化")
        }
        expect(record.scope == .crossDomain, "持久化记录必须是 crossDomain")
        expect(record.sourceDomains == [.finance, .health], "持久化记录必须保留来源领域")
        expect(record.sensitivity == .sensitive, "包含 health 的跨域记忆必须 sensitiveLocal")
        expect(record.upstreamMemoryIDs.count == 2, "持久化记录必须保留上游记忆")
        try record.validate()

        let confirmed = HoloCrossDomainFusionService.evaluate(
            safeOutput,
            for: candidate,
            priorOccurrenceCount: 0,
            userConfirmed: true,
            now: now
        )
        guard case .persist = confirmed else {
            fatalError("用户确认后应允许持久化")
        }

        var causalOutput = safeOutput
        causalOutput.displaySummary = "晚睡导致了餐饮支出增加"
        let causal = HoloCrossDomainFusionService.evaluate(
            causalOutput,
            for: candidate,
            priorOccurrenceCount: 2,
            userConfirmed: false,
            now: now
        )
        expect(causal == .rejected(.causalOrMedicalInference), "确定因果表达必须拒绝")

        var diagnosisOutput = safeOutput
        diagnosisOutput.aiUseSummary = "这证明用户存在睡眠障碍"
        let diagnosis = HoloCrossDomainFusionService.evaluate(
            diagnosisOutput,
            for: candidate,
            priorOccurrenceCount: 2,
            userConfirmed: false,
            now: now
        )
        expect(diagnosis == .rejected(.causalOrMedicalInference), "医疗判断必须拒绝")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(
            HoloCrossDomainFusionOutputEnvelope(candidates: [safeOutput])
        )
        let decodedDecisions = HoloCrossDomainFusionService.evaluate(
            encoded,
            against: [candidate],
            priorOccurrenceCounts: [candidate.identityKey: 1],
            now: now
        )
        guard case .persist = decodedDecisions.first else {
            fatalError("服务端 envelope 应能匹配本地候选并通过统一 Validator")
        }
        expect(
            HoloCrossDomainFusionService.evaluate(
                Data("not-json".utf8),
                against: [candidate],
                now: now
            ) == [.rejected(.malformedJSON)],
            "非法 JSON 必须在本地拒绝"
        )

        print("HoloCrossDomainFusionStandaloneTests passed: \(assertionCount) assertions")
    }

    private static func makeRecord(
        domain: HoloMemoryDomain,
        anchor: HoloMemoryAnchorRef,
        lineage: String,
        start: Date,
        end: Date,
        sourceID: String? = nil
    ) throws -> HoloMemoryRecord {
        let evidence = HoloMemoryEvidenceRef(
            id: "evidence-\(domain.rawValue)-\(lineage)",
            kind: .aggregateSnapshot,
            sourceDomain: domain,
            lineageKey: lineage,
            sourceID: sourceID,
            revisionDigest: "rev-1",
            observedAt: end,
            validFrom: start,
            validTo: end,
            aggregateDefinition: "test",
            sampleCount: 7,
            summary: "测试证据"
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
            persistenceClass: .currentState,
            displaySummary: "\(domain.rawValue) 近期状态",
            aiUseSummary: "\(domain.rawValue) 近期状态",
            prohibitedInferences: [],
            evidenceRefs: [evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            validFrom: start,
            validTo: end,
            lastSupportedAt: end,
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: end,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: domain == .health ? .sensitive : .normal,
            userDecision: .none,
            createdAt: start,
            updatedAt: end
        )
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    private static func require<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw NSError(domain: message, code: 1) }
        return value
    }
}
