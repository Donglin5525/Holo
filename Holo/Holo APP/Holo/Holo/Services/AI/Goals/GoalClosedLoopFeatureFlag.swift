//
//  GoalClosedLoopFeatureFlag.swift
//  Holo
//
//  目标闭环统一功能开关（最终规格 §11）：服务端 feature_flags `goalClosedLoopV1` 下发，
//  默认关。关闭时隐藏新增的「目标分析」区、修正入口与目标专属回顾调度；
//  旧目标与所有原模块对象、记录、报告保留，不降级重写新 schema、不批量删除已创建对象。
//  已确认的计划修改属于真实用户数据，回退不等于自动撤销它们。
//  开关消费一律走 .holoServerFlagsDidUpdate 广播刷新（goal-workshop 入口「时有时无」教训）。
//

import Foundation

extension HoloAIFeatureFlags {
    static var goalClosedLoopEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("GOAL_CLOSED_LOOP_FORCE_ON") { return true }
        #endif
        return HoloServerFeatureFlags.value("goalClosedLoopV1", localDefault: false)
    }
}
