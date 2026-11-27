//
//  MemoryExtractionCostSlimTests.swift
//  HoloTests
//
//  记忆萃取瘦身（2026-10-06 成本体检）：域萃取请求白名单投影/上限/排序稳定性、
//  个人萃取候选宽召回预筛与 prompt 顺序。全部是请求文本层的性质——包内完整
//  记录与 Validator 数据流不受影响是硬前提。
//

import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo

// 进测试工程后的断言出口：记为用例失败并继续，不再崩掉整个测试进程。
// 只在本文件生效（外层 #if HOLO_XCTEST_BRIDGE 已保证仅测试工程编译）；独立脚本运行仍用标准库的 fatalError / precondition。
private func fatalError(_ message: @autoclosure () -> String, file: StaticString = #filePath, line: UInt = #line) {
    XCTFail(message(), file: file, line: line)
}

#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try MemoryExtractionCostSlimTests.main()
    }
}
#endif
struct MemoryExtractionCostSlimTests {
    private static var assertions = 0

    static func main() throws {
        try testDomainRequestWhitelistAndOrder()
        try testDomainRequestLimitKeepsRecent()
        try testDomainRequestSortStability()
        try testPackageKeepsFullRecordsForValidator()
        try testPersonalCandidateWideRecall()
        try testPersonalCandidateLimitPrefersOverlap()
        try testPersonalPromptOrderAndSort()
        try testPersonalCandidateOrderStableForCache()
        print("MemoryExtractionCostSlimTests: \(assertions) assertions passed")
    }

    // MARK: - 域萃取请求投影

    private static func testDomainRequestWhitelistAndOrder() throws {
        let package = HoloDomainObservationPackageBuilder.build(
            domain: .thought,
            window: .init(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200)),
            signals: [try thoughtSignal(id: "sig-1")],
            existingMemories: [try domainRecord(id: "mem-a")]
        )
        let request = try HoloDomainObservationPackageBuilder.makeRequest(package)

