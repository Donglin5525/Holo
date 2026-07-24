//
//  HoloAgentToolModels.swift
//  Holo
//
//  HoloAI Agent V3.1 — 本地工具协议：请求 / 结果 / 度量 / 事件 / 覆盖度 / 警告
//

import Foundation

// MARK: - 工具请求

nonisolated struct HoloToolRequest: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var tool: String
    var query: String
    var timeRange: HoloAgentTimeRange?
    var baseline: HoloAgentTimeRange?
    var requiredMetrics: [String]
    var parameters: [String: String]
    var dynamicPlan: HoloDynamicQueryPlan? = nil
    var crossDomainPlan: HoloCrossDomainQueryPlan? = nil
}

// MARK: - 结果状态与错误

nonisolated enum HoloToolResultStatus: String, Codable, CaseIterable, Sendable {
    case success
    case empty
    case partial
    case error
    case unavailable
    case timeout
}

nonisolated struct HoloToolError: Codable, Equatable, Sendable {
    var code: String
    var message: String
    var recoverable: Bool
}

nonisolated struct HoloToolWarning: Codable, Equatable, Sendable {
    var code: String
    var message: String
}

// MARK: - 工具输出度量与事件

/// 工具输出的单个度量值（如 habit.negative.frequency_change = 20）
nonisolated struct HoloMetric: Codable, Equatable, Sendable {
    var metricKey: String
    var value: Double?
    var unit: String?
    var baselineValue: Double?
    var comparison: String?
    var formula: String? = nil
    var sourceRecordIDs: [String]? = nil
}

// MARK: - 用户可见指标语义

