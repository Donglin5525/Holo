import Foundation

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        HoloMemoryContextEnvelopeStandaloneTests.main()
    }
}
#endif
struct HoloMemoryContextEnvelopeStandaloneTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let running = makeMemory(
            id: "memory-running",
            subjectKey: "habit:running",
            title: "跑步节奏",
            summary: "最近持续跑步",
            updatedAt: now.addingTimeInterval(-30 * 86_400)
        )
        let finance = makeMemory(
            id: "memory-finance",
            subjectKey: "finance:dining",
            title: "餐饮支出",
            summary: "餐饮支出较稳定",
            updatedAt: now
        )
        let ranked = HoloMemoryRelevanceRanker.rank(
            [finance, running],
            queryText: "我最近跑步情况怎么样",
            limit: 2,
            now: now
        )
        expect(ranked.first?.id == "memory-running", "当前问题相关性应优先于单纯最近更新")
        let matchedOnly = HoloMemoryRelevanceRanker.rank(
            [finance, running],
            queryText: "我最近跑步情况怎么样",
            limit: 2,
            requireQueryMatch: true,
            now: now
        )
        expect(matchedOnly.map(\.id) == ["memory-running"], "对话召回不能夹带未命中当前问题的记忆")
        expect(
            HoloMemoryRelevanceRanker.isDeterministicMetricQuery("这个月一共跑了几次"),
            "精确数字查询不应读取长期记忆"
        )
        expect(
            !HoloMemoryRelevanceRanker.isDeterministicMetricQuery("为什么这个月跑步次数变少了"),
            "解释型问题仍可参考长期记忆"
        )

        let parsed = HoloMemoryUsageMarker.parseAndStrip(
            "回答正文\n[[HOLO_MEMORY_IDS:memory-running,fake-id]]",
            allowedMemoryIDs: ["memory-running"]
        )
        expect(parsed.cleanText == "回答正文", "展示前必须移除内部记忆标记")
        expect(parsed.usedMemoryIDs == ["memory-running"], "只能接受本轮实际提供给模型的记忆 ID")
        expect(
            HoloMemoryUsageMarker.visibleTextWhileStreaming("回答正文\n[[HOLO_MEMORY_IDS:mem") == "回答正文",
            "流式展示不能短暂暴露内部标记"
        )
        expect(
            HoloMemoryUsageMarker.visibleTextWhileStreaming("回答正文\n[[HOLO_MEM") == "回答正文",
            "标记跨 chunk 时不能短暂暴露半截控制字符"
        )
        let truncated = HoloMemoryUsageMarker.parseAndStrip(
            "回答正文\n[[HOLO_MEMORY_IDS:memory-running",
            allowedMemoryIDs: ["memory-running"]
        )
        expect(truncated.cleanText == "回答正文", "截断的内部标记也必须在持久化前移除")
        expect(truncated.usedMemoryIDs.isEmpty, "截断标记不能形成使用回执")
        print("HoloMemoryContextEnvelope standalone tests passed")
    }

    private static func makeMemory(
        id: String,
        subjectKey: String,
        title: String,
        summary: String,
        updatedAt: Date
    ) -> HoloLongTermMemory {
        HoloLongTermMemory(
            id: id,
            subjectKey: subjectKey,
            title: title,
            confidence: .high,
            confirmationState: .confirmed,
            sensitivity: .normal,
            evidence: [HoloLongTermMemoryEvidence(
                id: id + "-e1",
                source: .memoryInsight,
                sourceID: id + "-source",
                excerpt: summary,
                observedAt: updatedAt
            )],
            createdAt: updatedAt,
            updatedAt: updatedAt,
            expiresAt: nil,
            semanticType: .stablePattern,
            displaySummary: summary,
            aiUseSummary: summary + "，需结合最新数据。",
            useScopes: [.coreContext, .recentInsight],
            prohibitedInferences: ["不要推断一直持续"]
        )
    }
}
