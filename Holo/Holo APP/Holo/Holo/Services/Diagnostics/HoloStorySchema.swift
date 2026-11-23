#if DEBUG && targetEnvironment(simulator)
//
//  HoloStorySchema.swift
//  Holo
//
//  剧本文件（HOLO_STORY_FILE）的数据形状与相对日期解析。
//  字段清单的真源是 scripts/holo_stories/SCHEMA.md：改这里的字段必须同步改文档。
//

import Foundation

// MARK: - 错误

nonisolated enum StoryError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}

// MARK: - 相对日期

/// 剧本日期的换算时钟：以启动当天的 0 点为锚，把「D-123」「D+5T12:30」「2026-11-01」换算成 Date。
/// 锚点取当天而非当下时刻，所以同一台模拟器当天多次启动，剧本里的相对日期换算结果一致。
nonisolated struct StoryClock {
    /// 启动当天 0 点
    let anchor: Date
    let calendar: Calendar

    init(now: Date, calendar: Calendar = .current) {
        self.calendar = calendar
        self.anchor = calendar.startOfDay(for: now)
    }

    func date(_ text: String) throws -> Date {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var dayText = trimmed
        var timeText: String?
        if let separator = trimmed.firstIndex(of: "T") {
            dayText = String(trimmed[..<separator])
            timeText = String(trimmed[trimmed.index(after: separator)...])
        }

        let day: Date
        if dayText.hasPrefix("D") {
            let offsetText = String(dayText.dropFirst())
            guard let offset = Int(offsetText), abs(offset) <= 100_000 else {
                throw StoryError.invalid("相对天数看不懂：「\(text)」，应写成 D-123 / D+5 / D0")
            }
            guard let shifted = calendar.date(byAdding: .day, value: offset, to: anchor) else {
                throw StoryError.invalid("相对天数超出范围：「\(text)」")
            }
            day = shifted
        } else {
            let parts = dayText.split(separator: "-", omittingEmptySubsequences: false)
            let isASCII = { (part: Substring) in part.utf8.allSatisfy { (48...57).contains($0) } }
            guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                  parts.allSatisfy(isASCII),
                  let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]) else {
                throw StoryError.invalid("绝对日期看不懂：「\(text)」，应写成 2026-11-01")
            }
            // 按当月真实天数校验，避免把 2 月 30 日静默滚成 3 月
            guard (1...12).contains(month),
                  let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
                  let dayRange = calendar.range(of: .day, in: .month, for: monthStart),
                  dayRange.contains(dayOfMonth) else {
                throw StoryError.invalid("绝对日期不是真实存在的日子：「\(text)」")
            }
            day = calendar.date(byAdding: .day, value: dayOfMonth - 1, to: monthStart) ?? monthStart
        }

        var hour = 12
        var minute = 0
        if let timeText {
            let parts = timeText.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let parsedHour = Int(parts[0]), let parsedMinute = Int(parts[1]),
                  (0...23).contains(parsedHour), (0...59).contains(parsedMinute) else {
                throw StoryError.invalid("时刻看不懂：「\(text)」，应写成 T12:30")
            }
            hour = parsedHour
            minute = parsedMinute
        }
        let dayStart = calendar.startOfDay(for: day)
        guard let resolved = calendar.date(byAdding: .minute, value: hour * 60 + minute, to: dayStart) else {
            throw StoryError.invalid("日期换算失败：「\(text)」")
        }
        return resolved
    }

    func optionalDate(_ text: String?) throws -> Date? {
        try text.map(date)
    }

    /// 当天所在的「自然周期」起点（周 / 月 / 年），用于预算起始日这类要对齐日历的日期。
    func periodStart(_ component: Calendar.Component) -> Date {
        calendar.dateInterval(of: component, for: anchor)?.start ?? anchor
    }
}

// MARK: - 任意 JSON 值

/// 剧本里「读进来但不解释」的 JSON：meta.lockedClaims 与第二批预留模块（对话 / 洞察 / 记忆）。
nonisolated indirect enum StoryJSON {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([StoryJSON])
    case object([String: StoryJSON])
}

extension StoryJSON: Decodable {
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([StoryJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: StoryJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "不是可识别的 JSON 值")
        }
    }

    /// 日志回显用的紧凑文本
    var debugText: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return String(value)
        case .number(let value): return value == value.rounded() ? String(Int(value)) : String(value)
        case .string(let value): return "\"\(value)\""
        case .array(let items): return "[" + items.map(\.debugText).joined(separator: ",") + "]"
        case .object(let fields):
            return "{" + fields.keys.sorted().map { "\"\($0)\":\(fields[$0]!.debugText)" }.joined(separator: ",") + "}"
        }
    }
}

