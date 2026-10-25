//
//  DiscoverySchemaTests.swift
//  HoloTests
//
//  「一个发现」G1 契约测试：ai-output.schema.json examples 正反例 + 合成材料构建往返。
//  待挂载 HoloTests target（本文件为新增，未改动 pbxproj，由主会话统一挂载）。
//
//  反例纪律：未知字段/缺 verdict/claimID 重复/comparisonPeriods 类型错配/quote 超长/
//  空候选带 none/accept 含 unsupported/双文档尾部垃圾——全部必须拒。
//

// 待挂载 HoloTests target
import XCTest
@testable import Holo

final class DiscoverySchemaTests: XCTestCase {

    // MARK: - 材料定位（#filePath 相对定位到仓库根）

    private static let planDirectory = "docs/_common/plans/2026-10-23-holo-ai-discovery-implementation"

    /// 从测试文件位置向上找仓库根（含 docs/_common/plans/... 的目录）
    private static func locateRepoRoot() -> URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            let candidate = directory.appendingPathComponent(planDirectory)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private static func loadJSON(_ fileName: String) throws -> Data {
        guard let root = locateRepoRoot() else {
            throw XCTSkip("未定位到仓库根，跳过 \(fileName)")
        }
        let url = root.appendingPathComponent(planDirectory).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else {
            print("材料缺失：\(url.path)")
            throw XCTSkip("材料缺失：\(url.path)")
        }
        return data
    }

    private static func schemaExamples() throws -> [[String: Any]] {
        let data = try loadJSON("ai-output.schema.json")
        let object = try JSONSerialization.jsonObject(with: data)
        guard let examples = (object as? [String: Any])?["examples"] as? [[String: Any]] else {
            throw XCTSkip("schema examples 结构不符")
        }
        return examples
    }

