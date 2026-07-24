//
//  HoloToolExecutorTests.swift
//  HoloTests
//
//  Agent V3.1 — Task 2.2 Tool Executor 测试
//  运行：swiftc -parse-as-library \
//    <Models/AI/Agent/*.swift> <Services/AI/Agent/Tools/HoloDataTool.swift> \
//    <Services/AI/Agent/Tools/HoloToolRegistry.swift> <Services/AI/Agent/Tools/HoloToolExecutor.swift> \
//    <本测试> -o /tmp/holo_tool_executor_test && /tmp/holo_tool_executor_test
//

import Foundation

/// Executor 测试专用错误（Sendable，确保 mock struct 可自动 Sendable）。
struct MockExecutorError: Error, Sendable {}

/// Executor 测试专用工具：可配置校验结果、返回结果或抛错。
struct MockExecutorTool: HoloDataTool {
    let descriptor = HoloToolDescriptor(
        name: "mock", description: "测试工具",
        supportedQueries: [], supportedTimeRanges: [],
        outputMetrics: [], sensitivityPolicy: "normal"
    )
    let validation: HoloToolValidationResult
    let result: HoloDataToolResult?
    let thrownError: MockExecutorError?

    init(validation: HoloToolValidationResult = .valid,
         result: HoloDataToolResult? = nil,
         thrownError: MockExecutorError? = nil) {
        self.validation = validation
        self.result = result
        self.thrownError = thrownError
    }

    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult { validation }

    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult {
        if let thrownError { throw thrownError }
        return result ?? HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .success,
            coverage: nil, metrics: [], events: [], warnings: [], error: nil
        )
    }
}

#if HOLO_XCTEST_BRIDGE
import XCTest
@testable import Holo
#else
@main
private struct HoloStandaloneLauncher {
    static func main() async throws {
        await HoloToolExecutorTests.main()
    }
}
#endif
struct HoloToolExecutorTests {

    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() async {
        await test不存在工具返回error和TOOL_NOT_FOUND()
        await test参数非法返回error和INVALID_PARAMS()
        await test工具空结果透传empty()
        await test工具抛错返回error且recoverable()
        print("HoloToolExecutorTests passed")
    }

    private static func makeRequest(tool: String, id: String = "req-1") -> HoloToolRequest {
        HoloToolRequest(id: id, tool: tool, query: "summary", timeRange: nil, baseline: nil,
                        requiredMetrics: [], parameters: [:])
    }

    private static func test不存在工具返回error和TOOL_NOT_FOUND() async {
        let registry = HoloToolRegistry()
        let executor = HoloToolExecutor(registry: registry)

        let result = await executor.execute(makeRequest(tool: "ghost"))

        expect(result.status == .error, "不存在工具应返回 error，实际 \(result.status)")
        expect(result.error?.code == HoloToolErrorCode.toolNotFound, "错误码应为 TOOL_NOT_FOUND")
        expect(result.error?.recoverable == false, "TOOL_NOT_FOUND 应不可恢复")
    }

    private static func test参数非法返回error和INVALID_PARAMS() async {
        let registry = HoloToolRegistry()
        await registry.register(MockExecutorTool(validation: .invalid(reason: "缺少时间范围")))
        let executor = HoloToolExecutor(registry: registry)

        let result = await executor.execute(makeRequest(tool: "mock"))

        expect(result.status == .error, "参数非法应返回 error")
        expect(result.error?.code == HoloToolErrorCode.invalidParams, "错误码应为 INVALID_PARAMS")
        expect(result.error?.recoverable == true, "INVALID_PARAMS 应可恢复")
        expect(result.error?.message.contains("缺少时间范围") ?? false, "应携带校验原因")
    }

    private static func test工具空结果透传empty() async {
        let registry = HoloToolRegistry()
        let emptyResult = HoloDataToolResult(
            toolRequestID: "req-1", tool: "mock", status: .empty,
            coverage: nil, metrics: [], events: [], warnings: [], error: nil
        )
        await registry.register(MockExecutorTool(result: emptyResult))
        let executor = HoloToolExecutor(registry: registry)

        let result = await executor.execute(makeRequest(tool: "mock"))

        expect(result.status == .empty, "工具空结果应透传 empty，实际 \(result.status)")
        expect(result.error == nil, "empty 不应带 error")
    }

    private static func test工具抛错返回error且recoverable() async {
        let registry = HoloToolRegistry()
        await registry.register(MockExecutorTool(thrownError: MockExecutorError()))
        let executor = HoloToolExecutor(registry: registry)

        let result = await executor.execute(makeRequest(tool: "mock"))

        expect(result.status == .error, "工具抛错应返回 error")
        expect(result.error?.recoverable == true, "执行异常应标记为可恢复")
    }
}
