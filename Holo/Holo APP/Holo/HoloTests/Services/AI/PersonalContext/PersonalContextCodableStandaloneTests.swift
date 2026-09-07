//
//  PersonalContextCodableStandaloneTests.swift
//  HoloTests
//
//  P1 契约与存储兼容的 Codable 验证：旧记录无字段、新字段 round-trip、
//  未知版本原样保留、旧读写后 payload 丢失、信封单条隔离不抛错。
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
        try PersonalContextCodableStandaloneTests.main()
    }
}
#endif
struct PersonalContextCodableStandaloneTests {
    private static var assertionCount = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        testLegacyRecordWithoutPayloadDecodes()
        testPayloadRoundTrip()
        testUnknownSchemaVersionPreservedLosslessly()
        testUnknownVersionDoubleRoundTripStaysUnknown()
        testLegacyReaderRoundTripLosesPayload()
        testBadPayloadDoesNotThrowRecordDecode()
        testSourceSnapshotRoundTrip()
        print("PersonalContextCodableStandaloneTests: \(assertionCount) 断言全部通过")
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    static func makePayload(
        contextID: String = "11111111-2222-3333-4444-555555555555",
        statement: String = "用户的父亲被要求低盐饮食",
        relationText: String = "被要求采取低盐饮食",
        epistemicStatus: HoloContextEpistemicStatus = .declared
    ) -> HoloPersonalContextPayloadV1 {
        HoloPersonalContextPayloadV1(
            contextID: contextID,
            statement: statement,
            subjects: [HoloContextPartyRef(label: "父亲", scope: .person)],
            objects: [],
            relationText: relationText,
            facets: [HoloContextFacet(kind: .constraint)],
            epistemicStatus: epistemicStatus,
            applicability: HoloContextApplicabilityV1(
                partyRefs: [HoloContextPartyRef(label: "父亲", scope: .person)],
                conditionText: "体检后医生要求"
            ),
            temporal: HoloContextTemporalV1(
                kind: .ongoing,
                originalExpression: "上个月体检后开始",
                precision: .month
            ),
            basis: [HoloContextBasisRef(
                sourceID: "thought-1",
                quote: "医生说要低盐饮食",
                quoteUTF16Location: 12,
                quoteUTF16Length: 9,
                sourceRevision: "rev-1"
            )],
            openQuestions: ["是否严格到需要自带饮食"],
            admission: HoloContextAdmissionV1(
                level: .adviceEligible,
                policyVersion: 1,
                decidedAt: Date(timeIntervalSince1970: 1_780_000_000)
            )
        )
    }

    /// 无 personalContext key 的旧 recordData 必须照常解码（nil 载荷）。
    static func testLegacyRecordWithoutPayloadDecodes() {
        let legacyJSON = """
        {"id":"holo-memory-v3-abc","scope":"domain","primaryDomain":"thought",
        "sourceDomains":["thought"],"subjectKey":"饮食",
        "anchorRefs":[{"type":"userTheme","canonicalValue":"饮食"}],
        "claimKind":"observedFact","persistenceClass":"durable",
        "displaySummary":"旧摘要","aiUseSummary":"旧用途","prohibitedInferences":[],
        "evidenceRefs":[],"upstreamMemoryIDs":[],"counterEvidenceRefs":[],
        "confidenceScore":0.5,"freshnessScore":0.5,"scoringVersion":1,
        "scoreComputedAt":"2026-09-06T00:00:00Z","extractorVersion":1,"promptVersion":1,
        "state":"active","sensitivity":"normal","userDecision":"none",
        "recordVersion":1,"createdAt":"2026-09-06T00:00:00Z","updatedAt":"2026-09-06T00:00:00Z",
        "schemaVersion":1}
        """
        let record = try! decoder().decode(HoloMemoryRecord.self, from: Data(legacyJSON.utf8))
        expect(record.personalContext == nil, "旧记录无 personalContext key 应解码为 nil")
        expect(record.displaySummary == "旧摘要", "旧记录其余字段照常解码")
    }

    /// 带载荷的新记录 round-trip 后信封可读、字段完整。
    static func testPayloadRoundTrip() {
        let payload = makePayload()
        let record = TestRecordFactory.record(with: payload)
        let data = try! encoder().encode(record)
        let decoded = try! decoder().decode(HoloMemoryRecord.self, from: data)
        expect(decoded.personalContext?.isReadable == true, "round-trip 后信封应可读")
        expect(decoded.personalContext?.v1 == payload, "round-trip 后 V1 载荷逐字段一致")
        expect(decoded.personalContext?.schemaVersion == 1, "schemaVersion 应为 1")
    }

    /// 未知 schemaVersion：信封保留原始 JSON，isReadable=false，不抛错。
    static func testUnknownSchemaVersionPreservedLosslessly() {
        let futureJSON = """
        {"schemaVersion":99,"contextID":"x","statement":"未来字段","futureField":{"a":[1,2],"b":null},"tags":["新能力"]}
        """
        let envelope = try! decoder().decode(
            HoloPersonalContextPayloadEnvelope.self,
            from: Data(futureJSON.utf8)
        )
        expect(envelope.schemaVersion == 99, "未知版本号应保留")
        expect(!envelope.isReadable, "未知版本不可当结构化情境使用")
        expect(envelope.v1 == nil, "未知版本不应解析出 V1")
        let raw = envelope.unknownPayloadJSON ?? ""
        expect(raw.contains("\"futureField\""), "原始 JSON 应保留未知字段")
        expect(raw.contains("schemaVersion"), "原始 JSON 应保留版本键")
    }

