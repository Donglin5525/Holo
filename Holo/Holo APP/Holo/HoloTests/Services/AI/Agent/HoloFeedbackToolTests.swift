//
//  HoloFeedbackToolTests.swift
//  HoloTests
//

import Foundation

struct MockFeedbackDataSource: HoloFeedbackDataSource {
    let records: [HoloFeedbackRecord]
    func recentFeedback(limit: Int) async -> [HoloFeedbackRecord] {
        Array(records.prefix(limit))
    }
}

@main
struct HoloFeedbackToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test评分汇总统计准确率与价值占比()
        try await test纠正主题按reason与module聚类()
        try await test纠正摘要截断且标记敏感()
        try await test空反馈返回empty()
        print("HoloFeedbackToolTests passed")
    }

    private static let base = Date(timeIntervalSince1970: 1_700_000_000)

    private static func feedback(
        _ index: Int,
        accuracy: String? = AccuracyRating.accurate.rawValue,
        value: String? = ValueRating.useful.rawValue,
        reason: String? = nil,
        module: String? = "health",
        correction: String? = nil
    ) -> HoloFeedbackRecord {
        HoloFeedbackRecord(
            id: UUID(),
            insightId: UUID(),
            accuracyRating: accuracy,
            valueRating: value,
            reasonType: reason,
            module: module,
            patternType: nil,
            userCorrection: correction,
            createdAt: base.addingTimeInterval(Double(index) * 100)
        )
    }

    private static func request(_ query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "feedback-\(query)", tool: "feedback", query: query,
            timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:]
        )
    }

    private static func test评分汇总统计准确率与价值占比() async throws {
        let records = [
            feedback(0, accuracy: "accurate", value: "useful"),
            feedback(1, accuracy: "accurate", value: "notUseful"),
            feedback(2, accuracy: "inaccurate", value: "notMeaningful"),
            feedback(3, accuracy: "accurate", value: "useful")
        ]
        let result = try await HoloFeedbackTool(
            dataSource: MockFeedbackDataSource(records: records)
        ).execute(request("rating_summary"))

        expect(result.status == .success, "rating_summary 应成功")
        expect(result.sensitivity == .sensitive, "反馈应标记 sensitive")
        let total = result.metrics.first { $0.metricKey == "feedback.total.count" }?.value
        expect(total == 4, "总数应为 4")
        let accurate = result.metrics.first { $0.metricKey == "feedback.accuracy.accurate_count" }?.value
        expect(accurate == 3, "准确数应为 3")
        let inaccurate = result.metrics.first { $0.metricKey == "feedback.accuracy.inaccurate_count" }?.value
        expect(inaccurate == 1, "不准确数应为 1")
        let excerpt = result.events.first?.excerpt ?? ""
        expect(excerpt.contains("75%"), "摘要应反映 75% 准确率，实际：\(excerpt)")
    }

    private static func test纠正主题按reason与module聚类() async throws {
        let records = [
            feedback(0, reason: "dataWrong", module: "health", correction: "我没失眠"),
            feedback(1, reason: "dataWrong", module: "finance", correction: "金额不对"),
            feedback(2, reason: "toneWrong", module: "health", correction: "语气太冲"),
            feedback(3, reason: "suggestionWrong", module: "task", correction: "建议没用")
        ]
        let result = try await HoloFeedbackTool(
            dataSource: MockFeedbackDataSource(records: records)
        ).execute(request("correction_themes"))

        expect(result.status == .success, "correction_themes 应成功")
        let correctionCount = result.metrics.first { $0.metricKey == "feedback.correction.count" }?.value
        expect(correctionCount == 4, "纠正总数应为 4")
        // 事件里不应出现纠正原文
        expect(result.events.allSatisfy { !$0.excerpt.contains("我没失眠") && !$0.excerpt.contains("金额不对") }, "主题聚类不应暴露纠正原文")
        // 应出现 reason 聚合
        expect(result.events.contains { $0.excerpt.contains("数据不准") }, "应聚合「数据不准」reason")
        expect(result.events.contains { $0.excerpt.contains("领域「health」被纠正 2 次") }, "应聚合 health 领域 2 次")
    }

    private static func test纠正摘要截断且标记敏感() async throws {
        let longText = String(repeating: "用户写了很长的纠正内容用来测试截断逻辑", count: 5)
        let records = [
            feedback(0, reason: "dataWrong", module: "health", correction: longText),
            feedback(1, reason: nil, module: "health", correction: "短纠正")
        ]
        let result = try await HoloFeedbackTool(
            dataSource: MockFeedbackDataSource(records: records)
        ).execute(request("corrections_summary"))

        expect(result.status == .success, "corrections_summary 应成功")
        expect(result.sensitivity == .sensitive, "纠正摘要必须标记 sensitive")
        let longExcerpt = result.events.first { $0.excerpt.contains("用户写了很长的") }?.excerpt ?? ""
        expect(longExcerpt.contains("…"), "长纠正应被截断并以 … 结尾，实际：\(longExcerpt)")
        // 截断后用户可见文本应明显短于原文
        expect(longExcerpt.count < longText.count + 40, "截断后长度应远小于原文")
    }

    private static func test空反馈返回empty() async throws {
        let result = try await HoloFeedbackTool(
            dataSource: MockFeedbackDataSource(records: [])
        ).execute(request("rating_summary"))

        expect(result.status == .empty, "空反馈应返回 empty")
        expect(result.warnings.contains { $0.code == "NO_FEEDBACK_DATA" }, "应返回 NO_FEEDBACK_DATA")
    }
}
