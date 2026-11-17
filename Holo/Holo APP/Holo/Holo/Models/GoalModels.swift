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
        case .active: return String(localized: "进行中")
        case .paused: return String(localized: "已暂停")
        case .completed: return String(localized: "已完成")
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
        case .learning: return String(localized: "学习")
        case .health: return String(localized: "健康")
        case .career: return String(localized: "职业")
        case .finance: return String(localized: "财务")
        case .life: return String(localized: "生活")
        case .project: return String(localized: "项目")
        case .other: return String(localized: "其他")
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

    /// 领域自动认领（2026-11-13 目标界面减法重设计 v3，S3b）：
    /// 表单不再让用户选领域，按标题本地关键词 contains 匹配认领，认不出=其他。
    /// 纯客户端零后端；career 排 life 前（「跳槽后陪家人」类歧义按职业归）。
    static func infer(from title: String) -> GoalDomain {
        let text = title.lowercased()
        let table: [(GoalDomain, [String])] = [
            (.health, ["跑", "步", "走", "体重", "公斤", "kg", "睡", "熬", "烟", "酒", "健身", "游泳"]),
            (.finance, ["存款", "贷款", "攒", "还", "花", "省钱", "预算", "投资", "基金", "股票", "万", "块"]),
            (.learning, ["读", "书", "学", "考", "证", "雅思", "英语", "日语", "课", "单词"]),
            (.project, ["上线", "发布", "交付", "项目", "开发", "写完", "做完"]),
            (.career, ["上班", "跳槽", "简历", "晋升", "绩效", "面试"]),
            (.life, ["家人", "朋友", "见", "陪", "旅行", "搬"]),
        ]
        for (domain, keywords) in table where keywords.contains(where: { text.contains($0) }) {
            return domain
        }
        return .other
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
        case .process: return String(localized: "过程型")
        case .cumulative: return String(localized: "累积型")
        case .target: return String(localized: "达标型")
        }
    }

    /// 选择器下方的解释文案
    var descriptor: String {
        switch self {
        case .process: return String(localized: "拆成任务和习惯，靠行动推进")
        case .cumulative: return String(localized: "从 0 累计到一个总量，如跑 300km")
        case .target: return String(localized: "让当前水平到达一个值，如减到 70kg")
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
    /// 苹果健康：HealthKit 被动同步（体重 / 步数 / 跑步距离 / 睡眠 / 活动能量）
    case healthKit

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .manual: return String(localized: "手动记录")
        case .habit: return String(localized: "数值习惯")
        case .ledger: return String(localized: "账本")
        case .healthKit: return String(localized: "苹果健康")
        }
    }

    /// 表单可选项（按目标类型收窄矩阵）：
    /// 累积型可选手动/习惯/账本/苹果健康；
    /// 达标型可选手动/习惯/账本/苹果健康
    static func selectable(for kind: GoalKind) -> [GoalMetricSource] {
        switch kind {
        case .process: return [.manual]
        case .cumulative: return [.manual, .habit, .ledger, .healthKit]
        case .target: return [.manual, .habit, .ledger, .healthKit]
        }
    }
}

/// 苹果健康量化指标类型（GoalMetricSource.healthKit 使用）
enum GoalHealthMetricKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case bodyMass
    case bodyFatPercentage
    case stepCount
    case distanceWalkingRunning
    case activeEnergyBurned
    case sleepHours

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .bodyMass: return String(localized: "体重")
        case .bodyFatPercentage: return String(localized: "体脂率")
        case .stepCount: return String(localized: "步数")
        case .distanceWalkingRunning: return String(localized: "步行/跑步距离")
        case .activeEnergyBurned: return String(localized: "活动能量")
        case .sleepHours: return String(localized: "睡眠时长")
        }
    }

    var defaultUnit: String {
        switch self {
        case .bodyMass: return "kg"
        case .bodyFatPercentage: return "%"
        case .stepCount: return String(localized: "步")
        case .distanceWalkingRunning: return "km"
        case .activeEnergyBurned: return "kcal"
        case .sleepHours: return String(localized: "小时")
        }
    }

    /// true = 取最新观测值（如体重、体脂率、睡眠）；false = 累计求和（如步数、距离、热量）
    var isLatestSample: Bool {
        switch self {
        case .bodyMass, .bodyFatPercentage, .sleepHours:
            return true
        case .stepCount, .distanceWalkingRunning, .activeEnergyBurned:
            return false
        }
    }
}

enum GoalPlanningMode: String, Codable, CaseIterable, Identifiable {
    case concise
    case complete

    var id: String { rawValue }
    var displayName: String { self == .concise ? String(localized: "精简") : String(localized: "完整") }
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
    /// 目标闭环 v2：复用授权候选中的既有习惯（"habit:<uuid>"）而不新建；
    /// 复用只建逻辑绑定，不抢对象原有 goal 父引用
    var reuseHabitRef: String? = nil
    /// 数值习惯聚合语义："sum"（练习时长）/ "latest"（体重）；nil 按 sum
    var aggregation: String? = nil

    var resolvedFrequency: HabitFrequency {
        HabitFrequency(rawValue: frequency) ?? .daily
    }

    var resolvedAggregation: HabitAggregationType {
        aggregation == "latest" ? .latest : .sum
    }