        guard let root = try JSONSerialization.jsonObject(
            with: Data(request.userDataJSON.utf8)
        ) as? [String: Any] else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail("请求必须是 JSON 对象")
            return
            #else
            fatalError("请求必须是 JSON 对象")
            #endif
        }
        guard let memories = root["existingMemories"] as? [[String: Any]],
              memories.count == 1 else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail("existingMemories 投影后必须保留条目")
            return
            #else
            fatalError("existingMemories 投影后必须保留条目")
            #endif
        }
        let keys = Set(memories[0].keys)
        expect(
            keys == ["id", "claimKind", "persistenceClass", "state",
                     "displaySummary", "aiUseSummary", "updatedAt", "anchors"],
            "既有记忆请求视图必须是 8 字段白名单，实际键：\(keys.sorted())"
        )
        expect(
            request.userDataJSON.range(of: "\"existingMemories\"")!.lowerBound
                < request.userDataJSON.range(of: "\"signals\"")!.lowerBound,
            "稳定块 existingMemories 必须排在 signals 之前（缓存前缀）"
        )
    }

    private static func testDomainRequestLimitKeepsRecent() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var records: [HoloMemoryRecord] = []
        for index in 0..<250 {
            records.append(try domainRecord(
                id: String(format: "mem-%03d", index),
                updatedAt: now.addingTimeInterval(TimeInterval(index * 60))
            ))
        }
        let package = HoloDomainObservationPackageBuilder.build(
            domain: .thought,
            window: .init(start: now, end: now),
            signals: [try thoughtSignal(id: "sig-1")],
            existingMemories: records
        )
        let request = try HoloDomainObservationPackageBuilder.makeRequest(package)
        guard let root = try JSONSerialization.jsonObject(
            with: Data(request.userDataJSON.utf8)
        ) as? [String: Any],
              let memories = root["existingMemories"] as? [[String: Any]] else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail("请求必须是 JSON 对象")
            return
            #else
            fatalError("请求必须是 JSON 对象")
            #endif
        }
        expect(memories.count == 200, "250 条既有记忆必须截断到上限 200，实际 \(memories.count)")
        let ids = Set(memories.map { $0["id"] as? String ?? "" })
        expect(!ids.contains("mem-000"), "最老的记录应被截掉")
        expect(ids.contains("mem-249"), "最新的记录必须保留")
    }

    private static func testDomainRequestSortStability() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var records: [HoloMemoryRecord] = []
        for index in 0..<30 {
            records.append(try domainRecord(
                id: String(format: "mem-%02d", index),
                updatedAt: now.addingTimeInterval(TimeInterval((index * 37) % 30 * 60))
            ))
        }
        let first = try requestJSON(
            records: records,
            signals: [try thoughtSignal(id: "sig-1")]
        )
        let second = try requestJSON(
            records: records.reversed() + [],   // 输入顺序打乱
            signals: [try thoughtSignal(id: "sig-1")]
        )
        expect(first == second, "同集合不同输入顺序必须产出字节级相同的请求（缓存前缀稳定）")
    }

    private static func testPackageKeepsFullRecordsForValidator() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var records: [HoloMemoryRecord] = []
        for index in 0..<250 {
            records.append(try domainRecord(
                id: String(format: "mem-%03d", index),
                updatedAt: now.addingTimeInterval(TimeInterval(index))
            ))
        }
        let package = HoloDomainObservationPackageBuilder.build(
            domain: .thought,
            window: .init(start: now, end: now),
            signals: [try thoughtSignal(id: "sig-1")],
            existingMemories: records
        )
        expect(
            package.existingMemories.count == 250,
            "包内完整记录不因请求截断而丢失（Validator 反证/取代改写依赖全量）"
        )
        expect(
            package.existingMemories.first?.evidenceRefs.isEmpty == false,
            "包内记录保留证据引用等完整字段"
        )
    }

    // MARK: - 个人萃取候选预筛

    private static func testPersonalCandidateWideRecall() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = HoloContextSegment(
            sourceID: "src-1", revision: "r1",
            utf16Location: 0, utf16Length: 12, text: "今天买了苹果和洋葱"
        )
        let sourcesByID = [
            "src-1": HoloContextSourceSnapshot(
                sourceID: "src-1", sourceDomain: "thought", sourceKind: "userNote",
                revisionDigest: "r1", sourceCreatedAt: now, sourceUpdatedAt: now,
                plainText: "今天买了苹果和洋葱", sensitivity: .normal, accessGeneration: 1
            )
        ]
        // 同域老命题（无文字重合）：带——域是强相关信号。
        let sameDomainOld = try personalRecord(
            id: "ctx-same", domain: .thought, updatedAt: now.addingTimeInterval(-90 * 86_400),
            statement: "用户长期关注睡眠规律"
        )
        // 跨域但文字重合（「苹果」双字命中）：带。
        let crossDomainOverlap = try personalRecord(
            id: "ctx-overlap", domain: .finance, updatedAt: now.addingTimeInterval(-90 * 86_400),
            statement: "用户常在盒马买苹果"
        )
        // 跨域、无重合、8 天前更新：不带。
        let staleIrrelevant = try personalRecord(
            id: "ctx-stale", domain: .finance, updatedAt: now.addingTimeInterval(-8 * 86_400),
            statement: "用户使用招商银行信用卡"
        )
        let payloads = HoloPersonalContextExtractor.promptCandidatePayloads(
            from: [sameDomainOld, crossDomainOverlap, staleIrrelevant],
            package: [segment],
            sourcesByID: sourcesByID,
            now: now
        )
        let ids = Set(payloads.map(\.contextID))
        expect(ids.contains("ctx-same"), "同域候选必须全带（宽召回）")
        expect(ids.contains("ctx-overlap"), "文字重合的跨域候选必须带")
        expect(!ids.contains("ctx-stale"), "跨域无重合且超 7 天的候选不进请求")
        expect(ids.count == 2, "预筛结果集合必须精确，实际 \(ids)")
    }

    private static func testPersonalCandidateLimitPrefersOverlap() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = HoloContextSegment(
            sourceID: "src-1", revision: "r1",
            utf16Location: 0, utf16Length: 12, text: "今天买了苹果和洋葱"
        )
        let sourcesByID = [
            "src-1": HoloContextSourceSnapshot(
                sourceID: "src-1", sourceDomain: "thought", sourceKind: "userNote",
                revisionDigest: "r1", sourceCreatedAt: now, sourceUpdatedAt: now,
                plainText: "今天买了苹果和洋葱", sensitivity: .normal, accessGeneration: 1
            )
        ]
        var records: [HoloMemoryRecord] = []
        for index in 0..<400 {
            records.append(try personalRecord(
                id: String(format: "ctx-%03d", index),
                domain: .thought,
                updatedAt: now.addingTimeInterval(TimeInterval(-index * 60)),
                statement: "与包文本毫无重合的既有序号命题 \(index)"
            ))
        }
        // 最老的记录但与包文字重合：截断后必须仍在（重合优先于时间近）。
        let oldestOverlap = try personalRecord(
            id: "ctx-oldest-overlap", domain: .thought,
            updatedAt: now.addingTimeInterval(-400 * 86_400),
            statement: "很久以前也买过苹果"
        )
        records.append(oldestOverlap)

        let payloads = HoloPersonalContextExtractor.promptCandidatePayloads(
            from: records, package: [segment], sourcesByID: sourcesByID, now: now
        )
        expect(payloads.count == 300, "401 条候选必须截断到上限 300，实际 \(payloads.count)")
        expect(
            payloads.contains { $0.contextID == "ctx-oldest-overlap" },
            "文字重合的候选在超限截断时必须优先保留"
        )
        expect(
            !payloads.contains { $0.contextID == "ctx-399" },
            "无重合且最旧的同域候选应被截掉"
        )
    }

    private static func testPersonalPromptOrderAndSort() throws {
        let candidates = (0..<5).map { index in
            HoloPersonalContextPayloadV1(
                contextID: "id-\(4 - index)",
                statement: "命题 \(4 - index)",
                relationText: "r",
                epistemicStatus: .declared,
                admission: .init(level: .unreviewed, policyVersion: 1, decidedAt: Date(timeIntervalSince1970: 100))
            )
        }
        let segment = HoloContextSegment(
            sourceID: "src-1", revision: "r1",
            utf16Location: 0, utf16Length: 4, text: "内容"
        )
        let prompt = HoloPersonalContextPromptBuilder.extractionPrompt(
            packageSegments: [segment],
            sourcesByID: [:],
            existingCandidates: candidates
        )
        expect(
            prompt.hasPrefix("{\"existingCandidates\":["),
            "稳定块 existingCandidates 必须在 JSON 开头（缓存前缀）"
        )
        // 2026-11-27：顺序由 promptCandidatePayloads 按创建先后钉死，Prompt 原样保持输入顺序
        //（按 contextID 排会让新记忆插进清单中间，打断缓存前缀）。
        var positions: [Int] = []
        for id in candidates.map(\.contextID) {
            guard let range = prompt.range(of: "\"contextID\":\"\(id)\"") else {
                expect(false, "候选 \(id) 必须进 Prompt")
                return
            }
            positions.append(range.lowerBound.utf16Offset(in: prompt))
        }
        expect(positions == positions.sorted(), "候选必须保持调用方给定的顺序")
    }

    /// 降本（2026-11-27 P4）：清单按创建先后排列，新记忆只追加到末尾——
    /// 相邻请求前缀一致，上游隐式缓存按命中价计费（生产实测同前缀命中 95%）。
    private static func testPersonalCandidateOrderStableForCache() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let segment = HoloContextSegment(
            sourceID: "src-1", revision: "r1",
            utf16Location: 0, utf16Length: 4, text: "内容"
        )
        let sourcesByID = [
            "src-1": HoloContextSourceSnapshot(
                sourceID: "src-1", sourceDomain: "thought", sourceKind: "userNote",
                revisionDigest: "r1", sourceCreatedAt: now, sourceUpdatedAt: now,
                plainText: "内容", sensitivity: .normal, accessGeneration: 1
            )
        ]
        // contextID 字典序与创建先后相反：旧 = ctx-b，新 = ctx-a。
        let older = try personalRecord(id: "ctx-b", domain: .thought,
                                       updatedAt: now.addingTimeInterval(-30 * 86_400), statement: "旧命题")
        let newer = try personalRecord(id: "ctx-a", domain: .thought,
                                       updatedAt: now.addingTimeInterval(-10 * 86_400), statement: "新命题")
        let first = HoloPersonalContextExtractor.promptCandidatePayloads(
            from: [newer, older], package: [segment], sourcesByID: sourcesByID, now: now
        ).map(\.contextID)
        expect(first == ["ctx-b", "ctx-a"], "清单必须按创建先后排列，实际 \(first)")

        let appended = try personalRecord(id: "ctx-0", domain: .thought, updatedAt: now, statement: "刚写入的命题")
        let second = HoloPersonalContextExtractor.promptCandidatePayloads(
            from: [appended, newer, older], package: [segment], sourcesByID: sourcesByID, now: now
        ).map(\.contextID)
        expect(second == ["ctx-b", "ctx-a", "ctx-0"], "新记忆只能追加在末尾，不得打断已有前缀，实际 \(second)")
    }

    // MARK: - 夹具

    private static func thoughtSignal(id: String) throws -> HoloDomainMemorySignal {
        try HoloDomainSignalBuilder.make(
            id: id,
            domain: .thought,
            kind: .explicitUserText,
            evidence: HoloMemoryEvidenceRef(
                id: "\(id)-evidence", kind: .entityRef, sourceDomain: .thought,
                lineageKey: "thought:\(id)-evidence", sourceID: "\(id)-evidence",
                revisionDigest: "revision", observedAt: Date(timeIntervalSince1970: 150)
            ),
            anchors: [try HoloMemoryAnchorRef(type: .thoughtTopic, value: "daily")]
        )
    }

    private static func domainRecord(
        id: String,
        updatedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
        domain: HoloMemoryDomain = .thought
    ) throws -> HoloMemoryRecord {
        let evidence = HoloMemoryEvidenceRef(
            id: "\(id)-evidence", kind: .entityRef, sourceDomain: domain,
            lineageKey: "\(domain.rawValue):\(id)-evidence", sourceID: "\(id)-evidence",
            revisionDigest: "revision", observedAt: Date(timeIntervalSince1970: 150)
        )
        return HoloMemoryRecord(
            id: id,
            scope: .domain,
            primaryDomain: domain,
            sourceDomains: [domain],
            subjectKey: "\(domain.rawValue):\(id)",
            anchorRefs: [try HoloMemoryAnchorRef(type: .thoughtTopic, value: id)],
            claimKind: .recurringPattern,
            persistenceClass: .phase,
            displaySummary: "测试记忆 \(id)",
            aiUseSummary: "测试记忆用途 \(id)",
            prohibitedInferences: ["不得推断"],
            evidenceRefs: [evidence, evidence, evidence],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            confidenceScore: 0.8,
            freshnessScore: 1,
            scoringVersion: HoloMemoryScorer.currentVersion,
            scoreComputedAt: updatedAt,
            extractorVersion: 1,
            promptVersion: 1,
            state: .active,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: updatedAt.addingTimeInterval(-86_400),
            updatedAt: updatedAt
        )
    }

    private static func personalRecord(
        id: String,
        domain: HoloMemoryDomain,
        updatedAt: Date,
        statement: String
    ) throws -> HoloMemoryRecord {
        var record = try domainRecord(id: id, updatedAt: updatedAt, domain: domain)
        record.personalContext = HoloPersonalContextPayloadEnvelope(
            v1: HoloPersonalContextPayloadV1(
                contextID: id,
                statement: statement,
                relationText: "r",
                epistemicStatus: .observed,
                admission: .init(
                    level: .unreviewed, policyVersion: 1,
                    decidedAt: Date(timeIntervalSince1970: 100)
                )
            )
        )
        return record
    }

    private static func requestJSON(
        records: [HoloMemoryRecord],
        signals: [HoloDomainMemorySignal]
    ) throws -> String {
        let package = HoloDomainObservationPackageBuilder.build(
            domain: .thought,
            window: .init(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200)),
            signals: signals,
            existingMemories: records
        )
        return try HoloDomainObservationPackageBuilder.makeRequest(package).userDataJSON
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        guard condition() else {
            #if HOLO_XCTEST_BRIDGE
            XCTFail(message)
            return
            #else
            fatalError(message)
            #endif
        }
    }
}
