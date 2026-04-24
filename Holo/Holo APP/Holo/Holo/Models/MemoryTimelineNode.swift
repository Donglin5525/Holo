//
//  MemoryTimelineNode.swift
//  Holo
//
//  记忆长廊时间线节点模型
//  三层叙事结构：日摘要 → 高亮 → 里程碑
//

import Foundation

// MARK: - MemoryNodeType

/// 时间线节点类型，视觉权重递增
enum MemoryNodeType: String, Comparable {
    case dailySummary   // 日摘要 — 每天一个，聚合数据
    case highlight      // 高亮 — 算法筛选的值得注意的事件
    case milestone      // 里程碑 — 重大成就

    /// 节点在时间线上的视觉权重
    var visualWeight: Int {
        switch self {
        case .dailySummary: return 1
        case .highlight: return 2
        case .milestone: return 3
        }
    }

    // Comparable — 按视觉权重排序
    static func < (lhs: MemoryNodeType, rhs: MemoryNodeType) -> Bool {
        lhs.visualWeight < rhs.visualWeight
    }
}

// MARK: - MemoryTimelineNode

/// 时间线节点
struct MemoryTimelineNode: Identifiable {
    let id: UUID
    let date: Date
    let type: MemoryNodeType
    let data: NodeData

    init(date: Date, type: MemoryNodeType, data: NodeData) {
        self.id = UUID()
        self.date = date
        self.type = type
        self.data = data
    }

    /// 同一天内的排序优先级（日摘要 < 里程碑 < 高亮）
    /// 数值越小越靠前
    var sortOrder: Int {
        switch type {
        case .dailySummary: return 0
        case .milestone: return 1
        case .highlight: return 2
        }
    }
}

// MARK: - NodeData

/// 节点数据（按类型区分）
enum NodeData {
    case summary(DailySummaryData)
    case highlight(HighlightData)
    case milestone(MilestoneData)
}

// MARK: - DailySummaryData

/// 日摘要数据 — 聚合当日所有模块统计
struct DailySummaryData {
    /// 当日总消费（nil = 无记账数据）
    let totalExpense: Decimal?
    /// 完成习惯数
    let habitsCompleted: Int
    /// 总习惯数
    let habitsTotal: Int
    /// 完成任务数
    let tasksCompleted: Int
    /// 观点数
    let thoughtCount: Int
}

// MARK: - HighlightData

/// 高亮数据 — 算法筛选的值得注意事件
struct HighlightData {
    let category: HighlightCategory
    let title: String
    let subtitle: String?
    let icon: String
    let sourceModule: MemoryItemType

    /// 高亮语义色调
    var tone: HighlightTone {
        switch category {
        case .streakAchievement, .habitPerfect:
            return .positive
        case .spendingAnomaly:
            return .negative
        case .taskCompletion:
            return .achievement
        }
    }
}

/// 高亮类别
enum HighlightCategory: String {
    case streakAchievement  // 连续打卡成就（3/7/14/21天）
    case spendingAnomaly    // 消费异常（高于7日均值 x 1.5）
    case taskCompletion     // 重要任务完成（priority >= high）
    case habitPerfect       // 习惯全勤日
}

/// 高亮语义色调
enum HighlightTone {
    case positive    // 正面 — holoPrimary 橙色
    case negative    // 负面 — holoError 红色
    case achievement // 成就 — holoSuccess 绿色
}

// MARK: - MilestoneData

/// 里程碑数据 — 重大成就
struct MilestoneData {
    let title: String
    let description: String
    let icon: String
    let milestoneType: MilestoneType
}

/// 里程碑类型
enum MilestoneType: String {
    case streakDays       // 连续打卡 N 天（30/365）
    case cumulativeCount  // 累计记录 N 笔（100/500）
    case habitMastery     // 习惯掌握（单习惯连续 30 天+）
}

// MARK: - TimelineSection

/// 时间线按日期分组的 section
struct TimelineSection: Identifiable {
    let date: Date
    var nodes: [MemoryTimelineNode]

    var id: Date { date }

    /// 格式化日期标题
    var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 星期几
    var formattedWeekday: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.locale = Locale(identifier: "zh_CN")
        let weekday = formatter.string(from: date)
        // "星期一" → "周一"
        return weekday.replacingOccurrences(of: "星期", with: "周")
    }

    var isToday: Bool {
        Calendar.current.isDateInToday(date)
    }

    var isYesterday: Bool {
        Calendar.current.isDateInYesterday(date)
    }

    /// 显示用的日期标签
    var displayLabel: String {
        if isToday {
            return "今天"
        } else if isYesterday {
            return "昨天"
        } else {
            return formattedWeekday
        }
    }
}
