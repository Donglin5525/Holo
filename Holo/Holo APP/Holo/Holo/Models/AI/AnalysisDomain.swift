//
//  AnalysisDomain.swift
//  Holo
//
//  AI 分析查询领域枚举
//

import Foundation

/// 分析查询覆盖的数据领域
enum AnalysisDomain: String, Codable, Equatable, Sendable {
    case finance
    case habit
    case task
    case thought
    case crossModule

    /// 从用户原文关键词推断领域
    static func infer(from text: String) -> AnalysisDomain? {
        let lower = text.lowercased()
        let financeKeywords = ["消费", "支出", "收入", "预算", "账单", "财务", "花了多少", "花钱"]
        let habitKeywords = ["习惯", "打卡", "连续", "完成率", "坚持"]
        let taskKeywords = ["任务", "待办", "完成", "逾期", "优先级"]
        let thoughtKeywords = ["想法", "记录", "情绪", "标签", "观点", "心情"]
        let crossKeywords = ["复盘", "综合分析", "状态", "最近过得", "总结", "整体"]

        for keyword in crossKeywords where lower.contains(keyword) { return .crossModule }
        for keyword in financeKeywords where lower.contains(keyword) { return .finance }
        for keyword in habitKeywords where lower.contains(keyword) { return .habit }
        for keyword in taskKeywords where lower.contains(keyword) { return .task }
        for keyword in thoughtKeywords where lower.contains(keyword) { return .thought }
        return nil
    }
}
