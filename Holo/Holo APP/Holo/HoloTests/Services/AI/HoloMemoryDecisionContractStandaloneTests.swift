import Foundation

/// 五路决策契约护栏（记忆低确认成本方案 P0 / 方案 §21 纪律 4、13）。
///
/// 锁定三件事：
/// 1. decision metadata v2 的容错解码：未知枚举原样保留、缺 key 保守降级、未知版本无损封存；
/// 2. 五路 fixtures 全部结构合法且场景覆盖完整（P2 决策策略的冻结评测输入）；
/// 3. 容错枚举的 round-trip 不丢原始值（旧客户端回写后新客户端仍可重算）。

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloMemoryDecisionContractStandaloneTests.main()
    }
}
#endif
struct HoloMemoryDecisionContractStandaloneTests {
    private static var assertions = 0

    static func main() throws {
        metadataRoundTrip()
        try unknownEnumPreservedAndDowngraded()
        try missingKeysFallToConservativeDefaults()
        try envelopeUnknownVersionPreservedOpaque()
        fixturesAreWellFormed()
        print("HoloMemoryDecisionContractStandaloneTests: \(assertions) assertions passed")
    }

    // MARK: - decision metadata v2

    private static func makeMetadata() -> HoloMemoryDecisionMetadataV2 {
        HoloMemoryDecisionMetadataV2(
            policyVersion: 4,
            sourceAuthority: .structuredObservation,
            evidenceVerdict: .supported,
            impactLevel: .low,
            persistencePermission: .durable,
            useLevel: .factEligible,
            attentionPolicy: .silent,
            reasonCodes: [.boundedStructuredFact],
            evaluatedAt: HoloMemoryFiveWayFixtures.anchorNow,
            evidenceRevision: "rev-1",
            clarification: HoloMemoryClarificationMetadata(
                logicalQuestionKey: "user|sunday-morning|availability",
                missingVariable: "周日早晨是否长期空闲",
                impactSummary: "影响周末出行规划",
                options: ["每周都空闲", "只限本月", "暂时不确定"],
                lastPromptedAt: nil,
                cooldownUntil: nil,
                promptCount: 0,
                materialEvidenceRevisionAtLastPrompt: nil
            )
        )
    }

    private static func metadataRoundTrip() {
        let metadata = makeMetadata()
        let decoded = roundTrip(metadata)
        expect(decoded == metadata, "decision metadata 编码解码应无损往返")
        expect(decoded.isReliablyDecoded, "全部已知值的 metadata 应视为可靠")
        expect(decoded.clarification == metadata.clarification, "澄清元数据应无损往返")
    }

    private static func unknownEnumPreservedAndDowngraded() throws {
        // 把 sourceAuthority 换成未来版本才有的值，模拟旧客户端读到新数据。
        let mutated = try mutateJSON(makeMetadata()) { object in
            object["sourceAuthority"] = "quantumOracle"
            object["reasonCodes"] = ["boundedStructuredFact", "fromTheYear3000"]
        }
        let decoded = try JSONDecoder().decode(HoloMemoryDecisionMetadataV2.self, from: mutated)
        expect(
            decoded.sourceAuthority == .unrecognized("quantumOracle"),
            "未知枚举原样保留为 unrecognized，不猜语义"
        )
        expect(
            decoded.reasonCodes.contains(.unrecognized("fromTheYear3000")),
            "未知 reason code 同样原样保留"
        )
        expect(
            !decoded.isReliablyDecoded,
            "含未知值的 metadata 必须整体视为不可靠（消费端降级为 blocked/observeOnly）"
        )
        // 未知值 round-trip 不丢：旧端转发新数据时不损坏原始信息。
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(HoloMemoryDecisionMetadataV2.self, from: reEncoded)
        expect(
            reDecoded.sourceAuthority == .unrecognized("quantumOracle"),
            "unrecognized 值再编码后仍保留原始字符串"
        )
    }

