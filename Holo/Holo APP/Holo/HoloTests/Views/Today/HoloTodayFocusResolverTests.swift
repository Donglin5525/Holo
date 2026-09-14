//
//  HoloTodayFocusResolverTests.swift
//  HoloTests
//
//  「现在最值得推进」确定性排序器单测（今日看板 Matter 化方案 §7/§13.1）
//
//  覆盖：P0-P5 层级、同层 tie-break、Matter/Task 去重、stale 降级、
//  suggested 永不成为主行动、跨午夜口径、稳定 ID 序、calm state。
//

import XCTest
@testable import Holo

final class HoloTodayFocusResolverTests: XCTestCase {

    /// 固定基准时刻：2026-09-14 10:00（周一），跨午夜用例单独构造。
    private let base = date(2026, 9, 14, 10, 0)
    private lazy var dayStart = date(2026, 9, 14, 0, 0)
    private lazy var dayEnd = date(2026, 9, 15, 0, 0)

    private func makeInput(
        schedules: [HoloTodayScheduleCandidate] = [],
        tasks: [HoloTodayTaskCandidate] = [],
        matters: [HoloTodayMatterCandidate] = [],
        habits: [HoloTodayHabitWindowCandidate] = [],
        postponedKeys: Set<String> = [],
        reference: Date? = nil
    ) -> HoloTodayFocusInput {
        HoloTodayFocusInput(
            referenceTime: reference ?? base,
            dayStart: dayStart,
            dayEnd: dayEnd,
            schedules: schedules,
            tasks: tasks,
            matters: matters,
            habits: habits,
            postponedKeys: postponedKeys
        )
    }

    // MARK: P0/P1 日程

    /// 当前有正在进行的日程 → 日程为 P0，severity=risk。
    func testCurrentScheduleWinsAsP0() {
        let schedule = HoloTodayScheduleCandidate(
            id: "evt-1", title: "产品评审",
            startAt: date(2026, 9, 14, 9, 30), endAt: date(2026, 9, 14, 11, 0)
        )
        let task = HoloTodayTaskCandidate(
            id: UUID(), title: "确认签证材料", dueAt: dayEnd.addingTimeInterval(-1)
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(schedules: [schedule], tasks: [task]))
        XCTAssertNotNil(focus)
        XCTAssertEqual(focus?.source, .currentSchedule)
        XCTAssertEqual(focus?.reasonCode, .scheduleInProgress)
        XCTAssertEqual(focus?.severity, .risk)
        XCTAssertEqual(focus?.action, .openSchedule("evt-1"))
    }

    /// 80 分钟后有日程 + 普通今日任务 → 日程为 P1。
    func testUpcomingScheduleBeatsTodayTask() {
        let schedule = HoloTodayScheduleCandidate(
            id: "evt-2", title: "周会",
            startAt: base.addingTimeInterval(80 * 60), endAt: base.addingTimeInterval(100 * 60)
        )
        let task = HoloTodayTaskCandidate(
            id: UUID(), title: "回邮件", dueAt: dayEnd.addingTimeInterval(-1)
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(schedules: [schedule], tasks: [task]))
        XCTAssertEqual(focus?.source, .upcomingSchedule)
        XCTAssertEqual(focus?.reasonCode, .scheduleStartingSoon)
        XCTAssertEqual(focus?.reasonArguments.minutesUntilStart, 80)
        XCTAssertEqual(focus?.severity, .attention)
    }

    /// 窗口外（>90 分钟）的日程不进 Primary Focus。
    func testFarFutureScheduleDoesNotEnterFocus() {
        let schedule = HoloTodayScheduleCandidate(
            id: "evt-3", title: "下午的会",
            startAt: base.addingTimeInterval(4 * 3600), endAt: base.addingTimeInterval(5 * 3600)
        )
        let task = HoloTodayTaskCandidate(
            id: UUID(), title: "普通今日任务", dueAt: dayEnd.addingTimeInterval(-1)
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(schedules: [schedule], tasks: [task]))
        XCTAssertEqual(focus?.source, .todayTask)
    }

    // MARK: P2 逾期 / atRisk

    /// 已逾期任务进 P2，晚于今日任务、早于无逾期因素的 Matter。
    func testOverdueTaskIsP2() {
        let overdue = HoloTodayTaskCandidate(
            id: UUID(), title: "交房租", dueAt: date(2026, 9, 12, 12, 0)
        )
        let today = HoloTodayTaskCandidate(
            id: UUID(), title: "普通今日", dueAt: dayEnd.addingTimeInterval(-1)
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(tasks: [overdue, today]))
        XCTAssertEqual(focus?.source, .overdueTask)
        XCTAssertEqual(focus?.severity, .risk)
        XCTAssertEqual(focus?.action, .openTask(overdue.id))
    }