/// 把稳定的内部 metric key 转换为用户能直接理解的中文。
/// metric key 继续用于计算和校验，但任何面向用户的正文都必须经过这里。
nonisolated enum HoloMetricSemanticCatalog {

    static func title(for metricKey: String) -> String {
        title(for: metricKey, comparison: nil)
    }

    static func title(for metricKey: String, comparison: String?) -> String {
        if let dynamicTitle = dynamicTitle(for: metricKey, comparison: comparison) {
            return dynamicTitle
        }
        switch metricKey {
        case "health.steps.average": return "平均步数"
        case "health.steps.goal_met_days": return "达标情况"
        case "health.steps.daily": return "每日步数"
        case "health.sleep.average_hours": return "平均睡眠"
        case "health.sleep.goal_met_days": return "睡眠达标"
        case "health.sleep.low_days": return "睡眠不足"
        case "health.sleep.recorded_nights": return "有效记录"
        case "health.sleep.duration_variation_minutes": return "睡眠时长波动"
        case "health.sleep.deep_hours": return "平均深睡"
        case "health.sleep.core_hours": return "平均核心睡眠"
        case "health.sleep.rem_hours": return "平均 REM 睡眠"
        case "health.sleep.awake_hours": return "夜间清醒"
        case "health.sleep.in_bed_hours": return "平均在床时长"
        case "health.sleep.efficiency": return "睡眠效率"
        case "health.sleep.average_bedtime_minutes": return "平均入睡时间"
        case "health.sleep.average_wake_minutes": return "平均起床时间"
        case "health.sleep.bedtime_variation_minutes": return "入睡时间波动"
        case "health.sleep.wake_variation_minutes": return "起床时间波动"
        case "health.sleep.interruptions": return "夜间中断"
        case "health.sleep.hours": return "睡眠时长"
        case "health.stand.average_hours": return "平均站立时长"
        case "health.stand.goal_met_days": return "站立达标"
        case "health.stand.hours": return "站立时长"
        case "health.activity.average_minutes": return "平均活动时间"
        case "health.activity.goal_met_days": return "活动达标"
        case "health.activity.minutes": return "活动时间"
        case "health.workout.total_minutes": return "运动总时长"
        case "health.workout.session_count": return "运动次数"
        case "health.workout.active_days": return "运动天数"
        case "health.workout.daily_minutes": return "每日运动"
        case "finance.total.amount": return "总支出"
        case "finance.category.amount": return "主要支出去向"
        case "finance.transaction.sample": return "重点账单"
        case "finance.meal.nighttime_count": return "夜间餐饮次数"
        case "finance.category.concentration": return "支出集中度"
        case "finance.amount.change": return "支出变化"
        case "finance.keyword.count": return "相关消费次数"
        case "finance.keyword.amount": return "相关消费金额"
        case "finance.budget.total": return "预算总额"
        case "finance.budget.spent": return "已用预算"
        case "finance.budget.remaining": return "剩余预算"
        case "finance.budget.progress": return "预算使用率"
        case "finance.account.count": return "账户数量"
        case "finance.account.assets": return "总资产"
        case "finance.account.liabilities": return "总负债"
        case "finance.account.net_worth": return "净资产"
        case "habit.negative.frequency_change": return "发生频率变化"
        case "habit.negative.over_limit_days": return "超出目标天数"
        case "habit.negative.control_rate": return "控制达标率"
        case "habit.negative.goal_conflict_days": return "与目标冲突天数"
        case "habit.positive.completion_rate": return "习惯完成率"
        case "habit.streak_break_days": return "连续中断天数"
        case "task.today.total": return "今日任务"
        case "task.today.completed": return "今日已完成"
        case "task.overdue.count": return "逾期任务"
        case "task.backlog.active_count": return "待处理积压"
        case "task.completion.rate": return "任务完成率"
        case "goal.active.count": return "进行中的目标"
        case "goal.deadline.upcoming_days": return "距离截止日"
        case "goal.linked_task.completion_rate": return "关联任务完成率"
        case "goal.linked_habit.count": return "关联习惯数量"
        case "thought.count.total": return "想法数量"
        case "thought.mood.count": return "心情记录"
        case "thought.activity.daily_count": return "每日想法数量"
        case "thought.topic.count": return "关注主题数量"
        case "memory.long_term.count": return "长期记忆"
        case "memory.episodic.active_count": return "近期记忆"
        case "memory.suppression.active_count": return "不再提醒的内容"
        case "insight.observation.count": return "历史洞察"
        case "profile.field.count": return "档案信息"
        case "profile.focus.count": return "当前关注"
        case "profile.communication_style.count": return "沟通偏好"
        case "profile.sensitive_boundary.count": return "敏感边界"
        case "conversation.message.count": return "近期消息"
        case "conversation.user.count": return "用户消息"
        case "conversation.assistant.count": return "Holo 回复"
        case "conversation.intent.count": return "对话主题"
        case "conversation.session.message_count": return "本次对话消息"
        case "dynamic.cross.correlation": return "同期相关性"
        case "dynamic.cross.conditional_average": return "分组平均值"
        case "dynamic.cross.group_difference": return "分组差异"
        default: return inferredTitle(for: metricKey)
        }
    }

    static func topic(for metricKey: String) -> String {
        if metricKey.hasPrefix("health.steps") { return "步数" }
        if metricKey.hasPrefix("health.sleep") { return "睡眠" }
        if metricKey.hasPrefix("health.stand") { return "站立" }
        if metricKey.hasPrefix("health.activity") { return "活动" }
        if metricKey.hasPrefix("health.workout") { return "运动" }
        if metricKey.hasPrefix("finance") || metricKey.hasPrefix("dynamic.finance") { return "财务" }
        if metricKey.hasPrefix("habit") || metricKey.hasPrefix("dynamic.habit") { return "习惯" }
        if metricKey.hasPrefix("task") || metricKey.hasPrefix("dynamic.task") { return "任务" }
        if metricKey.hasPrefix("goal") || metricKey.hasPrefix("dynamic.goal") { return "目标" }
        if metricKey.hasPrefix("thought") || metricKey.hasPrefix("dynamic.thought") { return "想法" }
        if metricKey.hasPrefix("memory") || metricKey.hasPrefix("dynamic.memory") { return "记忆" }
        if metricKey.hasPrefix("insight") || metricKey.hasPrefix("dynamic.insight") { return "洞察" }
        if metricKey.hasPrefix("profile") || metricKey.hasPrefix("dynamic.profile") { return "个人档案" }
        if metricKey.hasPrefix("conversation") || metricKey.hasPrefix("dynamic.conversation") { return "对话" }
        if metricKey.hasPrefix("dynamic.cross") { return "跨领域变化" }
        return "数据"
    }

    static func sentence(
        metricKey: String,
        value: Double?,
        unit: String?,
        comparison: String? = nil
    ) -> String? {
        guard let value else { return nil }
        if let dynamicSentence = dynamicSentence(
            metricKey: metricKey,
            value: value,
            unit: unit,
            comparison: comparison
        ) {
            return dynamicSentence
        }
        let valueText = formattedNumber(value, metricKey: metricKey, unit: unit)
        switch metricKey {
        case "health.steps.average": return "平均每天 \(valueText) 步"
        case "health.steps.goal_met_days": return "达到 10,000 步 \(valueText) 天"
        case "health.sleep.average_hours": return "平均睡眠 \(valueText) 小时"
        case "health.sleep.goal_met_days": return "睡够 8 小时 \(valueText) 晚"
        case "health.sleep.low_days": return "低于 6 小时 \(valueText) 晚"
        case "health.sleep.recorded_nights": return "有效睡眠记录 \(valueText) 晚"
        case "health.stand.average_hours": return "平均每天站立 \(valueText) 小时"
        case "health.stand.goal_met_days": return "达到 12 小时站立目标 \(valueText) 天"
        case "health.activity.average_minutes": return "平均每天活动 \(valueText) 分钟"
        case "health.activity.goal_met_days": return "活动至少 30 分钟 \(valueText) 天"
        case "health.workout.total_minutes": return "累计运动 \(valueText) 分钟"
        case "health.workout.session_count": return "共运动 \(valueText) 次"
        case "health.workout.active_days": return "有运动记录 \(valueText) 天"
        case "finance.category.amount":
            let category = comparison?.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(category?.isEmpty == false ? category! : "该分类")支出 \(valueText) 元"
        default:
            let resolvedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return "\(title(for: metricKey)) \(valueText)\(resolvedUnit)"
        }
    }

    static func containsInternalToken(_ text: String) -> Bool {
        if text.contains(" = ") || text.contains("_") || text.contains("计算结果") { return true }
        let prefixes = [
            "health.", "finance.", "habit.", "task.", "goal.", "thought.",
            "memory.", "insight.", "profile.", "conversation.", "dynamic."
        ]
        return prefixes.contains { text.contains($0) }
    }

    static func formattedNumber(_ value: Double, metricKey: String, unit: String?) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.minimumFractionDigits = 0

        let needsInteger = value.rounded() == value ||
            unit == "步" || unit == "天" || unit == "晚" || unit == "次" || unit == "条" || unit == "项"
        if needsInteger {
            formatter.maximumFractionDigits = 0
        } else if metricKey.contains("amount") || unit == "元" {
            formatter.maximumFractionDigits = 2
        } else {
            formatter.maximumFractionDigits = 1
        }
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private static func inferredTitle(for metricKey: String) -> String {
        let normalized = metricKey.lowercased()
        if normalized.contains("average_sleep") { return "平均睡眠" }
        if normalized.contains("per_day") || normalized.contains("daily_average") { return "平均每天" }
        if normalized.contains("average") || normalized.contains("mean") { return "平均值" }
        if normalized.contains("total_spending") || normalized.contains("total_amount") { return "总金额" }
        if normalized.contains("count") { return "数量" }
        if normalized.contains("sum") || normalized.contains("total") { return "合计" }
        if normalized.contains("rate") || normalized.contains("ratio") { return "占比" }
        if normalized.contains("trend") || normalized.contains("change") { return "变化趋势" }
        return "计算结果"
    }

    private static func dynamicTitle(for metricKey: String, comparison: String?) -> String? {
        let normalized = metricKey.lowercased()
        guard normalized.hasPrefix("dynamic.") else { return nil }
        let subject = dynamicGroupLabel(metricKey: metricKey, comparison: comparison)

        if normalized.hasPrefix("dynamic.finance") {
            if isPercentageChangeMetric(normalized) {
                return subject.map { "\($0)支出增幅" } ?? "分类支出增幅"
            }
            if isDifferenceMetric(normalized) {
                return subject.map { "\($0)支出变化" } ?? "分类支出变化"
            }
            if normalized.contains("amount") || normalized.contains("spending") {
                return subject.map { "\($0)支出" } ?? "支出金额"
            }
        }
        return nil
    }

    private static func dynamicSentence(
        metricKey: String,
        value: Double,
        unit: String?,
        comparison: String?
    ) -> String? {
        let normalized = metricKey.lowercased()
        guard normalized.hasPrefix("dynamic.") else { return nil }
        let subject = dynamicGroupLabel(metricKey: metricKey, comparison: comparison)

        if normalized.hasPrefix("dynamic.finance") {
            if isPercentageChangeMetric(normalized) {
                let percent = abs(value) <= 1.000_001 ? value * 100 : value
                let amount = formattedNumber(abs(percent), metricKey: metricKey, unit: "%")
                let prefix = subject.map { "\($0)支出" } ?? "该项支出"
                if percent > 0 { return "\(prefix)相比上期增加 \(amount)%" }
                if percent < 0 { return "\(prefix)相比上期减少 \(amount)%" }
                return "\(prefix)与上期基本持平"
            }

            if isDifferenceMetric(normalized) {
                if unit == "比例" || unit == "%" {
                    let percent = abs(value) <= 1.000_001 ? value * 100 : value
                    let amount = formattedNumber(abs(percent), metricKey: metricKey, unit: "%")
                    let prefix = subject.map { "\($0)支出" } ?? "该项支出"
                    if percent > 0 { return "\(prefix)相比上期增加 \(amount)%" }
                    if percent < 0 { return "\(prefix)相比上期减少 \(amount)%" }
                    return "\(prefix)与上期基本持平"
                }
                let amount = formattedNumber(abs(value), metricKey: metricKey, unit: unit)
                let resolvedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let prefix = subject.map { "\($0)支出" } ?? "该项支出"
                if value > 0 { return "\(prefix)相比上期多 \(amount)\(resolvedUnit)" }
                if value < 0 { return "\(prefix)相比上期少 \(amount)\(resolvedUnit)" }
                return "\(prefix)与上期持平"
            }

            if normalized.contains("share") ||
                normalized.contains("ratio") ||
                normalized.contains("rate") ||
                unit == "比例" ||
                unit == "%" {
                let percent = abs(value) <= 1.000_001 ? value * 100 : value
                let amount = formattedNumber(percent, metricKey: metricKey, unit: "%")
                return "\(subject ?? "该分类")支出占比 \(amount)%"
            }

            if normalized.contains("amount") || normalized.contains("spending") {
                let amount = formattedNumber(value, metricKey: metricKey, unit: unit)
                let resolvedUnit = unit?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return "\(subject ?? "该分类")支出 \(amount)\(resolvedUnit)"
            }
        }
        return nil
    }

    private static func isPercentageChangeMetric(_ normalizedMetricKey: String) -> Bool {
        normalizedMetricKey.contains("percentage_change") ||
            normalizedMetricKey.contains("percent_change") ||
            normalizedMetricKey.contains("ratio_change") ||
            normalizedMetricKey.contains("growth") ||
            normalizedMetricKey.contains("increase_rate")
    }

    private static func isDifferenceMetric(_ normalizedMetricKey: String) -> Bool {
        normalizedMetricKey.contains("difference") ||
            normalizedMetricKey.contains("delta") ||
            normalizedMetricKey.contains("amount_change") ||
            normalizedMetricKey.contains("change")
    }

    private static func dynamicGroupLabel(metricKey: String, comparison: String?) -> String? {
        if let comparison {
            let trimmed = comparison.trimmingCharacters(in: .whitespacesAndNewlines)
            let excluded = ["all", "unknown", "increasing", "decreasing", "flat"]
            if !trimmed.isEmpty, !excluded.contains(trimmed.lowercased()) {
                return trimmed
            }
        }

        let components = metricKey.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 4 else { return nil }
        let raw = String(components.last ?? "")
        guard !raw.isEmpty, raw != "all", raw != "unknown" else { return nil }
        return raw.replacingOccurrences(of: "_", with: " ")
    }
}

