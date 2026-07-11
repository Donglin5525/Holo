//
//  HoloToolRegistryTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 2.2 Tool Registry 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Tools/HoloDataTool.swift> \
//    <Services/AI/Agent/Tools/HoloToolRegistry.swift> <本测试> \
//    -o /tmp/holo_tool_registry_test && /tmp/holo_tool_registry_test
//

import Foundation

/// Registry 测试专用工具（独立命名，避免与其他测试文件联合编译时重复定义）。
struct MockRegistryTool: HoloDataTool {
    let descriptor = HoloToolDescriptor(
        name: "finance", description: "记账数据查询",
        supportedQueries: ["expense", "income"],
        supportedTimeRanges: ["7d", "30d"],
        outputMetrics: ["amount"],
        sensitivityPolicy: "normal"
    )

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult { .valid }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        HoloDataToolResult(toolRequestID: request.id, tool: request.tool, status: .success,
                           coverage: nil, metrics: [], events: [], warnings: [], error: nil)
    }
}

/// 可配置名字的 registry 测试工具，用于验证多工具注册与排序。
struct RegistryTestTool: HoloDataTool {
    let descriptor: HoloToolDescriptor

    init(name: String, catalog: HoloDataCatalog? = nil) {
        descriptor = HoloToolDescriptor(
            name: name,
            description: "\(name) 工具",
            supportedQueries: catalog == nil ? [] : ["dynamic_query"],
            supportedTimeRanges: [],
            outputMetrics: [],
            sensitivityPolicy: "normal",
            dynamicCatalog: catalog
        )
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult { .valid }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        HoloDataToolResult(toolRequestID: request.id, tool: request.tool, status: .success,
                           coverage: nil, metrics: [], events: [], warnings: [], error: nil)
    }
}

@main
struct HoloToolRegistryTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async {
        await test注册工具后可按名查找()
        await testPromptDescription包含已注册工具信息()
        await test注册多工具后描述含目标想法任务且按名排序()
        await testPromptDescription公开动态字段目录()
        test生产覆盖契约包含全部用户语义工具()
        test动态目录覆盖全部用户数据域()
        print("HoloToolRegistryTests passed")
    }

    private static func test注册工具后可按名查找() async {
        let registry = HoloToolRegistry()
        await registry.register(MockRegistryTool())

        let tool = await registry.tool(named: "finance")
        expect(tool != nil, "应能按名找到已注册工具")
        expect(tool?.descriptor.name == "finance", "工具名应为 finance")

        let missing = await registry.tool(named: "ghost")
        expect(missing == nil, "未注册的工具应返回 nil")
    }

    private static func testPromptDescription包含已注册工具信息() async {
        let registry = HoloToolRegistry()
        await registry.register(MockRegistryTool())

        let description = await registry.promptDescription()
        expect(description.contains("finance"), "描述应包含工具名 finance")
        expect(description.contains("记账数据查询"), "描述应包含工具描述")
    }

    private static func test注册多工具后描述含目标想法任务且按名排序() async {
        let registry = HoloToolRegistry()
        await registry.register(RegistryTestTool(name: "task"))
        await registry.register(RegistryTestTool(name: "goal"))
        await registry.register(RegistryTestTool(name: "thought"))
        await registry.register(RegistryTestTool(name: "finance"))

        let description = await registry.promptDescription()
        expect(description.contains("【goal】"), "描述应含 goal 工具")
        expect(description.contains("【thought】"), "描述应含 thought 工具")
        expect(description.contains("【task】"), "描述应含 task 工具")

        // promptDescription 按名字升序：finance < goal < task < thought
        guard let financeRange = description.range(of: "【finance】"),
              let goalRange = description.range(of: "【goal】"),
              let taskRange = description.range(of: "【task】"),
              let thoughtRange = description.range(of: "【thought】") else {
            fatalError("四个工具区间应都存在")
        }
        expect(financeRange.lowerBound < goalRange.lowerBound, "finance 应排在 goal 前")
        expect(goalRange.lowerBound < taskRange.lowerBound, "goal 应排在 task 前")
        expect(taskRange.lowerBound < thoughtRange.lowerBound, "task 应排在 thought 前")
    }

    private static func testPromptDescription公开动态字段目录() async {
        HoloAgentDynamicQueryFlags.enabled = true
        let registry = HoloToolRegistry()
        await registry.register(RegistryTestTool(name: "thought", catalog: HoloAgentDynamicCatalogs.thought))
        let description = await registry.promptDescription()
        expect(description.contains("dynamic_query"), "动态工具描述必须公开统一 query")
        expect(description.contains("thought.daily"), "动态工具描述必须公开数据集")
        expect(description.contains("value:number[条]"), "动态工具描述必须公开字段类型和单位")
    }

    private static func test生产覆盖契约包含全部用户语义工具() {
        let expected: Set<String> = [
            "conversation", "finance", "goal", "habit", "health",
            "insight", "memory", "profile", "task", "thought"
        ]
        expect(
            Set(HoloAgentToolCoverage.requiredToolNames) == expected,
            "生产工具覆盖契约应包含 10 个用户语义工具"
        )
    }

    private static func test动态目录覆盖全部用户数据域() {
        let domains = Set(HoloAgentToolCoverage.requiredDynamicDatasets.map { $0.split(separator: ".").first.map(String.init) ?? "" })
        let expected: Set<String> = ["conversation", "finance", "goal", "habit", "health", "insight", "memory", "profile", "task", "thought"]
        expect(domains == expected, "动态目录覆盖契约必须覆盖全部 10 个用户数据域")
        expect(HoloAgentToolCoverage.requiredDynamicDatasets.contains("health.sleep"), "健康睡眠必须进入动态目录")
        expect(HoloAgentToolCoverage.requiredDynamicDatasets.contains("conversation.metadata"), "对话只允许受控元数据目录")
    }
}