    private static func missingKeysFallToConservativeDefaults() throws {
        // 仅保留版本号，其余 key 全部缺失（更旧的 v2 小版本写入）。
        let json = #"{"schemaVersion":2,"policyVersion":4}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HoloMemoryDecisionMetadataV2.self, from: json)
        expect(decoded.persistencePermission == .blocked, "缺 key 时持久化权限必须落到 blocked")
        expect(decoded.useLevel == .blocked, "缺 key 时使用权限必须落到 blocked（保守，不是开放）")
        expect(decoded.attentionPolicy == .silent, "缺 key 时打扰策略保持静默")
        expect(decoded.evidenceVerdict == .unreviewed, "缺 key 时核验结论按未核验处理")
        expect(
            decoded.reasonCodes == [.conservativeDowngrade],
            "缺 key 时必须携带保守降级理由"
        )
        expect(decoded.clarification == nil, "缺 key 时无澄清元数据")
    }

    private static func envelopeUnknownVersionPreservedOpaque() throws {
        // 未来 schemaVersion（例如 3）的载荷：整体原样封存，不降为 nil 覆盖。
        let futureJSON = #"{"schemaVersion":99,"policyVersion":9,"custom":"payload"}"#
            .data(using: .utf8)!
        let envelope = try JSONDecoder().decode(
            HoloMemoryDecisionMetadataEnvelope.self,
            from: futureJSON
        )
        expect(!envelope.isReadable, "未知版本不可当结构化决策结果使用")
        expect(
            envelope.unknownPayloadJSON?.contains("custom") == true,
            "未知版本载荷整体原样封存"
        )
        let reEncoded = try JSONEncoder().encode(envelope)
        let reDecoded = try JSONDecoder().decode(
            HoloMemoryDecisionMetadataEnvelope.self,
            from: reEncoded
        )
        expect(
            reDecoded.unknownPayloadJSON == envelope.unknownPayloadJSON,
            "封存载荷再编码不丢失（无损转发）"
        )

        // v2 正常载荷。
        let envelopeV2 = HoloMemoryDecisionMetadataEnvelope(v2: makeMetadata())
        let roundTripped = try JSONDecoder().decode(
            HoloMemoryDecisionMetadataEnvelope.self,
            from: JSONEncoder().encode(envelopeV2)
        )
        expect(roundTripped.isReadable, "v2 载荷应可读")
        expect(roundTripped.v2 == makeMetadata(), "v2 载荷应无损往返")
    }

    // MARK: - fixtures 护栏

    private static func fixturesAreWellFormed() {
        let fixtures = HoloMemoryFiveWayFixtures.all
        expect(fixtures.count == 21, "冻结评测集应包含 21 条 fixture（§16.1 场景 + §6.1 对抗门禁）")
        let ids = Set(fixtures.map(\.scenarioID))
        expect(ids.count == fixtures.count, "scenarioID 不得重复")

        for fixture in fixtures {
            do {
                try fixture.record.validate()
            } catch {
                fatalError("fixture \(fixture.scenarioID) 结构不合法：\(error)")
            }
        }
        assertions += 1

        let routes = Set(fixtures.map(\.expectedRoute))
        expect(
            routes == [.factEligible, .qualifiedAdvice, .observeOnly, .askWhenRelevant, .discard],
            "fixtures 必须覆盖全部五路结果"
        )

        // §13.1 门禁项如实登记：这些条目在 P2/P4 契约评测通过前不得当 derivable 使用。
        let contractProofRequired = fixtures.filter { $0.derivation == .requiresContractProof }
        expect(
            contractProofRequired.map(\.scenarioID) == ["MTX-04", "ADV-01", "ADV-02"],
            "需契约证明的门禁项应恰为：明确记忆请求、假设语气、引用他人（§13.1）"
        )
        for fixture in fixtures where fixture.derivation == .derivableToday {
            expect(
                fixture.expectedAuthority != nil && fixture.expectedVerdict != nil
                    && fixture.expectedImpact != nil,
                "derivableToday 的 fixture \(fixture.scenarioID) 必须给出完整期望推导"
            )
        }
    }

    // MARK: - 助手

    private static func roundTrip(_ metadata: HoloMemoryDecisionMetadataV2) -> HoloMemoryDecisionMetadataV2 {
        do {
            let data = try JSONEncoder().encode(metadata)
            return try JSONDecoder().decode(HoloMemoryDecisionMetadataV2.self, from: data)
        } catch {
            fatalError("round-trip 失败：\(error)")
        }
    }

    private static func mutateJSON(
        _ metadata: HoloMemoryDecisionMetadataV2,
        _ mutate: (inout [String: Any]) -> Void
    ) throws -> Data {
        let data = try JSONEncoder().encode(metadata)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("metadata 应编码为 JSON 对象")
        }
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
}
