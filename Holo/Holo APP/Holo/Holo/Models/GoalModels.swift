//
//  GoalModels.swift
//  Holo
//
//  目标系统值类型：状态、领域、草案、规划会话
//

import Foundation

enum GoalStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case paused
    case completed

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .active: return "进行中"
        case .paused: return "已暂停"
        case .completed: return "已完成"
        }
    }
}

enum GoalDomain: String, Codable, CaseIterable, Identifiable {
    case learning
    case health
    case career
    case finance
    case life
    case project
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .learning: return "学习"
        case .health: return "健康"
        case .career: return "职业"
        case .finance: return "财务"
        case .life: return "生活"
        case .project: return "项目"
        case .other: return "其他"
        }
    }

    var icon: String {
        switch self {
        case .learning: return "book.closed"
        case .health: return "figure.run"
        case .career: return "briefcase"
        case .finance: return "chart.pie"
        case .life: return "sparkles"
        case .project: return "folder"
        case .other: return "target"
        }
    }

    /// 大图标位（列表行等个性化场景）的默认 emoji；
    /// 小徽章与领域选择器仍用 SF Symbol icon 保持语义标识
    var defaultEmoji: String {
        switch self {
        case .learning: return "📚"
        case .health: return "💪"
        case .career: return "💼"
        case .finance: return "💰"
        case .life: return "✨"
        case .project: return "🚀"
        case .other: return "🎯"
        }
    }
}

/// 量化目标类型：进度怎么算
enum GoalKind: String, Codable, CaseIterable, Identifiable {
    /// 过程型（默认）：拆成任务和习惯，靠行动推进
    case process
    /// 累积型：从 0 往目标攒，如跑 300km、存 5 万
    case cumulative
    /// 达标型：当前水平到达/降到目标值，如减到 70kg
    case target

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .process: return "过程型"
        case .cumulative: return "累积型"
        case .target: return "达标型"
        }
    }

    /// 选择器下方的解释文案
    var descriptor: String {
        switch self {
        case .process: return "拆成任务和习惯，靠行动推进"
        case .cumulative: return "从 0 累计到一个总量，如跑 300km"
        case .target: return "让当前水平到达一个值，如减到 70kg"
        }
    }
}

/// 量化目标数据来源：数字从哪来
enum GoalMetricSource: String, Codable, CaseIterable, Identifiable {
    /// 手动记录：目标页记一笔，通用兜底
    case manual
    /// 数值习惯：挂一个数值型习惯当数据源，自动读（3b 接入）
    case habit
    /// 账本：财务流水自动算（3b 接入）
    case ledger

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return "手动记录"
        case .habit: return "数值习惯"
        case .ledger: return "账本"
        }
    }

    /// 表单可选项（按目标类型收窄矩阵）：
    /// 累积型可选手动/习惯/账本；达标型只选手动/习惯（「账本」没有「降到某值」的语义）
    static func selectable(for kind: GoalKind) -> [GoalMetricSource] {
        switch kind {
        case .process: return [.manual]
        case .cumulative: return [.manual, .habit, .ledger]
        case .target: return [.manual, .habit]
        }
    }
}

enum GoalPlanningMode: String, Codable, CaseIterable, Identifiable {
    case concise
    case complete

    var id: String { rawValue }
    var displayName: String { self == .concise ? "精简" : "完整" }
}

enum GoalPlanningStatus: String, Codable, Equatable {
    case collecting
    case draftReady
    case confirming
    case confirmed
    case cancelled
}

struct GoalTaskDraft: Codable, Equatable, Identifiable {
    let id: String
    var isSelected: Bool
    var title: String
    var dueDateText: String?
    var priority: Int?
    var note: String?
}

struct GoalHabitDraft: Codable, Equatable, Identifiable {
    let id: String
    var isSelected: Bool
    var name: String
    var frequency: String
    var targetCount: Int?
    var type: String
    var unit: String?
    var targetValue: Double?
    var isBadHabit: Bool?
    var successRule: String?

