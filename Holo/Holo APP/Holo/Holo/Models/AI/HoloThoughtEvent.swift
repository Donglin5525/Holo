//
//  HoloThoughtEvent.swift
//  Holo
//
//  AI 思考过程的可见化事件模型。
//  统一表达「深度分析 / 普通聊天 / 普通分析」三条线在思考期间发生的一个个动作，
//  供思考状态卡片折叠态（最近一条）与展开态（完整日志时间线）渲染。
//

import Foundation

/// 一次 AI 思考动作（理解问题 / 翻阅账单 / 回顾记忆 / 生成结论 …）。
struct HoloThoughtEvent: Identifiable, Equatable {
    let id = UUID()
    /// 动作发生时间（近似；reporter 触发时刻）。
    let timestamp: Date
    /// 用户可见文案，如「正在翻阅账单」「正在回顾记忆（3 条）」。
    let title: String
}
