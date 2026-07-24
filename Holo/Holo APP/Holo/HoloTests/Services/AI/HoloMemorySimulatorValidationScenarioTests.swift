import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        try HoloMemorySimulatorValidationScenarioTests.main()
    }
}
#endif
struct HoloMemorySimulatorValidationScenarioTests {
    private static var assertions = 0

    static func main() throws {
        let fixtures = try HoloMemorySimulatorValidationFixtures.make(
            now: Date(timeIntervalSince1970: 1_720_000_000)
        )
        expect(
            Set(fixtures.map(\.role)) == Set(HoloMemorySimulatorValidationFixtureRole.allCases),
            "固定场景必须覆盖全部角色"
        )
        expect(
            fixtures.allSatisfy {
                $0.observationKey.hasPrefix(HoloMemorySimulatorValidationFixtures.namespace)
            },
            "observation key 必须使用 mock namespace"
        )
        expect(
            fixtures.flatMap(\.package.signals).allSatisfy { signal in
                signal.id.hasPrefix(HoloMemorySimulatorValidationFixtures.namespace) &&
                    signal.evidence.id.hasPrefix(HoloMemorySimulatorValidationFixtures.namespace) &&
                    signal.evidence.lineageKey.hasPrefix(HoloMemorySimulatorValidationFixtures.namespace)
            },
            "信号、evidence 和 lineage 必须使用 mock namespace"
        )
        expect(
            fixtures.allSatisfy { fixture in
                guard let object = try? JSONSerialization.jsonObject(with: fixture.modelOutput),
                      let root = object as? [String: Any],
                      let candidates = root["candidates"] as? [[String: Any]],
                      let first = candidates.first else { return false }
                return first["requestedActions"] is NSNull
            },
            "每个模型 fixture 必须显式包含 requestedActions:null"
        )
        expect(
            fixtures.first(where: { $0.role == .financeActive })?
                .package.signals.first?.evidence.sampleCount == 4,
            "财务 active fixture 必须有足够聚合样本"
        )
        expect(
            fixtures.first(where: { $0.role == .healthCandidate })?
                .package.signals.first?.evidence.sampleCount == 5,
            "健康 active fixture 必须有足够聚合样本"
        )
        expect(
            fixtures.filter { $0.role != .healthCandidate }
                .allSatisfy { $0.role == .financeActive ||
                    $0.package.signals.first?.evidence.kind == .entityRef },
            "普通领域 fixture 可直接采用，健康 fixture 单独等待确认"
        )

        let report = HoloMemorySimulatorValidationReport(
            scenario: "full-chain-v2",
            startedAt: Date(timeIntervalSince1970: 1),
            completedAt: Date(timeIntervalSince1970: 2),
            status: "passed",
            assertions: [
                .init(name: "sample", passed: true, expected: "yes", actual: "yes")
            ],
            recordStates: ["mock": "active/none/v1"],
            queryResults: []
        )
        let decoded = try JSONDecoder().decode(
            HoloMemorySimulatorValidationReport.self,
            from: JSONEncoder().encode(report)
        )
        expect(decoded == report, "验收报告必须可稳定 Codable 往返")
        expect(decoded.failedAssertionCount == 0, "通过报告失败断言必须为 0")

        print("HoloMemorySimulatorValidationScenarioTests: \(assertions) assertions passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        assertions += 1
    }
}
