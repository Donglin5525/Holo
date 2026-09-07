//
//  ContextRetrievalStandaloneTests.swift
//  HoloTests
//
//  P5 检索与时间验证：时间解析（周期键/月末钳制/重叠判定/实例状态）、
//  向量缓存（键隔离/校验/淘汰/失效）、混合检索（信号合并/份额/选取/降级词法/反证/实例状态）。
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
        try await ContextRetrievalStandaloneTests.main()
    }
}
#endif
struct ContextRetrievalStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await testTemporalResolverBasics()
        testTemporalOverlapAndActive()
        try await testEmbeddingStoreLifecycle()
        try await testRetrievalHybridMergeAndShares()
        try await testRetrievalDegradedLexicalFallback()
        try await testRetrievalOccurrenceAndContradiction()
        print("ContextRetrievalStandaloneTests: \(assertionCount) 断言全部通过")
    }

    // MARK: 工厂

    static var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return c
    }

    static func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.date(from: string)!
    }

    static func candidate(
        recordID: String,
        statement: String,
        subjects: [HoloContextPartyRef] = [],
        temporal: HoloContextTemporalV1? = nil,
        conditionText: String? = nil,
        linkedContextIDs: [String] = [],
        epistemicStatus: HoloContextEpistemicStatus = .declared
    ) -> HoloContextAdviceCandidate {
        HoloContextAdviceCandidate(
            recordID: recordID,
            versionID: "\(recordID)@v1",
            payload: HoloPersonalContextPayloadV1(
                contextID: "ctx-\(recordID)",
                statement: statement,
                subjects: subjects,
                relationText: statement,
                epistemicStatus: epistemicStatus,
                applicability: HoloContextApplicabilityV1(conditionText: conditionText),
                temporal: temporal,
                basis: [HoloContextBasisRef(sourceID: "thought-1", sourceRevision: "rev-1")],
                linkedContextIDs: linkedContextIDs,
                admission: HoloContextAdmissionV1(
                    level: .adviceEligible,
                    policyVersion: 1,
                    decidedAt: Date(timeIntervalSince1970: 0)
                )
            ),
            needsQualifiedExpression: epistemicStatus == .inferred
        )
    }

    // MARK: 时间解析

    static func testTemporalResolverBasics() async throws {
        let cal = calendar
        // 周期键：月/周。
        expect(
            HoloContextTemporalResolver.monthPeriodKey(for: date("2026-09-06"), calendar: cal) == "2026-09",
            "月度周期键 yyyy-MM"
        )
        let weekKey = HoloContextTemporalResolver.weekPeriodKey(for: date("2026-09-06"), calendar: cal)
        expect(weekKey.hasPrefix("2026-W"), "周度周期键 ISO 周（实际 \(weekKey)）")

        // 月末钳制：1/31 在 2 月不溢出到 3 月。
        let februaryOccurrence = HoloContextTemporalResolver.nextOccurrence(
            of: HoloContextRecurrenceV1(frequency: .monthly, dayOfMonth: 31),
            after: date("2026-02-01"),
            calendar: cal
        )
        expect(februaryOccurrence != nil, "月末钳制有结果")
        if let occurrence = februaryOccurrence {
            let day = cal.component(.day, from: occurrence.date)
            let month = cal.component(.month, from: occurrence.date)
            expect(month == 2 && day == 28, "2 月 31 日钳制到 28（2026 非闰年），实际 \(month)/\(day)")
            expect(occurrence.periodKey == "2026-02", "周期键正确")
        }

        // 跨年：12 月的下一次月度在次年 1 月。
        let nextJanuary = HoloContextTemporalResolver.nextOccurrence(
            of: HoloContextRecurrenceV1(frequency: .monthly, dayOfMonth: 15),
            after: date("2026-12-20"),
            calendar: cal
        )
        expect(nextJanuary?.periodKey == "2027-01", "跨年滚动到次年 1 月")

        // 未知锚点返回 nil（模糊时间保留原文，不伪造）。
        let unknownAnchor = HoloContextTemporalResolver.nextOccurrence(
            of: HoloContextRecurrenceV1(frequency: .weekly),
            after: date("2026-09-06"),
            calendar: cal
        )
        expect(unknownAnchor == nil, "周锚点缺失不得伪造下次发生")

        // 实例状态：无证据 unknown（不默认 pending）。
        expect(
            HoloContextTemporalResolver.occurrenceStatus(
                occurrences: [], contextID: "ctx-1", periodKey: "2026-09"
            ) == .unknown,
            "无完成证据时 unknown"
        )
        expect(
            HoloContextTemporalResolver.occurrenceStatus(
                occurrences: [HoloContextOccurrence(contextID: "ctx-1", periodKey: "2026-09", status: .done)],
                contextID: "ctx-1",
                periodKey: "2026-09"
            ) == .done,
            "有完成证据 done"
        )
    }

    static func testTemporalOverlapAndActive() {
        let now = date("2026-09-06")
        let ongoing = HoloContextTemporalV1(kind: .ongoing, originalExpression: "持续")
        expect(
            HoloContextTemporalResolver.overlaps(
                temporal: ongoing, rangeStart: now, rangeEnd: now.addingTimeInterval(86_400), now: now
            ),
            "ongoing 恒重叠"
        )
        let pastEvent = HoloContextTemporalV1(
            kind: .event,
            originalExpression: "去年",
            validFrom: date("2025-01-01"),
            validTo: date("2025-01-02")
        )
        expect(
            !HoloContextTemporalResolver.overlaps(
                temporal: pastEvent, rangeStart: now, rangeEnd: now.addingTimeInterval(86_400), now: now
            ),
            "过去事件不重叠"
        )
        let expired = HoloContextTemporalV1(
            kind: .ongoing, originalExpression: "已结束", validTo: date("2026-01-01")
        )
        expect(
            !HoloContextTemporalResolver.isActive(temporal: expired, at: now),
            "失效 ongoing 不再生效"
        )
    }

    // MARK: 向量缓存

    static func testEmbeddingStoreLifecycle() async throws {
        let store = HoloContextEmbeddingStore(
            persistence: HoloContextInMemoryEmbeddingPersistence()
        )
        let textA = "文本A"
        let hashA = HoloContextEmbeddingCacheKey.contentHash(of: textA)
        let key = HoloContextEmbeddingCacheKey.make(
            contextID: "ctx-1", sourceID: "t-1", contentHash: hashA,
            modelID: "m", modelVersion: "v1", dimensions: 3,
            policyVersion: 1, accessGeneration: 5
        )
        // 键隔离：任一版本要素变化即不同键。
        let keyV2 = HoloContextEmbeddingCacheKey.make(
            contextID: "ctx-1", sourceID: "t-1", contentHash: "h2",
            modelID: "m", modelVersion: "v1", dimensions: 3,
            policyVersion: 1, accessGeneration: 5
        )
        expect(key != keyV2, "内容变化产生不同缓存键")

        // 写入与命中。
        try await store.store(entries: [HoloContextEmbeddingEntry(
            cacheKey: key,
            contextID: "ctx-1",
            sourceID: "t-1",
            contentHash: hashA,
            modelID: "m",
            modelVersion: "v1",
            dimensions: 3,
            policyVersion: 1,
            accessGeneration: 5,
            vector: [0.1, 0.2, 0.3],
            createdAt: date("2026-09-01")
        )], now: date("2026-09-06"))
        let hit = try await store.cachedVector(
            contextID: "ctx-1", sourceID: "t-1", text: textA,
            modelID: "m", modelVersion: "v1", dimensions: 3,
            policyVersion: 1, accessGeneration: 5
        )
        expect(hit != nil, "同键命中（contentHash 一致）")

        // 内容变化（hash 不同）→ 未命中。
        let miss = try await store.cachedVector(
            contextID: "ctx-1", sourceID: "t-1", text: "文本B（改过）",
            modelID: "m", modelVersion: "v1", dimensions: 3,
            policyVersion: 1, accessGeneration: 5
        )
        expect(miss == nil, "内容变化不命中旧向量")

        // 非法向量被拒：零范数/含 NaN/维度不符。
        expect(!HoloContextEmbeddingStore.isValid([0, 0, 0], dimensions: 3), "零范数非法")
        expect(!HoloContextEmbeddingStore.isValid([0.1, Double.nan, 0.3], dimensions: 3), "NaN 非法")
        expect(!HoloContextEmbeddingStore.isValid([0.1, 0.2], dimensions: 3), "维度不符非法")
        expect(HoloContextEmbeddingStore.isValid([0.1, 0.2, 0.3], dimensions: 3), "合法向量通过")

        // 相似度。
        let similarity = HoloContextEmbeddingStore.cosineSimilarity([1, 0, 0], [1, 0, 0])
        expect(abs((similarity ?? 0) - 1.0) < 0.0001, "同向相似度 1")
        let orthogonal = HoloContextEmbeddingStore.cosineSimilarity([1, 0], [0, 1])
        expect(abs((orthogonal ?? 1) - 0.0) < 0.0001, "正交相似度 0")

        // 来源失效。
        let removed = try await store.invalidate(sourceIDs: ["t-1"])
        expect(removed == 1, "来源失效清除条目")
        let afterRemoval = try await store.cachedVector(
            contextID: "ctx-1", sourceID: "t-1", text: "文本A",
            modelID: "m", modelVersion: "v1", dimensions: 3,
            policyVersion: 1, accessGeneration: 5
        )
        expect(afterRemoval == nil, "失效后不可命中")
        _ = textA

        // 同 contextID 覆盖旧版本。
        try await store.store(entries: [
            HoloContextEmbeddingEntry(
                cacheKey: key, contextID: "ctx-1", sourceID: "t-1", contentHash: hashA,
                modelID: "m", modelVersion: "v1", dimensions: 3,
                policyVersion: 1, accessGeneration: 5,
                vector: [0.1, 0.2, 0.3], createdAt: date("2026-09-01")
            ),
        ], now: date("2026-09-06"))
        let newKey = HoloContextEmbeddingCacheKey.make(
            contextID: "ctx-1", sourceID: "t-1", contentHash: hashA,
            modelID: "m", modelVersion: "v2", dimensions: 3,
            policyVersion: 1, accessGeneration: 5
        )
        try await store.store(entries: [
            HoloContextEmbeddingEntry(
                cacheKey: newKey, contextID: "ctx-1", sourceID: "t-1", contentHash: hashA,
                modelID: "m", modelVersion: "v2", dimensions: 3,
                policyVersion: 1, accessGeneration: 5,
                vector: [0.3, 0.2, 0.1], createdAt: date("2026-09-06")
            ),
        ], now: date("2026-09-06"))
        let oldHit = try await store.cachedVector(
            contextID: "ctx-1", sourceID: "t-1", text: textA,
            modelID: "m", modelVersion: "v1", dimensions: 3,
            policyVersion: 1, accessGeneration: 5
        )
        expect(oldHit == nil, "同 contextID 新版本覆盖旧版本条目")
    }

    // MARK: 混合检索

    /// 语义提供方假件。
    final class FakeSemantic: HoloContextSemanticSearchProviding, @unchecked Sendable {
        var scores: [String: Double]
        var shouldThrow = false
        init(scores: [String: Double]) { self.scores = scores }
        func semanticCandidateIDs(query: String, directions: [String]) async throws -> [String: Double] {
            if shouldThrow { throw NSError(domain: "offline", code: 1) }
            return scores
        }
    }

    static func frame(utterance: String = "帮我想想下周末爸妈来昆明怎么安排") -> HoloPlanningRequestFrame {
        HoloPlanningRequestFrame(
            utterance: utterance,
            goalSummary: "安排父母来访的周末行程",
            successConditions: ["行程顺畅，父母不累"],
            timeRangeExpression: "下周末",
            unknowns: ["到达时间"],
            retrievalDirections: ["饮食限制", "交通偏好"],
            referenceTime: date("2026-09-06")
        )
    }

    static func testRetrievalHybridMergeAndShares() async throws {
        let now = date("2026-09-06")
        let catalog = [
            candidate( // 主体匹配+时间重叠
                recordID: "r-salt",
                statement: "父亲被要求低盐饮食",
                subjects: [HoloContextPartyRef(label: "父亲", scope: .person)],
                temporal: HoloContextTemporalV1(kind: .ongoing, originalExpression: "持续")
            ),
            candidate( // 时间重叠（周期规则）
                recordID: "r-mortgage",
                statement: "房贷每月 15 号自动扣款",
                temporal: HoloContextTemporalV1(
                    kind: .recurring,
                    originalExpression: "每月 15 号",
                    recurrence: HoloContextRecurrenceV1(frequency: .monthly, dayOfMonth: 15)
                )
            ),
            candidate( // 纯语义命中（低相关历史）
                recordID: "r-semantic-only",
                statement: "三年前学过日语入门"
            ),
            candidate( // 无任何信号：不进结果
                recordID: "r-noise",
                statement: "无关记录星座运势"
            ),
        ]
        let service = HoloContextRetrievalService(
            semanticProvider: FakeSemantic(scores: [
                "r-semantic-only": 0.9,
                "r-noise": 0.8,
            ])
        )
        let result = await service.retrieve(
            frame: frame(),
            catalog: catalog,
            calendar: calendar,
            now: now
        )
        let ids = result.entries.map(\.recordID)
        expect(ids.contains("r-salt"), "主体匹配命中")
        expect(ids.contains("r-mortgage"), "时间重叠命中")
        expect(ids.contains("r-semantic-only"), "语义命中")
        expect(ids.contains("r-noise"), "语义分即信号（provider 返回的候选应命中）")
        expect(result.entries.count == 4, "四条全部命中")
        expect(result.semanticCoverage == .full, "语义可用不降级")
        expect(result.selected.count <= 8, "选取不超上限")
        expect(result.selected.contains { $0.recordID == "r-salt" }, "高信号条目优先入选")
    }

    static func testRetrievalDegradedLexicalFallback() async throws {
        let now = date("2026-09-06")
        let catalog = [
            candidate(recordID: "r-car", statement: "母亲晕车，不适应山路汽车出行",
                      subjects: [HoloContextPartyRef(label: "母亲", scope: .person)]),
            candidate(recordID: "r-else", statement: "公司季度考评加分项"),
        ]
        let offline = FakeSemantic(scores: [:])
        offline.shouldThrow = true
        let service = HoloContextRetrievalService(semanticProvider: offline)
        let result = await service.retrieve(
            frame: frame(),
            catalog: catalog,
            calendar: calendar,
            now: now
        )
        expect(result.semanticCoverage == .degraded, "语义不可用标记 degraded")
        expect(result.entries.contains { $0.recordID == "r-car" }, "降级词法仍召回基础候选（母亲/晕车词命中）")
        // 无 provider 同样降级。
        let noProvider = HoloContextRetrievalService(semanticProvider: nil)
        let result2 = await noProvider.retrieve(
            frame: frame(), catalog: catalog, calendar: calendar, now: now
        )
        expect(result2.semanticCoverage == .degraded, "无 provider 即降级（不算正常召回已验收）")
    }

    static func testRetrievalOccurrenceAndContradiction() async throws {
        let now = date("2026-09-06")
        let catalog = [
            candidate(
                recordID: "r-heating",
                statement: "每年负责缴纳老家暖气费",
                temporal: HoloContextTemporalV1(
                    kind: .recurring,
                    originalExpression: "一年一缴",
                    recurrence: HoloContextRecurrenceV1(frequency: .yearly, dayOfMonth: 1, month: 9)
                )
            ),
        ]
        let service = HoloContextRetrievalService(semanticProvider: FakeSemantic(scores: [:]))
        // 本月已完成的实例证据。
        let result = await service.retrieve(
            frame: frame(),
            catalog: catalog,
            occurrences: [
                HoloContextOccurrence(
                    contextID: "ctx-r-heating",
                    periodKey: HoloContextTemporalResolver.monthPeriodKey(for: now, calendar: calendar),
                    status: .done,
                    evidenceRefs: ["txn-1"]
                )
            ],
            counterEvidenceByRecordID: ["r-heating": ["r-refund"]],
            calendar: calendar,
            now: now
        )
        let heating = result.entries.first { $0.recordID == "r-heating" }
        expect(heating?.currentOccurrenceStatus == .done, "本周期完成状态进入条目（不当未做）")
        expect(result.contradictions["r-heating"] == ["r-refund"], "反证记录被标注")
    }
}
