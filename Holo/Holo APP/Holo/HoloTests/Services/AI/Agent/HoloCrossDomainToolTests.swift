import Foundation

struct MockCrossDomainDataSource: HoloCrossDomainDataSource {
    var values: [String: [HoloQueryRow]]
    func rows(source: String, timeRange: HoloAgentTimeRange?) async -> [HoloQueryRow] { values[source] ?? [] }
}

@main
struct HoloCrossDomainToolTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test健康与财务按日对齐后计算相关系数()
        try await test健康与习惯只表达分组差异不表达因果()
        try await test任务与习惯支持受控关联()
        try await test目标与任务支持受控关联()
        test非法字段和未授权组合会被拒绝()
        try await test对齐天数不足返回明确空结果()
        print("HoloCrossDomainToolTests passed")
    }

    static func row(_ id: String, day: Int, value: Double, textField: (String, String)? = nil) -> HoloQueryRow {
        let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 7, day: day))!
        var fields: [String: HoloQueryValue] = ["value": .number(value), "amount": .number(value), "date": .date(date)]
        if let textField { fields[textField.0] = .text(textField.1) }
        return HoloQueryRow(id: id, occurredAt: date, fields: fields, excerpt: id)
    }

    static func request(_ plan: HoloCrossDomainQueryPlan) -> HoloToolRequest {
        HoloToolRequest(id: "cross-1", tool: "cross_domain", query: "aligned_analysis", timeRange: nil, baseline: nil, requiredMetrics: [], parameters: [:], crossDomainPlan: plan)
    }

    static func test健康与财务按日对齐后计算相关系数() async throws {
        let health = (1...7).map { row("h\($0)", day: $0, value: Double($0)) }
        let finance = (1...7).map { row("f\($0)", day: $0, value: Double($0 * 10)) }
        let tool = HoloCrossDomainTool(dataSource: MockCrossDomainDataSource(values: ["health.sleep": health, "finance.transactions": finance]))
        let plan = HoloCrossDomainQueryPlan(leftSource: "health.sleep", leftField: "value", rightSource: "finance.transactions", rightField: "amount", operation: .correlation)
        let result = try await tool.execute(request(plan))
        expect(result.status == .success, "健康×财务应成功")
        expect(result.metrics.first?.value == 1, "完全同向数据相关系数应为 1")
        expect(result.events.first?.excerpt.contains("不表示因果") == true, "跨域结果必须带非因果边界")
        expect(result.metrics.first?.sourceRecordIDs?.count == 14, "应保存两侧来源 ID")
    }

    static func test健康与习惯只表达分组差异不表达因果() async throws {
        let health = (1...6).map { row("h\($0)", day: $0, value: Double($0)) }
        let habits = (1...6).map { row("a\($0)", day: $0, value: $0 >= 4 ? 1 : 0, textField: ("habit", "跑步")) }
        let tool = HoloCrossDomainTool(dataSource: MockCrossDomainDataSource(values: ["health.sleep": health, "habit.daily": habits]))
        let plan = HoloCrossDomainQueryPlan(leftSource: "health.sleep", leftField: "value", rightSource: "habit.daily", rightField: "value", operation: .groupComparison, minimumAlignedDays: 5)
        let result = try await tool.execute(request(plan))
        expect(result.status == .success, "健康×习惯分组应成功")
        expect(result.events.first?.excerpt.contains("分组差异") == true, "应表述为分组差异")
        expect(result.events.first?.excerpt.contains("不表示因果") == true, "不得表述因果")
    }

    static func test任务与习惯支持受控关联() async throws {
        let tasks = (1...7).map { row("t\($0)", day: $0, value: Double($0)) }
        let habits = (1...7).map { row("a\($0)", day: $0, value: Double($0 * 2)) }
        let tool = HoloCrossDomainTool(dataSource: MockCrossDomainDataSource(values: ["task.daily": tasks, "habit.daily": habits]))
        let plan = HoloCrossDomainQueryPlan(leftSource: "task.daily", leftField: "value", rightSource: "habit.daily", rightField: "value", operation: .correlation)
        let result = try await tool.execute(request(plan))
        expect(result.status == .success, "任务×习惯应成功")
        expect(result.metrics.first?.value == 1, "完全同向数据应得到确定相关系数")
    }

    static func test目标与任务支持受控关联() async throws {
        let goals = (1...7).map { row("g\($0)", day: $0, value: Double($0 * 10)) }
        let tasks = (1...7).map { row("t\($0)", day: $0, value: Double($0)) }
        let tool = HoloCrossDomainTool(dataSource: MockCrossDomainDataSource(values: ["goal.progress.daily": goals, "task.daily": tasks]))
        let plan = HoloCrossDomainQueryPlan(leftSource: "goal.progress.daily", leftField: "value", rightSource: "task.daily", rightField: "value", operation: .groupComparison)
        let result = try await tool.execute(request(plan))
        expect(result.status == .success, "目标×任务应成功")
        expect(result.events.first?.excerpt.contains("不表示因果") == true, "目标×任务也必须保持非因果边界")
    }

    static func test非法字段和未授权组合会被拒绝() {
        let tool = HoloCrossDomainTool(dataSource: MockCrossDomainDataSource(values: [:]))
        let invalidField = request(HoloCrossDomainQueryPlan(leftSource: "task.daily", leftField: "title", rightSource: "habit.daily", rightField: "value", operation: .correlation))
        guard case .invalid = tool.validate(invalidField) else { fatalError("未注册字段必须拒绝") }
        let invalidPair = request(HoloCrossDomainQueryPlan(leftSource: "finance.transactions", leftField: "amount", rightSource: "task.daily", rightField: "value", operation: .correlation))
        guard case .invalid = tool.validate(invalidPair) else { fatalError("未授权跨域组合必须拒绝") }
    }

    static func test对齐天数不足返回明确空结果() async throws {
        let tool = HoloCrossDomainTool(dataSource: MockCrossDomainDataSource(values: [
            "health.sleep": [row("h1", day: 1, value: 6)],
            "finance.transactions": [row("f1", day: 1, value: 10)]
        ]))
        let plan = HoloCrossDomainQueryPlan(leftSource: "health.sleep", leftField: "value", rightSource: "finance.transactions", rightField: "amount", operation: .correlation)
        let result = try await tool.execute(request(plan))
        expect(result.status == .empty, "对齐不足应为空结果")
        expect(result.warnings.first?.code == "INSUFFICIENT_ALIGNED_DAYS", "应返回明确原因")
    }
}
