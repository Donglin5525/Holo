//
//  HabitPresentationModels.swift
//  Holo
//
//  习惯模块展示层值快照与动作契约（2026-10 交互重构）。
//  只读投影产物：UI 不持有 NSManagedObject，弹层持有 UUID 与草稿。
//  四个概念分开计算（方案 §9.1）：已记录 / 已达标 / 表现 / 连续积累。
//

import Foundation

// MARK: - 三态字段更新

/// 可清除字段的三态更新语义：nil 表示「不修改」，无法表达「用户要清除」。
enum HabitFieldUpdate<Value: Equatable> {
    /// 保持原值（用户没碰这个字段）
    case keep
    /// 设置为新值
    case set(Value)
    /// 用户明确清除（清空目标/单位等）
    case clear

    var isKeep: Bool {
        if case .keep = self { return true }
        return false
    }
}

// MARK: - 行类型与生命周期

/// 今天页连续行的记录方式（UI 三方式，底层仍只有 checkIn/numeric 两存储类型）
enum HabitRowKind: Equatable {
    case checkIn
    case count
    case measure
}

/// 习惯生命周期（管理页三分组的同一批有效习惯）
enum HabitLifecycle: Equatable {
    case active
    case paused
    case archived
}

// MARK: - 目标摘要

/// 当前生效的目标（打卡次数 / 数值目标）。
/// 无目标 = nil，不捏造「达标」。
struct HabitTargetSummary: Equatable {
    /// 打卡型：每周期目标次数；数值型历史记录的 targetCount 兜底
    let count: Int?
    /// 数值型目标值
    let value: Double?
    let unit: String?
    /// 坏习惯数值目标 = 上限控制目标（超过即超标），语义与好习惯目标相反
    let isControlTarget: Bool

    static func == (lhs: HabitTargetSummary, rhs: HabitTargetSummary) -> Bool {
        lhs.count == rhs.count && lhs.value == rhs.value
            && lhs.unit == rhs.unit && lhs.isControlTarget == rhs.isControlTarget
    }
}

// MARK: - 今日 / 周期进展

/// 行级今日与当前周期进展快照。
/// isRecorded 是「今天有有效记录」（打卡 isCompleted；数值有限值含 0），
/// 与 isTargetMet（周期达标）严格分开。
struct HabitTodayProgress: Equatable {
    /// 打卡型：今日勾选态；数值型恒 false（勾选语义不适用）
    let isCheckInDone: Bool
    /// 今天有有效记录（数值型含真实 0；不由值 > 0 推断）
    let isRecorded: Bool
    /// 当前周期已达标（仅好习惯有目标时可能为 true；坏习惯恒 false）
    let isTargetMet: Bool
    /// 今日数值原值（计数 SUM / 测量 LATEST；含真实 0；打卡型 nil）。供右侧大数字直接格式化。
    let todayValue: Double?
    /// 周期进展文本，如「今天 3 / 8 杯」「本周 2 / 3 次」；无目标时只有已记录说明
    let periodValueText: String?
    /// 当前周期日期范围文本（周/月习惯展示，如「10月5日 – 10月11日」）
    let periodRangeText: String?
    /// 坏习惯今日已超控制上限（当日聚合 > targetValue；口径与 HabitDaySnapshot.isOverLimit 一致）。
    /// 仅数值型坏习惯可能为 true；打卡型无上限概念恒 false。
    let isOverLimit: Bool
}

// MARK: - 连续积累标签

/// 连续积累展示标签。单位固定 天/周/月，不把月/周折算成天。
struct HabitStreakLabel: Equatable {
    let value: Int
    /// 「天」「周」「月」
    let unitName: String
    /// 「连续记录」「连续达标」「连续坚持」（打卡型达标）等
    let kindName: String

    var displayText: String { "\(kindName) \(value) \(unitName)" }
}

// MARK: - 三十天痕迹

/// 滚动三十天的单日痕迹（B 方案「缝线日课」数据源，探索入口，不承担统计口径）
/// 四态互斥渲染：实针=已记录 / 空心针=已记录且补录 / 搭线=暂停日 / 针眼=漏做；
/// 创建前空位不渲染。isToday 是今天指针（空圈），独立于四态。
struct HabitTrailDay: Equatable, Identifiable {
    let day: Date
    let isRecorded: Bool
    let isRetroactive: Bool
    var isPaused: Bool = false
    var isToday: Bool = false
    var isBeforeCreation: Bool = false
    var id: Date { day }
}

// MARK: - 行快照

/// 今天页连续行 / 管理页行的完整值快照。
/// 禁止承担：NSManagedObject 引用、body 内查询数据库。
struct HabitRowSnapshot: Identifiable, Equatable {
    let id: UUID
    let name: String
    let icon: String
    let isCustomIcon: Bool
    let colorHex: String
    let kind: HabitRowKind
    let frequency: HabitFrequency
    let isBadHabit: Bool
    let lifecycle: HabitLifecycle
    /// 当前暂停窗口说明（如「暂停至 10月10日」「无限期暂停」）
    let pauseSummaryText: String?
    let target: HabitTargetSummary?
    let today: HabitTodayProgress
    let streak: HabitStreakLabel?
    /// 最近三十天痕迹（含今天，升序；2026-10-07 B 方案从七天扩到三十天）
    let trail: [HabitTrailDay]
    /// 今天是否允许记录（暂停/归档关闭今天记录按钮）
    let allowsTodayRecord: Bool
}

// MARK: - 单日快照