    /// atRisk Matter 的已确认 Open Loop 动作进 P2；suggested loop 不成为可执行主行动。
    func testAtRiskMatterConfirmedLoopEntersP2ButSuggestedDoesNot() {
        let matterID = UUID()
        let confirmedLoop = HoloTodayLoopCandidate(
            id: UUID(), title: "确认签证材料",
            state: .open, epistemic: .confirmed,
            targetDate: date(2026, 9, 10, 0, 0)
        )
        let atRiskMatter = HoloTodayMatterCandidate(
            id: matterID, title: "日本旅行",
            attention: .atRisk,
            loops: [confirmedLoop]
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(matters: [atRiskMatter]))
        XCTAssertNotNil(focus, "atRisk Matter 的 confirmed loop 应成为主行动")
        XCTAssertEqual(focus?.source, .matterOpenLoop)
        XCTAssertEqual(focus?.severity, .risk)
        XCTAssertEqual(focus?.action, .createTaskFromOpenLoop(matterID: matterID, openLoopID: confirmedLoop.id))

        // suggested 版本：同一 Matter 只有 suggested loop → 不产生可执行动作，只能打开 Matter。
        let suggestedOnly = HoloTodayMatterCandidate(
            id: matterID, title: "日本旅行",
            attention: .atRisk,
            loops: [HoloTodayLoopCandidate(
                id: UUID(), title: "换日元", state: .open, epistemic: .suggested
            )]
        )
        let suggestedFocus = HoloTodayFocusResolver.resolve(input: makeInput(matters: [suggestedOnly]))
        XCTAssertNotNil(suggestedFocus, "atRisk 但只有 suggested 时仍要给出入口")
        if case .openMatter(let id, _) = suggestedFocus?.action {
            XCTAssertEqual(id, matterID)
        } else {
            XCTFail("suggested loop 只允许降级为打开 Matter，实际 \(String(describing: suggestedFocus?.action))")
        }
        if case .createTaskFromOpenLoop = suggestedFocus?.action {
            XCTFail("suggested loop 不得直接生成建任务动作")
        }
    }

    /// suggestion 类型 Next Action 未经确认不得成为主行动。
    func testSuggestionNextActionNeverExecutable() {
        let matterID = UUID()
        let matter = HoloTodayMatterCandidate(
            id: matterID, title: "发布",
            attention: .needsAttention,
            nextAction: HoloTodayMatterActionCandidate(
                kind: .suggestion, entityID: nil, title: "写更新说明",
                sourceMatterRevision: 3
            )
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(matters: [matter]))
        if let action = focus?.action, case .createTaskFromOpenLoop = action {
            XCTFail("suggestion 不得直接执行")
        }
        if case .openTask = focus?.action {
            XCTFail("suggestion 无真实 entityID，不得伪装为已存在任务")
        }
    }

    /// stale 投影（sourceRevision < 当前 revision）的 nextAction 禁止进入候选。
    func testStaleProjectionNextActionSuppressed() {
        let matterID = UUID()
        let stale = HoloTodayMatterCandidate(
            id: matterID, title: "日本旅行", revision: 7,
            attention: .needsAttention,
            loops: [HoloTodayLoopCandidate(
                id: UUID(), title: "确认签证材料", state: .open, epistemic: .confirmed,
                targetDate: base.addingTimeInterval(3 * 86400)
            )],
            // 投影基于 revision 3，已过期 → nextAction 不得采用
            nextAction: HoloTodayMatterActionCandidate(
                kind: .openLoopAction, entityID: UUID(), title: "已过期的旧动作",
                sourceMatterRevision: 3
            )
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(matters: [stale]))
        XCTAssertEqual(focus?.title, "确认签证材料", "stale 投影抑制后用确定性 loop 重建候选")
        XCTAssertEqual(focus?.source, .matterOpenLoop)
    }

    // MARK: 去重

    /// Matter linkedTask 指向今日真实任务 → 只出现一条 task 候选，并附加 Matter 上下文。
    func testLinkedTaskDeduplicatesAgainstTaskCandidate() {
        let matterID = UUID()
        let taskID = UUID()
        let task = HoloTodayTaskCandidate(
            id: taskID, title: "确认签证材料",
            dueAt: dayEnd.addingTimeInterval(-1),
            matterID: matterID, matterTitle: "日本旅行"
        )
        let matter = HoloTodayMatterCandidate(
            id: matterID, title: "日本旅行",
            revision: 5,
            attention: .needsAttention,
            nextAction: HoloTodayMatterActionCandidate(
                kind: .linkedTask, entityID: taskID, title: "确认签证材料",
                sourceMatterRevision: 5
            ),
            linkedTaskIDs: [taskID]
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(tasks: [task], matters: [matter]))
        // 同实体只留一条：候选来自 Matter linkedTask 投影，但动作直达真实任务并保留 Matter 归属。
        XCTAssertEqual(focus?.source, .matterLinkedTask)
        XCTAssertEqual(focus?.action, .openTask(taskID))
        XCTAssertEqual(focus?.matterID, matterID, "task 候选保留 Matter 归属")
    }

