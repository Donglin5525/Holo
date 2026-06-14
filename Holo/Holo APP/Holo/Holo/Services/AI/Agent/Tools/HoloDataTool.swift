//
//  HoloDataTool.swift
//  Holo
//
//  HoloAI Agent V3.1 — Task 2.2 本地数据工具协议
//  Agent 通过实现此协议的工具读取用户数据（记账/习惯/健康等），产出可信证据。
//

import Foundation

/// 本地数据工具协议：所有可被 Agent 调用的工具统一形态。
protocol HoloDataTool: Sendable {
    var descriptor: HoloToolDescriptor { get }
    func validate(_ request: HoloToolRequest) -> HoloToolValidationResult
    func execute(_ request: HoloToolRequest) async throws -> HoloDataToolResult
}

/// 工具自描述：名称、能力、敏感度策略，用于注册中心汇总为 Prompt。
struct HoloToolDescriptor: Codable, Equatable, Sendable {
    var name: String
    var description: String
    var supportedQueries: [String]
    var supportedTimeRanges: [String]
    var outputMetrics: [String]
    var sensitivityPolicy: String
}

/// 参数校验结果。
enum HoloToolValidationResult: Equatable, Sendable {
    case valid
    case invalid(reason: String)
}

/// 工具错误码（Executor 与各工具统一使用，便于上层识别与重试策略）。
enum HoloToolErrorCode {
    /// 工具未注册
    static let toolNotFound = "TOOL_NOT_FOUND"
    /// 参数非法（可恢复，提示 LLM 重试）
    static let invalidParams = "INVALID_PARAMS"
    /// 执行异常（通常可恢复）
    static let executionFailure = "EXECUTION_FAILURE"
}
