//
//  HabitReminderContentTests.swift
//  HoloTests
//
//  习惯打卡提醒文案纯函数单测（2026-10-09 方案A改版）：
//  濒危 streak 习惯打头说透「别断」赌注，其余点名兜后，头名自身不重复进名单；
//  streak 不足 2 天时保持纯名单。排序并列会造成输出不确定，用例一律全序数据。
//

import XCTest
import CoreData
@testable import Holo

@MainActor
final class HabitReminderContentTests: XCTestCase {

    private func habit(_ name: String, streak: Int) -> (name: String, streak: Int) {
        (name: name, streak: streak)
    }

    // MARK: - 提醒保存失败与重试（2026-10-14）

    private func makeReminderHabit() throws -> (Habit, NSManagedObjectContext) {
        let context = CoreDataTestSupport.sharedTestContainer.viewContext
        try CoreDataTestSupport.clearEntities(context, ["HabitRecord", "Habit"])
        let habit = Habit.create(in: context, name: "提醒测试", icon: "book.fill", color: "#F46D38", type: .checkIn, frequency: .daily, targetCount: 1)
        try context.save()
        return (habit, context)
    }

    func testReminderSaveFailureRestoresOnlyReminderFields() throws {
        let (habit, _) = try makeReminderHabit()
        let oldMode = habit.habitReminderMode
        let oldTime = habit.reminderTime
        let oldUpdatedAt = habit.updatedAt
        habit.name = "其他未保存编辑"
        XCTAssertThrowsError(try HabitReminderCommit.apply(habit, mode: .solo, time: (21, 30)) { habit, updates in
            habit.habitReminderMode = updates.reminderMode ?? .follow
            habit.reminderTime = updates.reminderTime ?? (9, 0)
            habit.updatedAt = Date()
            throw URLError(.cannotWriteToFile)
        })
        XCTAssertEqual(habit.habitReminderMode, oldMode)
        XCTAssertEqual(habit.reminderTime.hour, oldTime.hour)
        XCTAssertEqual(habit.reminderTime.minute, oldTime.minute)
        XCTAssertEqual(habit.updatedAt, oldUpdatedAt)
        XCTAssertEqual(habit.name, "其他未保存编辑")
    }

    func testReminderSuccessfulRetryPersistsSelectedTime() throws {
        let (habit, context) = try makeReminderHabit()
        try HabitReminderCommit.apply(habit, mode: .solo, time: (21, 30)) { habit, updates in
            habit.habitReminderMode = updates.reminderMode ?? .follow
            habit.reminderTime = updates.reminderTime ?? (9, 0)
            try context.save()
        }
        context.refresh(habit, mergeChanges: false)
        XCTAssertEqual(habit.habitReminderMode, .solo)
        XCTAssertEqual(habit.reminderTime.hour, 21)
        XCTAssertEqual(habit.reminderTime.minute, 30)
    }

    // MARK: - 空与单习惯

    func testEmptyPendingReturnsNil() {
        XCTAssertNil(HabitReminderScheduler.reminderContent(pending: []))
    }

    func testSingleHabitWithoutStreak() {
        let c = HabitReminderScheduler.reminderContent(pending: [habit("阅读", streak: 0)])!
        XCTAssertEqual(c.title, "阅读还没打卡")
        XCTAssertEqual(c.body, "睡前一分钟，完成今天的打卡")
    }

    func testSingleHabitWithStreakSaysDontBreak() {
        let c = HabitReminderScheduler.reminderContent(pending: [habit("健身", streak: 3)])!
        XCTAssertEqual(c.title, "健身还没打卡")
        XCTAssertEqual(c.body, "已连续打卡 3 天，今天别断了")
    }

    // MARK: - 多习惯（streak 打头）

    func testMultiHabitLeadsWithAtRiskStreak() {
        let c = HabitReminderScheduler.reminderContent(pending: [
            habit("英语对话学习", streak: 1),
            habit("摩卡刷牙", streak: 2),
            habit("健身", streak: 3),
            habit("喝水", streak: 0),
        ])!
        XCTAssertEqual(c.title, "4 个习惯还没打卡")
        XCTAssertEqual(c.body, "健身已连续打卡 3 天，今天别断 · 还有摩卡刷牙、英语对话学习等 3 个")
    }

    func testMultiHabitWithSingleRestHasNoCountSuffix() {
        let c = HabitReminderScheduler.reminderContent(pending: [
            habit("健身", streak: 3),
            habit("阅读", streak: 0),
        ])!
        XCTAssertEqual(c.title, "2 个习惯还没打卡")
        XCTAssertEqual(c.body, "健身已连续打卡 3 天，今天别断 · 还有阅读")
    }

    func testStreakHabitNotRepeatedInRestList() {
        let c = HabitReminderScheduler.reminderContent(pending: [
            habit("健身", streak: 5),
            habit("阅读", streak: 4),
            habit("喝水", streak: 2),
        ])!
        XCTAssertEqual(c.title, "3 个习惯还没打卡")
        XCTAssertEqual(c.body, "健身已连续打卡 5 天，今天别断 · 还有阅读、喝水等 2 个")
    }

    func testMultiHabitWithoutStreakKeepsPlainList() {
        let c = HabitReminderScheduler.reminderContent(pending: [
            habit("阅读", streak: 0),
            habit("喝水", streak: 1),
            habit("冥想", streak: 0),
        ])!
        XCTAssertEqual(c.body, "阅读、喝水 等 3 个")
    }
}
