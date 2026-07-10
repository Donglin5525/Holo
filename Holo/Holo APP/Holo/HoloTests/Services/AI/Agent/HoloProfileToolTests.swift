//
//  HoloProfileToolTests.swift
//  HoloTests
//

import Foundation

struct MockProfileDataSource: HoloProfileDataSource {
    let value: HoloProfileToolSnapshot?
    func snapshot() async -> HoloProfileToolSnapshot? { value }
}

@main
struct HoloProfileToolTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async throws {
        try await test档案摘要只输出结构化字段()
        try await test当前关注包含生活与健康目标()
        try await test偏好边界标记为敏感数据()
        try await test空档案返回empty()
        print("HoloProfileToolTests passed")
    }

    private static let snapshot = HoloProfileToolSnapshot(
        preferredName: "东林",
        language: "中文",
        timezone: "Asia/Shanghai",
        city: "上海",
        profession: "产品负责人",
        communicationStyle: ["先讲结论", "直接指出风险"],
        currentFocus: ["Holo 上架"],
        lifeContext: ["独立开发者"],
        healthHabitContext: ["提高睡眠稳定性"],
        sensitiveBoundaries: ["无关场景不要提健康信息"]
    )

    private static func request(_ query: String) -> HoloToolRequest {
        HoloToolRequest(
            id: "profile-\(query)",
            tool: "profile",
            query: query,
            timeRange: nil,
            baseline: nil,
            requiredMetrics: [],
            parameters: [:]
        )
    }

    private static func metric(_ key: String, in result: HoloDataToolResult) -> Double? {
        result.metrics.first { $0.metricKey == key }?.value
    }

    private static func test档案摘要只输出结构化字段() async throws {
        let tool = HoloProfileTool(dataSource: MockProfileDataSource(value: snapshot))
        let result = try await tool.execute(request("profile_summary"))

        expect(result.status == .success, "profile_summary 应成功")
        expect(metric("profile.field.count", in: result) == 5, "应输出 5 个已填写基础字段")
        expect(result.events.contains { $0.excerpt.contains("称呼：东林") }, "应包含称呼")
        expect(result.events.allSatisfy { !$0.excerpt.contains("# 关于我") }, "不得返回原始 Markdown")
    }

    private static func test当前关注包含生活与健康目标() async throws {
        let tool = HoloProfileTool(dataSource: MockProfileDataSource(value: snapshot))
        let result = try await tool.execute(request("current_focus"))

        expect(metric("profile.focus.count", in: result) == 3, "关注、生活、健康目标合计应为 3")
        expect(result.events.contains { $0.excerpt.contains("Holo 上架") }, "应包含当前关注")
        expect(result.events.contains { $0.excerpt.contains("提高睡眠稳定性") }, "应包含健康目标")
    }

    private static func test偏好边界标记为敏感数据() async throws {
        let tool = HoloProfileTool(dataSource: MockProfileDataSource(value: snapshot))
        let result = try await tool.execute(request("preference_boundaries"))

        expect(metric("profile.communication_style.count", in: result) == 2, "沟通偏好应为 2 条")
        expect(metric("profile.sensitive_boundary.count", in: result) == 1, "敏感边界应为 1 条")
        expect(result.sensitivity == .sensitive, "Profile 工具结果必须标记 sensitive")
    }

    private static func test空档案返回empty() async throws {
        let tool = HoloProfileTool(dataSource: MockProfileDataSource(value: nil))
        let result = try await tool.execute(request("profile_summary"))

        expect(result.status == .empty, "空档案应返回 empty")
        expect(result.warnings.contains { $0.code == "NO_PROFILE_DATA" }, "应返回明确 warning")
    }
}