// MARK: - 剧本顶层

nonisolated struct StoryDocument: Decodable {
    var meta: StoryMeta
    var accounts: [StoryAccount] = []
    var categories: [StoryCategory] = []
    var budgets: [StoryBudget] = []
    var financeProjects: [StoryFinanceProject] = []
    var transactions: [StoryTransaction] = []
    var thoughts: [StoryThought] = []
    var tasks: [StoryTask] = []
    var habits: [StoryHabit] = []
    var habitRecords: [StoryHabitRecord] = []
    var goals: [StoryGoal] = []
    // 第二批（对话 / 洞察 / 记忆）：解码层先接受，暂不写入。
    var conversations: [StoryJSON] = []
    var insights: [StoryJSON] = []
    var memoryRecords: [StoryJSON] = []

    enum CodingKeys: String, CodingKey {
        case meta, accounts, categories, budgets, financeProjects, transactions, thoughts, tasks
        case habits, habitRecords, goals, conversations, insights, memoryRecords
    }

    /// 合成的解码器对「带默认值的数组」仍然要求 key 必须出现；这里改成除 meta 外都可省略（省略 = 空数组）
    nonisolated init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        meta = try container.decode(StoryMeta.self, forKey: .meta)
        accounts = try container.decodeIfPresent([StoryAccount].self, forKey: .accounts) ?? []
        categories = try container.decodeIfPresent([StoryCategory].self, forKey: .categories) ?? []
        budgets = try container.decodeIfPresent([StoryBudget].self, forKey: .budgets) ?? []
        financeProjects = try container.decodeIfPresent([StoryFinanceProject].self, forKey: .financeProjects) ?? []
        transactions = try container.decodeIfPresent([StoryTransaction].self, forKey: .transactions) ?? []
        thoughts = try container.decodeIfPresent([StoryThought].self, forKey: .thoughts) ?? []
        tasks = try container.decodeIfPresent([StoryTask].self, forKey: .tasks) ?? []
        habits = try container.decodeIfPresent([StoryHabit].self, forKey: .habits) ?? []
        habitRecords = try container.decodeIfPresent([StoryHabitRecord].self, forKey: .habitRecords) ?? []
        goals = try container.decodeIfPresent([StoryGoal].self, forKey: .goals) ?? []
        conversations = try container.decodeIfPresent([StoryJSON].self, forKey: .conversations) ?? []
        insights = try container.decodeIfPresent([StoryJSON].self, forKey: .insights) ?? []
        memoryRecords = try container.decodeIfPresent([StoryJSON].self, forKey: .memoryRecords) ?? []
    }
}

nonisolated struct StoryMeta: Decodable {
    /// 幂等键：同一 storyId 只注入一次
    var storyId: String
    /// 剧本主角名，写入 App 的显示名（首页问候语等处显示）
    var persona: String?
    /// 内容侧锁定的对外口径，生成器负责对账；App 只回显不校验
    var lockedClaims: StoryJSON?
}

// MARK: - 记账

nonisolated struct StoryAccount: Decodable {
    var name: String
    /// AccountType.rawValue：cash / digital / bank / card / creditCard / other
    var type: String
    var initialBalanceCents: Int?
    var icon: String?
    var color: String?
    var notes: String?
    /// 以下仅信用卡生效
    var billingDay: Int?
    var dueDay: Int?
    var creditLimitCents: Int?
    var dueReminderEnabled: Bool?
}

nonisolated struct StoryCategory: Decodable {
    var name: String
    /// expense / income
    var type: String
    /// 一级分类名；给了即二级分类（挂到该一级下，一级不存在则自动建）。不给 = 自成一级
    var parent: String?
    var icon: String?
    var color: String?
}

nonisolated struct StoryBudget: Decodable {
    var account: String
    var amountCents: Int
    /// week / month / year
    var period: String
    /// 周期对齐日；不给 = 启动当天所在的那个自然周期起点
    var startDate: String?
    /// 分类预算：一级或二级分类名；不给 = 该账户总预算
    var category: String?
}

nonisolated struct StoryFinanceProject: Decodable {
    var name: String
    var icon: String?
    var color: String?
    var note: String?
    var startDate: String?
    var endDate: String?
    var budgetAmountCents: Int?
    /// active / completed / archived
    var status: String?
    /// 不给 = 注入当刻；项目列表按它从新到旧排
    var createdAt: String?
}