    /// linked task 已删除（entityID 解析不到）→ 不猜标题，降级为打开 Matter。
    func testDanglingLinkedTaskFallsBackToOpenMatter() {
        let matterID = UUID()
        let deletedTaskID = UUID()
        let matter = HoloTodayMatterCandidate(
            id: matterID, title: "日本旅行",
            revision: 5,
            attention: .needsAttention,
            nextAction: HoloTodayMatterActionCandidate(
                kind: .linkedTask, entityID: deletedTaskID, title: "确认签证材料",
                sourceMatterRevision: 5
            ),
            linkedTaskIDs: [] // 任务已删：links 为空
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(matters: [matter]))
        XCTAssertEqual(focus?.action, .openMatter(matterID, focusOpenLoopID: nil), "降级为打开 Matter，不生成假任务")
    }

    /// 标题相同但 ID 不同：不合并，各自是独立候选。
    func testSameTitleDifferentIDNotMerged() {
        let taskA = HoloTodayTaskCandidate(
            id: UUID(), title: "确认签证材料", dueAt: date(2026, 9, 12, 0, 0)
        )
        let taskB = HoloTodayTaskCandidate(
            id: UUID(), title: "确认签证材料", dueAt: dayEnd.addingTimeInterval(-1)
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(tasks: [taskA, taskB]))
        XCTAssertEqual(focus?.title, "确认签证材料")
        XCTAssertEqual(focus?.action, .openTask(taskA.id), "同标题不合并：逾期者（P2）胜出")
    }

    // MARK: P3/P4/P5

