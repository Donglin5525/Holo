#if DEBUG
import Foundation

@main
struct HoloMemoryTraceRedactionStandaloneTests {
    private static var assertions = 0

    static func main() async throws {
        let now = Date(timeIntervalSince1970: 1_752_595_200)
        let store = HoloMemoryTraceStore(
            maximumEntries: 2,
            retention: 7 * 86_400,
            now: { now }
        )
        let context = HoloMemoryQueryContext(
            route: .holisticMemory,
            answerAuthority: .answerMaterial,
            records: [],
            requiresDetailData: false,
            estimatedTokens: 0,
            refreshDecision: .none
        )
        let trace = HoloMemorySelectionTrace(context: context)
        let sensitiveQuestion = "PRIVATE_QUESTION_RECENT_HEALTH_SECRET"

        await store.appendSelection(trace, question: sensitiveQuestion)
        let firstData = try await store.redactedExportData()
        let firstJSON = String(decoding: firstData, as: UTF8.self)
        expect(!firstJSON.contains(sensitiveQuestion), "Trace 不得保存问题正文")
        expect(firstJSON.contains("holisticMemory"), "Trace 应保留路由元数据")
        expect(firstJSON.contains("queryFingerprint"), "Trace 应保存不可逆问题指纹")

        await store.appendDomainPipeline(
            domain: .health,
            signalCount: 4,
            packageRecordCount: 2,
            validatorAcceptedCount: 1,
            plannedMutationCount: 1
        )
        let secretMemoryBody = "RAW_MEMORY_BODY_DO_NOT_PERSIST"
        await store.appendSelection(trace, question: secretMemoryBody)

        let snapshot = await store.snapshot()
        expect(snapshot.count == 2, "Trace 必须执行容量上限")
        expect(snapshot.allSatisfy { $0.selectedMemoryIDs.isEmpty }, "测试 Trace 不应凭空产生 ID")
        let data = try await store.redactedExportData()
        let json = String(decoding: data, as: UTF8.self)
        expect(!json.contains(secretMemoryBody), "Trace 不得保存记忆或问题正文")
        expect(!json.contains("summary"), "Trace schema 不得包含正文摘要字段")

        await store.removeAll()
        let cleared = await store.snapshot()
        expect(cleared.isEmpty, "Debug Trace 应支持主动清空")

        print("HoloMemoryTraceRedactionStandaloneTests: \(assertions) assertions passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        assertions += 1
        if !condition() { fatalError(message) }
    }
}
#endif
