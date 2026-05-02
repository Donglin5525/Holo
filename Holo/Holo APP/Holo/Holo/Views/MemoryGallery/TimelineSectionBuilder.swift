//
//  TimelineSectionBuilder.swift
//  Holo
//
//  时间线 section 构建器
//

import Foundation

// MARK: - TimelineSectionBuilder

/// 时间线 section 构建器
/// 将原始 MemoryItem + 高亮 + 里程碑 合成为时间线节点
enum TimelineSectionBuilder {

    /// 为某一天构建完整的时间线 section
    static func buildSection(
        date: Date,
        items: [MemoryItem],
        highlights: [HighlightData],
        milestones: [MilestoneData],
        moduleFilter: MemoryModuleFilter
    ) -> TimelineSection {
        var nodes: [MemoryTimelineNode] = []

        // 1. 日摘要节点（始终生成，即使部分数据为空）
        let summaryNode = buildDailySummary(
            date: date,
            items: items,
            moduleFilter: moduleFilter
        )
        nodes.append(summaryNode)

        // 2. 里程碑节点（如有）
        for milestoneData in milestones {
            let node = MemoryTimelineNode(
                date: date,
                type: .milestone,
                data: .milestone(milestoneData)
            )
            nodes.append(node)
        }

        // 3. 高亮节点
        for highlightData in highlights {
            let node = MemoryTimelineNode(
                date: date,
                type: .highlight,
                data: .highlight(highlightData)
            )
            nodes.append(node)
        }

        // 按 sortOrder 排序：日摘要 → 里程碑 → 高亮
        nodes.sort { $0.sortOrder < $1.sortOrder }

        return TimelineSection(date: date, nodes: nodes)
    }

    /// 构建日摘要节点
    private static func buildDailySummary(
        date: Date,
        items: [MemoryItem],
        moduleFilter: MemoryModuleFilter
    ) -> MemoryTimelineNode {
        // 计算各模块统计
        let transactions = items.filter { $0.type == .transaction }
        let habits = items.filter { $0.type == .habitRecord }
        let tasks = items.filter { $0.type == .task }
        let thoughts = items.filter { $0.type == .thought }

        // 总消费（仅支出）
        let totalExpense: Decimal? = transactions.isEmpty ? nil : transactions.reduce(Decimal(0)) { sum, item in
            guard let amount = item.amount else { return sum }
            return sum + amount
        }

        // 习惯完成数（简化：按有记录的习惯计数）
        let habitsCompleted = habits.filter { $0.subtitle != "未完成" }.count
        let habitsTotal = habits.count

        // 任务完成数
        let tasksCompleted = tasks.filter { $0.subtitle == "已完成" }.count

        let summaryData = DailySummaryData(
            totalExpense: totalExpense,
            habitsCompleted: habitsCompleted,
            habitsTotal: habitsTotal,
            tasksCompleted: tasksCompleted,
            thoughtCount: thoughts.count
        )

        return MemoryTimelineNode(
            date: date,
            type: .dailySummary,
            data: .summary(summaryData)
        )
    }
}
