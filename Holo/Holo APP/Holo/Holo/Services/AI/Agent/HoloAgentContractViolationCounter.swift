//
//  HoloAgentContractViolationCounter.swift
//  Holo
//
//  Agent 成熟度演进 P0-D — Contract Policy 违规计数器
//
//  Parser 是无状态静态 enum，无法直接访问 telemetry。
//  本计数器作为轻量桥接：Parser 记录违规/修复计数，Runtime 在 telemetry 事件中读取并清零。
//  只记录技术元数据（计数），不记录用户问题、金额、健康数据或证据正文。
//

import Foundation

final class HoloAgentContractViolationCounter: @unchecked Sendable {

    static let shared = HoloAgentContractViolationCounter()

    private let lock = NSLock()
    private var pendingViolations: Int = 0
    private var pendingRepairs: Int = 0

    private init() {}

    /// Parser 调用：记录一次解析的违规和修复计数。
    func record(violations: Int, repairs: Int) {
        lock.lock()
        defer { lock.unlock() }
        pendingViolations += violations
        pendingRepairs += repairs
    }

    /// Runtime 调用：读取并清零待报告的计数（用于 telemetry 事件）。
    /// 返回 nil 表示没有待报告的违规/修复。
    func consumeAndReport() -> (violations: Int, repairs: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard pendingViolations > 0 || pendingRepairs > 0 else { return nil }
        let result = (pendingViolations, pendingRepairs)
        pendingViolations = 0
        pendingRepairs = 0
        return result
    }
}