    var reuseHabitID: UUID? {
        guard let reuseHabitRef, reuseHabitRef.hasPrefix("habit:") else { return nil }
        return UUID(uuidString: String(reuseHabitRef.dropFirst("habit:".count)))
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
    /// ledger 源的账本范围（2026-11-14 表单暴露）：累积型=全账本/指定账户净结余增加，
    /// 达标型=账户余额；nil=未指定（老草案解码兼容，按全账本解释）
    var ledgerScope: GoalLedgerScopePayload? = nil
    /// healthKit 源对应的苹果健康指标类型（体重 / 步数 / 距离 / 睡眠等）
    var healthMetricKind: GoalHealthMetricKind? = nil

    var isQuantitative: Bool { goalKind != .process }

    /// 量化目标摘要（如 "82 → 70 kg" 或 "目标 300 km"），过程型返回 nil
    var quantitativeSummary: String? {
        guard isQuantitative, let target = metricTargetValue else { return nil }
        let targetText = Self.formatMetricNumber(target)
        let unitSuffix = metricUnit.map { $0.isEmpty ? "" : " \($0)" } ?? ""
        if goalKind == .target, let baseline = metricBaselineValue {
            let baseText = Self.formatMetricNumber(baseline)
            return "\(baseText) → \(targetText)\(unitSuffix)"
        }
        return String(localized: "目标 \(targetText)\(unitSuffix)")
    }

    private static func formatMetricNumber(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    var cardSummary: String {
        let taskCount = tasks.filter(\.isSelected).count
        let habitCount = habits.filter(\.isSelected).count
        let actionPart = String(localized: "\(taskCount) 个任务 · \(habitCount) 个习惯")
        if let metric = quantitativeSummary {
            return "\(metric) · \(actionPart)"
        }
        return actionPart
    }
}

// MARK: - AI 草案解码兼容（外部输入边界）

extension GoalDraft {
    /// AI 产出的草案 JSON 可能缺少量化字段，或将数字编码为字符串；
    /// 解码时做容错与默认值回退，不阻断规划链路
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decodeIfPresent(String.self, forKey: .summary)
        domain = (try? c.decode(GoalDomain.self, forKey: .domain)) ?? .other
        iconEmoji = try c.decodeIfPresent(String.self, forKey: .iconEmoji)
        desiredOutcome = try c.decodeIfPresent(String.self, forKey: .desiredOutcome)
        motivation = try c.decodeIfPresent(String.self, forKey: .motivation)
        deadlineText = try c.decodeIfPresent(String.self, forKey: .deadlineText)
        tasks = try c.decode([GoalTaskDraft].self, forKey: .tasks)
        habits = try c.decode([GoalHabitDraft].self, forKey: .habits)
        missingInfoWarnings = (try? c.decodeIfPresent([String].self, forKey: .missingInfoWarnings)) ?? []
        goalKind = (try? c.decodeIfPresent(GoalKind.self, forKey: .goalKind)) ?? .process
        metricSource = (try? c.decodeIfPresent(GoalMetricSource.self, forKey: .metricSource)) ?? .manual
        metricUnit = try c.decodeIfPresent(String.self, forKey: .metricUnit)
        metricTargetValue = Self.decodeFlexibleDouble(from: c, forKey: .metricTargetValue)
        metricBaselineValue = Self.decodeFlexibleDouble(from: c, forKey: .metricBaselineValue)
        sourceHabitId = try? c.decodeIfPresent(UUID.self, forKey: .sourceHabitId)
        ledgerScope = try? c.decodeIfPresent(GoalLedgerScopePayload.self, forKey: .ledgerScope)
        healthMetricKind = try? c.decodeIfPresent(GoalHealthMetricKind.self, forKey: .healthMetricKind)
        // 若模型给出了有效目标值但漏标 goalKind，自动按达标/累积兜底，避免量化目标退化成纯过程型
        if goalKind == .process, metricTargetValue != nil {
            goalKind = metricBaselineValue != nil ? .target : .cumulative
        }
    }

    private static func decodeFlexibleDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let text = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Double(trimmed)
        }
        return nil
    }

    enum CodingKeys: String, CodingKey {
        case id, title, summary, domain, iconEmoji, desiredOutcome, motivation, deadlineText
        case tasks, habits, missingInfoWarnings
        case goalKind, metricSource, metricUnit, metricTargetValue, metricBaselineValue, sourceHabitId
        case ledgerScope, healthMetricKind
    }
}

struct GoalPlanningSession: Identifiable, Equatable, Codable {
    /// 默认追问轮数上限（不含草案生成）。纯常量，nonisolated 供任意上下文引用。
    nonisolated static let defaultMaxTurns = 3

    let id: UUID
    var initialUserText: String?
    var turnCount: Int
    let maxTurns: Int
    var answers: [String]
    var mode: GoalPlanningMode
    var status: GoalPlanningStatus
    var draft: GoalDraft?

    /// - Parameter maxTurns: 追问轮数上限；额度紧张时由入口按 chat 池余量压缩传入，
    ///   保证流程（追问 + 草案）能在额度内完整走完，而不是中途因额度断裂。
    static func fresh(seedText: String? = nil, maxTurns: Int = GoalPlanningSession.defaultMaxTurns) -> GoalPlanningSession {
        GoalPlanningSession(
            id: UUID(),
            initialUserText: seedText,
            turnCount: 0,
            maxTurns: maxTurns,
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