    var resolvedFrequency: HabitFrequency {
        HabitFrequency(rawValue: frequency) ?? .daily
    }
}

struct GoalDraft: Codable, Equatable, Identifiable {
    let id: String
    var title: String
    var summary: String?
    var domain: GoalDomain
    /// 用户手选的 emoji 图标；nil 表示跟随领域默认 emoji
    var iconEmoji: String?
    var desiredOutcome: String?
    var motivation: String?
    var deadlineText: String?
    var tasks: [GoalTaskDraft]
    var habits: [GoalHabitDraft]
    var missingInfoWarnings: [String]

    // MARK: 量化目标字段（三期 3a 起手动创建/编辑链路使用；AI 规划草案暂不产出）
    var goalKind: GoalKind = .process
    var metricSource: GoalMetricSource = .manual
    var metricUnit: String? = nil
    var metricTargetValue: Double? = nil
    var metricBaselineValue: Double? = nil
    /// habit 源指向的数值习惯（三期 3b）
    var sourceHabitId: UUID? = nil

    var isQuantitative: Bool { goalKind != .process }

    var cardSummary: String {
        let taskCount = tasks.filter(\.isSelected).count
        let habitCount = habits.filter(\.isSelected).count
        return "\(taskCount) 个任务 · \(habitCount) 个习惯"
    }
}

// MARK: - AI 草案解码兼容（外部输入边界）

extension GoalDraft {
    /// AI 产出的草案 JSON 不含量化字段（后端 prompt 未升级前），
    /// 解码时缺失的量化键回退默认值，不阻断既有规划链路
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        domain = try c.decode(GoalDomain.self, forKey: .domain)
        iconEmoji = try c.decodeIfPresent(String.self, forKey: .iconEmoji)
        desiredOutcome = try c.decodeIfPresent(String.self, forKey: .desiredOutcome)
        motivation = try c.decodeIfPresent(String.self, forKey: .motivation)
        deadlineText = try c.decodeIfPresent(String.self, forKey: .deadlineText)
        tasks = try c.decode([GoalTaskDraft].self, forKey: .tasks)
        habits = try c.decode([GoalHabitDraft].self, forKey: .habits)
        missingInfoWarnings = try c.decode([String].self, forKey: .missingInfoWarnings)
        goalKind = try c.decodeIfPresent(GoalKind.self, forKey: .goalKind) ?? .process
        metricSource = try c.decodeIfPresent(GoalMetricSource.self, forKey: .metricSource) ?? .manual
        metricUnit = try c.decodeIfPresent(String.self, forKey: .metricUnit)
        metricTargetValue = try c.decodeIfPresent(Double.self, forKey: .metricTargetValue)
        metricBaselineValue = try c.decodeIfPresent(Double.self, forKey: .metricBaselineValue)
        sourceHabitId = try c.decodeIfPresent(UUID.self, forKey: .sourceHabitId)
    }

    enum CodingKeys: String, CodingKey {
        case id, title, summary, domain, iconEmoji, desiredOutcome, motivation, deadlineText
        case tasks, habits, missingInfoWarnings
        case goalKind, metricSource, metricUnit, metricTargetValue, metricBaselineValue, sourceHabitId
    }
}

struct GoalPlanningSession: Identifiable, Equatable {
    let id: UUID
    var initialUserText: String?
    var turnCount: Int
    let maxTurns: Int
    var answers: [String]
    var mode: GoalPlanningMode
    var status: GoalPlanningStatus
    var draft: GoalDraft?

    static func fresh(seedText: String? = nil) -> GoalPlanningSession {
        GoalPlanningSession(
            id: UUID(),
            initialUserText: seedText,
            turnCount: 0,
            maxTurns: 3,
            answers: seedText.map { [$0] } ?? [],
            mode: .concise,
            status: .collecting,
            draft: nil
        )
    }
}

struct GoalPlanningRequest: Identifiable, Equatable {
    let id = UUID()
    let seedText: String?
}