    private func jsonData(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - 合成 fixture DTO

    private struct FixtureFile: Codable {
        let fixtureVersion: Int
        let cases: [FixtureCase]
    }

    private struct FixtureCase: Codable {
        let id: String
        let positive: Bool
        let type: String?
        let name: String
        let evidence: [FixtureEvidence]
        let counterEvidence: [FixtureEvidence]?
        let coverageComplete: Bool?
        let proposedClaim: String
        let expectedVerdict: String
        let forbiddenMeaning: [String]?
    }

    private struct FixtureEvidence: Codable {
        let id: String
        let domain: String
        let occurredAt: String?
        let recordedAt: String?
        let lineage: String
        let text: String
    }

    private static func loadFixtures() throws -> FixtureFile {
        let data = try loadJSON("synthetic-fixtures.json")
        return try JSONDecoder().decode(FixtureFile.self, from: data)
    }

    // MARK: - Happy path（schema examples）

    func test_候选信封_空结果example解包且校验通过() throws {
        let example = try Self.schemaExamples()[0]
        let envelope = try DiscoveryAIPacket.decodeCandidateEnvelope(from: jsonData(example))
        XCTAssertEqual(envelope.runID, "run-empty")
        XCTAssertTrue(envelope.candidates.isEmpty)
        XCTAssertEqual(envelope.noFindingReason, .noMaterial)
        XCTAssertTrue(envelope.validate().isEmpty, "\(envelope.validate())")
    }

    func test_候选信封_完整example解包且校验通过() throws {
        let example = try Self.schemaExamples()[1]
        let envelope = try DiscoveryAIPacket.decodeCandidateEnvelope(from: jsonData(example))
        XCTAssertEqual(envelope.candidates.count, 1)
        let candidate = try XCTUnwrap(envelope.candidates.first)
        XCTAssertEqual(candidate.type, .twoEpisodes)
        XCTAssertEqual(candidate.scopeKind, .twoEpisodes)
        XCTAssertEqual(candidate.claims.count, 2)
        XCTAssertEqual(candidate.titleClaimID, "C01-title")
        XCTAssertEqual(candidate.supportEvidenceIDs, ["E01", "E02"])
        XCTAssertTrue(envelope.validate().isEmpty, "\(envelope.validate())")
    }

    func test_核验信封_acceptExample解包且校验通过() throws {
        let example = try Self.schemaExamples()[2]
        let envelope = try DiscoveryAIPacket.decodeVerificationEnvelope(from: jsonData(example))
        XCTAssertEqual(envelope.candidateResults.count, 1)
        XCTAssertEqual(envelope.candidateResults.first?.verdict, .accept)
        XCTAssertTrue(envelope.validate().isEmpty, "\(envelope.validate())")
    }

    func test_核验信封_rejectExample解包且校验通过() throws {
        let example = try Self.schemaExamples()[3]
        let envelope = try DiscoveryAIPacket.decodeVerificationEnvelope(from: jsonData(example))
        XCTAssertEqual(envelope.candidateResults.first?.verdict, .reject)
        XCTAssertTrue(envelope.validate().isEmpty, "\(envelope.validate())")
    }

    // MARK: - 反例：必须拒绝（结构层）

    func test_拒绝_信封根级未知字段() throws {
        var example = try Self.schemaExamples()[0]
        example["controlToken"] = "should-reject"
        assertDecodeThrows(try jsonData(example), expectCode: .unknownField)
    }

    func test_拒绝_claim内未知字段() throws {
        var example = try Self.schemaExamples()[1]
        let candidates = try XCTUnwrap(example["candidates"] as? [[String: Any]])
        var claims = try XCTUnwrap(candidates[0]["claims"] as? [[String: Any]])
        claims[0]["confidence"] = 0.9
        var mutatedCandidate = candidates[0]
        mutatedCandidate["claims"] = claims
        example["candidates"] = [mutatedCandidate]
        assertDecodeThrows(try jsonData(example), expectCode: .unknownField)
    }

    func test_拒绝_缺失verdict() throws {
        var example = try Self.schemaExamples()[2]
        let results = try XCTUnwrap(example["candidateResults"] as? [[String: Any]])
        var claimResults = try XCTUnwrap(results[0]["claimResults"] as? [[String: Any]])
        claimResults[0].removeValue(forKey: "verdict")
        var mutated = results[0]
        mutated["claimResults"] = claimResults
        example["candidateResults"] = [mutated]
        assertVerificationDecodeThrows(try jsonData(example), expectCode: .missingRequiredField)
    }

    func test_拒绝_quote超长() throws {
        var example = try Self.schemaExamples()[1]
        let candidates = try XCTUnwrap(example["candidates"] as? [[String: Any]])
        var claims = try XCTUnwrap(candidates[0]["claims"] as? [[String: Any]])
        var citations = try XCTUnwrap(claims[0]["citations"] as? [[String: Any]])
        citations[0]["quote"] = String(repeating: "长", count: 401)
        claims[0]["citations"] = citations
        var mutatedCandidate = candidates[0]
        mutatedCandidate["claims"] = claims
        example["candidates"] = [mutatedCandidate]
        assertDecodeThrows(try jsonData(example), expectCode: .invalidLength)
    }

    func test_拒绝_尾部第二个JSON文档() throws {
        let example = try Self.schemaExamples()[0]
        let single = try jsonData(example)
        let doubled = single + Data("\n".utf8) + single
        assertDecodeThrows(doubled, expectCode: .multipleDocuments)
    }

    // MARK: - 反例：必须拒绝（跨字段 validate 层）

    func test_检出_claimID重复() throws {
        var example = try Self.schemaExamples()[1]
        let candidates = try XCTUnwrap(example["candidates"] as? [[String: Any]])
        var claims = try XCTUnwrap(candidates[0]["claims"] as? [[String: Any]])
        claims.append(claims[0]) // 同 claimID 再来一条（claims 3 条仍在上限内）
        var mutatedCandidate = candidates[0]
        mutatedCandidate["claims"] = claims
        example["candidates"] = [mutatedCandidate]

        let envelope = try DiscoveryAIPacket.decodeCandidateEnvelope(from: jsonData(example))
        let issues = envelope.validate()
        XCTAssertTrue(issues.contains { $0.code == .duplicateID }, "\(issues)")
    }

    func test_检出_two_episodes带comparisonPeriods() throws {
        var example = try Self.schemaExamples()[1]
        let candidates = try XCTUnwrap(example["candidates"] as? [[String: Any]])
        var mutatedCandidate = candidates[0]
        mutatedCandidate["comparisonPeriods"] = [
            ["start": "2026-10-01T00:00:00Z", "end": "2026-10-05T00:00:00Z"],
            ["start": "2026-10-10T00:00:00Z", "end": "2026-10-15T00:00:00Z"],
        ]
        example["candidates"] = [mutatedCandidate]

        let envelope = try DiscoveryAIPacket.decodeCandidateEnvelope(from: jsonData(example))
        let issues = envelope.validate()
        XCTAssertTrue(
            issues.contains { $0.code == .conditionalMismatch && $0.path.contains("comparisonPeriods") },
            "\(issues)"
        )
    }

    func test_检出_空候选但noFindingReason为none() throws {
        var example = try Self.schemaExamples()[0]
        example["noFindingReason"] = "none"

        let envelope = try DiscoveryAIPacket.decodeCandidateEnvelope(from: jsonData(example))
        XCTAssertEqual(envelope.candidates.count, 0)
        let issues = envelope.validate()
        XCTAssertTrue(issues.contains { $0.code == .mutexViolation }, "\(issues)")

        // 组合入口同样必须拒（G3 网络层用它，不允许漏跑 validate）
        XCTAssertThrowsError(try DiscoveryAIPacket.decodeValidatedCandidateEnvelope(from: jsonData(example)))
    }

    func test_检出_accept但含unsupported() throws {
        var example = try Self.schemaExamples()[2]
        let results = try XCTUnwrap(example["candidateResults"] as? [[String: Any]])
        var claimResults = try XCTUnwrap(results[0]["claimResults"] as? [[String: Any]])
        claimResults[0]["verdict"] = "unsupported"
        var mutated = results[0]
        mutated["claimResults"] = claimResults
        example["candidateResults"] = [mutated]

        let envelope = try DiscoveryAIPacket.decodeVerificationEnvelope(from: jsonData(example))
        let issues = envelope.validate()
        XCTAssertTrue(issues.contains { $0.code == .verdictInconsistent }, "\(issues)")
    }

    func test_检出_supported但无支持证据() throws {
        var example = try Self.schemaExamples()[2]
        let results = try XCTUnwrap(example["candidateResults"] as? [[String: Any]])
        var claimResults = try XCTUnwrap(results[0]["claimResults"] as? [[String: Any]])
        claimResults[0]["supportEvidenceIDs"] = []
        var mutated = results[0]
        mutated["claimResults"] = claimResults
        example["candidateResults"] = [mutated]

        let envelope = try DiscoveryAIPacket.decodeVerificationEnvelope(from: jsonData(example))
        let issues = envelope.validate()
        XCTAssertTrue(issues.contains { $0.code == .verdictInconsistent }, "\(issues)")
    }

    // MARK: - 合成材料（synthetic-fixtures.json）

    func test_fixtures_正向场景构建的信封全部通过() throws {
        let fixtures = try Self.loadFixtures()
        let positives = fixtures.cases.filter(\.positive)
        XCTAssertGreaterThanOrEqual(positives.count, 4, "合成集正向场景缺失")

        for fixture in positives {
            let envelopeObject = try Self.envelopeObject(from: fixture)
            let data = try jsonData(envelopeObject)
            let envelope = try DiscoveryAIPacket.decodeValidatedCandidateEnvelope(from: data)
            XCTAssertEqual(envelope.candidates.count, 1, "fixture \(fixture.id)")
            XCTAssertEqual(envelope.noFindingReason, .none, "fixture \(fixture.id)")
        }
    }

    /// 用合成材料按 schema 组装完整信封（结构测试用；语义判断不在本测试范围）
    private static func envelopeObject(from fixture: FixtureCase) throws -> [String: Any] {
        let evidence = fixture.evidence
        let scopeKind: String
        switch fixture.type {
        case "two_episodes": scopeKind = "two_episodes"
        case "bounded_pattern": scopeKind = "bounded_events"
        case "change_over_time": scopeKind = "compared_periods"
        default: scopeKind = "two_episodes"
        }

        func iso(_ date: String?) -> String? {
            date.map { "\($0)T00:00:00Z" }
        }
        let occurredDates = evidence.compactMap(\.occurredAt).sorted()
        let timeRange: [String: Any?] = [
            "start": iso(occurredDates.first),
            "end": iso(occurredDates.last),
        ]

        var comparisonPeriods: [[String: Any?]] = []
        if fixture.type == "change_over_time", occurredDates.count >= 4 {
            comparisonPeriods = [
                ["start": iso(occurredDates[0]), "end": iso(occurredDates[1])],
                ["start": iso(occurredDates[2]), "end": iso(occurredDates[3])],
            ]
        }

        func shortQuote(_ text: String) -> String {
            String(text.prefix(20))
        }
        let citations: [[String: Any]] = evidence.map {
            ["evidenceID": $0.id, "quote": shortQuote($0.text)]
        }
        let bodyText = evidence.map { String($0.text.prefix(24)) }.joined(separator: "；")
        let claims: [[String: Any]] = [
            [
                "claimID": "C01-title",
                "kind": "observation",
                "text": fixture.proposedClaim,
                "citations": citations,
                "metricIDs": [],
            ],
            [
                "claimID": "C01-body",
                "kind": "fact",
                "text": String(bodyText.prefix(180)),
                "citations": citations,
                "metricIDs": [],
            ],
        ]

        return [
            "schemaVersion": 1,
            "kind": "candidates",
            "runID": "run-fixture-\(fixture.id)",
            "candidates": [[
                "candidateID": "C01",
                "type": fixture.type ?? "two_episodes",
                "subjectKey": "fixture-\(fixture.id)",
                "scopeKind": scopeKind,
                "timeRange": timeRange,
                "claims": claims,
                "titleClaimID": "C01-title",
                "bodyClaimIDs": ["C01-body"],
                "supportEvidenceIDs": evidence.map(\.id),
                "counterSearch": [[
                    "domains": ["thought"],
                    "anchorRefs": [],
                    "keywords": ["重新开始"],
                ]],
                "sensitivity": "non_sensitive",
                "comparisonPeriods": comparisonPeriods,
            ]],
            "noFindingReason": "none",
        ]
    }

    // MARK: - 断言工具

    private func assertDecodeThrows(
        _ data: Data,
        expectCode code: DiscoverySchemaIssue.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertDecodeThrows(data, expectCode: code, decode: DiscoveryAIPacket.decodeCandidateEnvelope(from:), file: file, line: line)
    }

    private func assertVerificationDecodeThrows(
        _ data: Data,
        expectCode code: DiscoverySchemaIssue.Code,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertDecodeThrows(data, expectCode: code, decode: DiscoveryAIPacket.decodeVerificationEnvelope(from:), file: file, line: line)
    }

    private func assertDecodeThrows<T>(
        _ data: Data,
        expectCode code: DiscoverySchemaIssue.Code,
        decode: (Data) throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try decode(data),
            file: file, line: line
        ) { error in
            guard let schemaError = error as? DiscoverySchemaError else {
                XCTFail("应为 DiscoverySchemaError，实际 \(error)", file: file, line: line)
                return
            }
            XCTAssertTrue(
                schemaError.issues.contains { $0.code == code },
                "期望 \(code)，实际 \(schemaError.issues)",
                file: file, line: line
            )
        }
    }
}
