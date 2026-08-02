//
//  HoloAgentStepPollingPolicy.swift
//  Holo
//
//  Agent step 幂等轮询预算：客户端连接中断后，等待后端原步骤完成，
//  不重新启动模型调用，也不使用无限重试次数作为任务真相源。
//

import Foundation

struct HoloAgentStepPollingPolicy: Sendable, Equatable {
    static let production = HoloAgentStepPollingPolicy(
        maximumWait: 130,
        maximumDelay: 5
    )

    let maximumWait: TimeInterval
    let maximumDelay: TimeInterval

    func nextDelay(retryIndex: Int, waited: TimeInterval) -> TimeInterval? {
        guard retryIndex > 0, maximumWait > 0, maximumDelay > 0 else { return nil }
        let boundedExponent = min(retryIndex, 20)
        let delay = min(pow(2.0, Double(boundedExponent)), maximumDelay)
        guard waited + delay <= maximumWait else { return nil }
        return delay
    }
}