/// 日历格 / 日记录弹层的单日快照。记录存在性与表现状态分开持有。
struct HabitDaySnapshot: Equatable {
    let habitId: UUID
    let day: Date
    /// 该日存在有效记录（打卡 isCompleted；数值有限值含 0）
    let isRecorded: Bool
    /// 打卡型当日勾选态（取消态记录存在但未勾 = false）
    let isCheckInDone: Bool
    /// 冻结日（暂停窗口内）
    let isPausedDay: Bool
    /// 早于习惯创建日
    let isBeforeCreation: Bool
    /// 晚于今天
    let isFuture: Bool
    /// 补录标记（该日有效记录中存在补录）
    let hasRetroactive: Bool
    /// 坏习惯表现（该日超标）
    let isOverLimit: Bool
    /// 数值型当日值（计数 SUM / 测量 LATEST；含 0）
    let numericValue: Double?
    /// 该日记录条数（数值明细用）
    let recordCount: Int
    /// 允许的补录模式（方案 §10.1：sign=补签窗口内漏签 / backfill=补记历史）。
    /// 复用 HabitRetroactiveSheet.swift 的既有枚举（sign/backfill）。
    let allowedRetroactiveMode: HabitRetroactiveMode?
}

// MARK: - 动作契约

/// 用户可发起的记录动作（一次用户意图）
enum HabitActionKind: Equatable {
    case toggleCheckIn
    case addNumeric(value: Double)
    case increment(amount: Int)
    case removeLatestNumeric
    case retroactive(mode: HabitRetroactiveMode, day: Date, value: Double?)
    case updateRecord(recordId: UUID, value: Double?, note: String?)
    case deleteRecord(recordId: UUID)
}

/// 动作回执：scoped undo 的事实底账（方案 §11.3）
struct HabitActionReceipt: Equatable {
    let operationID: UUID
    let habitId: UUID
    let kind: HabitActionKind
    /// 本次实际写入/修改的记录 ID（打卡可能复用既有行）
    let recordId: UUID?
    /// 打卡翻转前状态（撤销恢复用）
    let previousCheckInState: Bool?
    /// 打卡翻转后状态
    let newCheckInState: Bool?
    /// 数值记录内容指纹（撤销前校验记录未被后续修改）
    let recordFingerprint: String?
    /// 好习惯当天首次有效记录（决定暖光；Motion 中心另有当天去重）
    let isTodayFirstCompletion: Bool
}

/// unchanged 的原因（「已经完成」解释当前事实，不算失败）
enum HabitUnchangedReason: Equatable {
    /// 打卡目标日本已完成（幂等识别，补录场景不扣额度）
    case alreadyRecorded
    /// 今日无记录可撤销
    case nothingToUndo
}

/// 需要权益的动作
enum HabitEntitlementAction: Equatable {
    case retroactiveQuotaExhausted
    case pauseRequiresPlus
}

/// 无效输入/冲突
enum HabitInvalidatedReason: Equatable {
    case habitUnavailable
    case invalidDate
    case beforeCreation
    case futureDate
    case pausedDayNotMakeup
    case habitPaused
    case typeNotSupported
    case invalidValue
    case recordChanged
    case archivedNeedsUnarchive
}

/// 统一动作结果状态机（方案 §11.1）
enum HabitActionResult {
    /// 本次保存成功（可撤销窗口开启）
    case confirmed(HabitActionReceipt)
    /// 无变化：解释当前事实（如「这一天已经记录过了」）
    case unchanged(HabitUnchangedReason)
    /// 需要权益（Plus / 额度），成功后应重新校验并重试同一操作
    case requiresEntitlement(HabitEntitlementAction)
    /// 输入无效/状态冲突：保留草稿，说明如何修正
    case invalidated(HabitInvalidatedReason)
    /// 保存失败：保留草稿，用户重试
    case failed(String)
}

// MARK: - 编辑草稿载荷（值类型）

/// 编辑页提交的完整意图载荷。表单草稿是值类型，未点保存不修改 Core Data 对象。
struct HabitEditPayload {
    var name: String
    var icon: String
    var color: String
    var type: HabitType
    var aggregationType: HabitAggregationType
    var frequency: HabitFrequency
    var targetCount: HabitFieldUpdate<Int> = .keep
    var targetValue: HabitFieldUpdate<Double> = .keep
    var unit: HabitFieldUpdate<String> = .keep
    var isBadHabit: Bool
    var reminderMode: HabitReminderMode
    var reminderTime: (hour: Int, minute: Int)
    /// 目标关系三态（nil 原始 = 未关联；keep = 不修改；set = 关联该目标；clear = 解除）
    var goalId: HabitFieldUpdate<UUID?> = .keep

    init(name: String, icon: String, color: String, type: HabitType,
         aggregationType: HabitAggregationType = .sum, frequency: HabitFrequency = .daily,
         isBadHabit: Bool = false, reminderMode: HabitReminderMode = .follow,
         reminderTime: (hour: Int, minute: Int) = (9, 0)) {
        self.name = name
        self.icon = icon
        self.color = color
        self.type = type
        self.aggregationType = aggregationType
        self.frequency = frequency
        self.isBadHabit = isBadHabit
        self.reminderMode = reminderMode
        self.reminderTime = reminderTime
    }
}

// MARK: - 里程碑

/// 里程碑静态展示模型（仅好习惯）
struct HabitMilestone: Equatable, Identifiable {
    /// 去重键：habit UUID + 指标种类 + 周期单位 + 阈值
    let key: String
    let habitId: UUID
    let threshold: Int
    let unitName: String
    let kindName: String

    var id: String { key }
    var displayText: String { "\(kindName) \(threshold) \(unitName)" }
}
