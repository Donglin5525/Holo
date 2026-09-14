//
//  HoloTodayFocusResolver.swift
//  Holo
//
//  「现在最值得推进」唯一确定性排序器（今日看板 Matter 化方案 §7）
//
//  - 纯函数：不依赖 SwiftUI、Core Data、单例或当前系统时钟；时间全部来自输入；
//  - 相同输入必须产出相同结果（tie-break 最后一级用稳定 ID 字典序）；
//  - suggested Open Loop / suggestion Next Action / stale 投影 永不成为可执行主行动；
//  - 模型边界：resolver 不调用模型，priority/severity 只来自类型化事实。
//

import Foundation

// MARK: - 候选输入（与 managed objects 解耦的轻量快照）

nonisolated struct HoloTodayScheduleCandidate: Equatable, Sendable {
    let id: String
    let title: String
    let startAt: Date
    let endAt: Date
    let isAllDay: Bool

    init(id: String, title: String, startAt: Date, endAt: Date, isAllDay: Bool = false) {
        self.id = id
        self.title = title
        self.startAt = startAt
        self.endAt = endAt
        self.isAllDay = isAllDay
    }
}

nonisolated struct HoloTodayTaskCandidate: Equatable, Sendable {
    let id: UUID
    let title: String
    /// nil = 无截止日（只有用户明确加入今日才进 P4）。
    let dueAt: Date?
    let isCompleted: Bool
    /// 数值越大优先级越高（与 TaskPriority raw 对齐）。
    let priority: Int
    /// 用户明确加入今日且无具体时间。
    let plannedForToday: Bool
    let matterID: UUID?
    let matterTitle: String?
    let updatedAt: Date

    init(
        id: UUID,
        title: String,
        dueAt: Date? = nil,
        isCompleted: Bool = false,
        priority: Int = 1,
        plannedForToday: Bool = false,
        matterID: UUID? = nil,
        matterTitle: String? = nil,
        updatedAt: Date = .distantPast
    ) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.isCompleted = isCompleted
        self.priority = priority
        self.plannedForToday = plannedForToday
        self.matterID = matterID
        self.matterTitle = matterTitle
        self.updatedAt = updatedAt
    }
}

nonisolated struct HoloTodayLoopCandidate: Equatable, Sendable {
    let id: UUID
    let title: String
    let state: HoloMatterOpenLoopState
    let epistemic: HoloMatterOpenLoopEpistemic
    let targetDate: Date?
    /// Open Loop 已链接任务时只展示任务，不再展示同标题 Open Loop。
    let linkedTaskID: UUID?

    init(
        id: UUID,
        title: String,
        state: HoloMatterOpenLoopState,
        epistemic: HoloMatterOpenLoopEpistemic,
        targetDate: Date? = nil,
        linkedTaskID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.epistemic = epistemic
        self.targetDate = targetDate
        self.linkedTaskID = linkedTaskID
    }
}

nonisolated struct HoloTodayMatterCandidate: Equatable, Sendable {
    let id: UUID
    let title: String
    let targetDate: Date?
    let revision: Int64
    let updatedAt: Date
    /// 由 HoloMatterAttentionPolicy 确定性重算（调用方完成，不信任 stale 投影）。
    let attention: HoloMatterAttention
    let loops: [HoloTodayLoopCandidate]
    /// 投影 nextAction；stale 投影由调用方置 nil。
    let nextAction: HoloTodayMatterActionCandidate?
    let linkedTaskIDs: Set<UUID>

    init(
        id: UUID,
        title: String,
        targetDate: Date? = nil,
        revision: Int64 = 1,
        updatedAt: Date = .distantPast,
        attention: HoloMatterAttention = .unknown,
        loops: [HoloTodayLoopCandidate] = [],
        nextAction: HoloTodayMatterActionCandidate? = nil,
        linkedTaskIDs: Set<UUID> = []
    ) {
        self.id = id
        self.title = title
        self.targetDate = targetDate
        self.revision = revision
        self.updatedAt = updatedAt
        self.attention = attention
        self.loops = loops
        self.nextAction = nextAction
        self.linkedTaskIDs = linkedTaskIDs
    }
}

