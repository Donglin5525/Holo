//
//  HoloToolExecutor.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.2 工具执行器
//  统一编排「查找 → 校验 → 执行」，捕获工具异常，保证 Agent Loop 不因 throw 崩溃。
//

import Foundation

actor HoloToolExecutor: HoloAgentToolExecuting {

    private let registry: HoloToolRegistry

    init(registry: HoloToolRegistry) {
        self.registry = registry
    }

    /// 汇总已注册工具的 Prompt 描述，供 runtime 构建 agent_loop 系统提示。
    func promptDescription() async -> String {
        await registry.promptDescription()
    }

    /// 执行一次工具请求，永不 throw：所有失败转为带 error 的 HoloDataToolResult。
    func execute(_ request: HoloToolRequest) async -> HoloDataToolResult {
        guard let tool = await registry.tool(named: request.tool) else {
            return Self.makeError(request, code: HoloToolErrorCode.toolNotFound,
                                  message: "未注册的工具：\(request.tool)", recoverable: false)
        }

        switch tool.validate(request) {
        case .valid:
            break
        case .invalid(let reason):
            return Self.makeError(request, code: HoloToolErrorCode.invalidParams,
                                  message: reason, recoverable: true)
        }

        do {
            return try await tool.execute(request)
        } catch {
            return Self.makeError(request, code: HoloToolErrorCode.executionFailure,
                                  message: error.localizedDescription, recoverable: true)
        }
    }

    private static func makeError(_ request: HoloToolRequest, code: String,
                                  message: String, recoverable: Bool) -> HoloDataToolResult {
        HoloDataToolResult(
            toolRequestID: request.id, tool: request.tool, status: .error,
            coverage: nil, metrics: [], events: [], warnings: [],
            error: HoloToolError(code: code, message: message, recoverable: recoverable)
        )
    }
}