nonisolated struct StoryTransaction: Decodable {
    /// 剧本内的引用名（供退款 refundOf 指向），不是落库的 UUID
    var id: String?
    var amountCents: Int
    /// expense / income
    var type: String?
    /// 二级分类：写「午餐」或带父级路径「餐饮/午餐」
    var category: String?
    /// 账户名；不给 = 默认账户
    var account: String?
    var date: String?
    var note: String?
    var remark: String?
    var tags: [String]?
    /// 财务项目名
    var project: String?
    var installment: StoryInstallment?
    /// 退款笔：指向被退的那笔支出
    var refundOf: String?
}

nonisolated struct StoryInstallment: Decodable {
    var periods: Int
    var startDate: String
    var feePerPeriodCents: Int?
}

// MARK: - 想法

nonisolated struct StoryThought: Decodable {
    var content: String
    var createdAt: String?
    /// ThoughtMoodType.rawValue：happy / sad / angry / calm / thinking / inspired
    var mood: String?
    var tags: [String]?
    /// unprocessed / pending / processing / organized / failed / disabled / skipped；不给 = organized
    var organizedStatus: String?
}

// MARK: - 待办

nonisolated struct StoryTask: Decodable {
    var title: String
    var note: String?
    /// todo / inProgress / completed；不给 = todo
    var status: String?
    /// urgent / high / medium / low（旧优先级列）；不给 = medium
    var priority: String?
    /// p1 / p2 / p3 / unknown；不给 = unknown（待确认区）
    var importance: String?
    /// auto / p1 / p2 / p3 / unknown；不给 = auto（按截止日期折算）
    var urgencyMode: String?
    var dueDate: String?
    var isAllDay: Bool?
    var plannedStart: String?
    var plannedEnd: String?
    var completedAt: String?
    var createdAt: String?
    var archived: Bool?
    /// 目标标题
    var goal: String?
}

// MARK: - 习惯

nonisolated struct StoryHabit: Decodable {
    var name: String
    /// checkIn / numeric
    var type: String
    var icon: String?
    var color: String?
    /// daily / weekly / monthly；不给 = daily
    var frequency: String?
    /// 打卡型：周期内目标次数
    var targetCount: Int?
    /// 数值型：目标值、单位
    var targetValue: Double?
    var unit: String?
    /// 数值型聚合：sum（计数类，默认）/ latest（测量类）
    var aggregation: String?
    var description: String?
    var isBadHabit: Bool?
    var createdAt: String?
    var archived: Bool?
    var paused: Bool?
}

nonisolated struct StoryHabitRecord: Decodable {
    var habit: String
    var date: String
    /// 数值型习惯必填；打卡型习惯不填
    var value: Double?
    /// 打卡型：是否完成；不给 = true
    var completed: Bool?
    var note: String?
}

// MARK: - 目标

nonisolated struct StoryGoal: Decodable {
    var title: String
    var summary: String?
    /// learning / health / career / finance / life / project / other；不给 = other
    var domain: String?
    var iconEmoji: String?
    var desiredOutcome: String?
    var motivation: String?
    var deadline: String?
    var createdAt: String?
    /// active / paused / completed；不给 = active
    var status: String?
    /// status = completed 时的完成时刻；不给 = 注入当刻
    var completedAt: String?
    var allowAIContext: Bool?
    // 量化字段
    /// process（默认）/ cumulative / target
    var goalKind: String?
    /// manual / habit / ledger / healthKit；量化目标不给 = manual
    var metricSource: String?
    var metricUnit: String?
    var targetValue: Double?
    /// 达标型：起点水平（如当时体重）
    var baselineValue: Double?
    /// 累积型：从哪天起算；不给 = createdAt，再不给 = 注入当刻
    var startDate: String?
    /// reach / stayBelow / trendDown / trendUp。显式给了才会写进计划（影响进度算法与习惯累计起点）
    var comparison: String?
    /// metricSource = habit 时的数据来源习惯名
    var sourceHabit: String?
    /// metricSource = ledger 时：whole_ledger_delta（默认）/ account_balance / account_delta
    var ledgerScope: String?
    /// ledgerScope 为 account_balance / account_delta 时的账户名
    var ledgerAccount: String?
    /// 挂到目标下的行动习惯名（绑定，不改习惯归属）
    var habits: [String]?
    /// 挂到目标下的任务标题
    var tasks: [String]?
    /// 手动记录的进度（主要给 manual 源用）
    var metricLogs: [StoryMetricLog]?
}

nonisolated struct StoryMetricLog: Decodable {
    var date: String
    var value: Double
    var note: String?
}
#endif