/// 投影 Next Action 的最小快照；resolver 校验 revision 一致性。
nonisolated struct HoloTodayMatterActionCandidate: Equatable, Sendable {
    let kind: HoloMatterNextAction.Kind
    let entityID: UUID?
    let title: String
    let targetDate: Date?
    let sourceMatterRevision: Int64

    init(
        kind: HoloMatterNextAction.Kind,
        entityID: UUID?,
        title: String,
        targetDate: Date? = nil,
        sourceMatterRevision: Int64
    ) {
        self.kind = kind
        self.entityID = entityID
        self.title = title
        self.targetDate = targetDate
        self.sourceMatterRevision = sourceMatterRevision
    }
}

nonisolated struct HoloTodayHabitWindowCandidate: Equatable, Sendable {
    let id: UUID
    let name: String
    /// 无明确时间窗口的习惯不进入 Primary Focus（只在 Routine 展示）。
    let windowStart: Date?
    let windowEnd: Date?
    let isNegative: Bool

    init(id: UUID, name: String, windowStart: Date? = nil, windowEnd: Date? = nil, isNegative: Bool = false) {
        self.id = id
        self.name = name
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.isNegative = isNegative
    }
}

/// 一次求解的全部输入（时间口径必须与快照同源）。
nonisolated struct HoloTodayFocusInput: Equatable, Sendable {
    let referenceTime: Date
    let dayStart: Date
    let dayEnd: Date
    let schedules: [HoloTodayScheduleCandidate]
    let tasks: [HoloTodayTaskCandidate]
    let matters: [HoloTodayMatterCandidate]
    let habits: [HoloTodayHabitWindowCandidate]
    /// 用户本会话点过「稍后」的候选键（仅本次会话降级，不永久压制）。
    let postponedKeys: Set<String>

    init(
        referenceTime: Date,
        dayStart: Date,
        dayEnd: Date,
        schedules: [HoloTodayScheduleCandidate] = [],
        tasks: [HoloTodayTaskCandidate] = [],
        matters: [HoloTodayMatterCandidate] = [],
        habits: [HoloTodayHabitWindowCandidate] = [],
        postponedKeys: Set<String> = []
    ) {
        self.referenceTime = referenceTime
        self.dayStart = dayStart
        self.dayEnd = dayEnd
        self.schedules = schedules
        self.tasks = tasks
        self.matters = matters
        self.habits = habits
        self.postponedKeys = postponedKeys
    }
}

// MARK: - Resolver