/// 工具输出的事件级证据（对应原始数据点，可转为 EvidenceRecord）
nonisolated struct HoloEvidenceEvent: Codable, Equatable, Sendable {
    var id: String
    var occurredAt: Date?
    var metricKey: String?
    var metricValue: Double?
    var excerpt: String
    var timeRange: HoloAgentTimeRange? = nil
    var baselineTimeRange: HoloAgentTimeRange? = nil
    var formula: String? = nil
    var sourceRecordIDs: [String]? = nil
}

/// 工具查询的数据覆盖度（判断结论可信度的依据）
nonisolated struct HoloDataCoverage: Codable, Equatable, Sendable {
    var coveredDays: Int
    var totalDays: Int
    var coverageRatio: Double?
    var missingRanges: [HoloAgentTimeRange]
    var note: String?
}

// MARK: - 工具结果

nonisolated struct HoloDataToolResult: Codable, Equatable, Sendable {
    var toolRequestID: String
    var tool: String
    var status: HoloToolResultStatus
    var coverage: HoloDataCoverage?
    var metrics: [HoloMetric]
    var events: [HoloEvidenceEvent]
    var warnings: [HoloToolWarning]
    var error: HoloToolError?
    /// 可选以兼容旧持久化 JSON；nil 按 normal 处理。
    var sensitivity: HoloEvidenceSensitivity? = nil
}

/// Agent Runtime 对工具执行层的最小依赖，放在共享模型层便于独立验证运行时。
protocol HoloAgentToolExecuting: Sendable {
    func execute(_ request: HoloToolRequest) async -> HoloDataToolResult
    func promptDescription() async -> String
}