    /// 未知版本重编码→再解码：仍是未知版本且原样保留（无损往返）。
    static func testUnknownVersionDoubleRoundTripStaysUnknown() {
        let futureJSON = """
        {"schemaVersion":42,"contextID":"y","custom":["a","b"],"nested":{"k":1}}
        """
        let first = try! decoder().decode(
            HoloPersonalContextPayloadEnvelope.self,
            from: Data(futureJSON.utf8)
        )
        let reencoded = try! encoder().encode(first)
        let second = try! decoder().decode(
            HoloPersonalContextPayloadEnvelope.self,
            from: reencoded
        )
        expect(second.schemaVersion == 42, "重编码后版本号不变")
        expect(!second.isReadable, "重编码后仍是未知版本")
        let raw = second.unknownPayloadJSON ?? ""
        expect(raw.contains("\"custom\"") && raw.contains("\"nested\""), "未知字段经重编码不丢失")
    }

    /// 旧端读写 round-trip 会丢载荷（旧端不认识该字段，解码后重编码即消失）——
    /// 记录这一事实；对策是新情境记录只进本机存储（P2 分流），不与旧端共享同步面。
    static func testLegacyReaderRoundTripLosesPayload() {
        let payload = makePayload()
        let record = TestRecordFactory.record(with: payload)
        let data = try! encoder().encode(record)
        // 模拟旧端：解码时忽略未知键，重编码后未知键消失（剥掉 personalContext）。
        let object = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        var stripped = object
        stripped.removeValue(forKey: "personalContext")
        let rewritten = try! JSONSerialization.data(withJSONObject: stripped)
        let back = try! decoder().decode(HoloMemoryRecord.self, from: rewritten)
        expect(back.personalContext == nil, "旧端读写后结构化载荷丢失（预期事实，靠本机存储规避）")
        expect(back.id == record.id, "旧端其余字段照常读写")
    }

    /// 信封内部消化坏载荷：整条记录解码不抛错（单条隔离在 Codable 层成立）。
    static func testBadPayloadDoesNotThrowRecordDecode() {
        let payload = makePayload()
        var record = TestRecordFactory.record(with: payload)
        // 直接构造 schemaVersion=1 但字段损坏的信封 JSON。
        let corruptEnvelopeJSON = "{\"schemaVersion\":1,\"contextID\":123}"
        let corrupt = try! decoder().decode(
            HoloPersonalContextPayloadEnvelope.self,
            from: Data(corruptEnvelopeJSON.utf8)
        )
        expect(!corrupt.isReadable, "损坏的 v1 载荷不得被解析")
        record.personalContext = corrupt
        let data = try! encoder().encode(record)
        let decoded = try! decoder().decode(HoloMemoryRecord.self, from: data)
        expect(decoded.displaySummary == record.displaySummary, "坏载荷不拖垮整条记录解码")
    }

    /// 来源快照 round-trip：可选字段缺省时用默认值。
    static func testSourceSnapshotRoundTrip() {
        let snapshot = HoloContextSourceSnapshot(
            sourceID: "thought-9",
            sourceDomain: "thought",
            sourceKind: "userNote",
            revisionDigest: "rev-3",
            sourceCreatedAt: Date(timeIntervalSince1970: 1_770_000_000),
            sourceUpdatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            plainText: "一段正文",
            sensitivity: .normal,
            accessGeneration: 7,
            eventTime: Date(timeIntervalSince1970: 1_760_000_000),
            role: "user"
        )
        let data = try! encoder().encode(snapshot)
        let decoded = try! decoder().decode(HoloContextSourceSnapshot.self, from: data)
        expect(decoded == snapshot, "来源快照 round-trip 一致")

        // 最小字段（部分 key 缺失）走默认值。
        let minimal = """
        {"sourceID":"s1","sourceDomain":"conversation","revisionDigest":"r",
        "sourceCreatedAt":"2026-09-01T00:00:00Z","sourceUpdatedAt":"2026-09-01T00:00:00Z",
        "plainText":"hi","accessGeneration":1}
        """
        let min = try! decoder().decode(HoloContextSourceSnapshot.self, from: Data(minimal.utf8))
        expect(min.sourceKind == "unknown" && min.sensitivity == .normal && min.coverageGaps.isEmpty,
               "缺省可选字段使用默认值不失败")
    }
}

/// 测试用记录工厂：构造合法的最小 HoloMemoryRecord。
enum TestRecordFactory {
    static func record(with payload: HoloPersonalContextPayloadV1) -> HoloMemoryRecord {
        let anchor = try! HoloMemoryAnchorRef(
            type: .userTheme,
            value: payload.contextAnchorValue
        )
        return HoloMemoryRecord(
            id: try! HoloMemoryIdentity.makeStableID(
                scope: .domain,
                primaryDomain: .thought,
                sourceDomains: [.thought],
                claimKind: .observedFact,
                anchors: [anchor]
            ),
            scope: .domain,
            primaryDomain: .thought,
            sourceDomains: [.thought],
            subjectKey: "个人情境",
            anchorRefs: [anchor],
            claimKind: .observedFact,
            persistenceClass: .durable,
            displaySummary: "测试摘要",
            aiUseSummary: "测试用途",
            prohibitedInferences: [],
            evidenceRefs: [],
            upstreamMemoryIDs: [],
            counterEvidenceRefs: [],
            confidenceScore: 0.6,
            freshnessScore: 0.6,
            scoringVersion: 1,
            scoreComputedAt: Date(timeIntervalSince1970: 1_780_000_000),
            extractorVersion: 1,
            promptVersion: 1,
            state: .candidate,
            sensitivity: .normal,
            userDecision: .none,
            createdAt: Date(timeIntervalSince1970: 1_780_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            personalContext: HoloPersonalContextPayloadEnvelope(v1: payload)
        )
    }
}
