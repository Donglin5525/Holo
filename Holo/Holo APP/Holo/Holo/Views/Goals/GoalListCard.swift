//
//  GoalListCard.swift
//  Holo
//
//  目标列表卡片（2026-11-13 目标界面减法重设计 S1，规格 §三）：
//  行1 领域图标(40×40) + 标题单行截断 + 状态胶囊；行2 数值/摘要 + 期限；行3 4pt 进度条（仅量化且进行中）。
//  数值/摘要/进度由列表页从回顾快照算好传入——无真实数据时整行不渲染（A9：占位文案不见人）。
//

import SwiftUI

/// 行2/行3 的真实观测数据（GoalListCard.facts(goal:snapshot:) 产出）
struct GoalListCardFacts: Equatable {
    /// 量化目标数值行（如「128 / 300 km」「已减 2.5 / 5 kg」）；nil=无真实观测
    var valueText: String?
    /// 过程型摘要行（真实回顾数据）；nil=不渲染
    var summaryText: String?
    /// 进度 0...1；nil=暂无进度数据（量化进行中卡仍渲染空轨道）
    var progress: Double?

    init(valueText: String? = nil, summaryText: String? = nil, progress: Double? = nil) {
        self.valueText = valueText
        self.summaryText = summaryText
        self.progress = progress
    }
}

struct GoalListCard: View {
    /// @ObservedObject：设置面板改领域/图标保存后，同一 Goal 对象引用未变、
    /// 卡片行 id 也未变，SwiftUI 会跳过重渲染导致旧图标残留；
    /// NSManagedObject 的属性变更通知让卡片即时失效重画
    @ObservedObject var goal: Goal
    /// 到期待回顾（列表页加载路径算好的集合命中结果）
    var isReviewDue: Bool
    var facts: GoalListCardFacts

    // MARK: 状态胶囊（规格 A3：待回顾/已到期=警示，已完成=成功，已暂停=灰）

    private enum Pill {
        case reviewDue, overdue, paused, completed

        var text: String {
            switch self {
            case .reviewDue: return String(localized: "待回顾")
            case .overdue: return String(localized: "已到期")
            case .paused: return String(localized: "已暂停")
            case .completed: return String(localized: "已完成")
            }
        }

        var foreground: Color {
            switch self {
            case .reviewDue, .overdue: return .holoToolWarning
            case .paused: return .holoToolTextSecondary
            case .completed: return .holoToolSuccess
            }
        }

        var background: Color {
            switch self {
            case .reviewDue, .overdue: return Color.holoToolWarning.opacity(0.12)
            case .paused: return Color.holoToolBorder.opacity(0.5)
            case .completed: return Color.holoToolSuccess.opacity(0.12)
            }
        }
    }

    private var pill: Pill? {
        switch goal.goalStatus {
        case .completed: return .completed
        case .paused: return .paused
        case .active:
            if isReviewDue { return .reviewDue }
            if let deadline = goal.deadline, deadline < Date() { return .overdue }
            return nil
        }
    }

    /// 行2 期限位：进行中「12/31 截止」；已完成「10/18 达成」。过期时仍是灰字，警示进 行1 胶囊（A3）
    private var dueText: String? {
        if goal.goalStatus == .completed {
            guard let completedAt = goal.completedAt else { return nil }
            return Self.dayText(completedAt) + String(localized: " 达成")
        }
        guard let deadline = goal.deadline else { return nil }
        return Self.dayText(deadline) + String(localized: " 截止")
    }

    /// 进度条仅量化且进行中（规格 A1 行3；已完成/已暂停不出条）
    private var showsProgress: Bool {
        goal.isQuantitative && goal.goalStatus == .active
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(goal.displayIcon)
                    .font(.system(size: 20))
                    .frame(width: 40, height: 40)
                    .background(goal.goalDomain.badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                Text(goal.title)
                    .goalJourneyText(.row)
                    .foregroundStyle(Color.holoToolText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                if let pill {
                    pillView(pill)
                }
            }
            if facts.valueText != nil || facts.summaryText != nil || dueText != nil {
                row2
            }
            if showsProgress {
                HoloProgress(value: facts.progress, color: GoalJourneyStyle.action,
                             shape: .bar, lineWidth: 4, trackColor: Color.holoToolBorder)
                    .padding(.top, 10)
            }
        }
        .padding(16)
        .frame(minHeight: 84, alignment: .leading)
        .background(Color.holoToolSurface, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.holoToolBorder, lineWidth: 0.5))
    }

    /// 行2：数值(15 medium 等宽)/摘要(12 次文字) 二选一靠左 + 期限 12 次文字右对齐（A2）
    private var row2: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let valueText = facts.valueText {
                Text(valueText)
                    .goalJourneyText(.body)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .foregroundStyle(Color.holoToolText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            } else if let summaryText = facts.summaryText {
                Text(summaryText)
                    .goalJourneyText(.detail)
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
            if let dueText {
                Text(dueText)
                    .goalJourneyText(.detail)
                    .monospacedDigit()
                    .foregroundStyle(Color.holoToolTextSecondary)
                    .fixedSize()
            }
        }
        .padding(.top, 6)
    }

    private func pillView(_ pill: Pill) -> some View {
        Text(pill.text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(pill.foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(pill.background, in: Capsule())
            .fixedSize()
    }

    // MARK: - 回顾快照 → 行2/行3 数据

    /// 从回顾快照提取卡片数据；快照文案里属于内部状态的占位一律归 nil（A9）
    static func facts(goal: Goal, snapshot: GoalEvaluationSnapshot) -> GoalListCardFacts {
        let text = displayableText(GoalFactsPresentation.result(snapshot))
        let progress = GoalFactsPresentation.progress(snapshot.result)?.fraction
        guard goal.isQuantitative else {
            return GoalListCardFacts(valueText: nil, summaryText: text, progress: nil)
        }
        // 达标型按基线视角展示「已减 2.5 / 5 kg」（目标大于基线时「已增」，规格 A0）
        if goal.goalKindEnum == .target,
           let current = snapshot.result.value,
           let baseline = snapshot.result.baselineValue ?? goal.baselineValueDouble,
           let target = snapshot.result.targetValue ?? goal.metricTargetValueDouble {
            let unit = goal.metricUnit.map { " \($0)" } ?? ""
            let verb = target < baseline ? String(localized: "已减") : String(localized: "已增")
            return GoalListCardFacts(
                valueText: "\(verb) \(GoalMetricEvaluator.formatValue(abs(baseline - current))) / \(GoalMetricEvaluator.formatValue(abs(target - baseline)))\(unit)",
                summaryText: nil,
                progress: progress
            )
        }
        return GoalListCardFacts(valueText: text, summaryText: nil, progress: progress)
    }

    /// 「正在读取进展」类内部状态词不上卡：命中即整行不渲染
    private static func displayableText(_ text: String) -> String? {
        let placeholders: Set<String> = ["行动分别记录，成果待确认", "结果待记录", "结果来源暂不可用", "待记录"]
        guard !placeholders.contains(text), !text.contains("待记录") else { return nil }
        return text
    }

    /// 期限短格式「12/31」（规格 A0）
    static func dayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}
