import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloCrossDomainFusionStandaloneTests.main()
    }
}
#endif
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

        let routineAnchor = try HoloMemoryAnchorRef(
            type: .userTheme,
            value: "current-routine"
        )
        let routineFinance = try makeRecord(
            domain: .finance,
            anchor: routineAnchor,
            lineage: "finance-routine-1",
            start: now.addingTimeInterval(-7 * 86_400),
            end: now
        )
        let routineTask = try makeRecord(
            domain: .task,
            anchor: routineAnchor,
            lineage: "task-routine-1",
            start: now.addingTimeInterval(-7 * 86_400),
            end: now
        )
        expect(
            HoloCrossDomainCandidateBuilder.build(from: [routineFinance, routineTask]).isEmpty,
            "两个普通日常统计不能只因共享生活节奏锚点而融合"
        )
        let shiftedTask = try makeRecord(
            domain: .task,
            anchor: routineAnchor,
            lineage: "task-shift-1",
            start: now.addingTimeInterval(-7 * 86_400),
            end: now,
            claimKind: .phaseShift
        )
        expect(
            HoloCrossDomainCandidateBuilder.build(from: [routineFinance, shiftedTask]).count == 1,
            "至少一个领域出现阶段变化时才允许融合通用生活节奏"
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
        let firstCrossDomain = HoloCrossDomainFusionService.evaluate(
            safeOutput,
            for: candidate,
            priorOccurrenceCount: 0,
            userConfirmed: false,
            now: now
        )
        guard case .persist(let firstCrossDomainRecord) = firstCrossDomain else {
            fatalError("首次跨域结论应落为待确认记录")
        }
        expect(firstCrossDomainRecord.state == .candidate,
               "首次跨域结论确认前不得生效")
        expect(firstCrossDomainRecord.adoptionMetadata?.reason == .firstCrossDomainInference,
               "首次跨域结论必须记录首次推断原因码")

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
        expect(record.sensitivity == .normal, "含健康的跨域记忆不再一刀切标敏感")
        expect(record.state == .active, "重复出现的普通跨域结论应自动生效")
        expect(record.upstreamMemoryIDs.count == 2, "持久化记录必须保留上游记忆")
        try record.validate()

        let confirmed = HoloCrossDomainFusionService.evaluate(
            safeOutput,
            for: candidate,
            priorOccurrenceCount: 0,
            userConfirmed: true,
            now: now
        )
        guard case .persist(let confirmedRecord) = confirmed else {
            fatalError("用户确认后应允许持久化")
        }
        expect(confirmedRecord.state == .active && confirmedRecord.userDecision == .confirmed,
               "用户确认的敏感跨域结论应立即生效")

        let habit = try makeRecord(
            domain: .habit,
            anchor: anchor,
            lineage: "habit-run-1",
            start: now.addingTimeInterval(-6 * 86_400),
            end: now
        )
        let normalCandidate = try require(
            HoloCrossDomainCandidateBuilder.build(from: [finance, habit]).first,
            "普通跨域候选不存在"
        )
        var normalOutput = safeOutput
        normalOutput.upstreamMemoryIDs = normalCandidate.sourceMemoryIDs
        normalOutput.evidenceIDs = normalCandidate.evidenceRefs.map(\.id)
        normalOutput.requestedStorageClass = .normal
        let firstNormal = HoloCrossDomainFusionService.evaluate(
            normalOutput,
            for: normalCandidate,
            priorOccurrenceCount: 0,
            userConfirmed: false,
            now: now
        )
        guard case .persist(let firstNormalRecord) = firstNormal else {
            fatalError("首次普通跨域结论应进入待确认")
        }
        expect(firstNormalRecord.state == .candidate &&
               firstNormalRecord.adoptionMetadata?.reason == .firstCrossDomainInference,
               "首次普通跨域结论必须等待确认")
        let repeatedNormal = HoloCrossDomainFusionService.evaluate(
            normalOutput,
            for: normalCandidate,
            priorOccurrenceCount: 1,
            userConfirmed: false,
            now: now
        )
        guard case .persist(let repeatedNormalRecord) = repeatedNormal else {
            fatalError("重复支持的普通跨域结论应落盘")
        }
        expect(repeatedNormalRecord.state == .active &&
               repeatedNormalRecord.adoptionMetadata?.reason == .repeatedCrossDomainInference,
               "重复支持的普通跨域结论应自动采用")

        var pendingFinance = finance
        pendingFinance.state = .candidate
        expect(
            HoloCrossDomainCandidateBuilder.build(from: [pendingFinance, habit]).isEmpty,
            "待确认记忆不得参与跨域推断"
        )

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
        sourceID: String? = nil,
        claimKind: HoloMemoryClaimKind = .recurringPattern
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
            claimKind: claimKind,
            anchors: [anchor]
        )
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            subjectKey: anchor.stableKey,
            anchorRefs: [anchor],
            claimKind: claimKind,
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
            sensitivity: .normal,
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