    /// 今日到期任务（P3）在无更高层候选时胜出。
    func testDueTodayTaskIsP3() {
        let task = HoloTodayTaskCandidate(id: UUID(), title: "回邮件", dueAt: dayEnd.addingTimeInterval(-1))
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(tasks: [task]))
        XCTAssertEqual(focus?.source, .todayTask)
        XCTAssertEqual(focus?.reasonCode, .dueToday)
        XCTAssertEqual(focus?.severity, .attention)
    }

    /// 用户明确加入今日的无时间任务（P4）。
    func testPlannedTodayNoTimeTaskIsP4() {
        let task = HoloTodayTaskCandidate(
            id: UUID(), title: "整理行李清单", dueAt: nil, plannedForToday: true
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(tasks: [task]))
        XCTAssertEqual(focus?.source, .todayTask)
        XCTAssertEqual(focus?.reasonCode, .plannedToday)
        XCTAssertEqual(focus?.severity, .normal)
    }

    /// 有明确时间窗口的未完成习惯（P5），且不与更高层竞争。
    func testHabitWindowIsP5AndLosesToSchedule() {
        let habit = HoloTodayHabitWindowCandidate(
            id: UUID(), name: "晚间阅读",
            windowStart: date(2026, 9, 14, 21, 0), windowEnd: date(2026, 9, 14, 23, 0)
        )
        let schedule = HoloTodayScheduleCandidate(
            id: "evt-9", title: "进行中的会",
            startAt: date(2026, 9, 14, 9, 0), endAt: date(2026, 9, 14, 10, 30)
        )
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(schedules: [schedule], habits: [habit]))
        XCTAssertEqual(focus?.source, .currentSchedule)

        // 窗口临近（20:30，距 21:00 开窗 30 分钟）时习惯才进入焦点。
        let nearWindow = date(2026, 9, 14, 20, 30)
        let habitOnly = HoloTodayFocusResolver.resolve(
            input: makeInput(habits: [habit], reference: nearWindow)
        )
        XCTAssertEqual(habitOnly?.source, .habitWindow)
        XCTAssertEqual(habitOnly?.reasonCode, .habitWindowOpen)
    }

    /// 无时间窗口的习惯不进 Primary Focus。
    func testHabitWithoutWindowDoesNotEnterFocus() {
        let habit = HoloTodayHabitWindowCandidate(id: UUID(), name: "喝水", windowStart: nil, windowEnd: nil)
        let focus = HoloTodayFocusResolver.resolve(input: makeInput(habits: [habit]))
        XCTAssertNil(focus)
    }

    // MARK: 稍后降级

    /// 本会话点过「稍后」的同一候选被降级（仅会话级）。
    func testPostponedCandidateIsDemotedForSession() {
        let taskA = HoloTodayTaskCandidate(id: UUID(), title: "第一优先", dueAt: date(2026, 9, 12, 0, 0))
        let taskB = HoloTodayTaskCandidate(id: UUID(), title: "第二优先", dueAt: dayEnd.addingTimeInterval(-1))
        let key = HoloTodayFocusResolver.postponeKey(for: .task(taskA.id))
        let focus = HoloTodayFocusResolver.resolve(
            input: makeInput(tasks: [taskA, taskB], postponedKeys: [key])
        )
        XCTAssertEqual(focus?.action, .openTask(taskB.id), "稍后的候选让位给次优")
    }

    // MARK: tie-break 稳定序

    /// 两个候选所有字段相同 → 稳定 ID 字典序保证同输入同输出。
    func testStableIDTieBreak() {
        let idA = UUID(uuidString: "aaaaaaaa-0000-0000-0000-000000000000")!
        let idB = UUID(uuidString: "bbbbbbbb-0000-0000-0000-000000000000")!
        let taskA = HoloTodayTaskCandidate(id: idA, title: "甲", dueAt: dayEnd.addingTimeInterval(-1))
        let taskB = HoloTodayTaskCandidate(id: idB, title: "乙", dueAt: dayEnd.addingTimeInterval(-1))

        // 两种输入顺序都要产出同一结果。
        let first = HoloTodayFocusResolver.resolve(input: makeInput(tasks: [taskA, taskB]))
        let second = HoloTodayFocusResolver.resolve(input: makeInput(tasks: [taskB, taskA]))
        XCTAssertEqual(first, second)
        XCTAssertEqual(first?.action, .openTask(idA), "同字段按稳定 ID 字典序")
    }

    /// 同层内 dueAt 更早者优先；同 dueAt 任务显式优先级更高者胜。
    func testDueEarlierAndHigherPriorityWin() {
        let later = HoloTodayTaskCandidate(id: UUID(), title: "晚到期", dueAt: dayEnd.addingTimeInterval(-3600))
        let earlier = HoloTodayTaskCandidate(id: UUID(), title: "早到期", dueAt: dayEnd.addingTimeInterval(-7200))
        XCTAssertEqual(
            HoloTodayFocusResolver.resolve(input: makeInput(tasks: [later, earlier]))?.action,
            .openTask(earlier.id)
        )

        let low = HoloTodayTaskCandidate(
            id: UUID(), title: "低优先", dueAt: dayEnd.addingTimeInterval(-3600), priority: 0
        )
        let high = HoloTodayTaskCandidate(
            id: UUID(), title: "高优先", dueAt: dayEnd.addingTimeInterval(-3600), priority: 2
        )
        XCTAssertEqual(
            HoloTodayFocusResolver.resolve(input: makeInput(tasks: [low, high]))?.action,
            .openTask(high.id)
        )
    }

    // MARK: 跨午夜

    /// referenceTime 临近午夜：候选分类全部以同一 day interval 为准。
    func testNearMidnightUsesFrozenDayInterval() {
        let lateNight = date(2026, 9, 14, 23, 50)
        let start = date(2026, 9, 14, 0, 0)
        let end = date(2026, 9, 15, 0, 0)
        // 今日 23:55 到期 → 仍属今日（P3），不因临近午夜漂移成逾期。
        let task = HoloTodayTaskCandidate(
            id: UUID(), title: "睡前吃药", dueAt: start.addingTimeInterval(23 * 3600 + 55 * 60)
        )
        let input = HoloTodayFocusInput(
            referenceTime: lateNight, dayStart: start, dayEnd: end,
            tasks: [task]
        )
        let focus = HoloTodayFocusResolver.resolve(input: input)
        XCTAssertEqual(focus?.reasonCode, .dueToday)
        XCTAssertEqual(focus?.source, .todayTask)
    }

    // MARK: calm state

    /// 无任何候选 → primaryFocus=nil。
    func testNoCandidatesYieldsCalmState() {
        XCTAssertNil(HoloTodayFocusResolver.resolve(input: makeInput()))
    }

    /// 已完成/全 suggested 的输入不产生伪焦点。
    func testCompletedTasksAndSuggestedLoopsOnlyYieldCalmState() {
        let done = HoloTodayTaskCandidate(
            id: UUID(), title: "已完成", dueAt: dayEnd.addingTimeInterval(-1), isCompleted: true
        )
        let matter = HoloTodayMatterCandidate(
            id: UUID(), title: "旅行",
            attention: .onTrack,
            loops: [HoloTodayLoopCandidate(
                id: UUID(), title: "建议", state: .open, epistemic: .suggested
            )]
        )
        XCTAssertNil(HoloTodayFocusResolver.resolve(input: makeInput(tasks: [done], matters: [matter])))
    }
}

// MARK: - Helpers

private func date(_ y: Int, _ m: Int, _ d: Int, _ hh: Int, _ mm: Int) -> Date {
    var comps = DateComponents()
    comps.year = y; comps.month = m; comps.day = d; comps.hour = hh; comps.minute = mm
    return Calendar(identifier: .gregorian).date(from: comps)!
}
