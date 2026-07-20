//
//  HoloProjectToolTests.swift
//  HoloTests
//

import Foundation

struct MockProjectDataSource: HoloProjectDataSource {
    let snapshot: HoloProjectSnapshot
    func snapshot() async -> HoloProjectSnapshot { snapshot }
}

@main
struct HoloProjectToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test订阅总览统计活跃数与月均承诺()
        try await test即将到来的承诺按日期升序()
        try await test一次性大件摊销按日均成本排序()
        try await test空项目返回empty()
        print("HoloProjectToolTests passed")
    }

    private static func recurring(
        _ index: Int, name: String, monthly: Double, next: Date? = nil, paused: Bool = false, frequency: String? = "monthly"
    ) -> HoloProjectToolRecord {
        HoloProjectToolRecord(
            id: UUID(), name: name, kind: "recurring", amount: monthly,
            frequency: frequency, startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: nil, nextOccurrenceDate: next, isPaused: paused,
            occurrencesGenerated: 0, maxOccurrences: 0, usageCount: 0,
            monthlyCommitment: monthly, dailyCost: nil, perUseCost: nil,
            hasRemainingOccurrences: true
        )
    }

    private static func oneOff(_ index: Int, name: String, amount: Double, daily: Double?, perUse: Double?, usage: Int32) -> HoloProjectToolRecord {
        HoloProjectToolRecord(
            id: UUID(), name: name, kind: "oneOff", amount: amount,
            frequency: nil, startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: nil, nextOccurrenceDate: nil, isPaused: false,
            occurrencesGenerated: 0, maxOccurrences: 0, usageCount: usage,
            monthlyCommitment: nil, dailyCost: daily, perUseCost: perUse,
            hasRemainingOccurrences: false
        )
    }

    private static func request(_ query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "project-\(query)", tool: "project", query: query,
            timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:]
        )
    }

    private static func test订阅总览统计活跃数与月均承诺() async throws {
        let snapshot = HoloProjectSnapshot(projects: [
            recurring(0, name: "Netflix", monthly: 45),
            recurring(1, name: "Spotify", monthly: 18),
            recurring(2, name: "已暂停会员", monthly: 99, paused: true)
        ])
        let result = try await HoloProjectTool(
            dataSource: MockProjectDataSource(snapshot: snapshot)
        ).execute(request("recurring_summary"))

        expect(result.status == .success, "recurring_summary 应成功")
        let active = result.metrics.first { $0.metricKey == "project.recurring.active_count" }?.value
        expect(active == 2, "活跃订阅数应为 2（排除暂停）")
        let total = result.metrics.first { $0.metricKey == "project.recurring.monthly_commitment_total" }?.value
        expect(total == 63, "月均承诺合计应为 63，实际：\(total ?? -1)")
        // Top1 应是 Netflix
        let topExcerpt = result.events.first?.excerpt ?? ""
        expect(topExcerpt.contains("Netflix"), "Top1 应是 Netflix，实际：\(topExcerpt)")
        expect(topExcerpt.contains("每月"), "recurring 频率应显示「每月」")
    }

    private static func test即将到来的承诺按日期升序() async throws {
        let now = Date()
        let soon = now.addingTimeInterval(3 * 86_400)
        let later = now.addingTimeInterval(10 * 86_400)
        let snapshot = HoloProjectSnapshot(projects: [
            recurring(0, name: "后到的", monthly: 30, next: later),
            recurring(1, name: "先到的", monthly: 20, next: soon),
            recurring(2, name: "无下次日期的", monthly: 10, next: nil)
        ])
        let result = try await HoloProjectTool(
            dataSource: MockProjectDataSource(snapshot: snapshot)
        ).execute(request("upcoming_commitments"))

        expect(result.status == .success, "upcoming_commitments 应成功")
        let count = result.metrics.first { $0.metricKey == "project.upcoming.count" }?.value
        expect(count == 2, "应只列出有未来日期的 2 笔")
        let firstExcerpt = result.events.first?.excerpt ?? ""
        expect(firstExcerpt.contains("先到的"), "应按日期升序，先到的排第一")
    }

    private static func test一次性大件摊销按日均成本排序() async throws {
        let snapshot = HoloProjectSnapshot(projects: [
            oneOff(0, name: "Switch", amount: 2000, daily: 5.5, perUse: 10, usage: 200),
            oneOff(1, name: "吃灰机器", amount: 8000, daily: 21.9, perUse: nil, usage: 0),
            recurring(2, name: "不是大件", monthly: 50)
        ])
        let result = try await HoloProjectTool(
            dataSource: MockProjectDataSource(snapshot: snapshot)
        ).execute(request("oneoff_amortization"))

        expect(result.status == .success, "oneoff_amortization 应成功")
        let count = result.metrics.first { $0.metricKey == "project.oneoff.amortization_count" }?.value
        expect(count == 2, "一次性大件数应为 2（排除 recurring）")
        // 日均高的（吃灰机器）应排第一
        let firstExcerpt = result.events.first?.excerpt ?? ""
        expect(firstExcerpt.contains("吃灰机器"), "日均成本最高的应排第一，实际：\(firstExcerpt)")
        // usageCount == 0 时不输出使用相关文案（recordUsage 暂无 UI 入口，避免「已用 0 次」尴尬）
        expect(!firstExcerpt.contains("已用"), "未记录使用时不应出现「已用」文案，实际：\(firstExcerpt)")
        // usageCount > 0 且 perUseCost 有效时（mock 可造）应展示每次使用成本
        let switchExcerpt = result.events.first { $0.excerpt.contains("Switch") }?.excerpt ?? ""
        expect(switchExcerpt.contains("每次使用约") && switchExcerpt.contains("已用 200 次"), "有使用记录的大件应展示每次使用成本，实际：\(switchExcerpt)")
    }

    private static func test空项目返回empty() async throws {
        let result = try await HoloProjectTool(
            dataSource: MockProjectDataSource(snapshot: HoloProjectSnapshot(projects: []))
        ).execute(request("recurring_summary"))

        expect(result.status == .empty, "空项目应返回 empty")
        expect(result.warnings.contains { $0.code == "NO_PROJECT_DATA" }, "应返回 NO_PROJECT_DATA")
    }
}
