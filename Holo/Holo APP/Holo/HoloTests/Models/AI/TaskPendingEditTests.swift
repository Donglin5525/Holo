//
//  TaskPendingEditTests.swift
//  HoloTests
//
//  AI 建任务确认卡就地编辑的生效值决策单测：
//  用户在卡上的覆盖（userX 键）> AI 识别 > 历史默认；
//  空提醒数组 = 显式清空（不回落默认 15 分钟）；userSubtasks 单项合法。
//

import XCTest
@testable import Holo

final class TaskPendingEditTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.locale = Locale(identifier: "zh_CN")
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - 编解码 roundtrip

    func testReminderEncodingRoundtrip() {
        let reminders = [
            TaskReminder(offsetMinutes: 15),
            TaskReminder(triggerDate: date(2026, 9, 24, 9, 0))
        ]
        let encoded = TaskPendingDefaults.encodeReminders(reminders)
        XCTAssertNotNil(encoded)
        let decoded = TaskPendingDefaults.decodeReminders(encoded)
        XCTAssertEqual(decoded?.count, 2)
        XCTAssertEqual(Set(decoded ?? []), Set(reminders))
    }

    func testDecodeEmptyArrayIsNotNone() {
        let encoded = TaskPendingDefaults.encodeReminders([])
        let decoded = TaskPendingDefaults.decodeReminders(encoded)
        XCTAssertEqual(decoded, [])
        // 区分「没编过」（nil）与「显式清空」（空数组）
        XCTAssertNil(TaskPendingDefaults.decodeReminders(nil))
    }

    // MARK: - 用户覆盖截止时间

    func testUserDueDateOverridesOriginalInputFallback() {
        // AI 给了日期没时间、原话含时间 → 历史行为是合并；但用户已改全天时必须尊重用户
        let data: [String: String] = [
            "dueDate": "2026-09-24",
            "userDueDate": "2026-09-25",
            "originalInput": "9月24日晚上9点开会"
        ]
        let effective = TaskPendingDefaults.effectiveDueDate(data: data, originalInput: data["originalInput"])
        XCTAssertNotNil(effective.dueDate)
        XCTAssertEqual(
            calendar.startOfDay(for: effective.dueDate!),
            calendar.startOfDay(for: date(2026, 9, 25))
        )
        XCTAssertFalse(effective.hasTime)
    }

    func testUserDueDateTimeFormatKeepsTime() {
        let data: [String: String] = ["userDueDate": "2026-09-25 14:30"]
        let effective = TaskPendingDefaults.effectiveDueDate(data: data, originalInput: nil)
        XCTAssertEqual(
            calendar.dateComponents([.year, .month, .day, .hour, .minute], from: effective.dueDate!),
            DateComponents(year: 2026, month: 9, day: 25, hour: 14, minute: 30)
        )
        XCTAssertTrue(effective.hasTime)
    }

    func testUserDueDateFormatParseRoundtrip() {
        let d = date(2026, 10, 1, 8, 30)
        let formatted = TaskPendingDefaults.formatUserDueDate(d, hasTime: true)
        XCTAssertEqual(formatted, "2026-10-01 08:30")
        let parsed = TaskPendingDefaults.parseUserDueDate(formatted)
        XCTAssertEqual(parsed?.date, d)
        XCTAssertEqual(parsed?.hasTime, true)

        let dayFormatted = TaskPendingDefaults.formatUserDueDate(d, hasTime: false)
        XCTAssertEqual(dayFormatted, "2026-10-01")
        let dayParsed = TaskPendingDefaults.parseUserDueDate(dayFormatted)
        XCTAssertTrue(dayParsed!.hasTime == false)
    }

    // MARK: - 提醒生效值

    func testDefaultReminderOnlyForTimedTask() {
        // 有截止时刻 → 默认提前 15 分钟
        let timed: [String: String] = ["dueDate": "2026-09-25 14:30"]
        let timedEffective = TaskPendingDefaults.effectiveReminders(
            data: timed, dueDate: date(2026, 9, 25, 14, 30), hasTime: true
        )
        XCTAssertEqual(timedEffective?.count, 1)
        XCTAssertEqual(timedEffective?.first?.offsetMinutes, 15)
        XCTAssertFalse(timedEffective?.first?.isAbsolute ?? true)

        // 全天 / 无日期 → 无默认提醒
        let allDay: [String: String] = ["dueDate": "2026-09-25"]
        let allDayEffective = TaskPendingDefaults.effectiveReminders(
            data: allDay, dueDate: date(2026, 9, 25), hasTime: false
        )
        XCTAssertNil(allDayEffective)

        let none: [String: String] = [:]
        XCTAssertNil(TaskPendingDefaults.effectiveReminders(data: none, dueDate: nil, hasTime: false))
    }

    func testUserEmptyRemindersExplicitlyClearsDefault() {
        // 用户在弹层清空全部提醒 = 显式不要提醒，即便任务带截止时刻也不回落默认
        let data: [String: String] = [
            "dueDate": "2026-09-25 14:30",
            "userReminders": TaskPendingDefaults.encodeReminders([]) ?? "[]"
        ]
        let effective = TaskPendingDefaults.effectiveReminders(
            data: data, dueDate: date(2026, 9, 25, 14, 30), hasTime: true
        )
        XCTAssertNil(effective)
    }

    func testUserEditedRemindersOverrideAI() {
        let data: [String: String] = [
            "dueDate": "2026-09-25 14:30",
            "reminderDates": "2026-09-25 09:00,2026-09-24 20:00",
            "userReminders": TaskPendingDefaults.encodeReminders([TaskReminder(offsetMinutes: 60)]) ?? "[]"
        ]
        let effective = TaskPendingDefaults.effectiveReminders(
            data: data, dueDate: date(2026, 9, 25, 14, 30), hasTime: true
        )
        XCTAssertEqual(effective?.count, 1)
        XCTAssertEqual(effective?.first?.offsetMinutes, 60)
    }

    func testAIReminderSlotsBecomeAbsoluteReminders() {
        let data: [String: String] = [
            "dueDate": "2026-09-20 09:00",
            "reminderDates": "2026-09-19 20:00,2026-09-20 08:00"
        ]
        let effective = TaskPendingDefaults.effectiveReminders(
            data: data, dueDate: date(2026, 9, 20, 9, 0), hasTime: true
        )
        XCTAssertEqual(effective?.count, 2)
        XCTAssertTrue(effective?.allSatisfy { $0.isAbsolute } ?? false)
    }

    // MARK: - 子条目

    func testUserSubtasksKeepSingleItem() {
        // AI 通道单项不算清单（历史约定）；用户编辑后单项必须保留
        let edited: [String: String] = ["userSubtasks": "买奶茶"]
        XCTAssertEqual(TaskPendingDefaults.effectiveSubtasks(data: edited), ["买奶茶"])

        let aiSingle: [String: String] = ["subtasks": "买奶茶"]
        XCTAssertEqual(TaskPendingDefaults.effectiveSubtasks(data: aiSingle), [])

        let aiMulti: [String: String] = ["subtasks": "买奶茶,买蛋糕"]
        XCTAssertEqual(TaskPendingDefaults.effectiveSubtasks(data: aiMulti), ["买奶茶", "买蛋糕"])

        let editedMulti: [String: String] = ["userSubtasks": "买奶茶\n买蛋糕\n  \n带伞"]
        XCTAssertEqual(TaskPendingDefaults.effectiveSubtasks(data: editedMulti), ["买奶茶", "买蛋糕", "带伞"])
    }

    // MARK: - 清单

    func testEffectiveListNameInboxSentinel() {
        // 用户显式选收件箱：空串哨兵归一为 nil，且 AI 的 listName 失效
        let userInbox: [String: String] = ["userListName": "", "listName": "日本旅行"]
        XCTAssertNil(TaskPendingDefaults.effectiveListName(data: userInbox))

        let userPicked: [String: String] = ["userListName": "装修", "listName": "日本旅行"]
        XCTAssertEqual(TaskPendingDefaults.effectiveListName(data: userPicked), "装修")

        let aiOnly: [String: String] = ["listName": "日本旅行"]
        XCTAssertEqual(TaskPendingDefaults.effectiveListName(data: aiOnly), "日本旅行")

        let none: [String: String] = [:]
        XCTAssertNil(TaskPendingDefaults.effectiveListName(data: none))
    }

    // MARK: - AI 通道历史行为回归（原话兜底合并）

    func testResolveDueDateMergesTimeFromOriginalInput() {
        // LLM 给日期没时间 + 原话含时间 → 合并（历史行为不变）
        let merged = TaskPendingDefaults.resolveDueDate(
            dueDateText: "2026-09-24",
            originalInput: "9月24日晚上9点开会"
        )
        XCTAssertTrue(merged.hasTime)
        XCTAssertEqual(
            calendar.startOfDay(for: merged.dueDate!),
            calendar.startOfDay(for: date(2026, 9, 24))
        )

        // LLM 完整带时间 → 直接采用
        let direct = TaskPendingDefaults.resolveDueDate(
            dueDateText: "2026-09-24 21:00",
            originalInput: nil
        )
        XCTAssertTrue(direct.hasTime)
        XCTAssertEqual(
            calendar.dateComponents([.hour, .minute], from: direct.dueDate!),
            DateComponents(hour: 21, minute: 0)
        )
    }

    // MARK: - 绝对提醒默认时刻锚定任务日

    func testDefaultAbsoluteTriggerAnchorsToTaskDay() {
        // 任务明天（9.24 全天），现在 9.23 17:45 → 默认 9.24 09:00（而非「现在+1h」响在任务日前）
        let now = date(2026, 9, 23, 17, 45)
        let anchor = date(2026, 9, 24)
        let trigger = TaskPendingDefaults.defaultAbsoluteTrigger(anchorDate: anchor, now: now)
        XCTAssertEqual(trigger, date(2026, 9, 24, 9, 0))
    }

    func testDefaultAbsoluteTriggerNextFullHourWhenNinePast() {
        // 任务就是今天且 9 点已过 → 最近整点
        let now = date(2026, 9, 23, 17, 45)
        let anchor = date(2026, 9, 23)
        let trigger = TaskPendingDefaults.defaultAbsoluteTrigger(anchorDate: anchor, now: now)
        XCTAssertEqual(trigger, date(2026, 9, 23, 18, 0))
    }

    func testDefaultAbsoluteTriggerFallsBackToNowPlusOneHourWithoutAnchor() {
        // 任务无日期 → 退回「现在+1小时」
        let now = date(2026, 9, 23, 17, 45)
        let trigger = TaskPendingDefaults.defaultAbsoluteTrigger(anchorDate: nil, now: now)
        XCTAssertEqual(trigger, date(2026, 9, 23, 18, 45))
    }

    // MARK: - 卡片工厂

    func testChatCardFactoryUsesUserOverrides() {
        let data: [String: String] = [
            "title": "请孙老师喝奶茶",
            "dueDate": "2026-09-22",
            "userDueDate": "2026-09-23 09:00",
            "userListName": "",
            "userReminders": TaskPendingDefaults.encodeReminders([TaskReminder(triggerDate: date(2026, 9, 23, 8, 30))]) ?? "[]",
            "confirmationStatus": "pending"
        ]
        guard case .task(let card)? = ChatCardData.from(
            intent: AIIntent(rawValue: "create_task")!, data: data, itemID: "item-1"
        ) else {
            return XCTFail("应解析为任务卡")
        }
        XCTAssertEqual(card.dueDate, "2026-09-23 09:00")
        XCTAssertTrue(card.hasTime)
        XCTAssertNil(card.listName)
        XCTAssertTrue(card.listChosenByUser)
        XCTAssertEqual(card.editedReminders?.count, 1)
        // 提醒显示 = 用户编辑的绝对提醒标题（不显示默认 15 分钟）
        XCTAssertEqual(card.reminderDates, card.editedReminders?.map(\.displayTitle))
        XCTAssertTrue(card.requiresConfirmation)
    }

    func testChatCardFactoryShowsDefaultReminderWhenUnedited() {
        // 带时刻任务未编辑提醒 → 卡上亮出默认「15 分钟前」（所见即所建）
        let data: [String: String] = [
            "title": "下午3点开会",
            "dueDate": "2026-09-25 15:00",
            "confirmationStatus": "pending"
        ]
        guard case .task(let card)? = ChatCardData.from(
            intent: AIIntent(rawValue: "create_task")!, data: data, itemID: nil
        ) else {
            return XCTFail("应解析为任务卡")
        }
        XCTAssertEqual(card.reminderDates, [TaskReminder(offsetMinutes: 15).displayTitle])
    }
}