nonisolated enum HoloTodayFocusResolver {

    /// 90 分钟「即将开始」窗口。
    static let upcomingWindowMinutes = 90

    /// 「稍后」降级的候选键（仅本次会话内有效，不永久压制）。
    nonisolated enum FocusCandidateKey: Equatable, Sendable {
        case task(UUID)
        case matterLoop(matterID: UUID, loopID: UUID)
        case schedule(String)
        case habit(UUID)
    }

    /// 生成会话级稍后键。
    static func postponeKey(for candidate: FocusCandidateKey) -> String {
        switch candidate {
        case .task(let id): return "task:\(id.uuidString)"
        case .matterLoop(let m, let l): return "loop:\(m.uuidString):\(l.uuidString)"
        case .schedule(let id): return "schedule:\(id)"
        case .habit(let id): return "habit:\(id.uuidString)"
        }
    }

    /// 唯一入口：从候选中选出当前最值得推进的一件事；无可执行候选返回 nil（calm state）。
    ///
    /// 优先级层级（方案 §7.2）：
    /// P0 正在发生的固定日程 / P1 90 分钟内开始 / P2 逾期任务·atRisk Matter 已确认动作 /
    /// P3 今日到期·needsAttention Matter 已确认动作 / P4 加入今日无时间任务 / P5 时间窗习惯。
    /// 同层 tie-break：时间更早 → 优先级更高 → Matter 互动更近 → 稳定 ID 字典序。
    static func resolve(input: HoloTodayFocusInput) -> HoloTodayFocus? {
        let now = input.referenceTime
        var candidates: [(focus: HoloTodayFocus, tier: Int, timeKey: Date, priority: Int, matterStamp: Date, stableID: String)] = []

        // MARK: 日程（P0/P1）

        for schedule in input.schedules where !schedule.isAllDay {
            guard schedule.endAt > now else { continue }
            if schedule.startAt <= now {
                candidates.append((
                    HoloTodayFocus(
                        id: "schedule:\(schedule.id)",
                        source: .currentSchedule,
                        title: schedule.title,
                        reasonCode: .scheduleInProgress,
                        reasonArguments: HoloTodayReasonArguments(),
                        dueAt: schedule.endAt,
                        severity: .risk,
                        matterID: nil,
                        action: .openSchedule(schedule.id)
                    ),
                    0, schedule.startAt, 0, .distantPast, schedule.id
                ))
            } else if schedule.startAt.timeIntervalSince(now) <= Double(upcomingWindowMinutes * 60) {
                let minutes = Int(schedule.startAt.timeIntervalSince(now) / 60)
                candidates.append((
                    HoloTodayFocus(
                        id: "schedule:\(schedule.id)",
                        source: .upcomingSchedule,
                        title: schedule.title,
                        reasonCode: .scheduleStartingSoon,
                        reasonArguments: HoloTodayReasonArguments(minutesUntilStart: minutes),
                        dueAt: schedule.startAt,
                        severity: .attention,
                        matterID: nil,
                        action: .openSchedule(schedule.id)
                    ),
                    1, schedule.startAt, 0, .distantPast, schedule.id
                ))
            }
        }

        // Matter Next Action（linkedTask → entityID 指向真实任务时并进任务候选去重）。
        for matter in input.matters {
            appendMatterCandidates(matter, input: input, into: &candidates)
        }

        // MARK: 任务（P2 逾期 / P3 今日 / P4 加入今日）

        for task in input.tasks where !task.isCompleted {
            let isPostponed = input.postponedKeys.contains(postponeKey(for: .task(task.id)))
            let dueDateOnly = task.dueAt.map { input.dayStart <= $0 && $0 < input.dayEnd }
            if let due = task.dueAt, due < input.dayStart {
                // 逾期（P2）。
                if isPostponed { continue }
                let overdueDays = Calendar(identifier: .gregorian)
                    .dateComponents([.day], from: Calendar(identifier: .gregorian).startOfDay(for: due), to: Calendar(identifier: .gregorian).startOfDay(for: now)).day ?? 0
                candidates.append((
                    HoloTodayFocus(
                        id: "task:\(task.id.uuidString)",
                        source: .overdueTask,
                        title: task.title,
                        reasonCode: .overdueTask,
                        reasonArguments: HoloTodayReasonArguments(overdueDays: max(1, overdueDays)),
                        dueAt: due,
                        severity: .risk,
                        matterID: task.matterID,
                        action: .openTask(task.id)
                    ),
                    2, due, task.priority, .distantPast, task.id.uuidString
                ))
            } else if dueDateOnly == true {
                // 今日到期（P3）。
                if isPostponed { continue }
                candidates.append((
                    HoloTodayFocus(
                        id: "task:\(task.id.uuidString)",
                        source: .todayTask,
                        title: task.title,
                        reasonCode: .dueToday,
                        reasonArguments: HoloTodayReasonArguments(),
                        dueAt: task.dueAt,
                        severity: .attention,
                        matterID: task.matterID,
                        action: .openTask(task.id)
                    ),
                    3, task.dueAt ?? input.dayEnd, task.priority, .distantPast, task.id.uuidString
                ))
            } else if task.dueAt == nil, task.plannedForToday {
                // 用户明确加入今日、无具体时间（P4）。
                if isPostponed { continue }
                candidates.append((
                    HoloTodayFocus(
                        id: "task:\(task.id.uuidString)",
                        source: .todayTask,
                        title: task.title,
                        reasonCode: .plannedToday,
                        reasonArguments: HoloTodayReasonArguments(),
                        dueAt: nil,
                        severity: .normal,
                        matterID: task.matterID,
                        action: .openTask(task.id)
                    ),
                    4, now, task.priority, .distantPast, task.id.uuidString
                ))
            }
        }

        // MARK: 习惯（P5，仅有明确时间窗口且当前在窗内/临近）

        for habit in input.habits where !habit.isNegative {
            guard let start = habit.windowStart, let end = habit.windowEnd,
                  end > now else { continue }
            // 窗口已开始，或 90 分钟内开始。
            guard start <= now || start.timeIntervalSince(now) <= Double(upcomingWindowMinutes * 60) else { continue }
            if input.postponedKeys.contains(postponeKey(for: .habit(habit.id))) { continue }
            candidates.append((
                HoloTodayFocus(
                    id: "habit:\(habit.id.uuidString)",
                    source: .habitWindow,
                    title: habit.name,
                    reasonCode: .habitWindowOpen,
                    reasonArguments: HoloTodayReasonArguments(),
                    dueAt: end,
                    severity: .normal,
                    matterID: nil,
                    action: .none
                ),
                5, start, 0, .distantPast, habit.id.uuidString
            ))
        }

        // 过滤「稍后」降级的日程/loop 候选。
        let filtered = candidates.filter { entry in
            if entry.focus.source == .currentSchedule || entry.focus.source == .upcomingSchedule,
               case .openSchedule(let id) = entry.focus.action,
               input.postponedKeys.contains(postponeKey(for: .schedule(id))) {
                return false
            }
            if entry.focus.source == .matterOpenLoop,
               let matterID = entry.focus.matterID,
               case .createTaskFromOpenLoop(_, let loopID) = entry.focus.action,
               input.postponedKeys.contains(postponeKey(for: .matterLoop(matterID: matterID, loopID: loopID))) {
                return false
            }
            return true
        }

        guard let best = filtered.min(by: { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.timeKey != rhs.timeKey { return lhs.timeKey < rhs.timeKey }
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            if lhs.matterStamp != rhs.matterStamp { return lhs.matterStamp > rhs.matterStamp }
            return lhs.stableID < rhs.stableID
        }) else { return nil }

        // 任务候选的显式优先级在同层时间相同时参与比较（重新做一次精确比较）。
        return best.focus
    }

    /// Matter 候选转换（§7.3/§7.4：去重、stale 抑制、安全降级）。
    private static func appendMatterCandidates(
        _ matter: HoloTodayMatterCandidate,
        input: HoloTodayFocusInput,
        into candidates: inout [(focus: HoloTodayFocus, tier: Int, timeKey: Date, priority: Int, matterStamp: Date, stableID: String)]
    ) {
        let tierByAttention: (HoloMatterAttention) -> Int? = { attention in
            switch attention {
            case .atRisk: return 2
            case .needsAttention: return 3
            case .waiting, .onTrack, .unknown: return nil
            }
        }
        // 只有 atRisk / needsAttention 的 Matter 才参与焦点竞争（waiting/onTrack 不制造紧迫感）。
        guard let tier = tierByAttention(matter.attention) else { return }

        let linkedTaskIDs = matter.linkedTaskIDs

        // 1) 投影 linkedTask：entityID 指向真实任务 → 转为该任务候选（附加 Matter 上下文），
        //    与 Agenda/任务候选天然去重（同实体只留一条）；任务已删 → 降级打开 Matter，不猜标题。
        if let next = matter.nextAction,
           next.sourceMatterRevision == matter.revision,
           next.kind == .linkedTask {
            if let entityID = next.entityID,
               linkedTaskIDs.contains(entityID),
               let task = input.tasks.first(where: { $0.id == entityID && !$0.isCompleted }) {
                let isPostponed = input.postponedKeys.contains(postponeKey(for: .task(task.id)))
                if !isPostponed {
                    let due = task.dueAt
                    let taskTier: Int
                    let reason: HoloTodayFocusReason
                    var args = HoloTodayReasonArguments(matterTitle: matter.title)
                    let severity: HoloTodaySeverity
                    if let due, due < input.dayStart {
                        taskTier = 2
                        reason = .overdueTask
                        severity = .risk
                    } else if let due, input.dayStart <= due, due < input.dayEnd {
                        taskTier = 3
                        reason = .dueToday
                        severity = .attention
                    } else {
                        taskTier = tier
                        reason = matter.attention == .atRisk ? .matterAtRisk : .matterNeedsAttention
                        args.daysUntilTarget = matter.targetDate.flatMap { target -> Int? in
                            Calendar(identifier: .gregorian).dateComponents(
                                [.day],
                                from: Calendar(identifier: .gregorian).startOfDay(for: input.referenceTime),
                                to: Calendar(identifier: .gregorian).startOfDay(for: target)
                            ).day
                        }
                        severity = matter.attention == .atRisk ? .risk : .attention
                    }
                    candidates.append((
                        HoloTodayFocus(
                            id: "task:\(task.id.uuidString)",
                            source: .matterLinkedTask,
                            title: task.title,
                            reasonCode: reason,
                            reasonArguments: args,
                            dueAt: due,
                            severity: severity,
                            matterID: matter.id,
                            action: .openTask(task.id)
                        ),
                        taskTier, due ?? matter.updatedAt, task.priority, matter.updatedAt, task.id.uuidString
                    ))
                }
                return
            }
            // entityID 缺失或任务已删：整体降级为打开 Matter。
            candidates.append((
                HoloTodayFocus(
                    id: "matter:\(matter.id.uuidString)",
                    source: .matterLinkedTask,
                    title: matter.title,
                    reasonCode: matter.attention == .atRisk ? .matterAtRisk : .matterNeedsAttention,
                    reasonArguments: HoloTodayReasonArguments(matterTitle: matter.title),
                    dueAt: matter.targetDate,
                    severity: matter.attention == .atRisk ? .risk : .attention,
                    matterID: matter.id,
                    action: .openMatter(matter.id, focusOpenLoopID: nil)
                ),
                tier, matter.nextAction?.targetDate ?? matter.updatedAt, 0, matter.updatedAt, matter.id.uuidString
            ))
            return
        }

        // 2) confirmed Open Loop：从确定性 loop 中选最近的（stale 投影已由调用方置 nil）。
        //    已链接任务的 loop 由任务候选表达，不重复展示同标题 loop。
        let confirmedLoops = matter.loops.filter {
            $0.epistemic == .confirmed && $0.state == .open && $0.linkedTaskID == nil
        }
        if let top = confirmedLoops.min(by: {
            ($0.targetDate ?? .distantFuture, $0.title) < ($1.targetDate ?? .distantFuture, $1.title)
        }) {
            let isPostponed = input.postponedKeys.contains(
                postponeKey(for: .matterLoop(matterID: matter.id, loopID: top.id))
            )
            if !isPostponed {
                candidates.append((
                    HoloTodayFocus(
                        id: "loop:\(top.id.uuidString)",
                        source: .matterOpenLoop,
                        title: top.title,
                        reasonCode: matter.attention == .atRisk ? .matterAtRisk : .matterNeedsAttention,
                        reasonArguments: HoloTodayReasonArguments(
                            matterTitle: matter.title,
                            daysUntilTarget: top.targetDate.flatMap { target -> Int? in
                                Calendar(identifier: .gregorian).dateComponents(
                                    [.day],
                                    from: Calendar(identifier: .gregorian).startOfDay(for: input.referenceTime),
                                    to: Calendar(identifier: .gregorian).startOfDay(for: target)
                                ).day
                            }
                        ),
                        dueAt: top.targetDate,
                        severity: matter.attention == .atRisk ? .risk : .attention,
                        matterID: matter.id,
                        action: .createTaskFromOpenLoop(matterID: matter.id, openLoopID: top.id)
                    ),
                    tier, top.targetDate ?? matter.updatedAt, 0, matter.updatedAt, top.id.uuidString
                ))
            }
            return
        }

        // 3) 无可靠动作：atRisk/needsAttention 仍给出「查看这件事」入口（不生成假任务）。
        candidates.append((
            HoloTodayFocus(
                id: "matter:\(matter.id.uuidString)",
                source: .matterOpenLoop,
                title: matter.title,
                reasonCode: matter.attention == .atRisk ? .matterAtRisk : .matterNeedsAttention,
                reasonArguments: HoloTodayReasonArguments(matterTitle: matter.title),
                dueAt: matter.targetDate,
                severity: matter.attention == .atRisk ? .risk : .attention,
                matterID: matter.id,
                action: .openMatter(matter.id, focusOpenLoopID: nil)
            ),
            tier, matter.updatedAt, 0, matter.updatedAt, matter.id.uuidString
        ))
    }
}
