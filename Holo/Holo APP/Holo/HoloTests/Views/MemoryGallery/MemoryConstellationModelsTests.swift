import XCTest
@testable import Holo

final class MemoryConstellationModelsTests: XCTestCase {

    func testModulesKeepHealthAsFifthPeerSignal() {
        XCTAssertEqual(
            MemoryConstellationModule.allCases,
            [.habit, .finance, .task, .thought, .health]
        )
        XCTAssertEqual(MemoryConstellationModule.health.displayName, "健康")
    }

    func testFinanceSnippetUsesGentleObservationCopy() {
        let snippet = MemoryStorySnippet.financeSpendingPeak()

        XCTAssertEqual(snippet.title, "这天的外出支出比较集中")
        XCTAssertEqual(snippet.subtitle, "具体金额和对比留在详情里看")
        XCTAssertFalse(snippet.title.contains("超过"))
        XCTAssertFalse(snippet.title.contains("%"))
        XCTAssertFalse(snippet.title.contains("异常"))
    }

    func testHealthSignalCanRepresentPendingAgentConnection() {
        let signal = MemoryConstellationSignal.health(state: .agentPending)

        XCTAssertEqual(signal.module, .health)
        XCTAssertEqual(signal.title, "健康")
        XCTAssertEqual(signal.summary, "健康证据接入中")
        XCTAssertTrue(signal.isDashed)
    }

    func testFallbackMainLineIsConservativeWhenDataIsSparse() {
        let summary = MemoryConstellationSummary.fallback(hasInsight: false)

        XCTAssertEqual(summary.title, "记录还不多")
        XCTAssertEqual(summary.body, "先从几个生活信号开始，等数据更多后 Holo 会帮你连成一张星图。")
    }
}
